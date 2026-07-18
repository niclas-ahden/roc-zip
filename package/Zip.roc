## Create and extract ZIP archives in Roc.
##
## Uses store-only mode (no compression), suitable for already-compressed data
## or when size doesn't matter, and supports files up to 4 GB in size. We'll
## probably support compression and larger files in the future.
import crc32.Crc32

local_file_header_sig : U32
local_file_header_sig = 0x04034b50

central_dir_header_sig : U32
central_dir_header_sig = 0x02014b50

end_of_central_dir_sig : U32
end_of_central_dir_sig = 0x06054b50

version_needed : U16
version_needed = 20

compression_method_store : U16
compression_method_store = 0

## A file entry in the archive.
##
## The `path` can include directories (e.g. `"foo/bar.txt"`).
ZipEntry : { path : Str, content : List(U8) }

## Errors that can occur when creating a ZIP archive.
CreateError : [
	EmptyPath(Str),
	PathTooLong(Str),
	FileTooLarge(Str),
]

## Errors that can occur when extracting a ZIP archive.
ExtractError : [
	InvalidSignature,
	CompressionNotSupported(U16),
	CrcMismatch({ path : Str, expected : U32, actual : U32 }),
	InvalidFilename,
	TruncatedArchive,
]

Zip := [].{

	## Create a ZIP archive from a list of entries. Returns the archive as bytes.
	##
	## ```roc
	## match Zip.create([
	## 	{ path: "hello.txt", content: "Hello!".to_utf8() },
	## 	{ path: "data/info.json", content: "{}".to_utf8() },
	## ]) {
	## 	Ok(archive) => # Use the archive bytes
	## 	Err(EmptyPath(path)) => # Path was empty
	## 	Err(PathTooLong(path)) => # Path exceeds 65535 bytes
	## 	Err(FileTooLarge(path)) => # File exceeds 4GB
	## }
	## ```
	create : List(ZipEntry) -> Try(List(U8), CreateError)
	create = |entries| {
		validate_entries(entries)?

		state = { offset: 0, local_entries: [], central_entries: [] }

		final_state = entries.fold(
			state,
			|acc, entry| {
				crc = Crc32.checksum(entry.content)
				filename_bytes = entry.path.to_utf8()
				filename_len = filename_bytes.len()
				content_len = entry.content.len()

				local_header = build_local_file_header(crc, content_len, filename_len)
				local_entry = local_header.concat(filename_bytes).concat(entry.content)

				central_header = build_central_dir_header(crc, content_len, filename_len, acc.offset)
				central_entry = central_header.concat(filename_bytes)

				local_size = local_entry.len()
				{
					offset: acc.offset + local_size,
					local_entries: acc.local_entries.append(local_entry),
					central_entries: acc.central_entries.append(central_entry),
				}
			},
		)

		local_data = concat_all(final_state.local_entries)
		central_dir_offset = local_data.len()
		central_dir = concat_all(final_state.central_entries)
		central_dir_size = central_dir.len()
		entry_count = entries.len()
		end_of_central_dir = build_end_of_central_dir(entry_count, central_dir_size, central_dir_offset)

		Ok(local_data.concat(central_dir).concat(end_of_central_dir))
	}

	## Extract entries from a ZIP archive.
	##
	## ```roc
	## match Zip.extract(zip_bytes) {
	## 	Ok(entries) => # List of { path, content }
	## 	Err(InvalidSignature) => # Not a valid ZIP file
	## 	Err(CompressionNotSupported(method)) => # Only store method supported
	## 	Err(CrcMismatch({ path, expected, actual })) => # Data corruption
	## 	Err(InvalidFilename) => # Filename is not valid UTF-8
	## 	Err(TruncatedArchive) => # Archive is incomplete
	## }
	## ```
	extract : List(U8) -> Try(List(ZipEntry), ExtractError)
	extract = |bytes|
		extract_entries(bytes, 0, [])
}

# Concatenate a list of byte lists into one.
concat_all : List(List(U8)) -> List(U8)
concat_all = |parts|
	parts.fold([], |acc, part| acc.concat(part))

encode_u16_le : U16 -> List(U8)
encode_u16_le = |n|
	[n.to_u8_wrap(), n.shift_right_by(8).to_u8_wrap()]

encode_u32_le : U32 -> List(U8)
encode_u32_le = |n|
	[
		n.to_u8_wrap(),
		n.shift_right_by(8).to_u8_wrap(),
		n.shift_right_by(16).to_u8_wrap(),
		n.shift_right_by(24).to_u8_wrap(),
	]

expect encode_u16_le(0x1234) == [0x34, 0x12]
expect encode_u32_le(0x12345678) == [0x78, 0x56, 0x34, 0x12]

decode_u16_le : List(U8), U64 -> Try(U16, [OutOfBounds])
decode_u16_le = |bytes, offset| {
	b0 = bytes.get(offset)?
	b1 = bytes.get(offset + 1)?
	Ok(b0.to_u16() + b1.to_u16().shift_left_by(8))
}

decode_u32_le : List(U8), U64 -> Try(U32, [OutOfBounds])
decode_u32_le = |bytes, offset| {
	b0 = bytes.get(offset)?
	b1 = bytes.get(offset + 1)?
	b2 = bytes.get(offset + 2)?
	b3 = bytes.get(offset + 3)?
	Ok(
		b0.to_u32()
			+ b1.to_u32().shift_left_by(8)
			+ b2.to_u32().shift_left_by(16)
			+ b3.to_u32().shift_left_by(24),
	)
}

expect decode_u16_le([0x34, 0x12], 0) == Ok(0x1234)
expect decode_u32_le([0x78, 0x56, 0x34, 0x12], 0) == Ok(0x12345678)

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
		if entry.content.len() > 0xFFFFFFFF {
			return Err(FileTooLarge(entry.path))
		}
	}
	Ok({})
}

build_local_file_header : U32, U64, U64 -> List(U8)
build_local_file_header = |crc, content_len, filename_len|
	concat_all(
		[
			encode_u32_le(local_file_header_sig),
			encode_u16_le(version_needed),
			encode_u16_le(0), # General purpose bit flag
			encode_u16_le(compression_method_store),
			encode_u16_le(0), # Last mod time
			encode_u16_le(0), # Last mod date
			encode_u32_le(crc),
			encode_u32_le(content_len.to_u32_wrap()), # Compressed size
			encode_u32_le(content_len.to_u32_wrap()), # Uncompressed size
			encode_u16_le(filename_len.to_u16_wrap()),
			encode_u16_le(0), # Extra field length
		],
	)

build_central_dir_header : U32, U64, U64, U64 -> List(U8)
build_central_dir_header = |crc, content_len, filename_len, offset|
	concat_all(
		[
			encode_u32_le(central_dir_header_sig),
			encode_u16_le(version_needed), # Version made by
			encode_u16_le(version_needed), # Version needed to extract
			encode_u16_le(0), # General purpose bit flag
			encode_u16_le(compression_method_store),
			encode_u16_le(0), # Last mod time
			encode_u16_le(0), # Last mod date
			encode_u32_le(crc),
			encode_u32_le(content_len.to_u32_wrap()), # Compressed size
			encode_u32_le(content_len.to_u32_wrap()), # Uncompressed size
			encode_u16_le(filename_len.to_u16_wrap()),
			encode_u16_le(0), # Extra field length
			encode_u16_le(0), # File comment length
			encode_u16_le(0), # Disk number start
			encode_u16_le(0), # Internal file attributes
			encode_u32_le(0), # External file attributes
			encode_u32_le(offset.to_u32_wrap()), # Relative offset of local header
		],
	)

build_end_of_central_dir : U64, U64, U64 -> List(U8)
build_end_of_central_dir = |entry_count, central_dir_size, central_dir_offset|
	concat_all(
		[
			encode_u32_le(end_of_central_dir_sig),
			encode_u16_le(0), # Number of this disk
			encode_u16_le(0), # Disk where central directory starts
			encode_u16_le(entry_count.to_u16_wrap()), # Entries on this disk
			encode_u16_le(entry_count.to_u16_wrap()), # Total entries
			encode_u32_le(central_dir_size.to_u32_wrap()), # Size of central directory
			encode_u32_le(central_dir_offset.to_u32_wrap()), # Offset of central directory
			encode_u16_le(0), # Comment length
		],
	)

extract_entries : List(U8), U64, List(ZipEntry) -> Try(List(ZipEntry), ExtractError)
extract_entries = |bytes, offset, acc|
# Stop once we run out of bytes or reach the central directory.
	match decode_u32_le(bytes, offset) {
		Err(OutOfBounds) => Ok(acc)
		Ok(sig) =>
			if sig == local_file_header_sig {
				{ entry, next_offset } = parse_local_file_entry(bytes, offset)?
				extract_entries(bytes, next_offset, acc.append(entry))
			} else if sig == central_dir_header_sig or sig == end_of_central_dir_sig {
				Ok(acc)
			} else {
				Err(InvalidSignature)
			}
		}

parse_local_file_entry : List(U8), U64 -> Try({ entry : ZipEntry, next_offset : U64 }, ExtractError)
parse_local_file_entry = |bytes, offset| {
	# Local file header layout:
	# 0-3: signature (already checked)
	# 8-9: compression method
	# 14-17: crc32
	# 18-21: compressed size
	# 26-27: filename length
	# 28-29: extra field length
	# 30+: filename, extra field, content
	compression = decode_u16_le(bytes, offset + 8) ? |_| TruncatedArchive
	if compression != compression_method_store {
		Err(CompressionNotSupported(compression))
	} else {
		expected_crc = decode_u32_le(bytes, offset + 14) ? |_| TruncatedArchive
		compressed_size = decode_u32_le(bytes, offset + 18) ? |_| TruncatedArchive
		filename_len = decode_u16_le(bytes, offset + 26) ? |_| TruncatedArchive
		extra_len = decode_u16_le(bytes, offset + 28) ? |_| TruncatedArchive

		filename_start = offset + 30
		filename_bytes = bytes.sublist({ start: filename_start, len: filename_len.to_u64() })
		path = Str.from_utf8(filename_bytes) ? |_| InvalidFilename

		content_start = filename_start + filename_len.to_u64() + extra_len.to_u64()
		content = bytes.sublist({ start: content_start, len: compressed_size.to_u64() })

		actual_crc = Crc32.checksum(content)
		if actual_crc != expected_crc {
			Err(CrcMismatch({ path, expected: expected_crc, actual: actual_crc }))
		} else {
			next_offset = content_start + compressed_size.to_u64()
			Ok({ entry: { path, content }, next_offset })
		}
	}
}

# Round-trip tests

# Single file round-trip
expect {
	original = [{ path: "test.txt", content: "Hello, World!".to_utf8() }]
	match Zip.create(original) {
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
	match Zip.create(original) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Empty content round-trip
expect {
	original = [{ path: "empty.txt", content: [] }]
	match Zip.create(original) {
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
	match Zip.create(original) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Empty archive round-trip
expect {
	original : List(ZipEntry)
	original = []
	match Zip.create(original) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Binary content round-trip
expect {
	original = [{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] }]
	match Zip.create(original) {
		Ok(zip_bytes) => Zip.extract(zip_bytes) == Ok(original)
		Err(_) => Bool.False
	}
}

# Structural tests

# Verify local file header signature
expect {
	match Zip.create([{ path: "x", content: [] }]) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 0, len: 4 }) == [0x50, 0x4B, 0x03, 0x04]
		Err(_) => Bool.False
	}
}

# Verify central directory signature appears after local entries
expect {
	match Zip.create([{ path: "x", content: [] }]) {
		# Local header (30) + filename (1) + content (0) = 31
		Ok(zip_bytes) => zip_bytes.sublist({ start: 31, len: 4 }) == [0x50, 0x4B, 0x01, 0x02]
		Err(_) => Bool.False
	}
}

# Verify end of central directory signature
expect {
	match Zip.create([{ path: "x", content: [] }]) {
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
	match Zip.create([{ path: "x", content: "123456789".to_utf8() }]) {
		# CRC32 of "123456789" is 0xCBF43926, stored little-endian
		Ok(zip_bytes) => zip_bytes.sublist({ start: 14, len: 4 }) == [0x26, 0x39, 0xF4, 0xCB]
		Err(_) => Bool.False
	}
}

# Verify file size is stored correctly (offset 18-21 compressed, 22-25 uncompressed)
expect {
	content = "Hello".to_utf8() # 5 bytes
	match Zip.create([{ path: "x", content }]) {
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
	match Zip.create([{ path: "test.txt", content: [] }]) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 26, len: 2 }) == [0x08, 0x00]
		Err(_) => Bool.False
	}
}

# Verify filename is stored correctly (starts at offset 30)
expect {
	match Zip.create([{ path: "abc", content: [] }]) {
		Ok(zip_bytes) => zip_bytes.sublist({ start: 30, len: 3 }) == [0x61, 0x62, 0x63] # "abc"
		Err(_) => Bool.False
	}
}

# Verify content is stored correctly (after header + filename)
expect {
	match Zip.create([{ path: "x", content: [0xDE, 0xAD, 0xBE, 0xEF] }]) {
		# Header (30) + filename (1) = 31, then content
		Ok(zip_bytes) => zip_bytes.sublist({ start: 31, len: 4 }) == [0xDE, 0xAD, 0xBE, 0xEF]
		Err(_) => Bool.False
	}
}

# Verify empty archive has only end of central directory (22 bytes)
expect {
	match Zip.create([]) {
		Ok(zip_bytes) => zip_bytes.len() == 22 and zip_bytes.sublist({ start: 0, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]
		Err(_) => Bool.False
	}
}

# Error tests

# Empty path returns EmptyPath error
expect {
	result = Zip.create([{ path: "", content: [] }])
	result == Err(EmptyPath(""))
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

# Compressed ZIP returns CompressionNotSupported error
expect {
	# A valid-looking header but with deflate compression method (8)
	compressed_header = concat_all(
		[
			[0x50, 0x4B, 0x03, 0x04], # Local file header signature
			[0x14, 0x00], # Version needed
			[0x00, 0x00], # General purpose bit flag
			[0x08, 0x00], # Compression method: 8 = deflate (not store)
			[0x00, 0x00], # Last mod time
			[0x00, 0x00], # Last mod date
			[0x00, 0x00, 0x00, 0x00], # CRC32
			[0x00, 0x00, 0x00, 0x00], # Compressed size
			[0x00, 0x00, 0x00, 0x00], # Uncompressed size
			[0x01, 0x00], # Filename length: 1
			[0x00, 0x00], # Extra field length: 0
			[0x78], # Filename: "x"
		],
	)
	result = Zip.extract(compressed_header)
	result == Err(CompressionNotSupported(8))
}

# CRC mismatch returns CrcMismatch error
expect {
	# A header with wrong CRC (0x12345678 instead of correct CRC)
	bad_crc_header = concat_all(
		[
			[0x50, 0x4B, 0x03, 0x04], # Local file header signature
			[0x14, 0x00], # Version needed
			[0x00, 0x00], # General purpose bit flag
			[0x00, 0x00], # Compression method: 0 = store
			[0x00, 0x00], # Last mod time
			[0x00, 0x00], # Last mod date
			[0x78, 0x56, 0x34, 0x12], # CRC32: wrong value
			[0x05, 0x00, 0x00, 0x00], # Compressed size: 5
			[0x05, 0x00, 0x00, 0x00], # Uncompressed size: 5
			[0x01, 0x00], # Filename length: 1
			[0x00, 0x00], # Extra field length: 0
			[0x78], # Filename: "x"
			[0x48, 0x65, 0x6C, 0x6C, 0x6F], # Content: "Hello"
		],
	)
	match Zip.extract(bad_crc_header) {
		Err(CrcMismatch({ path: "x", expected: 0x12345678, actual: _ })) => Bool.True
		_ => Bool.False
	}
}

# Invalid UTF-8 filename returns InvalidFilename error
expect {
	invalid_utf8_header = concat_all(
		[
			[0x50, 0x4B, 0x03, 0x04], # Local file header signature
			[0x14, 0x00], # Version needed
			[0x00, 0x00], # General purpose bit flag
			[0x00, 0x00], # Compression method: 0 = store
			[0x00, 0x00], # Last mod time
			[0x00, 0x00], # Last mod date
			[0x00, 0x00, 0x00, 0x00], # CRC32
			[0x00, 0x00, 0x00, 0x00], # Compressed size: 0
			[0x00, 0x00, 0x00, 0x00], # Uncompressed size: 0
			[0x02, 0x00], # Filename length: 2
			[0x00, 0x00], # Extra field length: 0
			[0xFF, 0xFE], # Invalid UTF-8 bytes
		],
	)
	result = Zip.extract(invalid_utf8_header)
	result == Err(InvalidFilename)
}
