app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "../../package/main.roc",
}

import fuzz.Fuzz
import zip.Zip

## An archive `Zip.create` wrote, with up to eight bytes overwritten, and a
## per-entry limit of `limit × 64` bytes. `content` is written
## `repeat % 8 + 1` times. A nonzero `zeros` adds an entry of `zeros × 16`
## zero bytes, which compresses well. The bombs target covers large entries.
Input := {
	files : List({ content : List(U8), repeat : U8 }),
	compression : U8,
	zeros : U8,
	edits : List({ at : U16, value : U8 }),
	limit : U16,
}.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			files: Fuzz.list({ content: Fuzz.bytes, repeat: Fuzz.u8 }.Fuzz, 6),
			compression: Fuzz.u8,
			zeros: Fuzz.u8,
			edits: Fuzz.list({ at: Fuzz.map(Fuzz.u64_in(0, 65535), |n| n.to_u16_wrap()), value: Fuzz.u8 }.Fuzz, 8),
			limit: Fuzz.map(Fuzz.u64_in(0, 65535), |n| n.to_u16_wrap()),
		}.Fuzz
	}
}

## Every entry `Zip.entries` lists extracts to `Ok` or a structured `Err`,
## never a crash: an entry that declares more than the limit is
## `EntryTooLarge`, and extracted content is exactly its declared size and
## what `Zip.extract` gives for it. An unedited archive extracts to its
## entries. Copying every entry through `Zip.compressed` and `Copied` gives an
## archive with the same index, the same data bytes and the same content.
##
## Memory ratchets, which only ever move down: one entry's extraction holds
## at most the decoder's state plus the entry's declared size (nothing for a
## stored entry, which is a slice of the archive, or one over its limit),
## and an entry with a truthful declared size is never reallocated.
test! : Input => Fuzz.Outcome
test! = |input| {
	entries = input_entries(input)
	original = Zip.create(entries, compression_of(input.compression)) ?? crash "create refused distinct, nonempty paths"
	archive = input.edits.fold(original, |bytes, edit| bytes.set(edit.at.to_u64() % bytes.len(), edit.value) ?? bytes)
	extracted = Zip.extract(archive)
	if input.edits.is_empty() and extracted != Ok(entries) {
		crash "an unedited archive does not extract to its entries"
	}
	max_bytes = input.limit.to_u64() * 64
	match Zip.entries(archive) {
		Err(_) => Fuzz.keep
		Ok(index) => {
			for entry in index {
				check_entry!(archive, entry, max_bytes, extracted)
			}
			check_copy!(archive, index, extracted)
			Fuzz.keep
		}
	}
}

check_entry! : List(U8), Zip.Entry, U64, Try(List(Zip.ZipEntry), Zip.ExtractError) => {}
check_entry! = |archive, entry, max_bytes, extracted| {
	declared = entry.uncompressed_size
	{ value: result, stats } = Fuzz.measure!("extract-entry", || Zip.extract_entry(archive, entry, { max_bytes: max_bytes }))
	live = stats.peak_live_bytes - stats.entry_live_bytes
	reserved = if entry.method == Deflated and declared <= max_bytes {
		declared
	} else {
		0
	}
	if live > decoder_state + reserved {
		crash "extracting an entry held ${live.to_str()} bytes live, declaring ${declared.to_str()}"
	}
	match result {
		Err(EntryTooLarge(_)) if declared > max_bytes => {}
		_ if declared > max_bytes => crash "an entry over its limit was not EntryTooLarge"
		Ok(content) => {
			if content.len() != declared {
				crash "extracted content is not its declared size"
			}
			if entry.method == Deflated and stats.reallocs > 0 {
				crash "an entry with a truthful declared size was reallocated"
			}
			match extracted {
				Ok(all) =>
					if all.find_first(|candidate| candidate.path == entry.path).map_ok(|found| found.content) != Ok(content) {
						crash "extract_entry and extract disagree"
					}
				Err(_) => {}
			}
		}
		Err(_) => {}
	}
}

check_copy! : List(U8), List(Zip.Entry), Try(List(Zip.ZipEntry), Zip.ExtractError) => {}
check_copy! = |archive, index, extracted| {
	var $writer = Zip.writer({})
	var $copy = []
	for entry in index {
		match Zip.compressed(archive, entry) {
			Ok(stored) => {
				match Zip.add($writer, Copied(stored)) {
					Ok(added) => {
						$copy = $copy.concat(added.chunk)
						$writer = added.writer
					}
					# An archive can hold an empty path, which a writer refuses.
					Err(EmptyPath(_)) => return {}
					Err(err) => crash "add refused a copied entry: ${Str.inspect(err)}"
				}
			}
			# A stored entry whose sizes disagree is not copied.
			Err(_) => return {}
		}
	}
	copy = $copy.concat(Zip.finish($writer))
	copy_index = Zip.entries(copy) ?? crash "a copy does not list"
	same = |entry| { path: entry.path, method: entry.method, crc: entry.crc, compressed_size: entry.compressed_size, uncompressed_size: entry.uncompressed_size }
	if copy_index.map(same) != index.map(same) {
		crash "a copy's index differs from its source's"
	}
	if copy_index.map(|entry| data(copy, entry)) != index.map(|entry| data(archive, entry)) {
		crash "a copy's data bytes differ from its source's"
	}
	if Zip.extract(copy) != extracted {
		crash "a copy extracts differently from its source"
	}
}

data : List(U8), Zip.Entry -> List(U8)
data = |archive, entry| archive.sublist({ start: entry.data_offset, len: entry.compressed_size })

# Measured on nightly-2026-11-07-ad3a5d2 with roc-fuzz 0.5.0: the decode
# tables, rebuilt per call.
decoder_state : U64
decoder_state = 16_384

input_entries : Input -> List(Zip.ZipEntry)
input_entries = |input| {
	files = input.files.map_with_index(|file, i| { path: "f${i.to_str()}.xml", content: List.repeat(file.content, (file.repeat % 8).to_u64() + 1).join() })
	zeros_len = input.zeros.to_u64() * 16
	if zeros_len == 0 {
		files
	} else {
		files.append({ path: "zeros.bin", content: List.repeat(0, zeros_len) })
	}
}

compression_of : U8 -> Zip.Compression
compression_of = |n|
	match n % 4 {
		0 => None
		1 => Fastest
		2 => Balanced
		_ => Smallest
	}

target = Fuzz.target_with!({
	name: "extract-entry",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || Input.{ files: [], compression: 0, zeros: 0, edits: [], limit: 0 } }),
		Fuzz.example({ name: "text-and-zeros", revision: "1", make: || Input.{ files: [{ content: "<w:p>the cat sat on the mat</w:p>".to_utf8(), repeat: 7 }, { content: [1, 2, 3], repeat: 0 }], compression: 1, zeros: 40, edits: [], limit: 65535 } }),
		# A stored entry claiming 4 KiB more than it holds: the local record
		# is 30 + 6 + 3 bytes, and byte 64 is the second byte of the central
		# record's uncompressed size, 24 bytes into it.
		Fuzz.example({ name: "overstated-size", revision: "1", make: || Input.{ files: [{ content: "abc".to_utf8(), repeat: 0 }], compression: 0, zeros: 0, edits: [{ at: 64, value: 0x10 }], limit: 65535 } }),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
