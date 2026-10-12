import Blake3
import Table
import Tea

## Saved high scores: a top-five list per table. The plaintext is a short
## line-based text with the BLAKE3 hex digest of the body appended; it is
## sealed with TEA in counter mode under a key embedded here (obfuscation,
## not secrecy) behind a random 32-bit nonce.
Scores :: [].{
	Entry : { initials : Str, score : I64 }

	max_entries : U64
	max_entries = 5

	## Characters allowed in initials, in the order the left flipper cycles them.
	charset : List(U8)
	charset = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-*!?".to_utf8()

	key : List(U32)
	key = [0x99315377, 0xDC83993C, 0xAF31119E, 0x726C0801]

	## A score earns a place when positive and either the list has room or it
	## beats the lowest entry (a tie with the lowest does not).
	qualifies : List(Scores.Entry), I64 -> Bool
	qualifies = |list, score| {
		lowest = (list.last() ?? { initials: "", score: 0 }).score
		score > 0 and (list.len() < max_entries or score > lowest)
	}

	## Insert below any equal scores, keeping the list sorted high to low and
	## at most five long.
	insert : List(Scores.Entry), Scores.Entry -> List(Scores.Entry)
	insert = |list, entry| {
		var $out = []
		var $placed = Bool.False
		for x in list {
			if !$placed and entry.score > x.score {
				$out = $out.append(entry)
				$placed = Bool.True
			}
			$out = $out.append(x)
		}
		full = if $placed $out else $out.append(entry)
		full.take_first(max_entries)
	}

	## Plaintext: header line, one "TABLE INI SCORE" line per entry, then the
	## BLAKE3 hex digest of everything before it.
	serialize : List(List(Scores.Entry)) -> List(U8)
	serialize = |books| {
		var $body = header.to_utf8()
		var $t = first_table
		for list in books {
			for x in list {
				$body = $body.concat("${$t.to_str()} ${x.initials} ${x.score.to_str()}\n".to_utf8())
			}
			$t = $t + 1
		}
		$body.concat(Blake3.hex($body).to_utf8())
	}

	parse : List(U8) -> Try(List(List(Scores.Entry)), [BadChecksum, BadFormat])
	parse = |plain| {
		n = plain.len()
		if n < digest_len {
			return Err(BadChecksum)
		}
		body = plain.take_first(n - digest_len)
		if Str.from_utf8(plain.drop_first(n - digest_len)) != Ok(Blake3.hex(body)) {
			return Err(BadChecksum)
		}
		head = header.to_utf8()
		if body.take_first(head.len()) != head {
			return Err(BadFormat)
		}
		var $books = List.repeat([], Table.count)
		var $line = []
		for b in body.drop_first(head.len()) {
			if b == '\n' {
				(t, entry) = parse_line($line)?
				if t < Table.count {
					list = $books.get(t) ?? []
					$books = $books.set(t, list.append(entry)) ?? $books
				}
				$line = []
			} else {
				$line = $line.append(b)
			}
		}
		if $line.is_empty() Ok($books) else Err(BadFormat)
	}

	## Sealed bytes: little-endian nonce, then the TEA-CTR ciphertext.
	seal : List(List(Scores.Entry)), U32 -> List(U8)
	seal = |books, nonce| {
		le = [nonce.to_u8_wrap(), nonce.shr_zf_wrap(8).to_u8_wrap(), nonce.shr_zf_wrap(16).to_u8_wrap(), nonce.shr_zf_wrap(24).to_u8_wrap()]
		le.concat(Tea.ctr(key, nonce, serialize(books)))
	}

	unseal : List(U8) -> Try(List(List(Scores.Entry)), [BadChecksum, BadFormat])
	unseal = |sealed| {
		if sealed.len() < 4 {
			return Err(BadFormat)
		}
		byte = |i| (sealed.get(i) ?? 0).to_u32()
		nonce = byte(0).bitwise_or(byte(1).shl_wrap(8)).bitwise_or(byte(2).shl_wrap(16)).bitwise_or(byte(3).shl_wrap(24))
		parse(Tea.ctr(key, nonce, sealed.drop_first(4)))
	}
}

header : Str
header = "pinterm-scores 1\n"

digest_len : U64
digest_len = 64

## One entry line: decimal table index, a space, exactly three initials from
## the charset, a space, a positive decimal score.
parse_line : List(U8) -> Try((U64, Scores.Entry), [BadChecksum, BadFormat])
parse_line = |line| {
	var $i = 0
	var $t = 0
	while $i < 4 and is_digit(line.get($i) ?? 0) {
		$t = $t * 10 + ((line.get($i) ?? '0') - '0').to_u64()
		$i = $i + 1
	}
	if $i == 0 or $i > 3 or line.get($i) != Ok(' ') {
		return Err(BadFormat)
	}
	ini = line.sublist({ start: $i + 1, len: 3 })
	if ini.len() != 3 or !ini.all(|c| Scores.charset.contains(c)) or line.get($i + 4) != Ok(' ') {
		return Err(BadFormat)
	}
	digits = line.drop_first($i + 5)
	if digits.is_empty() or digits.len() > 18 or !digits.all(is_digit) {
		return Err(BadFormat)
	}
	score = digits.fold(0, |acc, d| acc * 10 + (d - '0').to_i64())
	initials = Str.from_utf8(ini) ?? "???"
	Ok(($t, { initials, score }))
}

is_digit : U8 -> Bool
is_digit = |c| c >= '0' and c <= '9'

first_table : U64
first_table = 0
