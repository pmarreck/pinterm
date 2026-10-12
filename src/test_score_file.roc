import ScoreFile

main! = |_args| Ok({})

# ---------- score file text layer ----------

every_byte : List(U8)
every_byte = {
	var $out = []
	var $b = 0
	while $b < 256 {
		$out = $out.append($b.to_u8_wrap())
		$b = $b + 1
	}
	$out
}

header : List(U8)
header = "pinterm scores 1\n".to_utf8()

# The file is a header line, then the printable-binary text of the sealed
# bytes, then a newline: valid UTF-8 with no control characters besides the
# two newlines.
expect {
	text = ScoreFile.encode(every_byte)
	body = text.drop_first(header.len())
	text.take_first(header.len()) == header and text.last() == Ok('\n') and Str.from_utf8(text).is_ok() and body.drop_last(1).all(|b| b >= 0x20 and b != 0x7F)
}

# Every byte value survives a round trip, alone and in sequence.
expect every_byte.all(|b| ScoreFile.decode(ScoreFile.encode([b])) == Ok([b]))
expect ScoreFile.decode(ScoreFile.encode(every_byte)) == Ok(every_byte)
expect ScoreFile.decode(ScoreFile.encode([])) == Ok([])

# A missing or wrong header, a stray character, or a missing final newline is
# rejected rather than silently decoded.
expect {
	good = ScoreFile.encode([1, 2, 3, 200])
	bad = [
		good.drop_first(header.len()),
		"pinterm scores 2\n".to_utf8().concat(good.drop_first(header.len())),
		good.drop_last(1).concat("\u(0007)\n".to_utf8()),
		good.drop_last(1),
		[],
	]
	bad.all(|t| ScoreFile.decode(t).is_err())
}
