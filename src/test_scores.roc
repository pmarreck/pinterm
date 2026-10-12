import Scores
import Blake3
import Tea

main! = |_args| Ok({})

# ---------- high-score lists ----------

e : Str, I64 -> Scores.Entry
e = |initials, score| { initials, score }

full : List(Scores.Entry)
full = [e("AAA", 500), e("BBB", 400), e("CCC", 300), e("DDD", 200), e("EEE", 100)]

# A score qualifies when it is positive and the list has room or it beats
# the lowest entry; a tie with the lowest entry does not qualify.
expect Scores.qualifies([], 1) and !Scores.qualifies([], 0)
expect Scores.qualifies(full, 101) and !Scores.qualifies(full, 100) and !Scores.qualifies(full, 50)
expect Scores.qualifies(full.take_first(4), 1)

# Inserting keeps the list sorted high to low, places a new score below
# existing equal scores, and keeps only the top five.
expect Scores.insert(full, e("NEW", 350)) == [e("AAA", 500), e("BBB", 400), e("NEW", 350), e("CCC", 300), e("DDD", 200)]
expect Scores.insert(full, e("TIE", 400)) == [e("AAA", 500), e("BBB", 400), e("TIE", 400), e("CCC", 300), e("DDD", 200)]
expect Scores.insert([], e("ONE", 10)) == [e("ONE", 10)]
expect Scores.insert(full, e("TOP", 900)).first() == Ok(e("TOP", 900)) and Scores.insert(full, e("TOP", 900)).len() == 5

# ---------- plaintext format ----------

books : List(List(Scores.Entry))
books = [full, [], [e("P M", 42), e("_-*", 7)], [e("!?0", 1)], []]

# The plaintext is the body followed by the BLAKE3 hex digest of the body.
expect {
	plain = Scores.serialize(books)
	n = plain.len()
	body = plain.take_first(n - 64)
	Str.from_utf8(plain.drop_first(n - 64)) == Ok(Blake3.hex(body)) and Str.from_utf8(body.take_first(17)) == Ok("pinterm-scores 1\n")
}

expect Scores.parse(Scores.serialize(books)) == Ok(books)

# Fewer stored tables than the game has are padded with empty lists.
expect Scores.parse(Scores.serialize([full])) == Ok([full, [], [], [], []])

# Any single changed byte is rejected: the checksum covers the body and the
# digest itself must match.
expect {
	plain = Scores.serialize(books)
	var $ok = Bool.True
	var $i = 0
	while $i < plain.len() {
		flipped = plain.set($i, (plain.get($i) ?? 0).bitwise_xor(1)) ?? plain
		if Scores.parse(flipped).is_ok() {
			$ok = Bool.False
		}
		$i = $i + 1
	}
	$ok
}

expect Scores.parse([]).is_err() and Scores.parse("pinterm-scores 1\n".to_utf8()).is_err()

# ---------- sealing ----------

# Sealed bytes are the little-endian nonce followed by the TEA counter-mode
# ciphertext of the plaintext under the embedded key.
expect {
	sealed = Scores.seal(books, 0x01020304)
	sealed.take_first(4) == [4, 3, 2, 1] and Tea.ctr(Scores.key, 0x01020304, sealed.drop_first(4)) == Scores.serialize(books)
}

expect Scores.unseal(Scores.seal(books, 99)) == Ok(books)

# A different nonce changes the ciphertext but not the contents.
expect Scores.seal(books, 1) != Scores.seal(books, 2) and Scores.unseal(Scores.seal(books, 2)) == Ok(books)

expect Scores.unseal([]).is_err() and Scores.unseal([1, 2, 3]).is_err()

# Flipping any ciphertext byte is detected after decryption.
expect {
	sealed = Scores.seal(books, 5)
	var $ok = Bool.True
	var $i = 0
	while $i < sealed.len() {
		flipped = sealed.set($i, (sealed.get($i) ?? 0).bitwise_xor(0x40)) ?? sealed
		if Scores.unseal(flipped).is_ok() {
			$ok = Bool.False
		}
		$i = $i + 1
	}
	$ok
}

# Well-checksummed but malformed lines are rejected rather than overflowing:
# an over-long table index or score, bad initials, missing fields.
expect {
	signed = |body| body.to_utf8().concat(Blake3.hex(body.to_utf8()).to_utf8())
	bad = [
		"pinterm-scores 1\n99999999999999999999999 AAA 5\n",
		"pinterm-scores 1\n0 AAA 99999999999999999999999\n",
		"pinterm-scores 1\n0 aaa 5\n",
		"pinterm-scores 1\n0 AA 5\n",
		"pinterm-scores 1\n0 AAA \n",
		"pinterm-scores 1\n0 AAA 5",
		"pinterm-scores 2\n",
	]
	bad.all(|body| Scores.parse(signed(body)).is_err()) and Scores.parse(signed("pinterm-scores 1\n9 AAA 5\n")) == Ok([[], [], [], [], []])
}
