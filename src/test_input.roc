import Input

main! = |_args| Ok({})

# ---------- input ----------

# Classifier over the full byte set: exactly the mapped bytes produce keys.
expect {
	mapped = ['z', 'Z', '/', ' ', 13, 10, 'p', 'P', 'n', 'N', 'q', 'Q', 3, 'm', 'M', 'h', 'H', '?', 26, 12, 't', 'T']
	var $ok = Bool.True
	var $b = 0
	while $b < 256 {
		byte = $b.to_u8_wrap()
		maps = !Input.key_for_byte(byte).is_empty()
		if maps != mapped.contains(byte) {
			$ok = Bool.False
		}
		$b = $b + 1
	}
	$ok
}

expect Input.parse(['z', '/', ' ']) == [Press(LeftFlip), Press(RightFlip), Press(Plunger)]
expect Input.parse([27, '[', 'D', 27, '[', 'C', 27, 'O', 'B', 27, '[', 'A']) == [Press(LeftFlip), Press(RightFlip), Press(Plunger), Press(Nudge)]
# Kitty keyboard protocol: press, repeat (as press) and release of z.
expect Input.parse(Str.to_utf8("\u(1b)[122;1:1u\u(1b)[122;1:2u\u(1b)[122;1:3u")) == [Press(LeftFlip), Press(LeftFlip), Release(LeftFlip)]
# Kitty-mode arrow release, Ctrl-C and Ctrl-Z.
expect Input.parse(Str.to_utf8("\u(1b)[1;1:3D\u(1b)[99;5u\u(1b)[122;5u")) == [Release(LeftFlip), Press(Quit), Press(Suspend)]
# Bare escape quits; unknown sequences are ignored; plain Ctrl-C byte quits.
expect Input.parse([27]) == [Press(Quit)]
expect Input.parse(Str.to_utf8("\u(1b)[200~x")) == []
expect Input.parse([3]) == [Press(Quit)]
# Alternate-key sub-fields on the code parameter do not confuse modifiers.
expect Input.parse(Str.to_utf8("\u(1b)[47:63;1:3u")) == [Release(RightFlip)]
