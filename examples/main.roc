app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.22.1/DobkAk7zNyqAgqh2Riaj5c5DtWtKhd5iVYE5RFa6izcd.tar.zst",
	zip: "../package/main.roc",
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
