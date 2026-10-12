import Codec
import Map

## The saved score file as text: a header line, then the sealed score bytes
## in printable-binary form (one visible glyph per byte, using the
## printable-binary project's own Roc codec and character map), then a
## newline. Decoding rejects anything that does not re-encode exactly, since
## the codec passes unknown bytes through unchanged.
ScoreFile :: [].{
	encode : List(U8) -> List(U8)
	encode = |sealed| header.to_utf8().concat(Codec.encode(sealed, Map.glyphs)).append('\n')

	decode : List(U8) -> Try(List(U8), [BadText])
	decode = |text| {
		head = header.to_utf8()
		if text.take_first(head.len()) != head or text.last() != Ok('\n') or text.len() <= head.len() {
			return Err(BadText)
		}
		body = text.drop_first(head.len()).drop_last(1)
		bytes = Codec.decode(body, Map.glyphs, Bool.False, Bool.False)
		if Codec.encode(bytes, Map.glyphs) == body Ok(bytes) else Err(BadText)
	}
}

header : Str
header = "pinterm scores 1\n"
