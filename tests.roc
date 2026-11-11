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
##
## Last, a smoke run of every roc-fuzz target under fuzz/: build it, check its
## declared examples against the allocation ceilings in its source, then
## explore for at most a second and 64 inputs. roc-fuzz builds only for x86-64
## Linux and Apple Silicon macOS, so elsewhere the run says so and skips it.
## Longer campaigns use the same executables, under .fuzz/:
##
##     .fuzz/writer run .fuzz/corpus/writer --time=600
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.OsStr
import pf.Path
import pf.System

main! = |_| {
	Stdout.line!("== unit tests")?
	run!("roc", ["test", "package/main.roc"])?

	Stdout.line!("== forward interop against real ZIP readers (compiled --opt=speed)")?
	build!("tests/harness.roc", "tests/harness")?
	run!("./tests/harness", [])?

	Stdout.line!("== fuzz smoke run")?
	target = System.target!()
	supported = match (target.os(), target.arch()) {
		(Linux(_), X64) | (MacOS(_), Arm64) => Bool.True
		_ => Bool.False
	}
	if supported {
		for name in fuzz_targets {
			fuzz_smoke!(name)?
		}
	} else {
		Stdout.line!("skipped: roc-fuzz builds only for x86-64 Linux and Apple Silicon macOS")?
	}
	Ok({})
}

# Every directory under fuzz/, each holding one target's main.roc.
fuzz_targets : List(Str)
fuzz_targets = ["entries", "extract_entry", "bombs", "writer"]

# Build one fuzz target, check its declared examples, and explore briefly.
# A failed example, an exceeded ceiling or a finding fails the script.
fuzz_smoke! : Str => Try({}, [Exit(I32)])
fuzz_smoke! = |name| {
	executable = ".fuzz/${name}"
	corpus = ".fuzz/corpus/${name}"
	report = ".fuzz/reports/${name}"
	Path.create_all!(Path.utf8(corpus)) ? |_| Exit(1)
	match Path.delete_all!(Path.utf8(report)) {
		_ => {}
	}
	run!("roc", ["build", "--fuzz", "fuzz/${name}/main.roc", "--output=${executable}"])?
	run!(executable, ["run", corpus, "--time=1", "--runs=64", "--max-input-size=4096", "--timeout=30", "--report-dir=${report}"])
}

# Build a .roc file to a named binary with the LLVM speed backend.
build! : Str, Str => Try({}, [Exit(I32)])
build! = |src, out| run!("roc", ["build", "--opt=speed", src, "--output=${out}"])

# Run a command with inherited stdio, failing the script on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32)])
run! = |program, arguments| {
	Cmd.call!(OsStr.from_str(program), arguments.map(OsStr.from_str)) ? |_| Exit(1)
	Ok({})
}
