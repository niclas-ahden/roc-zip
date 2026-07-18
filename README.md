# roc-zip

Create and extract basic ZIP archives in Roc.

Uses store-only mode (no compression), suitable for already-compressed data or when size doesn't matter, and supports files up to 4 GB in size. We'll probably support compression and larger files in the future.

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst",
    zip: "package/main.roc",
}

import pf.Stdout
import zip.Zip

main! = |_args| {
    entries = [
        { path: "foo.txt", content: "bar".to_utf8() },
        { path: "package/main.roc", content: "Some astonishing code".to_utf8() },
    ]

    match Zip.create(entries) {
        Ok(archive) => Stdout.line!("Created a ${archive.len().to_str()} byte archive")
        Err(EmptyPath(_path)) => Stdout.line!("Path was empty")
        Err(PathTooLong(_path)) => Stdout.line!("Path exceeds 65535 bytes")
        Err(FileTooLarge(_path)) => Stdout.line!("File exceeds 4GB")
    }

    Ok({})
}
```
