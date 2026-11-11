app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "../../package/main.roc",
}

import fuzz.Fuzz
import zip.Zip

## Any bytes give `Ok` or a structured `Err` from `Zip.entries`, never a
## crash, and the same answer twice. A listed index names every entry once
## and locates data inside the archive. Where `Zip.extract` also succeeds it
## agrees with the index on paths, order and sizes. Copying every entry
## through `Zip.compressed` and `Copied` never crashes, and the copy lists
## the same entries.
##
## Memory ratchet, which only ever moves down: listing holds at most
## `C + k × input` bytes live, however large the sizes the entries declare.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	{ value: first, stats } = Fuzz.measure!("entries", || Zip.entries(bytes))
	live = stats.peak_live_bytes - stats.entry_live_bytes
	if live > memory_ceiling(bytes.len()) {
		crash "Zip.entries held ${live.to_str()} bytes live for a ${bytes.len().to_str()} byte input"
	}
	if first != Zip.entries(bytes) {
		crash "listing the same bytes twice disagreed"
	}
	match first {
		Ok(index) => {
			paths = index.map(|entry| entry.path)
			if Set.from_list(paths).len() != paths.len() {
				crash "the index repeats a path"
			}
			if index.any(|entry| entry.data_offset + entry.compressed_size > bytes.len()) {
				crash "an entry's data lies outside the archive"
			}
			match Zip.extract(bytes) {
				Ok(extracted) => {
					if extracted.map(|entry| entry.path) != paths {
						crash "extract and entries disagree on paths"
					}
					if extracted.map(|entry| entry.content.len()) != index.map(|entry| entry.uncompressed_size) {
						crash "extract and entries disagree on sizes"
					}
				}
				Err(_) => {}
			}
			check_copy!(bytes, index)
			Fuzz.keep
		}
		Err(_) => Fuzz.keep
	}
}

check_copy! : List(U8), List(Zip.Entry) => {}
check_copy! = |bytes, index| {
	var $writer = Zip.writer({})
	var $copy = []
	for entry in index {
		match Zip.compressed(bytes, entry) {
			Ok(stored) =>
				match Zip.add($writer, Copied(stored)) {
					Ok(added) => {
						$copy = $copy.concat(added.chunk)
						$writer = added.writer
					}
					# An archive can hold an empty path, which a writer refuses.
					Err(EmptyPath(_)) => return {}
					Err(_) => crash "add refused a copied entry for a reason other than its path"
				}
			Err(_) => return {}
		}
	}
	copy = $copy.concat(Zip.finish($writer))
	same = |entry| { path: entry.path, method: entry.method, crc: entry.crc, compressed_size: entry.compressed_size, uncompressed_size: entry.uncompressed_size }
	match Zip.entries(copy) {
		Ok(copied) if copied.map(same) == index.map(same) => {}
		_ => crash "a copy does not list the entries it copied"
	}
}

# Measured on nightly-2026-11-07-ad3a5d2 with roc-fuzz 0.5.0.
memory_ceiling : U64 -> U64
memory_ceiling = |input_bytes| 1024 + 8 * input_bytes

# An archive of 16 empty entries whose central directory records each declare
# 1 GiB. The index is the same size as for the truthful archive.
declares_gigabytes : () -> List(U8)
declares_gigabytes = || {
	count = 16
	archive = Zip.create(List.repeat({}, count).map_with_index(|_, i| { path: "part${i.to_str()}.xml", content: [] }), None) ?? crash "the paths are valid"
	# The end record gives the central directory's offset 16 bytes in. Each
	# record Zip.create writes is 46 bytes and the name.
	directory = u32_at(archive, archive.len() - 22 + 16)
	var $bytes = archive
	var $at = directory
	var $i = 0
	while $i < count {
		# The uncompressed size sits 24 bytes into the record, the name
		# length 28.
		$bytes = set_u32(set_u32($bytes, $at + 24, 0x40000000), $at + 20, 0)
		$at = $at + 46 + u16_at($bytes, $at + 28)
		$i = $i + 1
	}
	$bytes
}

u16_at : List(U8), U64 -> U64
u16_at = |bytes, at| (bytes.get(at) ?? 0).to_u64() + (bytes.get(at + 1) ?? 0).to_u64().shl_wrap(8)

u32_at : List(U8), U64 -> U64
u32_at = |bytes, at| u16_at(bytes, at) + u16_at(bytes, at + 2).shl_wrap(16)

set_u32 : List(U8), U64, U32 -> List(U8)
set_u32 = |bytes, at, n|
	[0, 1, 2, 3].fold(bytes, |acc, i| acc.set(at + i, n.shr_zf_wrap((8 * i).to_u8_wrap()).to_u8_wrap()) ?? acc)

target = Fuzz.target_with!({
	name: "entries",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "small-archive", revision: "1", make: || Zip.create([{ path: "a.txt", content: "a".to_utf8() }, { path: "dir/", content: [] }], Balanced) ?? [] }),
		Fuzz.example({ name: "declares-gigabytes", revision: "1", make: declares_gigabytes }),
	],
	generator: Fuzz.bytes,
	test!,
	show: |bytes| Str.inspect(bytes),
})
