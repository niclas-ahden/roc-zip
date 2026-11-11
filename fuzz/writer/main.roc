app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "../../package/main.roc",
}

import fuzz.Fuzz
import zip.Zip

## One generated file. `name` picks a path from a small set, so paths repeat
## often, or, from 240 up, uses `raw_path` as written, which may be empty or
## any UTF-8. `content` is written `repeat % 8 + 1` times, so DEFLATE finds
## matches.
File : { name : U8, raw_path : Str, content : List(U8), repeat : U8 }

Input := { files : List(File), compression : U8 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		file = {
			name: Fuzz.u8,
			raw_path: Fuzz.str,
			content: Fuzz.bytes,
			repeat: Fuzz.u8,
		}.Fuzz
		{ files: Fuzz.list(file, 8), compression: Fuzz.u8 }.Fuzz
	}
}

## `Zip.create` fails exactly when a path is empty, too long or repeated,
## naming the first such path, and otherwise gives the same bytes twice,
## the bytes a writer's chunks and last chunk add up to, and an archive that
## extracts to its entries. No local header sets general purpose bit 3, and
## an entry is deflated only when that is smaller.
##
## Memory ratchets, which only ever move down: a writer whose chunks are
## dropped holds at most the compressor's state plus a multiple of the largest
## entry, and `create` requests at most the compressor's state per entry plus
## multiples of its input and output.
test! : Input => Fuzz.Outcome
test! = |input| {
	compression = compression_of(input.compression)
	entries = input.files.map(to_entry)
	for entry in entries {
		_ = Zip.is_safe_path(entry.path)
	}
	{ value: created, stats: create_stats } = Fuzz.measure!("create", || Zip.create(entries, compression))
	if created != Zip.create(entries, compression) {
		crash "creating the same entries twice disagreed"
	}
	match (created, first_invalid_path(entries)) {
		(Err(err), Err(expected)) if err == expected => Fuzz.keep
		(Err(_), _) => crash "create failed with the wrong error"
		(Ok(_), Err(_)) => crash "create accepted an invalid path"
		(Ok(archive), Ok({})) => {
			input_len = entries.fold(0, |total, entry| total + entry.content.len())
			if create_stats.requested_bytes > create_ceiling(entries.len(), input_len, archive.len(), compression) {
				crash "create requested ${create_stats.requested_bytes.to_str()} bytes for a ${archive.len().to_str()} byte archive"
			}
			check_writer!(entries, compression, archive)
			if Zip.extract(archive) != Ok(entries) {
				crash "the archive does not extract to its entries"
			}
			index = Zip.entries(archive) ?? crash "the archive does not list"
			var $at = 0
			for entry in index {
				flags = u16_at(archive, $at + 6)
				if flags.bitwise_and(0x0008) != 0 {
					crash "a local header sets general purpose bit 3"
				}
				deflated = entry.method == Deflated
				if deflated != (entry.compressed_size < entry.uncompressed_size) or (compression == None and deflated) {
					crash "an entry's method does not follow from its sizes"
				}
				$at = entry.data_offset + entry.compressed_size
			}
			Fuzz.keep
		}
	}
}

# The writer's chunks, then its last one, are the archive. A second pass
# drops each chunk as it comes, the way a writer feeding a file runs.
check_writer! : List(Zip.ZipEntry), Zip.Compression, List(U8) => {}
check_writer! = |entries, compression, archive| {
	var $writer = Zip.writer({ compression: compression })
	var $written = []
	for entry in entries {
		added = Zip.add($writer, Content(entry)) ?? crash "add refused an entry create accepted"
		$written = $written.concat(added.chunk)
		$writer = added.writer
	}
	if $written.concat(Zip.finish($writer)) != archive {
		crash "the writer's chunks are not the archive create made"
	}
	largest = entries.fold(0, |most, entry| most.max(entry.content.len()))
	{ value: total, stats } = Fuzz.measure!(
		"writer",
		|| {
			var $streaming = Zip.writer({ compression: compression })
			var $total = 0
			for entry in entries {
				added = Zip.add($streaming, Content(entry)) ?? crash "add refused an entry create accepted"
				$total = $total + added.chunk.len()
				$streaming = added.writer
			}
			$total + Zip.finish($streaming).len()
		},
	)
	if total != archive.len() {
		crash "the dropped chunks do not add up to the archive"
	}
	live = stats.peak_live_bytes - stats.entry_live_bytes
	if live > writer_ceiling(largest, archive.len(), compression) {
		crash "the writer held ${live.to_str()} bytes live, with a ${largest.to_str()} byte largest entry"
	}
}

# Measured on nightly-2026-11-07-ad3a5d2 with roc-fuzz 0.5.0. The constant is
# the compressor's fixed state at that level, which each entry allocates
# afresh and frees. Past it, the compressor's buffers grow with the entry it
# compresses, and the output with the archive.
writer_ceiling : U64, U64, Zip.Compression -> U64
writer_ceiling = |largest, archive_len, compression|
	compressor_state(compression) + 32 * largest + archive_len

create_ceiling : U64, U64, U64, Zip.Compression -> U64
create_ceiling = |count, input_len, archive_len, compression|
	1024 + count * compressor_state(compression) + 32 * input_len + 2 * archive_len

compressor_state : Zip.Compression -> U64
compressor_state = |compression|
	match compression {
		None => 1024
		Fastest => 190_000
		Balanced => 330_000
		Smallest => 700_000
	}

compression_of : U8 -> Zip.Compression
compression_of = |n|
	match n % 4 {
		0 => None
		1 => Fastest
		2 => Balanced
		_ => Smallest
	}

to_entry : File -> Zip.ZipEntry
to_entry = |file| {
	path = if file.name >= 240 {
		file.raw_path
	} else {
		"d${(file.name % 3).to_str()}/f${(file.name % 7).to_str()}.txt"
	}
	content = List.repeat(file.content, (file.repeat % 8).to_u64() + 1).join()
	{ path, content }
}

# The error create should give: the first path that is empty, too long or
# already used.
first_invalid_path : List(Zip.ZipEntry) -> Try({}, Zip.CreateError)
first_invalid_path = |entries| {
	var $seen = Set.empty()
	for entry in entries {
		if entry.path.is_empty() {
			return Err(EmptyPath(entry.path))
		}
		if entry.path.count_utf8_bytes() > 65535 {
			return Err(PathTooLong(entry.path))
		}
		if $seen.contains(entry.path) {
			return Err(DuplicatePath(entry.path))
		}
		$seen = $seen.insert(entry.path)
	}
	Ok({})
}

u16_at : List(U8), U64 -> U16
u16_at = |bytes, at| (bytes.get(at) ?? 0).to_u16() + (bytes.get(at + 1) ?? 0).to_u16().shl_wrap(8)

file : U8, Str, U8 -> File
file = |name, text, repeat| { name, raw_path: "", content: text.to_utf8(), repeat }

target = Fuzz.target_with!({
	name: "writer",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || Input.{ files: [], compression: 0 } }),
		Fuzz.example({ name: "text-every-level", revision: "1", make: || Input.{ files: [file(0, "the cat sat on the mat, and then the cat sat again. ", 7), file(1, "", 0), file(2, "x", 0)], compression: 2 } }),
		Fuzz.example({ name: "smallest", revision: "1", make: || Input.{ files: [file(0, "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabc", 7)], compression: 3 } }),
		Fuzz.example({ name: "duplicate", revision: "1", make: || Input.{ files: [file(0, "a", 0), file(1, "b", 0), file(21, "c", 0)], compression: 1 } }),
		Fuzz.example({ name: "empty-path", revision: "1", make: || Input.{ files: [file(0, "a", 0), file(250, "b", 0)], compression: 0 } }),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
