Codec := {}.{
	encode : List(U8), List(List(U8)) -> List(U8)
	encode = |input, mapping| encode_spaces(input, mapping, False)

	encode_spaces : List(U8), List(List(U8)), Bool -> List(U8)
	encode_spaces = |input, mapping, spaces| encode_with(input, mapping, spaces, False, False, [])

	encode_with : List(U8), List(List(U8)), Bool, Bool, Bool, List(U8) -> List(U8)
	encode_with = |input, mapping, spaces, tabs, crlf, preserved| {
		var $out = List.with_capacity(List.len(input) * 3)
		for byte in input {
			if should_preserve(byte, spaces, tabs, crlf, preserved) {
				$out = List.append($out, byte)
			} else {
				glyph = List.get(mapping, U8.to_u64(byte)) ?? crash "PrintableBinary mapping is incomplete"
				$out = List.concat($out, glyph)
			}
		}
		$out
	}

	decode : List(U8), List(List(U8)), Bool, Bool -> List(U8)
	decode = |input, mapping, spaces, strip_whitespace| {
		var $out = List.with_capacity(List.len(input))
		var $index = 0
		while $index < List.len(input) {
			remaining = List.drop_first(input, $index)
			mapped = find_mapping(remaining, mapping, 0)
			if mapped >= 0 {
				mapped_index = I64.to_u64_wrap(mapped)
				glyph = List.get(mapping, mapped_index) ?? crash "PrintableBinary mapping is incomplete"
				$out = List.append($out, I64.to_u8_wrap(mapped))
				$index = $index + List.len(glyph)
			} else {
				byte = List.get(input, $index) ?? crash "PrintableBinary decode index"
				if strip_whitespace and should_strip(byte, spaces) {
					$index = $index + 1
				} else {
					$out = List.append($out, byte)
					$index = $index + 1
				}
			}
		}
		$out
	}

	is_likely_double_encoded : List(U8), List(List(U8)) -> Bool
	is_likely_double_encoded = |input, mapping| {
		input_length = List.len(input)
		input_length > 0 and count_encoded_glyphs(input, mapping, 0, 0) * 100 > input_length * 5
	}
}

should_preserve : U8, Bool, Bool, Bool, List(U8) -> Bool
should_preserve = |byte, spaces, tabs, crlf, preserved| {
	(spaces and byte == 32)
		or (tabs and byte == 9)
			or (crlf and (byte == 10 or byte == 13))
				or List.contains(preserved, byte)
}

count_encoded_glyphs : List(U8), List(List(U8)), U64, U64 -> U64
count_encoded_glyphs = |input, mapping, index, count| {
	if index >= List.len(input) {
		count
	} else {
		remaining = List.drop_first(input, index)
		mapped = find_mapping(remaining, mapping, 0)
		if mapped < 0 {
			count_encoded_glyphs(input, mapping, index + 1, count)
		} else {
			glyph = List.get(mapping, I64.to_u64_wrap(mapped)) ?? crash "PrintableBinary mapping is incomplete"
			first = List.get(glyph, 0) ?? crash "PrintableBinary glyph is empty"
			increment = if first >= 128 {
				1
			} else {
				0
			}
			count_encoded_glyphs(input, mapping, index + List.len(glyph), count + increment)
		}
	}
}

find_mapping : List(U8), List(List(U8)), U64 -> I64
find_mapping = |remaining, mapping, index| {
	if index >= List.len(mapping) {
		-1
	} else {
		glyph = List.get(mapping, index) ?? crash "PrintableBinary mapping is incomplete"
		if List.starts_with(remaining, glyph) {
			U64.to_i64_wrap(index)
		} else {
			find_mapping(remaining, mapping, index + 1)
		}
	}
}

should_strip : U8, Bool -> Bool
should_strip = |byte, spaces| {
	(byte == 9 or byte == 10 or byte == 13) or (byte == 32 and Bool.not(spaces))
}
