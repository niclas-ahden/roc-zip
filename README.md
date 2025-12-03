# roc-zip

Create and extract basic ZIP archives in Roc.

Uses store-only mode (no compression), suitable for already-compressed data or when size doesn't matter, and supports files up to 4 GB in size. We'll probably support compression and larger files in the future.

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    zip: "https://github.com/niclas-ahden/roc-zip/releases/download/0.1.0/oGgGW2uQfX0VK7biC9eAbWtXQULRMWzhmgODLqyHN0c.tar.br",
}

import pf.File
import zip.Zip

main! = |_args|
    when Zip.create([
        { path: "foo.txt", content: Str.to_utf8("bar") },
        { path: "package/main.roc", content: Str.to_utf8("Some astonishing code") },
    ]) is
        Ok(archive) -> File.write_bytes!("output.zip", archive)
        Err(EmptyPath(path)) -> # Path was empty
        Err(PathTooLong(path)) -> # Path exceeds 65535 bytes
        Err(FileTooLarge(path)) -> # File exceeds 4GB
```

## Status

`roc-zip` is using the (old) Rust version of the Roc compiler. It'll be rewritten to use the Zig version in the future.

## Documentation

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

### Generating documentation locally

```bash
./docs.sh 0.1.0
```

This will generate HTML documentation and place it in `www/0.1.0/`.
