## Create and extract ZIP archives in Roc.
##
## Supports DEFLATE compression (see `Compression`) and ZIP64, so files
## and archives larger than 4 GB work.
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

## A file entry in the archive.
##
## The `path` can include directories (e.g. `"foo/bar.txt"`).
ZipEntry : { path : Str, content : List(U8) }

## How (and whether) [Zip.create] compresses entries.
##
## `None` stores entries uncompressed. The rest compress with DEFLATE,
## trading speed for size: `Fastest` compresses least but is quickest,
## `Smallest` produces the smallest archive this library can (dedicated
## tools at their highest settings still beat it by a few percent), and
## `Balanced` sits in between.
##
## With anything but `None`, an entry whose compressed form would not be
## smaller (e.g. data that is already compressed) is stored uncompressed
## instead, as ZIP tools conventionally do.
Compression : [None, Fastest, Balanced, Smallest]

## Errors that can occur when creating a ZIP archive.
CreateError : [
	EmptyPath(Str),
	PathTooLong(Str),
]

## Errors that can occur when extracting a ZIP archive.
ExtractError : [
	InvalidSignature,
	CompressionNotSupported(U16),
	CrcMismatch({ path : Str, expected : U32, actual : U32 }),
	InvalidFilename,
	TruncatedArchive,
	InvalidCompressedData(Str),
]

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
	## }
	## ```
	create : List(ZipEntry), Compression -> Try(List(U8), CreateError)
	create = |entries, compression| {
		validate_entries(entries)?
		prepared = match compression {
			None => entries.map(prepare_stored)
			Fastest => entries.map(|entry| prepare_deflated(entry, Fastest))
			Balanced => entries.map(|entry| prepare_deflated(entry, Balanced))
			Smallest => entries.map(|entry| prepare_deflated(entry, Smallest))
		}
		Ok(build_archive(prepared))
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
	## }
	## ```
	##
	## Security note: entry paths are returned exactly as stored in the
	## archive. A malicious archive can contain paths like `"../evil"` or
	## absolute paths, so check paths with [Zip.is_safe_path] (or your own
	## validation) before writing entries to disk (known as a "zip slip"
	## attack).
	extract : List(U8) -> Try(List(ZipEntry), ExtractError)
	extract = |bytes|
		match find_end_of_central_dir(bytes) {
			Ok(eocd_offset) => {
				if has_zip64_locator(bytes, eocd_offset) {
					# The locator stores the ZIP64 end of central directory
					# record's offset 8 bytes into its 20-byte record.
					zip64_offset = decode_u64_le(bytes, eocd_offset - 12) ? |_| TruncatedArchive
					sig = decode_u32_le(bytes, zip64_offset) ? |_| TruncatedArchive
					if sig != zip64_eocd_sig {
						Err(InvalidSignature)
					} else {
						entry_count = decode_u64_le(bytes, zip64_offset + 32) ? |_| TruncatedArchive
						central_dir_offset = decode_u64_le(bytes, zip64_offset + 48) ? |_| TruncatedArchive
						extract_central_entries(bytes, central_dir_offset, entry_count, [])
					}
				} else {
					entry_count = decode_u16_le(bytes, eocd_offset + 10) ? |_| TruncatedArchive
					central_dir_offset = decode_u32_le(bytes, eocd_offset + 16) ? |_| TruncatedArchive
					extract_central_entries(bytes, central_dir_offset.to_u64(), entry_count.to_u64(), [])
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

# An entry whose compression has been decided, ready for build_archive.
PreparedEntry : { path : Str, crc : U32, method : U16, data : List(U8), uncompressed_len : U64 }

prepare_stored : ZipEntry -> PreparedEntry
prepare_stored = |entry| {
	path: entry.path,
	crc: Crc32.checksum(entry.content),
	method: compression_method_store,
	data: entry.content,
	uncompressed_len: entry.content.len(),
}

# Compress one entry, falling back to store when compression would not
# shrink it, as ZIP tools conventionally do.
prepare_deflated : ZipEntry, [Fastest, Balanced, Smallest] -> PreparedEntry
prepare_deflated = |entry, level| {
	crc = Crc32.checksum(entry.content)
	deflated = Deflate.compress(entry.content, level)
	if deflated.len() < entry.content.len() {
		{
			path: entry.path,
			crc,
			method: compression_method_deflate,
			data: deflated,
			uncompressed_len: entry.content.len(),
		}
	} else {
		{
			path: entry.path,
			crc,
			method: compression_method_store,
			data: entry.content,
			uncompressed_len: entry.content.len(),
		}
	}
}

# Concatenate a list of byte lists into one. Byte-wise append into a
# preallocated list stays linear; List.concat currently copies both operands,
# which makes folding with it quadratic in the number of parts.
concat_all : List(List(U8)) -> List(U8)
concat_all = |parts| {
	total = parts.fold(0, |acc, part| acc + part.len())
	parts.fold(
		List.with_capacity(total),
		|acc, part| part.fold(acc, |bytes, byte| bytes.append(byte)),
	)
}

encode_u16_le : U16 -> List(U8)
encode_u16_le = |n|
	[n.to_u8_wrap(), n.shr_wrap(8).to_u8_wrap()]

encode_u32_le : U32 -> List(U8)
encode_u32_le = |n|
	[
		n.to_u8_wrap(),
		n.shr_wrap(8).to_u8_wrap(),
		n.shr_wrap(16).to_u8_wrap(),
		n.shr_wrap(24).to_u8_wrap(),
	]

encode_u64_le : U64 -> List(U8)
encode_u64_le = |n|
	encode_u32_le(n.to_u32_wrap()).concat(encode_u32_le(n.shr_wrap(32).to_u32_wrap()))

expect encode_u16_le(0x1234) == [0x34, 0x12]
expect encode_u32_le(0x12345678) == [0x78, 0x56, 0x34, 0x12]
expect encode_u64_le(0x123456789ABCDEF0) == [0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12]

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

validate_entries : List(ZipEntry) -> Try({}, CreateError)
validate_entries = |entries| {
	for entry in entries {
		filename_len = entry.path.to_utf8().len()

		if entry.path.is_empty() {
			return Err(EmptyPath(entry.path))
		}
		if filename_len > 65535 {
			return Err(PathTooLong(entry.path))
		}
	}
	Ok({})
}

# 32-bit header fields hold 0xFFFFFFFF (and the 16-bit entry count 0xFFFF)
# when the real value doesn't fit; readers then look for the real value in a
# ZIP64 extra field or the ZIP64 end of central directory record.
zip64_u32_field : U64 -> List(U8)
zip64_u32_field = |value|
	if value >= 0xFFFFFFFF {
		encode_u32_le(0xFFFFFFFF)
	} else {
		encode_u32_le(value.to_u32_wrap())
	}

zip64_u16_field : U64 -> List(U8)
zip64_u16_field = |value|
	if value >= 0xFFFF {
		encode_u16_le(0xFFFF)
	} else {
		encode_u16_le(value.to_u16_wrap())
	}

# Assemble a full archive from entries whose compression has already been
# decided. Builds the pieces with map rather than accumulating lists in a
# fold: list fields of a fold's record accumulator currently lose in-place
# mutation, which makes such a fold quadratic.
build_archive : List(PreparedEntry) -> List(U8)
build_archive = |prepared| {
	local_entries = prepared.map(
		|entry| {
			filename_bytes = entry.path.to_utf8()
			local_extra = local_zip64_extra_field(entry.uncompressed_len, entry.data.len())
			local_header = build_local_file_header(entry.crc, entry.method, entry.data.len(), entry.uncompressed_len, filename_bytes.len(), local_extra.len())
			concat_all([local_header, filename_bytes, local_extra, entry.data])
		},
	)

	# Each entry's local header offset: a running sum of the local entry
	# sizes, with one unused trailing element.
	offsets = local_entries.fold(
		[0],
		|acc, local_entry|
			match acc.last() {
				Ok(prev) => acc.append(prev + local_entry.len())
				Err(_) => acc # Unreachable: the list is never empty
			},
	)

	central_entries = prepared.map_with_index(
		|entry, index| {
			offset = offsets.get(index) ?? 0
			filename_bytes = entry.path.to_utf8()
			central_extra = central_zip64_extra_field(entry.uncompressed_len, entry.data.len(), offset)
			central_header = build_central_dir_header(entry.crc, entry.method, entry.data.len(), entry.uncompressed_len, filename_bytes.len(), offset, central_extra.len())
			concat_all([central_header, filename_bytes, central_extra])
		},
	)

	local_data = concat_all(local_entries)
	central_dir_offset = local_data.len()
	central_dir = concat_all(central_entries)
	central_dir_size = central_dir.len()
	entry_count = prepared.len()
	end_of_central_dir = build_end_of_central_dir(entry_count, central_dir_size, central_dir_offset)

	concat_all([local_data, central_dir, end_of_central_dir])
}

# In the local header, if either size overflows, both 32-bit size fields get
# the sentinel and the ZIP64 extra field must hold both sizes.
local_zip64_extra_field : U64, U64 -> List(U8)
local_zip64_extra_field = |uncompressed_len, compressed_len|
	if uncompressed_len >= 0xFFFFFFFF or compressed_len >= 0xFFFFFFFF {
		concat_all(
			[
				encode_u16_le(zip64_extra_field_id),
				encode_u16_le(16), # Data size
				encode_u64_le(uncompressed_len),
				encode_u64_le(compressed_len),
			],
		)
	} else {
		[]
	}

# In the central directory, a ZIP64 extra field holds only the values whose
# 32-bit fields overflowed, in order: uncompressed size, compressed size,
# local header offset.
central_zip64_extra_field : U64, U64, U64 -> List(U8)
central_zip64_extra_field = |uncompressed_len, compressed_len, offset| {
	uncompressed_part =
		if uncompressed_len >= 0xFFFFFFFF {
			encode_u64_le(uncompressed_len)
		} else {
			[]
		}
	compressed_part =
		if compressed_len >= 0xFFFFFFFF {
			encode_u64_le(compressed_len)
		} else {
			[]
		}
	offset_part =
		if offset >= 0xFFFFFFFF {
			encode_u64_le(offset)
		} else {
			[]
		}
	data = concat_all([uncompressed_part, compressed_part, offset_part])
	if data.len() == 0 {
		[]
	} else {
		concat_all(
			[
				encode_u16_le(zip64_extra_field_id),
				encode_u16_le(data.len().to_u16_wrap()),
				data,
			],
		)
	}
}

build_local_file_header : U32, U16, U64, U64, U64, U64 -> List(U8)
build_local_file_header = |crc, method, compressed_len, uncompressed_len, filename_len, extra_len| {
	sizes_zip64 = uncompressed_len >= 0xFFFFFFFF or compressed_len >= 0xFFFFFFFF
	version =
		if sizes_zip64 {
			version_needed_zip64
		} else {
			version_needed
		}
	size_fields =
		if sizes_zip64 {
			# Both real values live in the ZIP64 extra field
			encode_u32_le(0xFFFFFFFF).concat(encode_u32_le(0xFFFFFFFF))
		} else {
			encode_u32_le(compressed_len.to_u32_wrap()).concat(encode_u32_le(uncompressed_len.to_u32_wrap()))
		}
	concat_all(
		[
			encode_u32_le(local_file_header_sig),
			encode_u16_le(version),
			encode_u16_le(gp_flag_utf8), # General purpose bit flag
			encode_u16_le(method),
			encode_u16_le(0), # Last mod time
			encode_u16_le(dos_date_1980_01_01), # Last mod date
			encode_u32_le(crc),
			size_fields, # Compressed then uncompressed size
			encode_u16_le(filename_len.to_u16_wrap()),
			encode_u16_le(extra_len.to_u16_wrap()),
		],
	)
}

build_central_dir_header : U32, U16, U64, U64, U64, U64, U64 -> List(U8)
build_central_dir_header = |crc, method, compressed_len, uncompressed_len, filename_len, offset, extra_len| {
	version =
		if uncompressed_len >= 0xFFFFFFFF or compressed_len >= 0xFFFFFFFF or offset >= 0xFFFFFFFF {
			version_needed_zip64
		} else {
			version_needed
		}
	concat_all(
		[
			encode_u32_le(central_dir_header_sig),
			encode_u16_le(version), # Version made by
			encode_u16_le(version), # Version needed to extract
			encode_u16_le(gp_flag_utf8), # General purpose bit flag
			encode_u16_le(method),
			encode_u16_le(0), # Last mod time
			encode_u16_le(dos_date_1980_01_01), # Last mod date
			encode_u32_le(crc),
			zip64_u32_field(compressed_len), # Compressed size
			zip64_u32_field(uncompressed_len), # Uncompressed size
			encode_u16_le(filename_len.to_u16_wrap()),
			encode_u16_le(extra_len.to_u16_wrap()),
			encode_u16_le(0), # File comment length
			encode_u16_le(0), # Disk number start
			encode_u16_le(0), # Internal file attributes
			encode_u32_le(0), # External file attributes
			zip64_u32_field(offset), # Relative offset of local header
		],
	)
}

build_end_of_central_dir : U64, U64, U64 -> List(U8)
build_end_of_central_dir = |entry_count, central_dir_size, central_dir_offset| {
	end_record = concat_all(
		[
			encode_u32_le(end_of_central_dir_sig),
			encode_u16_le(0), # Number of this disk
			encode_u16_le(0), # Disk where central directory starts
			zip64_u16_field(entry_count), # Entries on this disk
			zip64_u16_field(entry_count), # Total entries
			zip64_u32_field(central_dir_size), # Size of central directory
			zip64_u32_field(central_dir_offset), # Offset of central directory
			encode_u16_le(0), # Comment length
		],
	)
	needs_zip64 =
		entry_count >= 0xFFFF or central_dir_size >= 0xFFFFFFFF or central_dir_offset >= 0xFFFFFFFF
	if needs_zip64 {
		zip64_record = concat_all(
			[
				encode_u32_le(zip64_eocd_sig),
				encode_u64_le(44), # Size of the record after this field
				encode_u16_le(version_needed_zip64), # Version made by
				encode_u16_le(version_needed_zip64), # Version needed to extract
				encode_u32_le(0), # Number of this disk
				encode_u32_le(0), # Disk where central directory starts
				encode_u64_le(entry_count), # Entries on this disk
				encode_u64_le(entry_count), # Total entries
				encode_u64_le(central_dir_size), # Size of central directory
				encode_u64_le(central_dir_offset), # Offset of central directory
			],
		)
		locator = concat_all(
			[
				encode_u32_le(zip64_eocd_locator_sig),
				encode_u32_le(0), # Disk with the ZIP64 end of central directory
				encode_u64_le(central_dir_offset + central_dir_size), # Its offset
				encode_u32_le(1), # Total number of disks
			],
		)
		concat_all([zip64_record, locator, end_record])
	} else {
		end_record
	}
}

# Find the end of central directory record by scanning backwards from the end
# of the archive (it's followed by a variable-length comment, so its position
# isn't fixed). A candidate only counts if its comment length field points
# exactly at the end of the bytes, which guards against the signature
# appearing by chance inside file content.
find_end_of_central_dir : List(U8) -> Try(U64, [NotFound])
find_end_of_central_dir = |bytes|
	if bytes.len() < 22 {
		Err(NotFound)
	} else {
		scan_for_eocd(bytes, bytes.len() - 22)
	}

scan_for_eocd : List(U8), U64 -> Try(U64, [NotFound])
scan_for_eocd = |bytes, offset| {
	is_eocd =
		match decode_u32_le(bytes, offset) {
			Ok(sig) =>
				if sig == end_of_central_dir_sig {
					match decode_u16_le(bytes, offset + 20) {
						Ok(comment_len) => offset + 22 + comment_len.to_u64() == bytes.len()
						Err(_) => Bool.False
					}
				} else {
					Bool.False
				}
			Err(_) => Bool.False
		}
	if is_eocd {
		Ok(offset)
	} else if offset == 0 {
		Err(NotFound)
	} else {
		scan_for_eocd(bytes, offset - 1)
	}
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

# Walk the central directory, which is the authoritative index of the archive.
# The sizes and CRCs stored here are correct even for streamed archives, whose
# local headers contain zeros (with the real values in data descriptors after
# each entry's content).
extract_central_entries : List(U8), U64, U64, List(ZipEntry) -> Try(List(ZipEntry), ExtractError)
extract_central_entries = |bytes, offset, remaining, acc|
	if remaining == 0 {
		Ok(acc)
	} else {
		# Central directory header layout:
		# 0-3: signature
		# 10-11: compression method
		# 16-19: crc32
		# 20-23: compressed size
		# 28-29: filename length
		# 30-31: extra field length
		# 32-33: comment length
		# 42-45: offset of local header
		# 46+: filename, extra field, comment
		sig = decode_u32_le(bytes, offset) ? |_| TruncatedArchive
		if sig != central_dir_header_sig {
			Err(InvalidSignature)
		} else {
			compression = decode_u16_le(bytes, offset + 10) ? |_| TruncatedArchive
			expected_crc = decode_u32_le(bytes, offset + 16) ? |_| TruncatedArchive
			compressed_size = decode_u32_le(bytes, offset + 20) ? |_| TruncatedArchive
			uncompressed_size = decode_u32_le(bytes, offset + 24) ? |_| TruncatedArchive
			filename_len = decode_u16_le(bytes, offset + 28) ? |_| TruncatedArchive
			extra_len = decode_u16_le(bytes, offset + 30) ? |_| TruncatedArchive
			comment_len = decode_u16_le(bytes, offset + 32) ? |_| TruncatedArchive
			local_header_offset = decode_u32_le(bytes, offset + 42) ? |_| TruncatedArchive

			if compression != compression_method_store and compression != compression_method_deflate {
				Err(CompressionNotSupported(compression))
			} else {
				filename_bytes = bytes.sublist({ start: offset + 46, len: filename_len.to_u64() })
				if filename_bytes.len() != filename_len.to_u64() {
					Err(TruncatedArchive)
				} else {
					path = Str.from_utf8(filename_bytes) ? |_| InvalidFilename
					resolved = resolve_zip64_values(
						bytes,
						offset + 46 + filename_len.to_u64(),
						extra_len.to_u64(),
						{ uncompressed_size, compressed_size, local_header_offset },
					)?
					raw = read_local_content(bytes, resolved.local_header_offset, resolved.compressed_size)?
					content =
						if compression == compression_method_deflate {
							Deflate.decompress(raw) ? |_| InvalidCompressedData(path)
						} else {
							raw
						}

					actual_crc = Crc32.checksum(content)
					if actual_crc != expected_crc {
						Err(CrcMismatch({ path, expected: expected_crc, actual: actual_crc }))
					} else {
						next_offset = offset + 46 + filename_len.to_u64() + extra_len.to_u64() + comment_len.to_u64()
						extract_central_entries(bytes, next_offset, remaining - 1, acc.append({ path, content }))
					}
				}
			}
		}
	}

# 32-bit central directory fields holding 0xFFFFFFFF store their real values
# in a ZIP64 extra field, in order: uncompressed size, compressed size, local
# header offset — each present only if its 32-bit field overflowed.
resolve_zip64_values : List(U8), U64, U64, { uncompressed_size : U32, compressed_size : U32, local_header_offset : U32 } -> Try({ compressed_size : U64, local_header_offset : U64 }, ExtractError)
resolve_zip64_values = |bytes, extra_start, extra_len, fields|
	if fields.uncompressed_size != 0xFFFFFFFF and fields.compressed_size != 0xFFFFFFFF and fields.local_header_offset != 0xFFFFFFFF {
		Ok({ compressed_size: fields.compressed_size.to_u64(), local_header_offset: fields.local_header_offset.to_u64() })
	} else {
		data_start = find_zip64_extra_field(bytes, extra_start, extra_start + extra_len) ? |_| TruncatedArchive
		after_usize =
			if fields.uncompressed_size == 0xFFFFFFFF {
				data_start + 8
			} else {
				data_start
			}
		compressed_size =
			if fields.compressed_size == 0xFFFFFFFF {
				decode_u64_le(bytes, after_usize) ? |_| TruncatedArchive
			} else {
				fields.compressed_size.to_u64()
			}
		after_csize =
			if fields.compressed_size == 0xFFFFFFFF {
				after_usize + 8
			} else {
				after_usize
			}
		local_header_offset =
			if fields.local_header_offset == 0xFFFFFFFF {
				decode_u64_le(bytes, after_csize) ? |_| TruncatedArchive
			} else {
				fields.local_header_offset.to_u64()
			}
		Ok({ compressed_size, local_header_offset })
	}

# Walk the (id, size, data) blocks of an extra field region looking for the
# ZIP64 block, returning the offset of its data.
find_zip64_extra_field : List(U8), U64, U64 -> Try(U64, [NotFound])
find_zip64_extra_field = |bytes, pos, end|
	if pos + 4 > end {
		Err(NotFound)
	} else {
		id = decode_u16_le(bytes, pos) ? |_| NotFound
		data_size = decode_u16_le(bytes, pos + 2) ? |_| NotFound
		if id == zip64_extra_field_id {
			Ok(pos + 4)
		} else {
			find_zip64_extra_field(bytes, pos + 4 + data_size.to_u64(), end)
		}
	}

# Read an entry's content via its local header. The filename and extra field
# lengths must come from the local header (they can differ from the central
# directory copy), but the content size comes from the central directory.
read_local_content : List(U8), U64, U64 -> Try(List(U8), ExtractError)
read_local_content = |bytes, local_offset, size| {
	sig = decode_u32_le(bytes, local_offset) ? |_| TruncatedArchive
	if sig != local_file_header_sig {
		Err(InvalidSignature)
	} else {
		filename_len = decode_u16_le(bytes, local_offset + 26) ? |_| TruncatedArchive
		extra_len = decode_u16_le(bytes, local_offset + 28) ? |_| TruncatedArchive
		content_start = local_offset + 30 + filename_len.to_u64() + extra_len.to_u64()
		if content_start + size > bytes.len() {
			Err(TruncatedArchive)
		} else {
			Ok(bytes.sublist({ start: content_start, len: size }))
		}
	}
}

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
	extra = local_zip64_extra_field(four_gb, four_gb)
	header = build_local_file_header(0, compression_method_store, four_gb, four_gb, 1, extra.len())
	version_ok = header.sublist({ start: 4, len: 2 }) == [45, 0]
	sizes_ok = header.sublist({ start: 18, len: 8 }) == List.repeat(0xFF, 8)
	extra_ok =
		extra
		== concat_all(
			[
				[0x01, 0x00], # ZIP64 extra field id
				[16, 0], # Data size
				[0, 0, 0, 0, 1, 0, 0, 0], # Uncompressed size: 2^32
				[0, 0, 0, 0, 1, 0, 0, 0], # Compressed size: 2^32
			],
		)
	version_ok and sizes_ok and extra_ok
}

# An entry whose local header sits past 4GB gets a sentinel offset in its
# central directory header, with the real offset in a ZIP64 extra field
expect {
	four_gb = 0x100000000
	extra = central_zip64_extra_field(5, 5, four_gb)
	header = build_central_dir_header(0, compression_method_store, 5, 5, 1, four_gb, extra.len())
	offset_ok = header.sublist({ start: 42, len: 4 }) == List.repeat(0xFF, 4)
	extra_ok =
		extra
		== concat_all(
			[
				[0x01, 0x00], # ZIP64 extra field id
				[8, 0], # Data size
				[0, 0, 0, 0, 1, 0, 0, 0], # Local header offset: 2^32
			],
		)
	offset_ok and extra_ok
}

# Past any of the classic limits, the end of central directory is preceded by
# a ZIP64 end of central directory record and locator
expect {
	end = build_end_of_central_dir(70000, 100, 200)
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
expect {
	content = "Hi".to_utf8()
	crc = Crc32.checksum(content)
	filename = "a".to_utf8()
	local = concat_all(
		[
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
		],
	)
	central = concat_all(
		[
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
		],
	)
	archive = concat_all([local, central, build_end_of_central_dir(1, central.len(), local.len())])
	Zip.extract(archive) == Ok([{ path: "a", content }])
}

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
	original = List.repeat({ path: "x", content: [] }, 65536)
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
build_test_archive = |{ method, crc, filename, content }| {
	local = concat_all(
		[
			encode_u32_le(local_file_header_sig),
			encode_u16_le(version_needed),
			encode_u16_le(0), # General purpose bit flag
			encode_u16_le(method),
			encode_u16_le(0), # Last mod time
			encode_u16_le(dos_date_1980_01_01),
			encode_u32_le(crc),
			encode_u32_le(content.len().to_u32_wrap()), # Compressed size
			encode_u32_le(content.len().to_u32_wrap()), # Uncompressed size
			encode_u16_le(filename.len().to_u16_wrap()),
			encode_u16_le(0), # Extra field length
			filename,
			content,
		],
	)
	central = concat_all(
		[
			encode_u32_le(central_dir_header_sig),
			encode_u16_le(version_needed), # Version made by
			encode_u16_le(version_needed), # Version needed to extract
			encode_u16_le(0), # General purpose bit flag
			encode_u16_le(method),
			encode_u16_le(0), # Last mod time
			encode_u16_le(dos_date_1980_01_01),
			encode_u32_le(crc),
			encode_u32_le(content.len().to_u32_wrap()), # Compressed size
			encode_u32_le(content.len().to_u32_wrap()), # Uncompressed size
			encode_u16_le(filename.len().to_u16_wrap()),
			encode_u16_le(0), # Extra field length
			encode_u16_le(0), # File comment length
			encode_u16_le(0), # Disk number start
			encode_u16_le(0), # Internal file attributes
			encode_u32_le(0), # External file attributes
			encode_u32_le(0), # Offset of local header
			filename,
		],
	)
	end = build_end_of_central_dir(1, central.len(), local.len())
	local.concat(central).concat(end)
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
expect {
	content = "Hello, World!".to_utf8()
	crc = Crc32.checksum(content)
	filename = "hello.txt".to_utf8()
	local = concat_all(
		[
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
		],
	)
	central = concat_all(
		[
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
		],
	)
	archive = local.concat(central).concat(build_end_of_central_dir(1, central.len(), local.len()))
	Zip.extract(archive) == Ok([{ path: "hello.txt", content }])
}

# Real-world interop: a store-mode archive created by Info-ZIP's `zip -0`,
# containing a directory entry and Unix timestamp/permission extra fields.
expect {
	fixture = [80,75,3,4,10,0,0,0,0,0,227,189,231,92,208,195,74,236,13,0,0,0,13,0,0,0,9,0,28,0,104,101,108,108,111,46,116,120,116,85,84,9,0,3,218,115,77,106,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,72,101,108,108,111,44,32,87,111,114,108,100,33,80,75,3,4,10,0,0,0,0,0,227,189,231,92,0,0,0,0,0,0,0,0,0,0,0,0,4,0,28,0,100,105,114,47,85,84,9,0,3,218,115,77,106,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,80,75,3,4,10,0,0,0,0,0,227,189,231,92,233,194,201,170,6,0,0,0,6,0,0,0,9,0,28,0,100,105,114,47,110,46,116,120,116,85,84,9,0,3,218,115,77,106,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,110,101,115,116,101,100,80,75,1,2,30,3,10,0,0,0,0,0,227,189,231,92,208,195,74,236,13,0,0,0,13,0,0,0,9,0,24,0,0,0,0,0,0,0,0,0,164,129,0,0,0,0,104,101,108,108,111,46,116,120,116,85,84,5,0,3,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,80,75,1,2,30,3,10,0,0,0,0,0,227,189,231,92,0,0,0,0,0,0,0,0,0,0,0,0,4,0,24,0,0,0,0,0,0,0,16,0,237,65,80,0,0,0,100,105,114,47,85,84,5,0,3,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,80,75,1,2,30,3,10,0,0,0,0,0,227,189,231,92,233,194,201,170,6,0,0,0,6,0,0,0,9,0,24,0,0,0,0,0,0,0,0,0,164,129,142,0,0,0,100,105,114,47,110,46,116,120,116,85,84,5,0,3,218,115,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,80,75,5,6,0,0,0,0,3,0,3,0,232,0,0,0,215,0,0,0,0,0]
	match Zip.extract(fixture) {
		Ok(entries) => {
			paths = entries.map(|e| e.path)
			contents = entries.map(|e| e.content)
			paths == ["hello.txt", "dir/", "dir/n.txt"]
				and contents == [ "Hello, World!".to_utf8(), [], "nested".to_utf8() ]
		}
		Err(_) => Bool.False
	}
}

# Real-world interop: a ZIP64 store-mode archive created by bsdtar, with a
# ZIP64 end of central directory record and ZIP64 extra fields.
expect {
	fixture = [80,75,3,4,45,0,8,0,0,0,227,189,231,92,0,0,0,0,0,0,0,0,0,0,0,0,9,0,32,0,104,101,108,108,111,46,116,120,116,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,85,84,13,0,7,218,115,77,106,218,115,77,106,218,115,77,106,72,101,108,108,111,44,32,87,111,114,108,100,33,80,75,7,8,208,195,74,236,13,0,0,0,0,0,0,0,13,0,0,0,0,0,0,0,80,75,1,2,45,3,45,0,8,0,0,0,227,189,231,92,208,195,74,236,13,0,0,0,13,0,0,0,9,0,24,0,0,0,0,0,0,0,0,0,164,129,0,0,0,0,104,101,108,108,111,46,116,120,116,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,85,84,5,0,1,218,115,77,106,80,75,6,6,44,0,0,0,0,0,0,0,45,0,45,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,79,0,0,0,0,0,0,0,108,0,0,0,0,0,0,0,80,75,6,7,0,0,0,0,187,0,0,0,0,0,0,0,1,0,0,0,80,75,5,6,0,0,0,0,1,0,1,0,79,0,0,0,108,0,0,0,0,0]
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
	fixture = [80,75,3,4,20,0,2,0,8,0,9,9,232,92,16,76,200,228,133,0,0,0,4,1,0,0,11,0,28,0,100,121,110,116,101,115,116,46,116,120,116,85,84,9,0,3,225,134,77,106,225,134,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,141,78,203,21,130,64,12,188,91,197,20,224,163,9,91,160,129,0,1,86,96,179,38,89,22,173,94,228,61,46,94,244,54,191,55,51,245,200,120,228,208,78,104,84,74,68,47,27,238,121,73,6,89,89,225,187,61,211,235,137,78,134,10,245,255,97,208,64,33,130,98,247,141,42,220,100,73,202,102,65,34,138,232,100,104,216,28,101,228,8,231,205,161,156,152,220,16,220,120,238,175,63,56,246,246,149,52,72,54,20,122,218,49,117,10,105,166,150,109,191,166,146,135,81,178,31,47,79,247,179,86,93,222,80,75,1,2,30,3,20,0,2,0,8,0,9,9,232,92,16,76,200,228,133,0,0,0,4,1,0,0,11,0,24,0,0,0,0,0,1,0,0,0,164,129,0,0,0,0,100,121,110,116,101,115,116,46,116,120,116,85,84,5,0,3,225,134,77,106,117,120,11,0,1,4,232,3,0,0,4,100,0,0,0,80,75,5,6,0,0,0,0,1,0,1,0,81,0,0,0,202,0,0,0,0,0]
	original = [84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,46,32,84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,32,97,103,97,105,110,32,97,110,100,32,97,103,97,105,110,32,97,110,100,32,97,103,97,105,110,46,32,67,111,109,112,114,101,115,115,105,111,110,32,119,111,114,107,115,32,98,101,115,116,32,119,104,101,110,32,116,101,120,116,32,114,101,112,101,97,116,115,32,105,116,115,101,108,102,44,32,114,101,112,101,97,116,115,32,105,116,115,101,108,102,44,32,114,101,112,101,97,116,115,32,105,116,115,101,108,102,32,105,110,32,118,97,114,105,111,117,115,32,119,97,121,115,32,97,110,100,32,118,97,114,105,111,117,115,32,112,108,97,99,101,115,32,116,104,114,111,117,103,104,111,117,116,32,116,104,101,32,118,97,114,105,111,117,115,32,116,101,120,116,46,10]
	match Zip.extract(fixture) {
		Ok(entries) => entries.map(|e| e.path) == ["dyntest.txt"]
			and entries.map(|e| e.content) == [original]
		Err(_) => Bool.False
	}
}
