app [main!] {
	pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst",
	zip: "../package/main.roc",
}

import pf.Stdout
import zip.Zip

main! = |_args| {
	Stdout.line!("=== Zip Package Demo ===")

	entries = [
		{ path: "foo.txt", content: "bar".to_utf8() },
		{ path: "docs/readme.md", content: "# Hello".to_utf8() },
	]

	match Zip.create(entries) {
		Ok(archive) => {
			Stdout.line!("Created archive of ${archive.len().to_str()} bytes")

			match Zip.extract(archive) {
				Ok(extracted) => Stdout.line!("Extracted ${extracted.len().to_str()} entries")
				Err(_) => Stdout.line!("Failed to extract archive")
			}
		}
		Err(_) => Stdout.line!("Failed to create archive")
	}

	Ok({})
}
