# roc-zip

Create and extract ZIP archives in Roc.

- `Zip.create` builds an archive from a list of entries, with a compression option: `None` stores entries as-is, while `Fastest`, `Balanced`, and `Smallest` compress with DEFLATE at increasing effort (falling back to store when compression doesn't help).
- `Zip.extract` reads both store and deflate entries, including archives made by other tools.
- For archives from untrusted sources, `Zip.entries` lists the central directory without inflating anything, and `Zip.extract_entry` inflates one entry within a size limit. An entry that declares more than the limit fails before anything is allocated for it, and a stream that runs past its declared size stops there.
- `Zip.compressed` takes an entry's bytes exactly as stored, so `Zip.add` can copy it into another archive without inflating or recompressing it.
- `Zip.writer`, `Zip.add` and `Zip.finish` write an archive one entry at a time. Each call returns the next chunk, which can go straight to a file. The chunks add up to the bytes `Zip.create` returns.
- Output is deterministic: entries keep their order, timestamps are zeroed, and there are no data descriptors. Repeated paths are refused by the writer and rejected by the reader, since different readers resolve them differently.
- Supports ZIP64, so files and archives larger than 4 GB work.
- Compression comes from [roc-deflate](https://github.com/niclas-ahden/roc-deflate), a pure-Roc DEFLATE implementation. Use that package directly if you need raw DEFLATE streams (gzip, PNG, etc.) without the ZIP container.

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
    zip: "https://github.com/niclas-ahden/roc-zip/releases/download/0.2.2/FpMTcemHxwRmDRCwnTtcrQeCRnqA5UcJ1TZzYL3iPtA4.tar.zst",
}

import pf.Stdout
import pf.OsStr
import zip.Zip

main! = |args| {
    # Archives the text you pass on the command line as the lyrics, or this
    # line if you pass none
    lyrics = match args.get(0) {
        Ok(arg) => OsStr.display(arg).to_utf8()
        Err(_) => "Bought a tarantula from a Swedish guy, he helped me out in Stockholm with a DUI".to_utf8()
    }

    entries = [
        { path: "irish/artists.txt", content: "Rubberbandits".to_utf8() },
        { path: "irish/songs.txt", content: "Dad's Best Friend".to_utf8() },
        { path: "irish/lyrics.txt", content: lyrics },
        { path: "links.txt", content: "https://www.youtube.com/watch?v=iYgPznBrjiA".to_utf8() },
    ]

    match Zip.create(entries, Balanced) {
        Ok(archive) => Stdout.line!("Created a ${archive.len().to_str()} byte archive")?
        Err(EmptyPath(_path)) => Stdout.line!("Path was empty")?
        Err(PathTooLong(_path)) => Stdout.line!("Path exceeds 65535 bytes")?
        Err(DuplicatePath(_path)) => Stdout.line!("Two entries share a path")?
    }

    Ok({})
}
```

See [examples](examples/) for a runnable program.

## Reading untrusted archives

A small archive can declare, or inflate to, gigabytes. List it first, and extract each entry within a limit:

```roc
read_parts : List(U8) -> Try(List({ path : Str, content : List(U8) }), _)
read_parts = |bytes| {
    index = Zip.entries(bytes)?
    var $parts = []
    for entry in index {
        content = Zip.extract_entry(bytes, entry, { max_bytes: 16_777_216 })?
        $parts = $parts.append({ path: entry.path, content })
    }
    Ok($parts)
}
```

Listing holds memory in proportion to the central directory, not to the sizes the entries declare. Extracting holds at most the decoder's tables and the entry's declared size. The [fuzz targets](fuzz/) check both bounds, along with the rest of the API, against arbitrary and corrupted archives.

## Choosing a compression level

`Zip.create` takes one of four compression options: `None` skips compression entirely (fastest possible, no size reduction), and the other three (`Fastest`, `Balanced`, `Smallest`) trade speed for size. Here's how they compare to `gzip` on the [Silesia corpus](http://mattmahoney.net/dc/silesia.html) (times are only meant to give an indication in relation to one another):

| Level      | Compressed size  | Ratio | Time   |
| ---------- | ---------------- | ----- | ------ |
| `Fastest`  | 85,524,903 bytes | 40.4% | ~4.7 s |
| `Balanced` | 78,420,875 bytes | 37.0% | ~6.9 s |
| `Smallest` | 76,929,989 bytes | 36.3% | ~15 s  |
| gzip -1    | 77,366,708 bytes | 36.5% | ~1.3 s |
| gzip -6    | 68,227,965 bytes | 32.2% | ~4.3 s |
| gzip -9    | 67,631,990 bytes | 31.9% | ~10 s  |

Speed and compression will improve as [roc-deflate](https://github.com/niclas-ahden/roc-deflate) and the Roc compiler matures. There's lots of headroom for improvement, so see this as a starting point 👍
