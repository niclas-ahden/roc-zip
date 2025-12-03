## Create and extract ZIP archives in Roc.
##
## Uses store-only mode (no compression), suitable for already-compressed data
## or when size doesn't matter, and supports files up to 4 GB in size. We'll probably support compression and larger files in the future.
##
## Example:
##
##     when Zip.create([
##         { path: "hello.txt", content: Str.to_utf8("Hello!") },
##     ]) is
##         Ok(archive) -> # Use the archive bytes
##         Err(e) -> # Handle error
##
##     when Zip.extract(zip_bytes) is
##         Ok(entries) -> # List of { path, content }
##         Err(e) -> # Handle error
module [
    ZipEntry,
    CreateError,
    ExtractError,
    create,
    extract,
]

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
## The `path` can include directories (e.g., `"foo/bar.txt"`).
ZipEntry : { path : Str, content : List U8 }

## Errors that can occur when creating a ZIP archive.
CreateError : [
    EmptyPath Str,
    PathTooLong Str,
    FileTooLarge Str,
]

## Errors that can occur when extracting a ZIP archive.
ExtractError : [
    InvalidSignature,
    CompressionNotSupported U16,
    CrcMismatch { path : Str, expected : U32, actual : U32 },
    InvalidFilename,
    TruncatedArchive,
]

encode_u16_le : U16 -> List U8
encode_u16_le = |n|
    low = Num.bitwise_and(n, 0xFF) |> Num.to_u8
    high = Num.shift_right_by(n, 8) |> Num.to_u8
    [low, high]

encode_u32_le : U32 -> List U8
encode_u32_le = |n|
    b0 = Num.bitwise_and(n, 0xFF) |> Num.to_u8
    b1 = Num.bitwise_and(Num.shift_right_by(n, 8), 0xFF) |> Num.to_u8
    b2 = Num.bitwise_and(Num.shift_right_by(n, 16), 0xFF) |> Num.to_u8
    b3 = Num.shift_right_by(n, 24) |> Num.to_u8
    [b0, b1, b2, b3]

expect encode_u16_le(0x1234) == [0x34, 0x12]
expect encode_u32_le(0x12345678) == [0x78, 0x56, 0x34, 0x12]

decode_u16_le : List U8, U64 -> Result U16 [OutOfBounds]
decode_u16_le = |bytes, offset|
    b0 = List.get(bytes, offset)?
    b1 = List.get(bytes, offset + 1)?
    Ok(Num.to_u16(b0) + Num.shift_left_by(Num.to_u16(b1), 8))

decode_u32_le : List U8, U64 -> Result U32 [OutOfBounds]
decode_u32_le = |bytes, offset|
    b0 = List.get(bytes, offset)?
    b1 = List.get(bytes, offset + 1)?
    b2 = List.get(bytes, offset + 2)?
    b3 = List.get(bytes, offset + 3)?
    Ok(
        Num.to_u32(b0)
        + Num.shift_left_by(Num.to_u32(b1), 8)
        + Num.shift_left_by(Num.to_u32(b2), 16)
        + Num.shift_left_by(Num.to_u32(b3), 24),
    )

expect decode_u16_le([0x34, 0x12], 0) == Ok(0x1234)
expect decode_u32_le([0x78, 0x56, 0x34, 0x12], 0) == Ok(0x12345678)

## Create a ZIP archive from a list of entries. Returns the archive as bytes.
##
##     when Zip.create([
##         { path: "hello.txt", content: Str.to_utf8("Hello!") },
##         { path: "data/info.json", content: Str.to_utf8("{}") },
##     ]) is
##         Ok(archive) -> # Use the archive bytes
##         Err(EmptyPath(path)) -> # Path was empty
##         Err(PathTooLong(path)) -> # Path exceeds 65535 bytes
##         Err(FileTooLarge(path)) -> # File exceeds 4GB
##
create : List ZipEntry -> Result (List U8) CreateError
create = |entries|
    when validate_entries(entries) is
        Err(e) -> Err(e)
        Ok({}) ->
            state = { offset: 0, local_entries: [], central_entries: [] }

            final_state =
                entries
                |> List.walk(
                    state,
                    |acc, entry|
                        crc = Crc32.checksum(entry.content)
                        filename_bytes = Str.to_utf8(entry.path)
                        filename_len = List.len(filename_bytes)
                        content_len = List.len(entry.content)

                        local_header = build_local_file_header(crc, content_len, filename_len)
                        local_entry =
                            List.concat(
                                local_header,
                                List.concat(filename_bytes, entry.content),
                            )

                        central_header = build_central_dir_header(crc, content_len, filename_len, acc.offset)
                        central_entry = List.concat(central_header, filename_bytes)

                        local_size = List.len(local_entry)
                        {
                            offset: acc.offset + local_size,
                            local_entries: List.append(acc.local_entries, local_entry),
                            central_entries: List.append(acc.central_entries, central_entry),
                        },
                )

            local_data = List.join(final_state.local_entries)
            central_dir_offset = List.len(local_data)
            central_dir = List.join(final_state.central_entries)
            central_dir_size = List.len(central_dir)
            entry_count = List.len(entries)
            end_of_central_dir = build_end_of_central_dir(entry_count, central_dir_size, central_dir_offset)

            Ok(List.concat(local_data, List.concat(central_dir, end_of_central_dir)))

validate_entries : List ZipEntry -> Result {} CreateError
validate_entries = |entries|
    List.walk_until(
        entries,
        Ok({}),
        |_, entry|
            filename_bytes = Str.to_utf8(entry.path)
            filename_len = List.len(filename_bytes)
            content_len = List.len(entry.content)

            if Str.is_empty(entry.path) then
                Break(Err(EmptyPath(entry.path)))
            else if filename_len > 65535 then
                Break(Err(PathTooLong(entry.path)))
            else if content_len > 0xFFFFFFFF then
                Break(Err(FileTooLarge(entry.path)))
            else
                Continue(Ok({})),
    )

build_local_file_header : U32, U64, U64 -> List U8
build_local_file_header = |crc, content_len, filename_len|
    List.join(
        [
            encode_u32_le(local_file_header_sig),
            encode_u16_le(version_needed),
            encode_u16_le(0), # General purpose bit flag
            encode_u16_le(compression_method_store),
            encode_u16_le(0), # Last mod time
            encode_u16_le(0), # Last mod date
            encode_u32_le(crc),
            encode_u32_le(Num.to_u32(content_len)), # Compressed size
            encode_u32_le(Num.to_u32(content_len)), # Uncompressed size
            encode_u16_le(Num.to_u16(filename_len)),
            encode_u16_le(0), # Extra field length
        ],
    )

build_central_dir_header : U32, U64, U64, U64 -> List U8
build_central_dir_header = |crc, content_len, filename_len, offset|
    List.join(
        [
            encode_u32_le(central_dir_header_sig),
            encode_u16_le(version_needed), # Version made by
            encode_u16_le(version_needed), # Version needed to extract
            encode_u16_le(0), # General purpose bit flag
            encode_u16_le(compression_method_store),
            encode_u16_le(0), # Last mod time
            encode_u16_le(0), # Last mod date
            encode_u32_le(crc),
            encode_u32_le(Num.to_u32(content_len)), # Compressed size
            encode_u32_le(Num.to_u32(content_len)), # Uncompressed size
            encode_u16_le(Num.to_u16(filename_len)),
            encode_u16_le(0), # Extra field length
            encode_u16_le(0), # File comment length
            encode_u16_le(0), # Disk number start
            encode_u16_le(0), # Internal file attributes
            encode_u32_le(0), # External file attributes
            encode_u32_le(Num.to_u32(offset)), # Relative offset of local header
        ],
    )

build_end_of_central_dir : U64, U64, U64 -> List U8
build_end_of_central_dir = |entry_count, central_dir_size, central_dir_offset|
    List.join(
        [
            encode_u32_le(end_of_central_dir_sig),
            encode_u16_le(0), # Number of this disk
            encode_u16_le(0), # Disk where central directory starts
            encode_u16_le(Num.to_u16(entry_count)), # Entries on this disk
            encode_u16_le(Num.to_u16(entry_count)), # Total entries
            encode_u32_le(Num.to_u32(central_dir_size)), # Size of central directory
            encode_u32_le(Num.to_u32(central_dir_offset)), # Offset of central directory
            encode_u16_le(0), # Comment length
        ],
    )

## Extract entries from a ZIP archive.
##
##     when Zip.extract(zip_bytes) is
##         Ok(entries) -> # List of { path, content }
##         Err(InvalidSignature) -> # Not a valid ZIP file
##         Err(CompressionNotSupported(method)) -> # Only store method supported
##         Err(CrcMismatch({ path, expected, actual })) -> # Data corruption
##         Err(InvalidFilename) -> # Filename is not valid UTF-8
##         Err(TruncatedArchive) -> # Archive is incomplete
##
extract : List U8 -> Result (List ZipEntry) ExtractError
extract = |bytes|
    extract_entries(bytes, 0, [])

extract_entries : List U8, U64, List ZipEntry -> Result (List ZipEntry) ExtractError
extract_entries = |bytes, offset, acc|
    # Check if we've reached central directory or end
    sig_result = decode_u32_le(bytes, offset)
    when sig_result is
        Err(OutOfBounds) -> Ok(acc)
        Ok(sig) ->
            if sig == local_file_header_sig then
                when parse_local_file_entry(bytes, offset) is
                    Ok({ entry, next_offset }) ->
                        extract_entries(bytes, next_offset, List.append(acc, entry))

                    Err(e) -> Err(e)
            else if sig == central_dir_header_sig or sig == end_of_central_dir_sig then
                # Reached central directory or end - done with entries
                Ok(acc)
            else
                Err(InvalidSignature)

parse_local_file_entry : List U8, U64 -> Result { entry : ZipEntry, next_offset : U64 } ExtractError
parse_local_file_entry = |bytes, offset|
    # Local file header structure:
    # 0-3: signature (already checked)
    # 4-5: version needed
    # 6-7: general purpose bit flag
    # 8-9: compression method
    # 10-11: last mod time
    # 12-13: last mod date
    # 14-17: crc32
    # 18-21: compressed size
    # 22-25: uncompressed size
    # 26-27: filename length
    # 28-29: extra field length
    # 30+: filename, extra field, content

    compression = decode_u16_le(bytes, offset + 8) |> Result.map_err(|_| TruncatedArchive)?
    if compression != compression_method_store then
        Err(CompressionNotSupported(compression))
    else
        expected_crc = decode_u32_le(bytes, offset + 14) |> Result.map_err(|_| TruncatedArchive)?
        compressed_size = decode_u32_le(bytes, offset + 18) |> Result.map_err(|_| TruncatedArchive)?
        filename_len = decode_u16_le(bytes, offset + 26) |> Result.map_err(|_| TruncatedArchive)?
        extra_len = decode_u16_le(bytes, offset + 28) |> Result.map_err(|_| TruncatedArchive)?

        filename_start = offset + 30
        filename_bytes = List.sublist(bytes, { start: filename_start, len: Num.to_u64(filename_len) })
        path = Str.from_utf8(filename_bytes) |> Result.map_err(|_| InvalidFilename)?

        content_start = filename_start + Num.to_u64(filename_len) + Num.to_u64(extra_len)
        content = List.sublist(bytes, { start: content_start, len: Num.to_u64(compressed_size) })

        actual_crc = Crc32.checksum(content)
        if actual_crc != expected_crc then
            Err(CrcMismatch({ path, expected: expected_crc, actual: actual_crc }))
        else
            next_offset = content_start + Num.to_u64(compressed_size)
            Ok({ entry: { path, content }, next_offset })

# Round-trip tests

# Single file round-trip
expect
    original = [{ path: "test.txt", content: Str.to_utf8("Hello, World!") }]
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Multiple files round-trip
expect
    original = [
        { path: "a.txt", content: Str.to_utf8("File A") },
        { path: "b.txt", content: Str.to_utf8("File B") },
        { path: "c.txt", content: Str.to_utf8("File C") },
    ]
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Empty content round-trip
expect
    original = [{ path: "empty.txt", content: [] }]
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Paths with directories round-trip
expect
    original = [
        { path: "docs/readme.md", content: Str.to_utf8("# Readme") },
        { path: "src/main.roc", content: Str.to_utf8("app [main] {}") },
        { path: "deep/nested/path/file.txt", content: Str.to_utf8("deep") },
    ]
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Empty archive round-trip
expect
    original : List ZipEntry
    original = []
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Binary content round-trip
expect
    original = [{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] }]
    when create(original) is
        Ok(zip_bytes) -> extract(zip_bytes) == Ok(original)
        Err(_) -> Bool.false

# Structural tests

# Verify local file header signature
expect
    when create([{ path: "x", content: [] }]) is
        Ok(zip_bytes) -> List.sublist(zip_bytes, { start: 0, len: 4 }) == [0x50, 0x4B, 0x03, 0x04]
        Err(_) -> Bool.false

# Verify central directory signature appears after local entries
expect
    when create([{ path: "x", content: [] }]) is
        Ok(zip_bytes) ->
            # Local header (30) + filename (1) + content (0) = 31
            List.sublist(zip_bytes, { start: 31, len: 4 }) == [0x50, 0x4B, 0x01, 0x02]

        Err(_) -> Bool.false

# Verify end of central directory signature
expect
    when create([{ path: "x", content: [] }]) is
        Ok(zip_bytes) ->
            len = List.len(zip_bytes)
            # End of central directory is 22 bytes
            List.sublist(zip_bytes, { start: len - 22, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]

        Err(_) -> Bool.false

# Verify CRC32 is stored correctly in local header (offset 14-17)
expect
    when create([{ path: "x", content: Str.to_utf8("123456789") }]) is
        Ok(zip_bytes) ->
            # CRC32 of "123456789" is 0xCBF43926, stored little-endian
            List.sublist(zip_bytes, { start: 14, len: 4 }) == [0x26, 0x39, 0xF4, 0xCB]

        Err(_) -> Bool.false

# Verify file size is stored correctly (offset 18-21 compressed, 22-25 uncompressed)
expect
    content = Str.to_utf8("Hello") # 5 bytes
    when create([{ path: "x", content }]) is
        Ok(zip_bytes) ->
            compressed_size = List.sublist(zip_bytes, { start: 18, len: 4 })
            uncompressed_size = List.sublist(zip_bytes, { start: 22, len: 4 })
            # 5 stored as little-endian U32
            compressed_size == [0x05, 0x00, 0x00, 0x00] and uncompressed_size == [0x05, 0x00, 0x00, 0x00]

        Err(_) -> Bool.false

# Verify filename length is stored correctly (offset 26-27)
expect
    when create([{ path: "test.txt", content: [] }]) is
        Ok(zip_bytes) -> List.sublist(zip_bytes, { start: 26, len: 2 }) == [0x08, 0x00]
        Err(_) -> Bool.false

# Verify filename is stored correctly (starts at offset 30)
expect
    when create([{ path: "abc", content: [] }]) is
        Ok(zip_bytes) -> List.sublist(zip_bytes, { start: 30, len: 3 }) == [0x61, 0x62, 0x63] # "abc"
        Err(_) -> Bool.false

# Verify content is stored correctly (after header + filename)
expect
    when create([{ path: "x", content: [0xDE, 0xAD, 0xBE, 0xEF] }]) is
        Ok(zip_bytes) ->
            # Header (30) + filename (1) = 31, then content
            List.sublist(zip_bytes, { start: 31, len: 4 }) == [0xDE, 0xAD, 0xBE, 0xEF]

        Err(_) -> Bool.false

# Verify empty archive has only end of central directory (22 bytes)
expect
    when create([]) is
        Ok(zip_bytes) ->
            List.len(zip_bytes) == 22 and List.sublist(zip_bytes, { start: 0, len: 4 }) == [0x50, 0x4B, 0x05, 0x06]

        Err(_) -> Bool.false

# Error tests

# Empty path returns EmptyPath error
expect
    result = create([{ path: "", content: [] }])
    result == Err(EmptyPath(""))

# Truncated archive returns TruncatedArchive error
expect
    # Just the signature, missing the rest of the header
    truncated = [0x50, 0x4B, 0x03, 0x04]
    result = extract(truncated)
    result == Err(TruncatedArchive)

# Invalid signature returns InvalidSignature error
expect
    # Wrong signature bytes
    invalid = [0x00, 0x00, 0x00, 0x00]
    result = extract(invalid)
    result == Err(InvalidSignature)

# Compressed ZIP returns CompressionNotSupported error
expect
    # Create a valid-looking header but with deflate compression method (8)
    compressed_header = List.join(
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
    result = extract(compressed_header)
    result == Err(CompressionNotSupported(8))

# CRC mismatch returns CrcMismatch error
expect
    # Create a header with wrong CRC (0x12345678 instead of correct CRC)
    bad_crc_header = List.join(
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
    when extract(bad_crc_header) is
        Err(CrcMismatch({ path: "x", expected: 0x12345678, actual: _ })) -> Bool.true
        _ -> Bool.false

# Invalid UTF-8 filename returns InvalidFilename error
expect
    invalid_utf8_header = List.join(
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
    result = extract(invalid_utf8_header)
    result == Err(InvalidFilename)
