## TEA, the Tiny Encryption Algorithm (Wheeler and Needham, 1994): a 64-bit
## block cipher with a 128-bit key and 32 Feistel cycles. The high-score file
## is obfuscated with it in counter mode; the key lives in the source, so this
## keeps casual editing out rather than providing secrecy.
Tea :: [].{
	encrypt_block : List(U32), (U32, U32) -> (U32, U32)
	encrypt_block = |k, (p0, p1)| {
		var $v0 = p0
		var $v1 = p1
		var $sum = 0
		var $i = 0
		while $i < cycles {
			$sum = $sum.plus_wrap(delta)
			$v0 = $v0.plus_wrap(mix($v1, $sum, word(k, 0), word(k, 1)))
			$v1 = $v1.plus_wrap(mix($v0, $sum, word(k, 2), word(k, 3)))
			$i = $i + 1
		}
		($v0, $v1)
	}

	decrypt_block : List(U32), (U32, U32) -> (U32, U32)
	decrypt_block = |k, (c0, c1)| {
		var $v0 = c0
		var $v1 = c1
		var $sum = delta.times_wrap(cycles)
		var $i = 0
		while $i < cycles {
			$v1 = $v1.minus_wrap(mix($v0, $sum, word(k, 2), word(k, 3)))
			$v0 = $v0.minus_wrap(mix($v1, $sum, word(k, 0), word(k, 1)))
			$sum = $sum.minus_wrap(delta)
			$i = $i + 1
		}
		($v0, $v1)
	}

	## Counter mode: XOR `bytes` with the keystream TEA(key, (nonce, block
	## index)), each block's two words taken little-endian. Encrypts and
	## decrypts alike, and needs no padding.
	ctr : List(U32), U32, List(U8) -> List(U8)
	ctr = |k, nonce, bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		var $stream = []
		for b in bytes {
			if $i % 8 == 0 {
				(s0, s1) = encrypt_block(k, (nonce, ($i // 8).to_u32_wrap()))
				$stream = List.concat(le_bytes(s0), le_bytes(s1))
			}
			$out = $out.append(b.bitwise_xor($stream.get($i % 8) ?? 0))
			$i = $i + 1
		}
		$out
	}
}

delta : U32
delta = 0x9E3779B9

cycles : U32
cycles = 32

mix : U32, U32, U32, U32 -> U32
mix = |v, sum, ka, kb| v.shl_wrap(4).plus_wrap(ka).bitwise_xor(v.plus_wrap(sum)).bitwise_xor(v.shr_zf_wrap(5).plus_wrap(kb))

word : List(U32), U64 -> U32
word = |k, i| k.get(i) ?? 0

le_bytes : U32 -> List(U8)
le_bytes = |w| [w.to_u8_wrap(), w.shr_zf_wrap(8).to_u8_wrap(), w.shr_zf_wrap(16).to_u8_wrap(), w.shr_zf_wrap(24).to_u8_wrap()]
