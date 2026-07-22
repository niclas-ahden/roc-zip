#!/usr/bin/env roc
## All tests: the package's `expect` blocks, then forward interop against real
## ZIP readers.
##
## The `expect` blocks in Zip.roc cover round-tripping, header layout, ZIP64,
## path safety, errors and streamed archives, plus three fixture archives that
## prove we read what Info-ZIP and bsdtar write. tests/harness.roc covers the
## direction those cannot: it hands archives we build to unzip, bsdtar and 7z
## and compares the bytes they hand back.
##
## harness is built with --opt=speed because it constructs a 65536-entry ZIP64
## archive, which is slow under the dev backend. unzip, bsdtar and 7z are the
## only external tools, and the flake dev shell provides all three:
##
##     nix develop -c ./tests.roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.22.1/DobkAk7zNyqAgqh2Riaj5c5DtWtKhd5iVYE5RFa6izcd.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.OsStr exposing [OsStr]

main! = |_| {
	Stdout.line!("== unit tests")?
	run!("roc", ["test", "package/main.roc"])?

	Stdout.line!("== forward interop against real ZIP readers (compiled --opt=speed)")?
	build!("tests/harness.roc", "tests/harness")?
	run!("./tests/harness", [])?
	Ok({})
}

# Build a .roc file to a named binary with the LLVM speed backend.
build! : Str, Str => Try({}, [Exit(I32), ..])
build! = |src, out| run!("roc", ["build", "--opt=speed", src, "--output=${out}"])

# Run a command with inherited stdio, failing the script on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32), ..])
run! = |program, arguments| {
	Cmd.exec!(OsStr.from_str(program), arguments.map(OsStr.from_str)) ? |_| Exit(1)
	Ok({})
}
