## Create and extract ZIP archives in Roc.
##
## Supports DEFLATE compression (see `Compression`) and ZIP64, so files
## and archives larger than 4 GB work.
##
## [Zip.create] and [Zip.extract] work on whole archives. For untrusted
## archives, or to copy entries from one archive to another unchanged, read
## the index with [Zip.entries], then take each entry with
## [Zip.extract_entry] (inflated, within a size limit) or [Zip.compressed]
## (as stored). [Zip.writer] writes an archive one entry at a time.
import crc32.Crc32
import deflate.Deflate

local_file_header_sig : U32
local_file_header_sig = 0x04034b50

central_dir_header_sig : U32
central_dir_header_sig = 0x02014b50

end_of_central_dir_sig : U32
end_of_central_dir_sig = 0x06054b50

zip64_eocd_locator_sig : U32
zip64_eocd_locator_sig = 0x07064b50

zip64_eocd_sig : U32
zip64_eocd_sig = 0x06064b50

# Extra fields are (id, size, data) blocks; this id marks the ZIP64 field
# holding 64-bit values whose 32-bit header fields overflowed.
zip64_extra_field_id : U16
zip64_extra_field_id = 0x0001

version_needed : U16
version_needed = 20

version_needed_zip64 : U16
version_needed_zip64 = 45

compression_method_store : U16
compression_method_store = 0

compression_method_deflate : U16
compression_method_deflate = 8

# Bit 11 of the general purpose flag: the filename is UTF-8. Without it,
# readers interpret filenames as CP437.
gp_flag_utf8 : U16
gp_flag_utf8 = 0x0800

# 1980-01-01, the earliest valid MS-DOS date (day and month are 1-based, so
# an all-zero date field is invalid).
dos_date_1980_01_01 : U16
dos_date_1980_01_01 = 0x0021

# Fixed record sizes, before any variable-length name, extra field or comment.
local_header_len : U64
local_header_len = 30

central_header_len : U64
central_header_len = 46

end_of_central_dir_len : U64
end_of_central_dir_len = 22

# The ZIP64 end of central directory record and its locator.
zip64_end_len : U64
zip64_end_len = 56 + 20

# The end of central directory record ends with a comment of up to 65535
# bytes, so it starts no further than this from the end of the archive.
max_end_of_central_dir_distance : U64
max_end_of_central_dir_distance = end_of_central_dir_len + 65535

# DEFLATE expands at most 1032:1: a 258-byte match costs at least two bits,
# one for its length code and one for its distance code. A deflated entry
# that declares more than this per stored byte cannot be telling the truth.
max_inflate_ratio : U64
max_inflate_ratio = 1032

## A file entry in the archive.
##
## The `path` can include directories (e.g. `"foo/bar.txt"`).
ZipEntry : { path : Str, content : List(U8) }

## How (and whether) [Zip.create] compresses entries.
##
## `None` stores entries uncompressed. The rest compress with DEFLATE,
## trading speed for size, with the levels of
## [roc-deflate](https://github.com/niclas-ahden/roc-deflate), a port of libdeflate:
## `Fastest` is level 1, the quickest, `Balanced` is level 6, zlib's default
## effort, and `Smallest` is level 12, the smallest archive libdeflate makes.
##
## With anything but `None`, an entry whose compressed form would not be
## smaller (e.g. data that is already compressed) is stored uncompressed
## instead, as ZIP tools conventionally do.
Compression : [None, Fastest, Balanced, Smallest]

## Errors that can occur when creating a ZIP archive.
##
## Paths are compared byte for byte, so `DuplicatePath` names a path that was
## already written.
CreateError : [
	EmptyPath(Str),
	PathTooLong(Str),
	DuplicatePath(Str),
]

## Errors that can occur when extracting a ZIP archive.
##
## `EntryTooLarge` is an entry that declares more bytes than the caller
## allows, and `SizeMismatch` one whose content is not the size it declares.
## `DuplicatePath` is a second entry with a path already in the archive, which
## different readers resolve differently.
ExtractError : [
	InvalidSignature,
	CompressionNotSupported(U16),
	CrcMismatch({ path : Str, expected : U32, actual : U32 }),
	InvalidFilename,
	TruncatedArchive,
	InvalidCompressedData(Str),
	EntryTooLarge({ path : Str, declared : U64, max_bytes : U64 }),
	SizeMismatch({ path : Str, declared : U64 }),
	DuplicatePath(Str),
]

## How an entry's data is stored: as-is, DEFLATE compressed, or with another
## method, named by its ZIP method number, that this package cannot inflate
## but can still copy (see [Zip.compressed]).
Method : [Stored, Deflated, Other(U16)]

## One central-directory record, with its data offset resolved from the local
## header. The sizes are as declared by the archive, with every ZIP64 value
## resolved. [Zip.extract_entry] checks the content against them.
Entry : {
	path : Str,
	method : Method,
	crc : U32,
	compressed_size : U64,
	uncompressed_size : U64,
	data_offset : U64,
}

## Bounds for [Zip.extract_entry]. `Zip.extract_entry(bytes, entry, {})`
## allows entries up to 1 GiB.
EntryLimits := {
	## The most bytes an entry may declare. A larger entry fails with
	## `EntryTooLarge` before any memory is allocated for its content.
	max_bytes : U64 ?? 1_073_741_824,
}

## An entry's compressed bytes exactly as stored, with the facts needed to
## write them again. [Zip.compressed] reads one, and [Zip.add] writes it with
## `Copied`, so the CRC and sizes the writer copies always belong to these
## bytes.
Compressed :: { entry : Entry, bytes : List(U8) }

## Options for [Zip.writer]. `Zip.writer({})` compresses with `Balanced`.
WriterOptions := {
	compression : Compression ?? Balanced,
}

## An archive being written one entry at a time; see [Zip.writer]. It holds
## the central directory written so far and the paths already used, never an
## entry's content.
Writer :: { compression : Compression, paths : Set(Str), dir : Directory }

# The central directory so far: the records, how many there are, and the
# archive offset where the next local header goes.
Directory : { offset : U64, central : List(U8), count : U64 }

Zip := [].{

	## Create a ZIP archive from a list of entries. Returns the archive as bytes.
	##
	## The `Compression` argument decides whether entries are stored as-is
	## (`None`) or DEFLATE compressed (`Fastest` / `Balanced` / `Smallest`).
	##
	## ```roc
	## match Zip.create([
	## 	{ path: "hello.txt", content: "Hello!".to_utf8() },
	## 	{ path: "data/info.json", content: "{}".to_utf8() },
	## ], Balanced) {
	## 	Ok(archive) => # Use the archive bytes
	## 	Err(EmptyPath(path)) => # Path was empty
	## 	Err(PathTooLong(path)) => # Path exceeds 65535 bytes
	## 	Err(DuplicatePath(path)) => # Two entries share a path
	## }
	## ```
	##
	## The output depends only on the entries, their order and the
	## compression: timestamps are zeroed, and there are no data descriptors.
	create : List(ZipEntry), Compression -> Try(List(U8), CreateError)
	create = |entries, compression| {
		validate_entries(entries)?
		var $dir = { offset: 0, central: List.with_capacity(central_dir_capacity(entries)), count: 0 }
		var $out = List.with_capacity(initial_archive_capacity(entries, compression))
		for entry in entries {
			written = append_content($dir, entry, compression, $out)
			$dir = written.dir
			$out = written.out
		}
		Ok(finish_into($dir, $out))
	}

	## Extract entries from a ZIP archive.
	##
	## ```roc
	## match Zip.extract(zip_bytes) {
	## 	Ok(entries) => # List of { path, content }
	## 	Err(InvalidSignature) => # Not a valid ZIP file
	## 	Err(CompressionNotSupported(method)) => # Only store and deflate supported
	## 	Err(CrcMismatch({ path, expected, actual })) => # Data corruption
	## 	Err(InvalidFilename) => # Filename is not valid UTF-8
	## 	Err(TruncatedArchive) => # Archive is incomplete
	## 	Err(InvalidCompressedData(path)) => # Entry's DEFLATE stream is corrupt
	## 	Err(SizeMismatch({ path, declared })) => # Content is not its declared size
	## 	Err(DuplicatePath(path)) => # Two entries share a path
	## 	Err(EntryTooLarge(_)) => # Not returned by extract, which allows every declared size
	## }
	## ```
	##
	## Every entry is inflated, up to the size it declares, so a small
	## archive can still declare a large one. For an archive from an untrusted
	## source, list it with [Zip.entries] and extract what you need with
	## [Zip.extract_entry] and a limit.
	##
	## Security note: entry paths are returned exactly as stored in the
	## archive. A malicious archive can contain paths like `"../evil"` or
	## absolute paths, so check paths with [Zip.is_safe_path] (or your own
	## validation) before writing entries to disk (known as a "zip slip"
	## attack).
	extract : List(U8) -> Try(List(ZipEntry), ExtractError)
	extract = |bytes| {
		index = Zip.entries(bytes)?
		var $extracted = List.with_capacity(index.len())
		for entry in index {
			content = Zip.extract_entry(bytes, entry, { max_bytes: entry.uncompressed_size })?
			$extracted = $extracted.append({ path: entry.path, content })
		}
		Ok($extracted)
	}

	## The archive's entries, in central-directory order, without inflating
	## or checking any of them.
	##
	## This reads the central directory and the fixed part of each entry's
	## local header, so its work and memory grow with the central directory,
	## not with the sizes the entries declare. It checks that each entry's
	## data lies inside the archive and that no two entries share a path.
	##
	## ```roc
	## index = Zip.entries(zip_bytes)?
	## for entry in index {
	## 	if entry.uncompressed_size <= 1_048_576 {
	## 		content = Zip.extract_entry(zip_bytes, entry, { max_bytes: 1_048_576 })?
	## 		# ...
	## 	}
	## }
	## ```
	entries : List(U8) -> Try(List(Entry), ExtractError)
	entries = |bytes| {
		location = find_central_directory(bytes)?
		# The count is the archive's claim. Each record takes at least 46
		# bytes, so the bytes after the directory's start bound the real one.
		room = bytes.len().minus_saturated(location.offset) // central_header_len
		capacity = location.count.min(room)
		var $index = List.with_capacity(capacity)
		var $paths = Set.with_capacity(capacity)
		var $offset = location.offset
		var $remaining = location.count
		while $remaining > 0 {
			record = read_central_record(bytes, $offset)?
			path = record.entry.path
			if $paths.contains(path) {
				return Err(DuplicatePath(path))
			}
			$paths = $paths.insert(path)
			$index = $index.append(record.entry)
			$offset = record.next
			$remaining = $remaining - 1
		}
		Ok($index)
	}

	## Inflate one entry from [Zip.entries], within `limits`.
	##
	## An entry that declares more than `max_bytes` fails with `EntryTooLarge`
	## before anything is allocated for it. Otherwise its output is reserved
	## at the declared size and inflation stops there, so content that runs
	## past or ends short of its declared size fails with `SizeMismatch`. The
	## CRC is checked last.
	##
	## A stored entry is returned as a slice of `bytes`, which keeps the whole
	## archive's allocation alive for as long as the slice is.
	##
	## ```roc
	## content = Zip.extract_entry(zip_bytes, entry, { max_bytes: 1_048_576 })?
	## ```
	extract_entry : List(U8), Entry, EntryLimits -> Try(List(U8), ExtractError)
	extract_entry = |bytes, entry, limits| {
		path = entry.path
		declared = entry.uncompressed_size
		if declared > limits.max_bytes {
			return Err(EntryTooLarge({ path, declared, max_bytes: limits.max_bytes }))
		}
		data = stored_bytes(bytes, entry)?
		content = match entry.method {
			Stored =>
				if entry.compressed_size != declared {
					return Err(SizeMismatch({ path, declared }))
				} else {
					data
				}
			Deflated => inflate(data, path, declared)?
			Other(method) => return Err(CompressionNotSupported(method))
		}
		actual = Crc32.checksum(content)
		if actual != entry.crc {
			Err(CrcMismatch({ path, expected: entry.crc, actual }))
		} else {
			Ok(content)
		}
	}

	## An entry's data exactly as the archive stores it, ready to be written
	## into another archive unchanged with [Zip.add]. Nothing is inflated,
	## copied or checked against the CRC: the bytes are a slice of `bytes`.
	## Call [Zip.extract_entry] as well when the content needs checking.
	##
	## Entries of any method can be copied, including ones this package
	## cannot inflate. A stored entry whose sizes disagree fails with
	## `SizeMismatch`, since writing it again would make an invalid archive.
	##
	## ```roc
	## copy = Zip.compressed(source_bytes, entry)?
	## { writer, chunk } = Zip.add(writer, Copied(copy))?
	## ```
	compressed : List(U8), Entry -> Try(Compressed, ExtractError)
	compressed = |bytes, entry| {
		data = stored_bytes(bytes, entry)?
		if entry.method == Stored and entry.compressed_size != entry.uncompressed_size {
			Err(SizeMismatch({ path: entry.path, declared: entry.uncompressed_size }))
		} else {
			Ok({ entry, bytes: data })
		}
	}

	## Start an archive written one entry at a time. Each [Zip.add] returns
	## the next chunk of the archive, and [Zip.finish] the last one, so the
	## chunks can go to a file or a socket as they are made and the writer
	## holds only the central directory.
	##
	## ```roc
	## var $writer = Zip.writer({ compression: Fastest })
	## for entry in entries {
	## 	added = Zip.add($writer, Content(entry))?
	## 	File.append_bytes!(path, added.chunk)?
	## 	$writer = added.writer
	## }
	## File.append_bytes!(path, Zip.finish($writer))?
	## ```
	##
	## The chunks of `Content` entries followed by `finish` are the bytes
	## [Zip.create] returns for the same entries and compression.
	writer : WriterOptions -> Writer
	writer = |options| {
		compression: options.compression,
		paths: Set.empty(),
		dir: { offset: 0, central: [], count: 0 },
	}

	## Write one entry: its local header, name, extra field and data, as one
	## chunk. A `Content` entry is compressed whole with the writer's
	## compression, falling back to store, and its CRC and sizes are known
	## before its header is written, so the archive has no data descriptors. A
	## `Copied` entry keeps the method, CRC, sizes and bytes it was read with.
	add : Writer, [Content(ZipEntry), Copied(Compressed)] -> Try({ writer : Writer, chunk : List(U8) }, CreateError)
	add = |w, item| {
		path = match item {
			Content(entry) => entry.path
			Copied(copy) => copy.entry.path
		}
		paths = check_path(w.paths, path)?
		written = match item {
			Content(entry) => {
				capacity = local_header_len + path.count_utf8_bytes() + 20 + content_capacity(entry.content.len(), w.compression)
				append_content(w.dir, entry, w.compression, List.with_capacity(capacity))
			}
			Copied(copy) => append_copied(w.dir, copy, [])
		}
		Ok({
			writer: { compression: w.compression, paths, dir: written.dir },
			chunk: written.out,
		})
	}

	## The last chunk of the archive: the central directory, the ZIP64
	## records when they are needed, and the end of central directory record.
	finish : Writer -> List(U8)
	finish = |w| {
		dir = w.dir
		finish_into(dir, List.with_capacity(dir.central.len() + zip64_end_len + end_of_central_dir_len))
	}

	## Whether an entry path is safe to join onto an extraction directory.
	##
	## Returns `Bool.False` for absolute paths, paths with `..` components,
	## and paths containing `:` (Windows drive letters), which malicious
	## archives use to write outside the extraction directory (known as a
	## "zip slip" attack). Check paths from [Zip.extract] with this before
	## writing entries to disk.
	##
	## ```roc
	## Zip.is_safe_path("docs/readme.md") # Bool.True
	## Zip.is_safe_path("../secret") # Bool.False
	## Zip.is_safe_path("/etc/passwd") # Bool.False
	## ```
	is_safe_path : Str -> Bool
	is_safe_path = |path|
		if path.is_empty() or path.starts_with("/") or path.starts_with("\\") or path.contains(":") {
			Bool.False
		} else {
			# The ZIP spec mandates forward slashes, but be defensive about
			# backslashes since some Windows tools write them anyway.
			path.split_on("/").all(|part| part.split_on("\\").all(|component| component != ".."))
		}
}

# --- Writing ---

## The roc-deflate level behind each DEFLATE setting of [Compression].
deflate_level : Compression -> [Store, Level(Deflate.Level)]
deflate_level = |compression|
	match compression {
		None => Store
		Fastest => Level(1)
		Balanced => Level(6)
		Smallest => Level(12)
	}

# Check paths in order, as `add` would, so `create` fails before it
# compresses anything.
validate_entries : List(ZipEntry) -> Try({}, CreateError)
validate_entries = |entries| {
	var $paths = Set.with_capacity(entries.len())
	for entry in entries {
		$paths = check_path($paths, entry.path)?
	}
	Ok({})
}

check_path : Set(Str), Str -> Try(Set(Str), CreateError)
check_path = |paths, path|
	if path.is_empty() {
		Err(EmptyPath(path))
	} else if path.count_utf8_bytes() > 65535 {
		Err(PathTooLong(path))
	} else if paths.contains(path) {
		Err(DuplicatePath(path))
	} else {
		Ok(paths.insert(path))
	}

# Every central record, with the largest ZIP64 extra field each could need.
central_dir_capacity : List(ZipEntry) -> U64
central_dir_capacity = |entries|
	entries.fold(0, |total, entry| total + central_header_len + entry.path.count_utf8_bytes() + 28)

# Stored, an archive's size is known up front, so it is allocated once. A
# compressed archive starts with room for its headers and grows
# geometrically as entries are compressed into it.
initial_archive_capacity : List(ZipEntry), Compression -> U64
initial_archive_capacity = |entries, compression| {
	headers = entries.fold(0, |total, entry| total + local_header_len + entry.path.count_utf8_bytes() + 20)
	data = match compression {
		None => entries.fold(0, |total, entry| total + entry.content.len())
		_ => 0
	}
	headers + data + central_dir_capacity(entries) + zip64_end_len + end_of_central_dir_len
}

# The room an entry's data needs while it is written.
content_capacity : U64, Compression -> U64
content_capacity = |len, compression|
	match compression {
		None => len
		_ => Deflate.compress_bound(len)
	}

# Make room for `spare` more bytes, at least doubling when the list must
# grow. `List.reserve` grows to exactly what is asked, so reserving once per
# entry would copy the whole archive once per entry.
reserve_geometric : List(U8), U64 -> List(U8)
reserve_geometric = |list, spare|
	if list.capacity() - list.len() >= spare {
		list
	} else {
		list.reserve(spare.max(list.len()))
	}

append_content : Directory, ZipEntry, Compression, List(U8) -> { dir : Directory, out : List(U8) }
append_content = |dir, entry, compression, out| {
	content = entry.content
	name = entry.path.to_utf8()
	crc = Crc32.checksum(content)
	len = content.len()
	start = out.len()
	match deflate_level(compression) {
		Store => {
			header = { name, crc, method: compression_method_store, compressed_len: len, uncompressed_len: len }
			data_start = local_header_len + name.len() + local_extra_len(len, len)
			with_header = append_local_header(reserve_geometric(out, data_start + len), header)
			appended = with_header.append_sublist(content, { start: 0, len })
			{ dir: add_central_record(dir, header, appended.len() - start), out: appended }
		}
		Level(level) => {
			# Compress straight into the output after a header that assumes
			# DEFLATE, then patch its method and compressed size. DEFLATE is
			# kept only when it is smaller, and stored data is exactly `len`
			# bytes, so whether the header needs ZIP64 sizes depends on `len`
			# alone and the header's length is known before compressing.
			zip64 = len >= 0xFFFFFFFF
			data_start = start + local_header_len + name.len() + local_extra_len(len, len)
			reserved = reserve_geometric(out, data_start - start + Deflate.compress_bound(len))
			with_header = append_local_header(reserved, { name, crc, method: compression_method_deflate, compressed_len: 0, uncompressed_len: len })
			deflated = Deflate.compress_into(content, level, with_header)
			deflated_len = deflated.len() - data_start
			# The compressed size sits in the 32-bit field, or after the
			# uncompressed size in the ZIP64 extra field.
			size_at = if zip64 {
				start + local_header_len + name.len() + 12
			} else {
				start + 18
			}
			if deflated_len < len {
				header = { name, crc, method: compression_method_deflate, compressed_len: deflated_len, uncompressed_len: len }
				patched = if zip64 {
					set_u64_le(deflated, size_at, deflated_len)
				} else {
					set_u32_le(deflated, size_at, deflated_len.to_u32_wrap())
				}
				{ dir: add_central_record(dir, header, patched.len() - start), out: patched }
			} else {
				header = { name, crc, method: compression_method_store, compressed_len: len, uncompressed_len: len }
				stored = deflated.take_first(data_start).append_sublist(content, { start: 0, len })
				with_method = set_u16_le(stored, start + 8, compression_method_store)
				patched = if zip64 {
					set_u64_le(with_method, size_at, len)
				} else {
					set_u32_le(with_method, size_at, len.to_u32_wrap())
				}
				{ dir: add_central_record(dir, header, patched.len() - start), out: patched }
			}
		}
	}
}

append_copied : Directory, Compressed, List(U8) -> { dir : Directory, out : List(U8) }
append_copied = |dir, copy, out| {
	entry = copy.entry
	name = entry.path.to_utf8()
	header = {
		name,
		crc: entry.crc,
		method: method_code(entry.method),
		compressed_len: entry.compressed_size,
		uncompressed_len: entry.uncompressed_size,
	}
	data_len = copy.bytes.len()
	record_len = local_header_len + name.len() + local_extra_len(header.uncompressed_len, header.compressed_len) + data_len
	start = out.len()
	written = append_local_header(reserve_geometric(out, record_len), header).append_sublist(copy.bytes, { start: 0, len: data_len })
	{ dir: add_central_record(dir, header, written.len() - start), out: written }
}

method_code : Method -> U16
method_code = |method|
	match method {
		Stored => compression_method_store
		Deflated => compression_method_deflate
		Other(code) => code
	}

method_from_code : U16 -> Method
method_from_code = |code|
	if code == compression_method_store {
		Stored
	} else if code == compression_method_deflate {
		Deflated
	} else {
		Other(code)
	}

# What a local and a central header both record about an entry.
Header : { name : List(U8), crc : U32, method : U16, compressed_len : U64, uncompressed_len : U64 }

# In the local header, if either size overflows, both 32-bit size fields get
# the sentinel and the ZIP64 extra field must hold both sizes.
local_extra_len : U64, U64 -> U64
local_extra_len = |uncompressed_len, compressed_len|
	if uncompressed_len >= 0xFFFFFFFF or compressed_len >= 0xFFFFFFFF {
		20
	} else {
		0
	}

append_local_header : List(U8), Header -> List(U8)
append_local_header = |out, header| {
	u = header.uncompressed_len
	c = header.compressed_len
	extra_len = local_extra_len(u, c)
	zip64 = extra_len > 0
	with_fixed = out
		|> put_u32(local_file_header_sig)
		|> put_u16(
			if zip64 {
				version_needed_zip64
			} else {
				version_needed
			},
		)
		|> put_u16(gp_flag_utf8) # General purpose bit flag
		|> put_u16(header.method)
		|> put_u16(0) # Last mod time
		|> put_u16(dos_date_1980_01_01) # Last mod date
		|> put_u32(header.crc)
	# Compressed then uncompressed size; with ZIP64 both real values live
	# in the extra field
		|> put_u32(
			if zip64 {
				0xFFFFFFFF
			} else {
				c.to_u32_wrap()
			},
		)
		|> put_u32(
			if zip64 {
				0xFFFFFFFF
			} else {
				u.to_u32_wrap()
			},
		)
		|> put_u16(header.name.len().to_u16_wrap())
		|> put_u16(extra_len.to_u16_wrap())
		.append_sublist(header.name, { start: 0, len: header.name.len() })
	if zip64 {
		with_fixed
			|> put_u16(zip64_extra_field_id)
			|> put_u16(16) # Data size
			|> put_u64(u)
			|> put_u64(c)
	} else {
		with_fixed
	}
}

# Record an entry whose local record, `record_len` bytes, starts at the
# directory's current offset.
add_central_record : Directory, Header, U64 -> Directory
add_central_record = |dir, header, record_len| {
	u = header.uncompressed_len
	c = header.compressed_len
	offset = dir.offset
	# A ZIP64 extra field holds only the values whose 32-bit fields
	# overflowed, in order: uncompressed size, compressed size, local header
	# offset.
	overflowing = [u, c, offset].keep_if(|value| value >= 0xFFFFFFFF)
	extra_len = if overflowing.is_empty() {
		0
	} else {
		4 + 8 * overflowing.len()
	}
	version = if overflowing.is_empty() {
		version_needed
	} else {
		version_needed_zip64
	}
	with_fixed = reserve_geometric(dir.central, central_header_len + header.name.len() + extra_len)
		|> put_u32(central_dir_header_sig)
		|> put_u16(version) # Version made by
		|> put_u16(version) # Version needed to extract
		|> put_u16(gp_flag_utf8) # General purpose bit flag
		|> put_u16(header.method)
		|> put_u16(0) # Last mod time
		|> put_u16(dos_date_1980_01_01) # Last mod date
		|> put_u32(header.crc)
		|> put_zip64_u32(c) # Compressed size
		|> put_zip64_u32(u) # Uncompressed size
		|> put_u16(header.name.len().to_u16_wrap())
		|> put_u16(extra_len.to_u16_wrap())
		|> put_u16(0) # File comment length
		|> put_u16(0) # Disk number start
		|> put_u16(0) # Internal file attributes
		|> put_u32(0) # External file attributes
		|> put_zip64_u32(offset) # Relative offset of local header
		.append_sublist(header.name, { start: 0, len: header.name.len() })
	central =
		if overflowing.is_empty() {
			with_fixed
		} else {
			with_extra = with_fixed |> put_u16(zip64_extra_field_id) |> put_u16((8 * overflowing.len()).to_u16_wrap())
			overflowing.fold(with_extra, |bytes, value| bytes |> put_u64(value))
		}
	{ offset: offset + record_len, central, count: dir.count + 1 }
}

finish_into : Directory, List(U8) -> List(U8)
finish_into = |dir, out| {
	central_dir_offset = dir.offset
	central_dir_size = dir.central.len()
	entry_count = dir.count
	needs_zip64 =
		entry_count >= 0xFFFF or central_dir_size >= 0xFFFFFFFF or central_dir_offset >= 0xFFFFFFFF
	# Exact, not geometric: this is the archive's last growth.
	tail_len = central_dir_size + (
		if needs_zip64 {
			zip64_end_len
		} else {
			0
		}
	) + end_of_central_dir_len
	room = if out.capacity() - out.len() >= tail_len {
		out
	} else {
		out.reserve(tail_len)
	}
	room.append_sublist(dir.central, { start: 0, len: central_dir_size }) |> append_end_records(entry_count, central_dir_size, central_dir_offset)
}

# The end of central directory record, preceded by the ZIP64 end of central
# directory record and locator past any of the classic limits.
append_end_records : List(U8), U64, U64, U64 -> List(U8)
append_end_records = |out, entry_count, central_dir_size, central_dir_offset| {
	needs_zip64 =
		entry_count >= 0xFFFF or central_dir_size >= 0xFFFFFFFF or central_dir_offset >= 0xFFFFFFFF
	with_zip64 =
		if needs_zip64 {
			out
				|> put_u32(zip64_eocd_sig)
				|> put_u64(44) # Size of the record after this field
				|> put_u16(version_needed_zip64) # Version made by
				|> put_u16(version_needed_zip64) # Version needed to extract
				|> put_u32(0) # Number of this disk
				|> put_u32(0) # Disk where central directory starts
				|> put_u64(entry_count) # Entries on this disk
				|> put_u64(entry_count) # Total entries
				|> put_u64(central_dir_size) # Size of central directory
				|> put_u64(central_dir_offset) # Offset of central directory
			# The locator
				|> put_u32(zip64_eocd_locator_sig)
				|> put_u32(0) # Disk with the ZIP64 end of central directory
				|> put_u64(central_dir_offset + central_dir_size) # Its offset
				|> put_u32(1) # Total number of disks
		} else {
			out
		}
	with_zip64
		|> put_u32(end_of_central_dir_sig)
		|> put_u16(0) # Number of this disk
		|> put_u16(0) # Disk where central directory starts
		|> put_zip64_u16(entry_count) # Entries on this disk
		|> put_zip64_u16(entry_count) # Total entries
		|> put_zip64_u32(central_dir_size) # Size of central directory
		|> put_zip64_u32(central_dir_offset) # Offset of central directory
		|> put_u16(0) # Comment length
}

# --- Encoding ---

put_u16 : List(U8), U16 -> List(U8)
put_u16 = |bytes, n|
	bytes.append(n.to_u8_wrap()).append(n.shr_zf_wrap(8).to_u8_wrap())

put_u32 : List(U8), U32 -> List(U8)
put_u32 = |bytes, n|
	bytes
		.append(n.to_u8_wrap())
		.append(n.shr_zf_wrap(8).to_u8_wrap())
		.append(n.shr_zf_wrap(16).to_u8_wrap())
		.append(n.shr_zf_wrap(24).to_u8_wrap())

put_u64 : List(U8), U64 -> List(U8)
put_u64 = |bytes, n|
	bytes |> put_u32(n.to_u32_wrap()) |> put_u32(n.shr_zf_wrap(32).to_u32_wrap())

# 32-bit header fields hold 0xFFFFFFFF (and the 16-bit entry count 0xFFFF)
# when the real value doesn't fit; readers then look for the real value in a
# ZIP64 extra field or the ZIP64 end of central directory record.
put_zip64_u32 : List(U8), U64 -> List(U8)
put_zip64_u32 = |bytes, value|
	bytes
		|> put_u32(
			if value >= 0xFFFFFFFF {
				0xFFFFFFFF
			} else {
				value.to_u32_wrap()
			},
		)

put_zip64_u16 : List(U8), U64 -> List(U8)
put_zip64_u16 = |bytes, value|
	bytes
		|> put_u16(
			if value >= 0xFFFF {
				0xFFFF
			} else {
				value.to_u16_wrap()
			},
		)

# Overwrite little-endian fields of bytes already written. Every caller
# passes a position inside the header it just wrote.
set_u8 : List(U8), U64, U8 -> List(U8)
set_u8 = |bytes, at, n|
	match bytes.set(at, n) {
		Ok(set) => set
		Err(OutOfBounds) => crash "set_u8: a header field lies outside the header just written"
	}

set_u16_le : List(U8), U64, U16 -> List(U8)
set_u16_le = |bytes, at, n|
	set_u8(set_u8(bytes, at, n.to_u8_wrap()), at + 1, n.shr_zf_wrap(8).to_u8_wrap())

set_u32_le : List(U8), U64, U32 -> List(U8)
set_u32_le = |bytes, at, n|
	set_u16_le(set_u16_le(bytes, at, n.to_u16_wrap()), at + 2, n.shr_zf_wrap(16).to_u16_wrap())

set_u64_le : List(U8), U64, U64 -> List(U8)
set_u64_le = |bytes, at, n|
	set_u32_le(set_u32_le(bytes, at, n.to_u32_wrap()), at + 4, n.shr_zf_wrap(32).to_u32_wrap())

encode_u16_le : U16 -> List(U8)
encode_u16_le = |n| [] |> put_u16(n)

encode_u32_le : U32 -> List(U8)
encode_u32_le = |n| [] |> put_u32(n)

encode_u64_le : U64 -> List(U8)
encode_u64_le = |n| [] |> put_u64(n)

expect encode_u16_le(0x1234) == [0x34, 0x12]
expect encode_u32_le(0x12345678) == [0x78, 0x56, 0x34, 0x12]
expect encode_u64_le(0x123456789ABCDEF0) == [0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12]
expect set_u32_le([0, 0, 0, 0, 0, 0], 1, 0x12345678) == [0, 0x78, 0x56, 0x34, 0x12, 0]

# --- Reading ---

# Every decode reads its first byte before computing any later offset, so an
# offset an archive claims, however large, fails as out of bounds rather than
# overflowing.
decode_u16_le : List(U8), U64 -> Try(U16, [OutOfBounds])
decode_u16_le = |bytes, offset| {
	b0 = bytes.get(offset)?
	b1 = bytes.get(offset + 1)?
	Ok(b0.to_u16() + b1.to_u16().shl_wrap(8))
}

decode_u32_le : List(U8), U64 -> Try(U32, [OutOfBounds])
decode_u32_le = |bytes, offset| {
	b0 = bytes.get(offset)?
	b1 = bytes.get(offset + 1)?
	b2 = bytes.get(offset + 2)?
	b3 = bytes.get(offset + 3)?
	Ok(
		b0.to_u32()
			+ b1.to_u32().shl_wrap(8)
			+ b2.to_u32().shl_wrap(16)
			+ b3.to_u32().shl_wrap(24),
	)
}

decode_u64_le : List(U8), U64 -> Try(U64, [OutOfBounds])
decode_u64_le = |bytes, offset| {
	lo = decode_u32_le(bytes, offset)?
	hi = decode_u32_le(bytes, offset + 4)?
	Ok(lo.to_u64() + hi.to_u64().shl_wrap(32))
}

expect decode_u16_le([0x34, 0x12], 0) == Ok(0x1234)
expect decode_u32_le([0x78, 0x56, 0x34, 0x12], 0) == Ok(0x12345678)
expect decode_u64_le([0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12], 0) == Ok(0x123456789ABCDEF0)

# Where the central directory starts and how many records it claims.
#
# The ZIP64 end of central directory record is consulted only when a field of
# the classic record holds its sentinel, as the format specifies. Otherwise
# the 20 bytes before the classic record belong to the last central record,
# where a name or extra field can hold the locator's signature by chance or
# on purpose. A sentinel with no locator is read as the value it is.
find_central_directory : List(U8) -> Try({ offset : U64, count : U64 }, ExtractError)
find_central_directory = |bytes|
	match find_end_of_central_dir(bytes) {
		Ok(eocd_offset) => {
			count = decode_u16_le(bytes, eocd_offset + 10) ? |_| TruncatedArchive
			size = decode_u32_le(bytes, eocd_offset + 12) ? |_| TruncatedArchive
			offset = decode_u32_le(bytes, eocd_offset + 16) ? |_| TruncatedArchive
			sentinel = count == 0xFFFF or size == 0xFFFFFFFF or offset == 0xFFFFFFFF
			if sentinel and has_zip64_locator(bytes, eocd_offset) {
				# The locator stores the ZIP64 end of central directory
				# record's offset 8 bytes into its 20-byte record.
				zip64_offset = decode_u64_le(bytes, eocd_offset - 12) ? |_| TruncatedArchive
				sig = decode_u32_le(bytes, zip64_offset) ? |_| TruncatedArchive
				if sig != zip64_eocd_sig {
					Err(InvalidSignature)
				} else {
					zip64_count = decode_u64_le(bytes, zip64_offset + 32) ? |_| TruncatedArchive
					zip64_dir_offset = decode_u64_le(bytes, zip64_offset + 48) ? |_| TruncatedArchive
					Ok({ offset: zip64_dir_offset, count: zip64_count })
				}
			} else {
				Ok({ offset: offset.to_u64(), count: count.to_u64() })
			}
		}
		Err(NotFound) =>
		# No central directory. If the bytes start like a ZIP entry,
		# the archive was probably cut off; otherwise it's not a ZIP.
			match decode_u32_le(bytes, 0) {
				Ok(sig) =>
					if sig == local_file_header_sig {
						Err(TruncatedArchive)
					} else {
						Err(InvalidSignature)
					}
				Err(_) => Err(InvalidSignature)
			}
	}

# Find the end of central directory record by scanning backwards from the end
# of the archive (it's followed by a variable-length comment, so its position
# isn't fixed). A candidate only counts if its comment length field points
# exactly at the end of the bytes, which guards against the signature
# appearing by chance inside file content. The comment is at most 65535
# bytes, so the scan never looks further back than that.
find_end_of_central_dir : List(U8) -> Try(U64, [NotFound])
find_end_of_central_dir = |bytes| {
	len = bytes.len()
	if len < end_of_central_dir_len {
		return Err(NotFound)
	}
	lowest = len.minus_saturated(max_end_of_central_dir_distance)
	var $offset = len - end_of_central_dir_len
	while $offset >= lowest {
		is_eocd =
			match decode_u32_le(bytes, $offset) {
				Ok(sig) if sig == end_of_central_dir_sig =>
					match decode_u16_le(bytes, $offset + 20) {
						Ok(comment_len) => $offset + end_of_central_dir_len + comment_len.to_u64() == len
						Err(_) => Bool.False
					}
				_ => Bool.False
			}
		if is_eocd {
			return Ok($offset)
		}
		if $offset == 0 {
			return Err(NotFound)
		}
		$offset = $offset - 1
	}
	Err(NotFound)
}

# A ZIP64 archive places a ZIP64 end of central directory locator directly
# before the end of central directory record.
has_zip64_locator : List(U8), U64 -> Bool
has_zip64_locator = |bytes, eocd_offset|
	if eocd_offset < 20 {
		Bool.False
	} else {
		match decode_u32_le(bytes, eocd_offset - 20) {
			Ok(sig) => sig == zip64_eocd_locator_sig
			Err(_) => Bool.False
		}
	}

# Read the central directory record at `offset`, which is the authoritative
# index of the archive. The sizes and CRCs stored here are correct even for
# streamed archives, whose local headers contain zeros (with the real values
# in data descriptors after each entry's content).
read_central_record : List(U8), U64 -> Try({ entry : Entry, next : U64 }, ExtractError)
read_central_record = |bytes, offset| {
	# Central directory header layout:
	# 0-3: signature
	# 10-11: compression method
	# 16-19: crc32
	# 20-23: compressed size
	# 24-27: uncompressed size
	# 28-29: filename length
	# 30-31: extra field length
	# 32-33: comment length
	# 42-45: offset of local header
	# 46+: filename, extra field, comment
	sig = decode_u32_le(bytes, offset) ? |_| TruncatedArchive
	if sig != central_dir_header_sig {
		return Err(InvalidSignature)
	}
	method = decode_u16_le(bytes, offset + 10) ? |_| TruncatedArchive
	crc = decode_u32_le(bytes, offset + 16) ? |_| TruncatedArchive
	compressed_size = decode_u32_le(bytes, offset + 20) ? |_| TruncatedArchive
	uncompressed_size = decode_u32_le(bytes, offset + 24) ? |_| TruncatedArchive
	filename_len = decode_u16_le(bytes, offset + 28) ? |_| TruncatedArchive
	extra_len = decode_u16_le(bytes, offset + 30) ? |_| TruncatedArchive
	comment_len = decode_u16_le(bytes, offset + 32) ? |_| TruncatedArchive
	local_header_offset = decode_u32_le(bytes, offset + 42) ? |_| TruncatedArchive

	name_start = offset + central_header_len
	filename_bytes = bytes.sublist({ start: name_start, len: filename_len.to_u64() })
	if filename_bytes.len() != filename_len.to_u64() {
		return Err(TruncatedArchive)
	}
	path = Str.from_utf8(filename_bytes) ? |_| InvalidFilename
	resolved = resolve_zip64_values(
		bytes,
		name_start + filename_len.to_u64(),
		extra_len.to_u64(),
		{ uncompressed_size, compressed_size, local_header_offset },
	)?
	data_offset = local_data_offset(bytes, resolved.local_header_offset)?
	if data_offset.plus_saturated(resolved.compressed_size) > bytes.len() {
		return Err(TruncatedArchive)
	}
	Ok({
		entry: {
			path,
			method: method_from_code(method),
			crc,
			compressed_size: resolved.compressed_size,
			uncompressed_size: resolved.uncompressed_size,
			data_offset,
		},
		next: name_start + filename_len.to_u64() + extra_len.to_u64() + comment_len.to_u64(),
	})
}

# 32-bit central directory fields holding 0xFFFFFFFF store their real values
# in a ZIP64 extra field, in order: uncompressed size, compressed size, local
# header offset — each present only if its 32-bit field overflowed.
resolve_zip64_values : List(U8), U64, U64, { uncompressed_size : U32, compressed_size : U32, local_header_offset : U32 } -> Try({ uncompressed_size : U64, compressed_size : U64, local_header_offset : U64 }, ExtractError)
resolve_zip64_values = |bytes, extra_start, extra_len, fields| {
	if fields.uncompressed_size != 0xFFFFFFFF and fields.compressed_size != 0xFFFFFFFF and fields.local_header_offset != 0xFFFFFFFF {
		return Ok({ uncompressed_size: fields.uncompressed_size.to_u64(), compressed_size: fields.compressed_size.to_u64(), local_header_offset: fields.local_header_offset.to_u64() })
	}
	data_start = find_zip64_extra_field(bytes, extra_start, extra_start + extra_len) ? |_| TruncatedArchive
	uncompressed = zip64_value(bytes, data_start, fields.uncompressed_size)?
	compressed = zip64_value(bytes, uncompressed.next, fields.compressed_size)?
	local_header = zip64_value(bytes, compressed.next, fields.local_header_offset)?
	Ok({ uncompressed_size: uncompressed.value, compressed_size: compressed.value, local_header_offset: local_header.value })
}

# A 32-bit field's real value: itself, or, when it holds the sentinel, the
# next 64-bit value in the ZIP64 extra field.
zip64_value : List(U8), U64, U32 -> Try({ value : U64, next : U64 }, ExtractError)
zip64_value = |bytes, at, field|
	if field == 0xFFFFFFFF {
		value = decode_u64_le(bytes, at) ? |_| TruncatedArchive
		Ok({ value, next: at + 8 })
	} else {
		Ok({ value: field.to_u64(), next: at })
	}

# Walk the (id, size, data) blocks of an extra field region looking for the
# ZIP64 block, returning the offset of its data.
find_zip64_extra_field : List(U8), U64, U64 -> Try(U64, [NotFound])
find_zip64_extra_field = |bytes, start, end| {
	var $pos = start
	while $pos + 4 <= end {
		id = decode_u16_le(bytes, $pos) ? |_| NotFound
		data_size = decode_u16_le(bytes, $pos + 2) ? |_| NotFound
		if id == zip64_extra_field_id {
			return Ok($pos + 4)
		}
		$pos = $pos + 4 + data_size.to_u64()
	}
	Err(NotFound)
}

# Where an entry's data starts, from the fixed part of its local header. The
# filename and extra field lengths must come from the local header (they can
# differ from the central directory copy).
local_data_offset : List(U8), U64 -> Try(U64, ExtractError)
local_data_offset = |bytes, local_offset| {
	sig = decode_u32_le(bytes, local_offset) ? |_| TruncatedArchive
	if sig != local_file_header_sig {
		return Err(InvalidSignature)
	}
	filename_len = decode_u16_le(bytes, local_offset + 26) ? |_| TruncatedArchive
	extra_len = decode_u16_le(bytes, local_offset + 28) ? |_| TruncatedArchive
	Ok(local_offset + local_header_len + filename_len.to_u64() + extra_len.to_u64())
}

# An entry's data as the archive stores it, a slice of the archive.
stored_bytes : List(U8), Entry -> Try(List(U8), ExtractError)
stored_bytes = |bytes, entry|
	if entry.data_offset.plus_saturated(entry.compressed_size) > bytes.len() {
		Err(TruncatedArchive)
	} else {
		Ok(bytes.sublist({ start: entry.data_offset, len: entry.compressed_size }))
	}

# Inflate into a buffer reserved at the declared size, stopping there.
inflate : List(U8), Str, U64 -> Try(List(U8), ExtractError)
inflate = |data, path, declared| {
	if declared > data.len().times_saturated(max_inflate_ratio) {
		return Err(SizeMismatch({ path, declared }))
	}
	match Deflate.decompress(data, { max_output: declared, expected_size: Declared(declared) }) {
		Ok(content) if content.len() == declared => Ok(content)
		Ok(_) => Err(SizeMismatch({ path, declared }))
		Err(OutputLimitExceeded) => Err(SizeMismatch({ path, declared }))
		Err(_) => Err(InvalidCompressedData(path))
	}
}

# Concatenate byte lists, for building test archives by hand.
concat_all : List(List(U8)) -> List(U8)
concat_all = |parts| List.join(parts)

# Round-trip tests

# Single file round-trip
expect {
	original = [{ path: "test.txt", content: "Hello, World!".to_utf8() }]
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Multiple files round-trip
expect {
	original = [
		{ path: "a.txt", content: "File A".to_utf8() },
		{ path: "b.txt", content: "File B".to_utf8() },
		{ path: "c.txt", content: "File C".to_utf8() },
	]
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Empty content round-trip
expect {
	original = [{ path: "empty.txt", content: [] }]
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Paths with directories round-trip
expect {
	original = [
		{ path: "docs/readme.md", content: "# Readme".to_utf8() },
		{ path: "src/main.roc", content: "app [main] {}".to_utf8() },
		{ path: "deep/nested/path/file.txt", content: "deep".to_utf8() },
	]
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Empty archive round-trip
expect {
	original : List(ZipEntry)
	original = []
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Binary content round-trip
expect {
	original = [{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] }]
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Structural tests

# Verify local file header signature
expect {
	match Zip.create([{ path: "x", content: [] }], None) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 0, len: 4 }) == [0x50, 0x4B, 0x03, 0x04]
		Err(_) => Bool.False
	}
}

# Verify central directory signature appears after local entries
expect {
	match Zip.create([{ path: "x", content: [] }], None) {
		# Local header (30) + filename (1) + content (0) = 31
		Ok(zip_bytes) => zip_bytes.sublist({ start: 31, len: 4 }) == [0x50, 0x4B, 0x01, 0x02]
		Err(_) => Bool.False
	}
}

# Verify end of central directory signature
expect {
	match Zip.create([{ path: "x", content: [] }], None) {
		Ok(zip_bytes) => {
			len = zip_bytes.len()
			# End of central directory is 22 bytes
			zip_bytes.sublist({ start: len - 22, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]
		}
		Err(_) => Bool.False
	}
}

# Verify CRC32 is stored correctly in local header (offset 14-17)
expect {
	match Zip.create([{ path: "x", content: "123456789".to_utf8() }], None) {
		# CRC32 of "123456789" is 0xCBF43926, stored little-endian
		Ok(zip_bytes) => zip_bytes.sublist({ start: 14, len: 4 }) == [0x26, 0x39, 0xF4, 0xCB]
		Err(_) => Bool.False
	}
}

# Verify file size is stored correctly (offset 18-21 compressed, 22-25 uncompressed)
expect {
	content = "Hello".to_utf8() # 5 bytes
	match Zip.create([{ path: "x", content }], None) {
		Ok(zip_bytes) => {
			compressed_size = zip_bytes.sublist({ start: 18, len: 4 })
			uncompressed_size = zip_bytes.sublist({ start: 22, len: 4 })
			# 5 stored as little-endian U32
			compressed_size == [0x05, 0x00, 0x00, 0x00] and uncompressed_size == [0x05, 0x00, 0x00, 0x00]
		}
		Err(_) => Bool.False
	}
}

# Verify filename length is stored correctly (offset 26-27)
expect {
	match Zip.create([{ path: "test.txt", content: [] }], None) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 26, len: 2 }) == [0x08, 0x00]
		Err(_) => Bool.False
	}
}

# Verify filename is stored correctly (starts at offset 30)
expect {
	match Zip.create([{ path: "abc", content: [] }], None) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 30, len: 3 }) == [0x61, 0x62, 0x63] # "abc"
		Err(_) => Bool.False
	}
}

# Verify content is stored correctly (after header + filename)
expect {
	match Zip.create([{ path: "x", content: [0xDE, 0xAD, 0xBE, 0xEF] }], None) {
		# Header (30) + filename (1) = 31, then content
		Ok(zip_bytes) => zip_bytes.sublist({ start: 31, len: 4 }) == [0xDE, 0xAD, 0xBE, 0xEF]
		Err(_) => Bool.False
	}
}

# Verify empty archive has only end of central directory (22 bytes)
expect {
	match Zip.create([], None) {
		Ok(zip_bytes) => zip_bytes.len() == 22 and zip_bytes.sublist({ start: 0, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]
		Err(_) => Bool.False
	}
}

# ZIP64 tests

# A file of 4GB or more gets sentinel sizes, version 4.5, and a ZIP64 extra
# field with the real sizes in its local header
expect {
	four_gb = 0x100000000
	header = append_local_header([], { name: [0x78], crc: 0, method: compression_method_store, compressed_len: four_gb, uncompressed_len: four_gb })
	version_ok = header.sublist({ start: 4, len: 2 }) == [45, 0]
	sizes_ok = header.sublist({ start: 18, len: 8 }) == List.repeat(0xFF, 8)
	extra_len_ok = header.sublist({ start: 28, len: 2 }) == [20, 0]
	extra_ok =
		header.sublist({ start: 31, len: 20 })
			== concat_all([
				[0x01, 0x00], # ZIP64 extra field id
				[16, 0], # Data size
				[0, 0, 0, 0, 1, 0, 0, 0], # Uncompressed size: 2^32
				[0, 0, 0, 0, 1, 0, 0, 0], # Compressed size: 2^32
			])
	version_ok and sizes_ok and extra_len_ok and extra_ok
}

# An entry whose local header sits past 4GB gets a sentinel offset in its
# central directory header, with the real offset in a ZIP64 extra field
expect {
	four_gb = 0x100000000
	dir = add_central_record({ offset: four_gb, central: [], count: 0 }, { name: [0x78], crc: 0, method: compression_method_store, compressed_len: 5, uncompressed_len: 5 }, 36)
	header = dir.central
	offset_ok = header.sublist({ start: 42, len: 4 }) == List.repeat(0xFF, 4)
	next_ok = dir.offset == four_gb + 36 and dir.count == 1
	extra_ok =
		header.sublist({ start: 47, len: 12 })
			== concat_all([
				[0x01, 0x00], # ZIP64 extra field id
				[8, 0], # Data size
				[0, 0, 0, 0, 1, 0, 0, 0], # Local header offset: 2^32
			])
	offset_ok and next_ok and extra_ok
}

# Past any of the classic limits, the end of central directory is preceded by
# a ZIP64 end of central directory record and locator
expect {
	end = append_end_records([], 70000, 100, 200)
	# ZIP64 record (56 bytes) + locator (20 bytes) + classic record (22 bytes)
	len_ok = end.len() == 98
	zip64_sig_ok = end.sublist({ start: 0, len: 4 }) == [0x50, 0x4B, 0x06, 0x06]
	count_ok = end.sublist({ start: 32, len: 8 }) == [0x70, 0x11, 0x01, 0x00, 0, 0, 0, 0] # 70000
	locator_sig_ok = end.sublist({ start: 56, len: 4 }) == [0x50, 0x4B, 0x06, 0x07]
	locator_offset_ok = end.sublist({ start: 64, len: 8 }) == [0x2C, 0x01, 0, 0, 0, 0, 0, 0] # 200 + 100
	classic_sig_ok = end.sublist({ start: 76, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]
	classic_count_ok = end.sublist({ start: 84, len: 4 }) == [0xFF, 0xFF, 0xFF, 0xFF] # Sentinels
	len_ok and zip64_sig_ok and count_ok and locator_sig_ok and locator_offset_ok and classic_sig_ok and classic_count_ok
}

# Extract an archive whose central directory uses ZIP64 sentinel sizes with
# the real values in an extra field (legal even for small files)
expect Zip.extract(zip64_sentinel_archive) == Ok([{ path: "a", content: "Hi".to_utf8() }])

# Path safety tests

expect Zip.is_safe_path("docs/readme.md")
expect Zip.is_safe_path("dir/")
expect Zip.is_safe_path("..foo/bar..")
expect Zip.is_safe_path("räksmörgås.txt")
expect Zip.is_safe_path("../evil") == Bool.False
expect Zip.is_safe_path("a/../b") == Bool.False
expect Zip.is_safe_path("..") == Bool.False
expect Zip.is_safe_path("/etc/passwd") == Bool.False
expect Zip.is_safe_path("C:\\windows\\system32") == Bool.False
expect Zip.is_safe_path("a\\..\\b") == Bool.False
expect Zip.is_safe_path("") == Bool.False

# Error tests

# Empty path returns EmptyPath error
expect {
	result = Zip.create([{ path: "", content: [] }], None)
	result == Err(EmptyPath(""))
}

# More than 65535 entries forces a ZIP64 end of central directory, which
# must round-trip
expect {
	original = List.repeat({}, 65536).map_with_index(|_, index| { path: index.to_str(), content: [] })
	match Zip.create(original, None) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Truncated archive returns TruncatedArchive error
expect {
	# Just the signature, missing the rest of the header
	truncated = [0x50, 0x4B, 0x03, 0x04]
	result = Zip.extract(truncated)
	result == Err(TruncatedArchive)
}

# Invalid signature returns InvalidSignature error
expect {
	invalid = [0x00, 0x00, 0x00, 0x00]
	result = Zip.extract(invalid)
	result == Err(InvalidSignature)
}

# Build a complete single-entry archive for tests, with control over the
# compression method, the stored CRC, and the raw filename bytes.
build_test_archive : { method : U16, crc : U32, filename : List(U8), content : List(U8) } -> List(U8)
build_test_archive = |{ method, crc, filename, content }|
	build_records_archive([{ method, crc, filename, data: content, declared: content.len() }])

# Build an archive from hand-made records, each with its own declared
# uncompressed size, so tests can write what Zip.create never would: lying
# sizes and repeated names.
TestRecord : { method : U16, crc : U32, filename : List(U8), data : List(U8), declared : U64 }

build_records_archive : List(TestRecord) -> List(U8)
build_records_archive = |records| {
	var $local = []
	var $central = []
	for record in records {
		offset = $local.len()
		$local = $local
			|> put_u32(local_file_header_sig)
			|> put_u16(version_needed)
			|> put_u16(0) # General purpose bit flag
			|> put_u16(record.method)
			|> put_u16(0) # Last mod time
			|> put_u16(dos_date_1980_01_01)
			|> put_u32(record.crc)
			|> put_u32(record.data.len().to_u32_wrap()) # Compressed size
			|> put_u32(record.declared.to_u32_wrap()) # Uncompressed size
			|> put_u16(record.filename.len().to_u16_wrap())
			|> put_u16(0) # Extra field length
			.concat(record.filename)
			.concat(record.data)
		$central = $central
			|> put_u32(central_dir_header_sig)
			|> put_u16(version_needed) # Version made by
			|> put_u16(version_needed) # Version needed to extract
			|> put_u16(0) # General purpose bit flag
			|> put_u16(record.method)
			|> put_u16(0) # Last mod time
			|> put_u16(dos_date_1980_01_01)
			|> put_u32(record.crc)
			|> put_u32(record.data.len().to_u32_wrap()) # Compressed size
			|> put_u32(record.declared.to_u32_wrap()) # Uncompressed size
			|> put_u16(record.filename.len().to_u16_wrap())
			|> put_u16(0) # Extra field length
			|> put_u16(0) # File comment length
			|> put_u16(0) # Disk number start
			|> put_u16(0) # Internal file attributes
			|> put_u32(0) # External file attributes
			|> put_u32(offset.to_u32_wrap()) # Offset of local header
			.concat(record.filename)
	}
	$local.concat($central) |> append_end_records(records.len(), $central.len(), $local.len())
}

# Compressed ZIP returns CompressionNotSupported error
expect {
	# Compression method 12 = bzip2, which isn't supported
	archive = build_test_archive({ method: 12, crc: 0, filename: [0x78], content: [] })
	result = Zip.extract(archive)
	result == Err(CompressionNotSupported(12))
}

# A deflate entry with a corrupt stream returns InvalidCompressedData
expect {
	# 0x07 declares a reserved block type 11
	archive = build_test_archive({ method: 8, crc: 0, filename: [0x78], content: [0x07] })
	result = Zip.extract(archive)
	result == Err(InvalidCompressedData("x"))
}

# CRC mismatch returns CrcMismatch error
expect {
	# Stored CRC 0x12345678 doesn't match the content's actual CRC
	archive = build_test_archive({ method: 0, crc: 0x12345678, filename: [0x78], content: "Hello".to_utf8() })
	match Zip.extract(archive) {
		Err(CrcMismatch({ path: "x", expected: 0x12345678, actual: _ })) => Bool.True
		_ => Bool.False
	}
}

# Invalid UTF-8 filename returns InvalidFilename error
expect {
	archive = build_test_archive({ method: 0, crc: 0, filename: [0xFF, 0xFE], content: [] })
	result = Zip.extract(archive)
	result == Err(InvalidFilename)
}

# Streamed archives (general purpose bit 3) store zeros in the local header,
# with the real CRC and sizes in a data descriptor after the content and in
# the central directory. Extraction must use the central directory values.
expect Zip.extract(streamed_archive) == Ok([{ path: "hello.txt", content: "Hello, World!".to_utf8() }])

# Real-world interop: a store-mode archive created by Info-ZIP's `zip -0`,
# containing a directory entry and Unix timestamp/permission extra fields.
expect {
	fixture = infozip_store_fixture
	match Zip.extract(fixture) {
		Ok(entries) => {
			paths = entries.map(|e| e.path)
			contents = entries.map(|e| e.content)
			paths == ["hello.txt", "dir/", "dir/n.txt"]
				and contents == ["Hello, World!".to_utf8(), [], "nested".to_utf8()]
		}
		Err(_) => Bool.False
	}
}

# Real-world interop: a ZIP64 store-mode archive created by bsdtar, with a
# ZIP64 end of central directory record and ZIP64 extra fields.
expect {
	fixture = bsdtar_zip64_fixture
	match Zip.extract(fixture) {
		Ok(entries) => entries.map(|e| e.path) == ["hello.txt"]
			and entries.map(|e| e.content) == ["Hello, World!".to_utf8()]
		Err(_) => Bool.False
	}
}

# Compression tests

# Compressed archives round-trip and actually shrink compressible content
expect {
	text = "Compression works best when text repeats itself, repeats itself, repeats itself."
	original = [
		{ path: "a.txt", content: text.to_utf8() },
		{ path: "dir/b.txt", content: List.repeat(0x41, 5000) },
	]
	match Zip.create(original, Balanced) {
		Ok(zip_bytes) =>
			Zip.extract(zip_bytes) == Ok(original) and zip_bytes.len() < 500
		Err(_) => Bool.False
	}
}

# Every compression option round-trips the same entries
expect {
	original = [
		{ path: "a.txt", content: "Repeats itself, repeats itself, repeats itself.".to_utf8() },
		{ path: "dir/b.bin", content: List.repeat(0x42, 2000) },
	]
	round_trips = |compression|
		match Zip.create(original, compression) {
			Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
			Err(_) => Bool.False
		}
	round_trips(None) and round_trips(Fastest) and round_trips(Balanced) and round_trips(Smallest)
}

# Compressed entries carry method 8 (deflate) in the local header (offset 8)
expect {
	match Zip.create([{ path: "x", content: List.repeat(0x41, 100) }], Balanced) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 8, len: 2 }) == [0x08, 0x00]
		Err(_) => Bool.False
	}
}

# Incompressible content falls back to store (method 0)
expect {
	match Zip.create([{ path: "x", content: [1, 2, 3] }], Balanced) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 8, len: 2 }) == [0x00, 0x00]
		Err(_) => Bool.False
	}
}

# Empty content compresses to a store entry and round-trips
expect {
	original = [{ path: "empty.txt", content: [] }]
	match Zip.create(original, Balanced) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Real-world interop: a deflate-compressed archive created by Info-ZIP's
# `zip -9` extracts to the original text
expect {
	fixture = infozip_deflate_fixture
	original = [84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 115, 32, 111, 118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 46, 32, 84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 115, 32, 111, 118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 32, 97, 103, 97, 105, 110, 32, 97, 110, 100, 32, 97, 103, 97, 105, 110, 32, 97, 110, 100, 32, 97, 103, 97, 105, 110, 46, 32, 67, 111, 109, 112, 114, 101, 115, 115, 105, 111, 110, 32, 119, 111, 114, 107, 115, 32, 98, 101, 115, 116, 32, 119, 104, 101, 110, 32, 116, 101, 120, 116, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 44, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 44, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 32, 105, 110, 32, 118, 97, 114, 105, 111, 117, 115, 32, 119, 97, 121, 115, 32, 97, 110, 100, 32, 118, 97, 114, 105, 111, 117, 115, 32, 112, 108, 97, 99, 101, 115, 32, 116, 104, 114, 111, 117, 103, 104, 111, 117, 116, 32, 116, 104, 101, 32, 118, 97, 114, 105, 111, 117, 115, 32, 116, 101, 120, 116, 46, 10]
	match Zip.extract(fixture) {
		Ok(entries) => entries.map(|e| e.path) == ["dyntest.txt"]
			and entries.map(|e| e.content) == [original]
		Err(_) => Bool.False
	}
}

# Entry index tests

# Every archive the tests read: the fixtures, the hand-built ones, and
# Zip.create's own output at every compression.
test_archives : List(List(U8))
test_archives = {
	created = [None, Fastest, Balanced, Smallest].map(|compression| Zip.create(sample_entries, compression) ?? [])
	[infozip_store_fixture, bsdtar_zip64_fixture, infozip_deflate_fixture, zip64_sentinel_archive, streamed_archive].concat(created)
}

# Distinct paths, an empty entry, bytes that do not compress, a UTF-8 name,
# and text that compresses differently at every level.
sample_entries : List(ZipEntry)
sample_entries = [
	{ path: "hello.txt", content: "Hello, World!".to_utf8() },
	{ path: "docs/readme.md", content: "# Readme".to_utf8() },
	{ path: "empty.txt", content: [] },
	{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] },
	{ path: "utf8/räksmörgås.txt", content: "UTF-8 filename".to_utf8() },
	{ path: "big.txt", content: word_salad(4000) },
]

# `count` words chosen by a multiplicative hash, so the text repeats without
# being periodic.
word_salad : U64 -> List(U8)
word_salad = |count|
	List.repeat({}, count)
		.map_with_index(|_, i| (["the ", "cat ", "sat ", "on ", "a ", "mat, ", "and ", "then "].get(i.times_wrap(0x9E3779B97F4A7C15).shr_zf_wrap(61)) ?? "").to_utf8())
		.join()

# `entries` agrees with `extract` on paths, order and sizes, and the data it
# locates holds as many bytes as the entry says it stores.
expect {
	test_archives.all(
		|archive|
			match (Zip.entries(archive), Zip.extract(archive)) {
				(Ok(index), Ok(extracted)) =>
					index.map(|entry| entry.path) == extracted.map(|entry| entry.path)
						and index.map(|entry| entry.uncompressed_size) == extracted.map(|entry| entry.content.len())
						and index.all(|entry| entry.data_offset + entry.compressed_size <= archive.len())
				_ => Bool.False
			},
	)
}

# The index reports each entry's method and CRC as the central directory
# declares them.
expect {
	match Zip.entries(infozip_deflate_fixture) {
		Ok([entry]) => entry.method == Deflated and entry.crc == 0xE4C84C10 and entry.compressed_size == 133 and entry.uncompressed_size == 260
		_ => Bool.False
	}
}

# A method this package cannot inflate is still listed, as Other.
expect {
	archive = build_test_archive({ method: 12, crc: 0, filename: "x.bz2".to_utf8(), content: [1, 2, 3] })
	match Zip.entries(archive) {
		Ok([entry]) => entry.method == Other(12) and Zip.extract_entry(archive, entry, {}) == Err(CompressionNotSupported(12))
		_ => Bool.False
	}
}

# Two records with the same name make the archive ambiguous.
expect {
	record = { method: compression_method_store, crc: Crc32.checksum([1]), filename: "a".to_utf8(), data: [1], declared: 1 }
	archive = build_records_archive([record, { ..record, filename: "b".to_utf8() }, record])
	Zip.entries(archive) == Err(DuplicatePath("a")) and Zip.extract(archive) == Err(DuplicatePath("a"))
}

# Names are compared byte for byte, so names that differ only in case are
# distinct.
expect {
	record = { method: compression_method_store, crc: Crc32.checksum([1]), filename: "a".to_utf8(), data: [1], declared: 1 }
	archive = build_records_archive([record, { ..record, filename: "A".to_utf8() }])
	match Zip.entries(archive) {
		Ok(index) => index.map(|entry| entry.path) == ["a", "A"]
		Err(_) => Bool.False
	}
}

# An entry count far beyond what the archive could hold fails on the first
# record that is not there, here the end record itself, instead of reserving
# room for the claim.
expect {
	archive = Zip.create([{ path: "a", content: [1] }], None) ?? []
	# The classic end record's two entry counts sit 8 and 10 bytes in.
	eocd = archive.len() - 22
	claims_more = set_u16_le(set_u16_le(archive, eocd + 8, 0xFFFE), eocd + 10, 0xFFFE)
	Zip.entries(claims_more) == Err(InvalidSignature)
}

# The end of central directory record is found behind a maximal comment, and
# not further back.
expect {
	archive = Zip.create([{ path: "a", content: [1] }], None) ?? []
	eocd = archive.len() - 22
	with_comment = set_u16_le(archive, eocd + 20, 65535).concat(List.repeat(0x20, 65535))
	match Zip.entries(with_comment) {
		Ok(index) => index.map(|entry| entry.path) == ["a"]
		Err(_) => Bool.False
	}
}

# A path whose last bytes look like a ZIP64 end of central directory locator
# sits where a real one would. It is part of the last central record, so the
# archive still reads.
expect {
	path = "a".to_utf8().concat([0x50, 0x4B, 0x06, 0x07]).concat(List.repeat(0x69, 8)).concat(List.repeat(0x12, 8))
	entries = [{ path: Str.from_utf8(path) ?? "", content: [1, 2, 3] }]
	match Zip.create(entries, None) {
		Ok(archive) => Zip.extract(archive) == Ok(entries)
		Err(_) => Bool.False
	}
}

# Exactly 65535 entries fills the classic count without needing ZIP64, so a
# count of 0xFFFF with no locator is read as it is.
expect {
	archive = Zip.create([{ path: "a", content: [1] }], None) ?? []
	eocd = archive.len() - 22
	# Claim 0xFFFF records; the walk then fails on the end record itself, which
	# shows the claim was taken as written rather than as a sentinel.
	claims = set_u16_le(set_u16_le(archive, eocd + 8, 0xFFFF), eocd + 10, 0xFFFF)
	Zip.entries(claims) == Err(InvalidSignature)
}

# Bounded extraction tests

# An entry that declares more than the limit fails before it is inflated.
expect {
	data = Deflate.compress(List.repeat(0, 4096), 6)
	archive = build_records_archive([{ method: compression_method_deflate, crc: 0, filename: "bomb".to_utf8(), data, declared: 1_073_741_824 }])
	match Zip.entries(archive) {
		Ok([entry]) => Zip.extract_entry(archive, entry, { max_bytes: 1_048_576 }) == Err(EntryTooLarge({ path: "bomb", declared: 1_073_741_824, max_bytes: 1_048_576 }))
		_ => Bool.False
	}
}

# A stream that runs past its declared size stops there.
expect {
	zeros = List.repeat(0, 65_536)
	archive = build_records_archive([{ method: compression_method_deflate, crc: Crc32.checksum(zeros), filename: "bomb".to_utf8(), data: Deflate.compress(zeros, 6), declared: 1024 }])
	Zip.extract(archive) == Err(SizeMismatch({ path: "bomb", declared: 1024 }))
}

# A stream that ends before its declared size is just as wrong.
expect {
	text = word_salad(100)
	archive = build_records_archive([{ method: compression_method_deflate, crc: Crc32.checksum(text), filename: "short".to_utf8(), data: Deflate.compress(text, 6), declared: text.len() + 1 }])
	Zip.extract(archive) == Err(SizeMismatch({ path: "short", declared: text.len() + 1 }))
}

# A declared size no DEFLATE stream of that length could reach is rejected
# without inflating, whatever the limit.
expect {
	data = Deflate.compress([1, 2, 3], 6)
	declared = data.len() * 1032 + 1
	archive = build_records_archive([{ method: compression_method_deflate, crc: 0, filename: "x".to_utf8(), data, declared }])
	match Zip.entries(archive) {
		Ok([entry]) => Zip.extract_entry(archive, entry, { max_bytes: U64.highest }) == Err(SizeMismatch({ path: "x", declared }))
		_ => Bool.False
	}
}

# A stored entry's sizes must agree.
expect {
	archive = build_records_archive([{ method: compression_method_store, crc: Crc32.checksum([1, 2]), filename: "x".to_utf8(), data: [1, 2], declared: 3 }])
	match Zip.entries(archive) {
		Ok([entry]) =>
			Zip.extract_entry(archive, entry, {}) == Err(SizeMismatch({ path: "x", declared: 3 }))
				and Zip.compressed(archive, entry).map_ok(|_| {}) == Err(SizeMismatch({ path: "x", declared: 3 }))
		_ => Bool.False
	}
}

# An entry exactly at its limit extracts, and a stored entry is a slice of the
# archive.
expect {
	archive = Zip.create(sample_entries, Balanced) ?? []
	match Zip.entries(archive) {
		Ok(index) =>
			index.all(
				|entry| {
					expected = sample_entries.find_first(|sample| sample.path == entry.path) ?? { path: "", content: [] }
					Zip.extract_entry(archive, entry, { max_bytes: entry.uncompressed_size }) == Ok(expected.content)
				},
			)
		Err(_) => Bool.False
	}
}

# An entry whose data lies past the end of the archive is truncated, however
# large the claimed offset.
expect {
	archive = Zip.create([{ path: "a", content: [1] }], None) ?? []
	match Zip.entries(archive) {
		Ok([entry]) =>
			Zip.extract_entry(archive, { ..entry, data_offset: U64.highest }, {}) == Err(TruncatedArchive)
				and Zip.compressed(archive, { ..entry, compressed_size: U64.highest }).map_ok(|_| {}) == Err(TruncatedArchive)
		_ => Bool.False
	}
}

# Writer tests

# The chunks of a writer followed by its last one are the archive Zip.create
# makes, at every compression, and writing twice gives the same bytes.
expect {
	[None, Fastest, Balanced, Smallest].all(
		|compression| {
			var $writer = Zip.writer({ compression: compression })
			var $chunks = []
			for entry in sample_entries {
				match Zip.add($writer, Content(entry)) {
					Ok(added) => {
						$writer = added.writer
						$chunks = $chunks.concat(added.chunk)
					}
					Err(_) => {}
				}
			}
			written = $chunks.concat(Zip.finish($writer))
			created = Zip.create(sample_entries, compression)
			created == Ok(written) and Zip.create(sample_entries, compression) == created
		},
	)
}

# Zip.create's output for the sample entries, as roc-zip 0.2.2 wrote it.
expect {
	golden = [(None, 16158, 288689382), (Fastest, 1257, 4049207964), (Balanced, 873, 2111224123), (Smallest, 839, 1037676504)]
	golden.all(
		|(compression, len, crc)|
			match Zip.create(sample_entries, compression) {
				Ok(archive) => archive.len() == len and Crc32.checksum(archive) == crc
				Err(_) => Bool.False
			},
	)
}

# No local header Zip.create writes sets general purpose bit 3, so no entry
# has a data descriptor.
expect {
	[None, Fastest, Balanced, Smallest].all(
		|compression| {
			archive = Zip.create(sample_entries, compression) ?? []
			match Zip.entries(archive) {
				Ok(index) => {
					# Each entry's local header starts where the previous
					# entry's data ends.
					var $at = 0
					var $ok = Bool.True
					for entry in index {
						flags = decode_u16_le(archive, $at + 6) ?? 0xFFFF
						$ok = $ok and flags.bitwise_and(0x0008) == 0
						$at = entry.data_offset + entry.compressed_size
					}
					$ok
				}
				Err(_) => Bool.False
			}
		},
	)
}

# A repeated path is refused by both the writer and Zip.create.
expect {
	entry = { path: "a.txt", content: [1] }
	added = Zip.add(Zip.writer({}), Content(entry)) ?? crash "the first entry is valid"
	Zip.add(added.writer, Content(entry)).is_err()
		and Zip.create([entry, { path: "b.txt", content: [] }, entry], None) == Err(DuplicatePath("a.txt"))
}

# Copying tests

# Copy every entry of an archive into a new one through `compressed` and
# `Copied`.
copy_archive : List(U8) -> Try(List(U8), [CopyFailed])
copy_archive = |archive| {
	index = Zip.entries(archive) ? |_| CopyFailed
	var $writer = Zip.writer({})
	var $out = []
	for entry in index {
		copy = Zip.compressed(archive, entry) ? |_| CopyFailed
		added = Zip.add($writer, Copied(copy)) ? |_| CopyFailed
		$writer = added.writer
		$out = $out.concat(added.chunk)
	}
	Ok($out.concat(Zip.finish($writer)))
}

# Copied entries extract to the original content, and their data bytes in the
# new archive are the source archive's, for every fixture and compression.
expect {
	test_archives.all(
		|archive|
			match (copy_archive(archive), Zip.entries(archive)) {
				(Ok(copy), Ok(source_index)) =>
					match Zip.entries(copy) {
						Ok(copy_index) =>
							Zip.extract(copy) == Zip.extract(archive)
								and copy_index.map(|entry| entry.method) == source_index.map(|entry| entry.method)
								and copy_index.map(|entry| archive_data(copy, entry)) == source_index.map(|entry| archive_data(archive, entry))
						Err(_) => Bool.False
					}
				_ => Bool.False
			},
	)
}

archive_data : List(U8), Entry -> List(U8)
archive_data = |archive, entry| archive.sublist({ start: entry.data_offset, len: entry.compressed_size })

# An entry this package cannot inflate passes through unchanged.
expect {
	archive = build_test_archive({ method: 12, crc: 0x1234, filename: "x.bz2".to_utf8(), content: [1, 2, 3] })
	match copy_archive(archive) {
		Ok(copy) =>
			match Zip.entries(copy) {
				Ok([entry]) => entry.method == Other(12) and entry.crc == 0x1234 and archive_data(copy, entry) == [1, 2, 3]
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}

# Fixtures

# A store entry whose central directory record puts both sizes in a ZIP64
# extra field.
zip64_sentinel_archive : List(U8)
zip64_sentinel_archive = {
	content = "Hi".to_utf8()
	crc = Crc32.checksum(content)
	filename = "a".to_utf8()
	local = concat_all([
		encode_u32_le(local_file_header_sig),
		encode_u16_le(version_needed_zip64),
		encode_u16_le(0), # General purpose bit flag
		encode_u16_le(compression_method_store),
		encode_u16_le(0), # Last mod time
		encode_u16_le(dos_date_1980_01_01),
		encode_u32_le(crc),
		encode_u32_le(2), # Compressed size
		encode_u32_le(2), # Uncompressed size
		encode_u16_le(1), # Filename length
		encode_u16_le(0), # Extra field length
		filename,
		content,
	])
	central = concat_all([
		encode_u32_le(central_dir_header_sig),
		encode_u16_le(version_needed_zip64),
		encode_u16_le(version_needed_zip64),
		encode_u16_le(0), # General purpose bit flag
		encode_u16_le(compression_method_store),
		encode_u16_le(0), # Last mod time
		encode_u16_le(dos_date_1980_01_01),
		encode_u32_le(crc),
		encode_u32_le(0xFFFFFFFF), # Compressed size: in ZIP64 extra field
		encode_u32_le(0xFFFFFFFF), # Uncompressed size: in ZIP64 extra field
		encode_u16_le(1), # Filename length
		encode_u16_le(20), # Extra field length
		encode_u16_le(0), # File comment length
		encode_u16_le(0), # Disk number start
		encode_u16_le(0), # Internal file attributes
		encode_u32_le(0), # External file attributes
		encode_u32_le(0), # Offset of local header
		filename,
		encode_u16_le(zip64_extra_field_id),
		encode_u16_le(16), # Data size
		encode_u64_le(2), # Uncompressed size
		encode_u64_le(2), # Compressed size
	])
	concat_all([local, central, append_end_records([], 1, central.len(), local.len())])
}

# A streamed store entry: zeros in the local header and a data descriptor
# after the content.
streamed_archive : List(U8)
streamed_archive = {
	content = "Hello, World!".to_utf8()
	crc = Crc32.checksum(content)
	filename = "hello.txt".to_utf8()
	local = concat_all([
		encode_u32_le(local_file_header_sig),
		encode_u16_le(version_needed),
		encode_u16_le(0x0008), # General purpose bit flag: bit 3 set
		encode_u16_le(compression_method_store),
		encode_u16_le(0), # Last mod time
		encode_u16_le(dos_date_1980_01_01),
		encode_u32_le(0), # CRC32: in data descriptor
		encode_u32_le(0), # Compressed size: in data descriptor
		encode_u32_le(0), # Uncompressed size: in data descriptor
		encode_u16_le(filename.len().to_u16_wrap()),
		encode_u16_le(0), # Extra field length
		filename,
		content,
		encode_u32_le(0x08074b50), # Data descriptor signature
		encode_u32_le(crc),
		encode_u32_le(content.len().to_u32_wrap()),
		encode_u32_le(content.len().to_u32_wrap()),
	])
	central = concat_all([
		encode_u32_le(central_dir_header_sig),
		encode_u16_le(version_needed),
		encode_u16_le(version_needed),
		encode_u16_le(0x0008), # General purpose bit flag: bit 3 set
		encode_u16_le(compression_method_store),
		encode_u16_le(0), # Last mod time
		encode_u16_le(dos_date_1980_01_01),
		encode_u32_le(crc),
		encode_u32_le(content.len().to_u32_wrap()),
		encode_u32_le(content.len().to_u32_wrap()),
		encode_u16_le(filename.len().to_u16_wrap()),
		encode_u16_le(0), # Extra field length
		encode_u16_le(0), # File comment length
		encode_u16_le(0), # Disk number start
		encode_u16_le(0), # Internal file attributes
		encode_u32_le(0), # External file attributes
		encode_u32_le(0), # Offset of local header
		filename,
	])
	local.concat(central).concat(append_end_records([], 1, central.len(), local.len()))
}

# A store-mode archive created by Info-ZIP's `zip -0`, with a directory entry
# and Unix timestamp/permission extra fields.
infozip_store_fixture : List(U8)
infozip_store_fixture = [80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 208, 195, 74, 236, 13, 0, 0, 0, 13, 0, 0, 0, 9, 0, 28, 0, 104, 101, 108, 108, 111, 46, 116, 120, 116, 85, 84, 9, 0, 3, 218, 115, 77, 106, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 72, 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33, 80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 28, 0, 100, 105, 114, 47, 85, 84, 9, 0, 3, 218, 115, 77, 106, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 233, 194, 201, 170, 6, 0, 0, 0, 6, 0, 0, 0, 9, 0, 28, 0, 100, 105, 114, 47, 110, 46, 116, 120, 116, 85, 84, 9, 0, 3, 218, 115, 77, 106, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 110, 101, 115, 116, 101, 100, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 208, 195, 74, 236, 13, 0, 0, 0, 13, 0, 0, 0, 9, 0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 0, 0, 0, 0, 104, 101, 108, 108, 111, 46, 116, 120, 116, 85, 84, 5, 0, 3, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 24, 0, 0, 0, 0, 0, 0, 0, 16, 0, 237, 65, 80, 0, 0, 0, 100, 105, 114, 47, 85, 84, 5, 0, 3, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 227, 189, 231, 92, 233, 194, 201, 170, 6, 0, 0, 0, 6, 0, 0, 0, 9, 0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 142, 0, 0, 0, 100, 105, 114, 47, 110, 46, 116, 120, 116, 85, 84, 5, 0, 3, 218, 115, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 80, 75, 5, 6, 0, 0, 0, 0, 3, 0, 3, 0, 232, 0, 0, 0, 215, 0, 0, 0, 0, 0]

# A ZIP64 store-mode archive created by bsdtar, with data descriptors, a ZIP64
# end of central directory record and ZIP64 extra fields.
bsdtar_zip64_fixture : List(U8)
bsdtar_zip64_fixture = [80, 75, 3, 4, 45, 0, 8, 0, 0, 0, 227, 189, 231, 92, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 32, 0, 104, 101, 108, 108, 111, 46, 116, 120, 116, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 85, 84, 13, 0, 7, 218, 115, 77, 106, 218, 115, 77, 106, 218, 115, 77, 106, 72, 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33, 80, 75, 7, 8, 208, 195, 74, 236, 13, 0, 0, 0, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 80, 75, 1, 2, 45, 3, 45, 0, 8, 0, 0, 0, 227, 189, 231, 92, 208, 195, 74, 236, 13, 0, 0, 0, 13, 0, 0, 0, 9, 0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 0, 0, 0, 0, 104, 101, 108, 108, 111, 46, 116, 120, 116, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 85, 84, 5, 0, 1, 218, 115, 77, 106, 80, 75, 6, 6, 44, 0, 0, 0, 0, 0, 0, 0, 45, 0, 45, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 79, 0, 0, 0, 0, 0, 0, 0, 108, 0, 0, 0, 0, 0, 0, 0, 80, 75, 6, 7, 0, 0, 0, 0, 187, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 79, 0, 0, 0, 108, 0, 0, 0, 0, 0]

# A deflate-compressed archive created by Info-ZIP's `zip -9`.
infozip_deflate_fixture : List(U8)
infozip_deflate_fixture = [80, 75, 3, 4, 20, 0, 2, 0, 8, 0, 9, 9, 232, 92, 16, 76, 200, 228, 133, 0, 0, 0, 4, 1, 0, 0, 11, 0, 28, 0, 100, 121, 110, 116, 101, 115, 116, 46, 116, 120, 116, 85, 84, 9, 0, 3, 225, 134, 77, 106, 225, 134, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 141, 78, 203, 21, 130, 64, 12, 188, 91, 197, 20, 224, 163, 9, 91, 160, 129, 0, 1, 86, 96, 179, 38, 89, 22, 173, 94, 228, 61, 46, 94, 244, 54, 191, 55, 51, 245, 200, 120, 228, 208, 78, 104, 84, 74, 68, 47, 27, 238, 121, 73, 6, 89, 89, 225, 187, 61, 211, 235, 137, 78, 134, 10, 245, 255, 97, 208, 64, 33, 130, 98, 247, 141, 42, 220, 100, 73, 202, 102, 65, 34, 138, 232, 100, 104, 216, 28, 101, 228, 8, 231, 205, 161, 156, 152, 220, 16, 220, 120, 238, 175, 63, 56, 246, 246, 149, 52, 72, 54, 20, 122, 218, 49, 117, 10, 105, 166, 150, 109, 191, 166, 146, 135, 81, 178, 31, 47, 79, 247, 179, 86, 93, 222, 80, 75, 1, 2, 30, 3, 20, 0, 2, 0, 8, 0, 9, 9, 232, 92, 16, 76, 200, 228, 133, 0, 0, 0, 4, 1, 0, 0, 11, 0, 24, 0, 0, 0, 0, 0, 1, 0, 0, 0, 164, 129, 0, 0, 0, 0, 100, 121, 110, 116, 101, 115, 116, 46, 116, 120, 116, 85, 84, 5, 0, 3, 225, 134, 77, 106, 117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 100, 0, 0, 0, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 81, 0, 0, 0, 202, 0, 0, 0, 0, 0]
