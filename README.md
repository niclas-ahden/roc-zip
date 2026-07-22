# roc-zip

Create and extract ZIP archives in Roc.

- `Zip.create` builds an archive from a list of entries, with a compression option: `None` stores entries as-is, while `Fastest`, `Balanced`, and `Smallest` compress with DEFLATE at increasing effort (falling back to store when compression doesn't help).
- `Zip.extract` reads both store and deflate entries, including archives made by other tools.
- Supports ZIP64, so files and archives larger than 4 GB work.
- Compression comes from [roc-deflate](https://github.com/niclas-ahden/roc-deflate), a pure-Roc DEFLATE implementation. Use that package directly if you need raw DEFLATE streams (gzip, PNG, etc.) without the ZIP container.

View the API documentation at [https://niclas-ahden.github.io/roc-zip/](https://niclas-ahden.github.io/roc-zip/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.22.1/DobkAk7zNyqAgqh2Riaj5c5DtWtKhd5iVYE5RFa6izcd.tar.zst",
    zip: "package/main.roc",
}

import pf.Stdout
import zip.Zip

main! = |_| {
    entries = [
        { path: "irish/artists.txt", content: "Rubberbandits".to_utf8() },
        { path: "irish/songs.txt", content: "Dad's Best Friend".to_utf8() },
        { path: "irish/lyrics.txt", content: "Bought a tarantula from a Swedish guy, he helped me out in Stockholm with a DUI".to_utf8() },
        { path: "links.txt", content: "https://www.youtube.com/watch?v=iYgPznBrjiA".to_utf8(), },
    ]

    match Zip.create(entries, Balanced) {
        Ok(archive) => Stdout.line!("Created a ${archive.len().to_str()} byte archive")?
        Err(EmptyPath(_path)) => Stdout.line!("Path was empty")?
        Err(PathTooLong(_path)) => Stdout.line!("Path exceeds 65535 bytes")?
    }

    Ok({})
}
```

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
