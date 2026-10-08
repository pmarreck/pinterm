## Terminal input decoder: turns raw tty bytes into key press/release events.
## Handles plain bytes, CSI/SS3 arrow keys, and the kitty keyboard protocol
## (CSI code;mods:event u) whose release events enable exact flipper holds.
Input :: [].{
	Key : [LeftFlip, RightFlip, Plunger, Start, Nudge, Pause, New, Quit, Mute, Help, Suspend, Redraw, PrevTable, NextTable]
	Ev : [Press(Key), Release(Key)]

	## Decode one tick's input bytes. Incomplete trailing escape sequences are
	## treated as a bare Escape (quit); terminals deliver sequences atomically.
	parse : List(U8) -> List(Ev)
	parse = |bytes| {
		var $i = 0
		var $out = []
		n = bytes.len()
		while $i < n {
			b = bytes.get($i) ?? 0
			if b == 27 {
				next = bytes.get($i + 1) ?? 0
				if next == '[' or next == 'O' {
					# Scan parameters up to the final byte (0x40..0x7E).
					var $j = $i + 2
					var $done = Bool.False
					while $j < n and !$done {
						c = bytes.get($j) ?? 0
						if c >= 0x40 and c <= 0x7E {
							$done = Bool.True
						} else {
							$j = $j + 1
						}
					}
					if $done {
						params = bytes.sublist({ start: $i + 2, len: $j - ($i + 2) })
						final = bytes.get($j) ?? 0
						$out = List.concat($out, decode_csi(params, final))
						$i = $j + 1
					} else {
						$out = $out.append(Press(Quit))
						$i = n
					}
				} else {
					$out = $out.append(Press(Quit))
					$i = $i + 1
				}
			} else {
				$out = List.concat($out, key_for_byte(b).map(|k| Press(k)))
				$i = $i + 1
			}
		}
		$out
	}

	## Plain byte classifier (also used for kitty key codes below 128).
	key_for_byte : U8 -> List(Key)
	key_for_byte = |b| key_for_byte_impl(b)
}

key_for_byte_impl : U8 -> List(Input.Key)
key_for_byte_impl = |b| {
	if b == 'z' or b == 'Z' {
		[LeftFlip]
	} else if b == '/' {
		[RightFlip]
	} else if b == ' ' {
		[Plunger]
	} else if b == 13 or b == 10 {
		[Start]
	} else if b == 'p' or b == 'P' {
		[Pause]
	} else if b == 'n' or b == 'N' {
		[New]
	} else if b == 'q' or b == 'Q' or b == 3 {
		[Quit]
	} else if b == 'm' or b == 'M' {
		[Mute]
	} else if b == 'h' or b == 'H' or b == '?' {
		[Help]
	} else if b == 26 {
		[Suspend]
	} else if b == 12 {
		[Redraw]
	} else if b == 't' or b == 'T' {
		[Nudge]
	} else if b == '[' {
		[PrevTable]
	} else if b == ']' {
		[NextTable]
	} else {
		[]
	}
}

## Decode "a;b:c" style parameters into numbers: (first, modifiers, event).
csi_fields : List(U8) -> (U64, U64, U64)
csi_fields = |params| {
	var $nums = [0, 1, 1]
	var $param = 0
	var $sub = 0
	var $value = 0
	var $seen = Bool.False
	for c in params {
		if c >= '0' and c <= '9' {
			$value = $value * 10 + (c - '0').to_u64()
			$seen = Bool.True
		} else if c == ';' or c == ':' {
			if $seen {
				$nums = $nums.set(field_slot($param, $sub), $value) ?? $nums
			}
			if c == ';' {
				$param = $param + 1
				$sub = 0
			} else {
				$sub = $sub + 1
			}
			$value = 0
			$seen = Bool.False
		} else {
			{}
		}
	}
	if $seen {
		$nums = $nums.set(field_slot($param, $sub), $value) ?? $nums
	}
	(($nums.get(0) ?? 0), ($nums.get(1) ?? 1), ($nums.get(2) ?? 1))
}

decode_csi : List(U8), U8 -> List(Input.Ev)
decode_csi = |params, final| {
	(code, mods, event) = csi_fields(params)
	ctrl = (mods - 1).bitwise_and(4) != 0
	keys =
		if final == 'u' {
			if ctrl and code == 'c'.to_u64() {
				[Quit]
			} else if ctrl and code == 'z'.to_u64() {
				[Suspend]
			} else if ctrl and code == 'l'.to_u64() {
				[Redraw]
			} else if code == 27 {
				[Quit]
			} else if code < 128 {
				key_for_byte_impl(code.to_u8_wrap())
			} else {
				[]
			}
		} else if final == 'D' {
			[LeftFlip]
		} else if final == 'C' {
			[RightFlip]
		} else if final == 'B' {
			[Plunger]
		} else if final == 'A' {
			[Nudge]
		} else if final == '~' and code == 5 {
			[PrevTable]
		} else if final == '~' and code == 6 {
			[NextTable]
		} else {
			[]
		}
	if event == 3 keys.map(|k| Release(k)) else keys.map(|k| Press(k))
}

## Map (parameter index, sub-field index) to a result slot; 3 means ignored.
## Slot 0 = key code, 1 = modifiers, 2 = event type (1 press, 2 repeat, 3 release).
field_slot : U64, U64 -> U64
field_slot = |param, sub| {
	if param == 0 and sub == 0 {
		0
	} else if param == 1 and sub == 0 {
		1
	} else if param == 1 and sub == 1 {
		2
	} else {
		3
	}
}
