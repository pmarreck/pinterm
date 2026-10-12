## BLAKE3 hashing (256-bit output), used as the integrity checksum inside the
## saved high-score file. A straightforward port of the reference
## implementation: 1 KiB chunks of 64-byte blocks through the 7-round
## compression function, merged with a binary tree of parent nodes.
Blake3 :: [].{

	## Hash `bytes` and return the 32-byte digest as lowercase hex.
	hex : List(U8) -> Str
	hex = |bytes| {
		var $out = ""
		for b in hash(bytes) {
			$out = Str.concat($out, hex_byte(b))
		}
		$out
	}

	## Hash `bytes` to a 32-byte digest. Chunks are compressed one at a time;
	## completed chunk chaining values merge into parents whenever the chunk
	## count has trailing zero bits, as in the reference implementation.
	hash : List(U8) -> List(U8)
	hash = |bytes| {
		n = bytes.len()
		chunks = if n == 0 1 else (n + chunk_len - 1) // chunk_len
		var $stack = []
		var $c = 0
		while $c + 1 < chunks {
			var $cv = chunk_output(bytes, $c).chaining
			var $total = $c + 1
			while $total.bitwise_and(1) == 0 {
				left = $stack.last() ?? iv
				$stack = $stack.drop_last(1)
				$cv = parent_output(left, $cv).chaining
				$total = $total.shr_zf_wrap(1)
			}
			$stack = $stack.append($cv)
			$c = $c + 1
		}
		var $out = chunk_output(bytes, chunks - 1)
		while !$stack.is_empty() {
			left = $stack.last() ?? iv
			$stack = $stack.drop_last(1)
			$out = parent_output(left, $out.chaining)
		}
		root = compress($out.cv, $out.block, $out.counter, $out.len, $out.flags.bitwise_or(flag_root))
		words_to_bytes(root.take_first(8))
	}
}

Output : { cv : List(U32), block : List(U32), counter : U64, len : U32, flags : U32, chaining : List(U32) }

chunk_len : U64
chunk_len = 1024

block_len : U64
block_len = 64

flag_chunk_start : U32
flag_chunk_start = 1

flag_chunk_end : U32
flag_chunk_end = 2

flag_parent : U32
flag_parent = 4

flag_root : U32
flag_root = 8

iv : List(U32)
iv = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]

msg_permutation : List(U64)
msg_permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

## Compress chunk `index` up to its last block; the last block is returned
## uncompressed-for-output so the caller can add the ROOT flag if needed.
chunk_output : List(U8), U64 -> Output
chunk_output = |bytes, index| {
	start = index * chunk_len
	n = bytes.len()
	end = if start + chunk_len < n start + chunk_len else n
	blocks = if end <= start 1 else (end - start + block_len - 1) // block_len
	var $cv = iv
	var $b = 0
	var $result = { cv: iv, block: List.repeat(0, 16), counter: index, len: 0, flags: 0, chaining: iv }
	while $b < blocks {
		from = start + $b * block_len
		len = if from + block_len < end block_len else end - from
		block = block_words(bytes.sublist({ start: from, len }))
		first = if $b == 0 flag_chunk_start else 0
		last = if $b + 1 == blocks flag_chunk_end else 0
		flags = first.bitwise_or(last)
		state = compress($cv, block, index, len.to_u32_wrap(), flags)
		chaining = state.take_first(8)
		$result = { cv: $cv, block, counter: index, len: len.to_u32_wrap(), flags, chaining }
		$cv = chaining
		$b = $b + 1
	}
	$result
}

parent_output : List(U32), List(U32) -> Output
parent_output = |left, right| {
	block = List.concat(left, right)
	state = compress(iv, block, 0, block_len.to_u32_wrap(), flag_parent)
	{ cv: iv, block, counter: 0, len: block_len.to_u32_wrap(), flags: flag_parent, chaining: state.take_first(8) }
}

## The BLAKE3 compression function: 7 rounds of the ChaCha-style G mixer over
## a 16-word state, permuting the message words between rounds.
compress : List(U32), List(U32), U64, U32, U32 -> List(U32)
compress = |cv, block, counter, len, flags| {
	var $s = cv.concat([iv_at(0), iv_at(1), iv_at(2), iv_at(3), counter.to_u32_wrap(), counter.shr_zf_wrap(32).to_u32_wrap(), len, flags])
	var $m = block
	var $r = 0
	while $r < 7 {
		$s = round($s, $m)
		$m = permute($m)
		$r = $r + 1
	}
	var $i = 0
	var $out = $s
	while $i < 8 {
		$out = set(set($out, $i, at($s, $i).bitwise_xor(at($s, $i + 8))), $i + 8, at($s, $i + 8).bitwise_xor(at(cv, $i)))
		$i = $i + 1
	}
	$out
}

round : List(U32), List(U32) -> List(U32)
round = |s0, m| {
	s1 = g(s0, 0, 4, 8, 12, at(m, 0), at(m, 1))
	s2 = g(s1, 1, 5, 9, 13, at(m, 2), at(m, 3))
	s3 = g(s2, 2, 6, 10, 14, at(m, 4), at(m, 5))
	s4 = g(s3, 3, 7, 11, 15, at(m, 6), at(m, 7))
	s5 = g(s4, 0, 5, 10, 15, at(m, 8), at(m, 9))
	s6 = g(s5, 1, 6, 11, 12, at(m, 10), at(m, 11))
	s7 = g(s6, 2, 7, 8, 13, at(m, 12), at(m, 13))
	g(s7, 3, 4, 9, 14, at(m, 14), at(m, 15))
}

g : List(U32), U64, U64, U64, U64, U32, U32 -> List(U32)
g = |s, ai, bi, ci, di, x, y| {
	a1 = at(s, ai).plus_wrap(at(s, bi)).plus_wrap(x)
	d1 = rotr(at(s, di).bitwise_xor(a1), 16)
	c1 = at(s, ci).plus_wrap(d1)
	b1 = rotr(at(s, bi).bitwise_xor(c1), 12)
	a2 = a1.plus_wrap(b1).plus_wrap(y)
	d2 = rotr(d1.bitwise_xor(a2), 8)
	c2 = c1.plus_wrap(d2)
	b2 = rotr(b1.bitwise_xor(c2), 7)
	set(set(set(set(s, ai, a2), bi, b2), ci, c2), di, d2)
}

permute : List(U32) -> List(U32)
permute = |m| msg_permutation.map(|i| at(m, i))

rotr : U32, U8 -> U32
rotr = |x, n| x.shr_zf_wrap(n).bitwise_or(x.shl_wrap(32 - n))

at : List(U32), U64 -> U32
at = |list, i| list.get(i) ?? 0

iv_at : U64 -> U32
iv_at = |i| at(iv, i)

set : List(U32), U64, U32 -> List(U32)
set = |list, i, v| list.set(i, v) ?? list

## Little-endian 32-bit words of a block of up to 64 bytes, zero padded.
block_words : List(U8) -> List(U32)
block_words = |bytes| {
	var $words = []
	var $w = 0
	while $w < 16 {
		byte = |k| (bytes.get($w * 4 + k) ?? 0).to_u32()
		$words = $words.append(byte(0).bitwise_or(byte(1).shl_wrap(8)).bitwise_or(byte(2).shl_wrap(16)).bitwise_or(byte(3).shl_wrap(24)))
		$w = $w + 1
	}
	$words
}

words_to_bytes : List(U32) -> List(U8)
words_to_bytes = |words| {
	var $out = []
	for w in words {
		$out = $out.concat([w.to_u8_wrap(), w.shr_zf_wrap(8).to_u8_wrap(), w.shr_zf_wrap(16).to_u8_wrap(), w.shr_zf_wrap(24).to_u8_wrap()])
	}
	$out
}

hex_byte : U8 -> Str
hex_byte = |b| {
	digits = "0123456789abcdef".to_utf8()
	Str.from_utf8([digits.get(b.shr_zf_wrap(4).to_u64()) ?? '0', digits.get(b.bitwise_and(15).to_u64()) ?? '0']) ?? ""
}
