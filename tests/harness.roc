## Forward interop: real ZIP tools read the archives roc-zip writes.
##
## The package's own `expect` blocks round-trip Zip.create through Zip.extract,
## which cannot catch a shared misreading of the spec: both sides would have to
## agree on the same mistake for the test to still pass. The fixture archives in
## Zip.roc cover the other direction (real tools -> us). This harness closes the
## loop by handing archives we build to unzip, bsdtar and 7z and comparing the
## bytes they hand back against the originals.
##
## Every entry is compared byte for byte rather than by exit code. `unzip -p`
## exits 0 and prints nothing when it cannot match a name, so an exit-code check
## alone would pass silently on an archive no reader could actually read.
##
## The three readers come from the flake dev shell:
##
##     nix develop -c ./tests.roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.22.1/DobkAk7zNyqAgqh2Riaj5c5DtWtKhd5iVYE5RFa6izcd.tar.zst",
	zip: "../package/main.roc",
}

import pf.Stdout
import pf.Cmd
import pf.Path
import pf.Env
import pf.IOErr exposing [IOErr]
import pf.OsStr exposing [OsStr]
import zip.Zip

main! = |args| {
	# `args.len()` keeps the entries runtime-derived. With fully literal entries
	# the compiler evaluates Zip.create at build time, which defeats the point of
	# handing a freshly built archive to another program. It is 1 with no
	# arguments, so the archives stay identical across runs.
	n = args.len()
	tmp = Env.temp_dir!()

	Stdout.line!("== forward: real tools read the archives we write")?
	check!(tmp, n, "store", None)?
	check!(tmp, n, "fastest", Fastest)?
	check!(tmp, n, "balanced", Balanced)?
	check!(tmp, n, "smallest", Smallest)?

	Stdout.line!("== forward: real tools read a ZIP64 end of central directory")?
	check_zip64!(tmp, n)?

	Stdout.line!("All forward interop checks passed")?
	Ok({})
}

# More than 65535 entries overflows the classic 16-bit entry count, so the
# archive gains a ZIP64 end of central directory record and locator and the
# classic record carries sentinels. Zip.roc's own tests only round-trip that
# through Zip.extract, which shares this writer's assumptions, so prove real
# readers accept it too.
check_zip64! : Path.Path, U64 => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
check_zip64! = |tmp, n| {
	total = 65535 + n
	entries = many_entries(0, total, List.with_capacity(total))
	archive = match Zip.create(entries, None) {
		Ok(bytes) => bytes
		Err(_) => {
			Stdout.line!("  zip64: Zip.create failed")?
			Err(Exit(1))?
		}
	}

	zip_path = tmp.join("roc_zip_harness_zip64.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))

	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], "zip64")?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], "zip64")?

	# Spot-check the ends rather than all 65536 entries: three readers times
	# every entry would be a quarter of a million subprocesses.
	first = entries.get(0) ?? { path: "", content: [] }
	last = entries.get(total - 1) ?? { path: "", content: [] }
	verify_entry!(zip_os, first, "zip64")?
	verify_entry!(zip_os, last, "zip64")?

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  zip64: ${total.to_str()} entries, ${archive.len().to_str()} bytes, unzip + bsdtar + 7z all agree")
}

# Distinct names and contents, so a reader that loses or misorders an entry
# cannot pass by accident.
many_entries : U64, U64, List({ path : Str, content : List(U8) }) -> List({ path : Str, content : List(U8) })
many_entries = |index, total, acc|
	if index >= total {
		acc
	} else {
		many_entries(index + 1, total, acc.append({ path: "e${index.to_str()}.txt", content: index.to_str().to_utf8() }))
	}

# Build one archive at the given compression, then make every reader prove it
# can both verify the container and reproduce each entry's bytes.
check! : Path.Path, U64, Str, [None, Fastest, Balanced, Smallest] => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
check! = |tmp, n, name, level| {
	entries = sample_entries(n)
	archive = match Zip.create(entries, level) {
		Ok(bytes) => bytes
		Err(EmptyPath(path)) => {
			Stdout.line!("  ${name}: Zip.create rejected an empty path: ${path}")?
			Err(Exit(1))?
		}
		Err(PathTooLong(path)) => {
			Stdout.line!("  ${name}: Zip.create rejected a long path: ${path}")?
			Err(Exit(1))?
		}
	}

	zip_path = tmp.join("roc_zip_harness_${name}.zip")
	Path.write_bytes!(zip_path, archive) ? |_| Exit(1)
	zip_os = OsStr.from_raw(Path.to_raw(zip_path))

	# Container-level verification: both readers walk every entry and check its
	# CRC against the stored value.
	expect_ok!("unzip", [OsStr.from_str("-tqq"), zip_os], name)?
	expect_ok!("7z", [OsStr.from_str("t"), zip_os], name)?

	verify_from!(zip_os, entries, name, 0)?

	Path.delete!(zip_path) ? |_| Exit(1)
	Stdout.line!("  ${name}: ${archive.len().to_str()} bytes, unzip + bsdtar + 7z all agree")
}

# The archive every reader is asked to read back. Covers nested directories, an
# empty entry, non-text bytes, a UTF-8 name (general purpose bit 11) and enough
# repetitive text that compression actually engages instead of falling back to
# store.
sample_entries : U64 -> List({ path : Str, content : List(U8) })
sample_entries = |n| [
	{ path: "hello.txt", content: "Hello, World!".to_utf8() },
	{ path: "docs/readme.md", content: "# Readme".to_utf8() },
	{ path: "deep/nested/path/file.txt", content: "deep".to_utf8() },
	{ path: "empty.txt", content: [] },
	{ path: "binary.bin", content: [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE] },
	{ path: "utf8/räksmörgås.txt", content: "UTF-8 filename".to_utf8() },
	{ path: "big.txt", content: repeated_text(200 * n) },
]

# Check one entry against every reader that can address it.
verify_entry! : OsStr, { path : Str, content : List(U8) }, Str => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
verify_entry! = |zip_os, entry, name| {
	path_os = OsStr.from_str(entry.path)

	# Info-ZIP 3.00 predates UTF-8 name support and cannot match a non-ASCII
	# name on the command line (it reports "filename not matched" and still
	# exits 0), so bsdtar and 7z carry that entry.
	_skip_non_ascii = if is_ascii(entry.path) {
		expect_bytes!("unzip", [OsStr.from_str("-p"), zip_os, path_os], entry, name)?
	} else {
		{}
	}

	expect_bytes!("bsdtar", [OsStr.from_str("-xOf"), zip_os, path_os], entry, name)?
	expect_bytes!("7z", [OsStr.from_str("e"), OsStr.from_str("-so"), zip_os, path_os], entry, name)
}

verify_from! : OsStr, List({ path : Str, content : List(U8) }), Str, U64 => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
verify_from! = |zip_os, entries, name, index|
	if index >= entries.len() {
		Ok({})
	} else {
		entry = entries.get(index) ?? { path: "", content: [] }
		verify_entry!(zip_os, entry, name)?
		verify_from!(zip_os, entries, name, index + 1)
	}

# Run a reader and require its stdout to equal the entry's original content.
expect_bytes! : Str, List(OsStr), { path : Str, content : List(U8) }, Str => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
expect_bytes! = |program, arguments, entry, name| {
	got = match Cmd.new(OsStr.from_str(program)).args(arguments).exec_output_bytes!() {
		Ok(res) => res.stdout_bytes
		Err(NonZeroExitCodeB({ exit_code, stderr_bytes, .. })) => {
			Stdout.line!("  ${name}: ${program} exited ${exit_code.to_str()} on ${entry.path}: ${Str.from_utf8_lossy(stderr_bytes)}")?
			Err(Exit(1))?
		}
		Err(_) => {
			Stdout.line!("  ${name}: could not run ${program}")?
			Err(Exit(1))?
		}
	}

	if got == entry.content {
		Ok({})
	} else {
		Stdout.line!("  ${name}: ${program} MISMATCH on ${entry.path}: got ${got.len().to_str()} bytes, expected ${entry.content.len().to_str()}")?
		Err(Exit(1))
	}
}

# Run a command purely for its exit status.
expect_ok! : Str, List(OsStr), Str => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
expect_ok! = |program, arguments, name| {
	match Cmd.new(OsStr.from_str(program)).args(arguments).exec_output_bytes!() {
		Ok(_res) => Ok({})
		Err(NonZeroExitCodeB({ exit_code, stderr_bytes, .. })) => {
			Stdout.line!("  ${name}: ${program} exited ${exit_code.to_str()}: ${Str.from_utf8_lossy(stderr_bytes)}")?
			Err(Exit(1))
		}
		Err(_) => {
			Stdout.line!("  ${name}: could not run ${program}")?
			Err(Exit(1))
		}
	}
}

is_ascii : Str -> Bool
is_ascii = |text| text.to_utf8().fold(Bool.True, |acc, byte| acc and byte < 0x80)

# Repetitive text, appended byte-wise into a bare list so the loop stays linear.
repeated_text : U64 -> List(U8)
repeated_text = |reps| {
	phrase = "Compression works best when text repeats itself. ".to_utf8()
	append_reps(List.with_capacity(reps * phrase.len() + 8), phrase, reps)
}

append_reps : List(U8), List(U8), U64 -> List(U8)
append_reps = |acc, phrase, remaining|
	if remaining == 0 {
		acc
	} else {
		append_reps(append_bytes(acc, phrase, 0), phrase, remaining - 1)
	}

append_bytes : List(U8), List(U8), U64 -> List(U8)
append_bytes = |acc, bytes, index|
	if index >= bytes.len() {
		acc
	} else {
		append_bytes(acc.append(bytes.get(index) ?? 0), bytes, index + 1)
	}
