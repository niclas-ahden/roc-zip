app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "../../package/main.roc",
}

import fuzz.Fuzz
import zip.Zip

## One deflated entry of `1 KiB << (size % 14)` zeros, up to 8 MiB, whose
## central directory declares `declared` bytes (or its true size when
## `truthful`), extracted under a limit of `1 KiB << (limit % 21)`, up to
## 1 GiB.
Input := { size : U8, declared : U32, truthful : Bool, limit : U8, compression : U8 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			size: Fuzz.u8,
			declared: Fuzz.map(Fuzz.u64_in(0, 4294967295), |n| n.to_u32_wrap()),
			truthful: Fuzz.map(Fuzz.u8, |n| n % 2 == 0),
			limit: Fuzz.u8,
			compression: Fuzz.u8,
		}.Fuzz
	}
}

## Whatever an entry declares, extracting it allocates at most the decoder's
## state plus the smaller of what it declares and its limit, and inflation
## stops there:
##
## - An entry declaring more than its limit fails with `EntryTooLarge` and
##   allocates nothing.
## - One whose stream runs past or ends short of its declared size fails with
##   `SizeMismatch`.
## - One declaring its true size extracts with no reallocation.
##
## Memory ratchet, which only ever moves down.
test! : Input => Fuzz.Outcome
test! = |input| {
	size = (1024).shl_wrap(input.size % 14)
	max_bytes = (1024).shl_wrap(input.limit % 21)
	declared = if input.truthful {
		size
	} else {
		input.declared.to_u64()
	}
	# 0xFFFFFFFF is the ZIP64 sentinel, which would need an extra field to
	# say what it stands for.
	if declared == 0xFFFFFFFF {
		return Fuzz.reject
	}
	compression = if input.compression % 2 == 0 {
		Fastest
	} else {
		Balanced
	}
	archive = declare(Zip.create([{ path: "zeros.bin", content: List.repeat(0, size) }], compression) ?? crash "the path is valid", declared.to_u32_wrap())
	entry = match Zip.entries(archive) {
		Ok([only]) => only
		_ => crash "the archive does not list its one entry"
	}
	{ value: result, stats } = Fuzz.measure!("extract-entry", || Zip.extract_entry(archive, entry, { max_bytes: max_bytes }))
	live = stats.peak_live_bytes - stats.entry_live_bytes
	if live > decoder_state + declared.min(max_bytes) {
		crash "extraction held ${live.to_str()} bytes live, declaring ${declared.to_str()} under ${max_bytes.to_str()}"
	}
	match result {
		Err(EntryTooLarge(_)) if declared > max_bytes and stats.allocs == 0 => Fuzz.keep
		_ if declared > max_bytes => crash "an entry over its limit was not refused before allocating"
		Ok(content) if declared == size and content.len() == size and stats.reallocs == 0 => Fuzz.keep
		Ok(_) => crash "an entry extracted wrongly, or with reallocation"
		Err(SizeMismatch(_)) if declared != size => Fuzz.keep
		Err(err) => crash "unexpected ${Str.inspect(err)}"
	}
}

# Measured on nightly-2026-11-07-ad3a5d2 with roc-fuzz 0.5.0: the decode
# tables and the match copy's scratch.
decoder_state : U64
decoder_state = 16_384

# Overwrite the uncompressed size the central directory declares for the
# archive's only entry. The end record gives the directory's offset 16 bytes
# in, and the size sits 24 bytes into the record.
declare : List(U8), U32 -> List(U8)
declare = |archive, size| {
	end = archive.len() - 22
	directory = [0, 1, 2, 3].fold(0, |n, i| n + (archive.get(end + 16 + i) ?? 0).to_u64().shl_wrap((8 * i).to_u8_wrap()))
	[0, 1, 2, 3].fold(archive, |bytes, i| bytes.set(directory + 24 + i, size.shr_zf_wrap((8 * i).to_u8_wrap()).to_u8_wrap()) ?? bytes)
}

target = Fuzz.target_with!({
	name: "bombs",
	examples: [
		# 1 MiB declared truthfully under a 1 MiB limit: reserved once.
		Fuzz.example({ name: "presized", revision: "1", make: || Input.{ size: 10, declared: 0, truthful: Bool.True, limit: 10, compression: 1 } }),
		# 8 MiB declared as 1 GiB under a 1 MiB limit.
		Fuzz.example({ name: "declared-bomb", revision: "1", make: || Input.{ size: 13, declared: 0x40000000, truthful: Bool.False, limit: 10, compression: 1 } }),
		# 8 MiB of zeros declared as 1 KiB: inflation stops at 1 KiB.
		Fuzz.example({ name: "lying-bomb", revision: "1", make: || Input.{ size: 13, declared: 1024, truthful: Bool.False, limit: 20, compression: 1 } }),
		# 1 KiB declared as 8 KiB: the stream ends early.
		Fuzz.example({ name: "short-stream", revision: "1", make: || Input.{ size: 0, declared: 8192, truthful: Bool.False, limit: 20, compression: 0 } }),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
