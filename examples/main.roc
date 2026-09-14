app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	zip: "../package/main.roc",
}

import pf.Stdout
import pf.OsStr
import zip.Zip

main! = |args| {
	# Archives the text you pass on the command line as the lyrics, or this
	# line if you pass none
	lyrics = match args.get(1) {
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
	}

	Ok({})
}
