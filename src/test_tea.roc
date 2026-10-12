import Tea

main! = |_args| Ok({})

# ---------- TEA ----------

# Expected ciphertexts come from Wheeler and Needham's reference C code; the
# all-zero case is the published vector 41EA3A0A 94BAA940.
vectors : List(({ k : List(U32), p : (U32, U32) }, (U32, U32)))
vectors = [
	({ k: [0x00000000, 0x00000000, 0x00000000, 0x00000000], p: (0x00000000, 0x00000000) }, (0x41EA3A0A, 0x94BAA940)),
	({ k: [0xCD1DCF18, 0xAF5AAD71, 0x20DA7756, 0xAFE533D7], p: (0x69ACC4C4, 0x961BAFAD) }, (0x4677D316, 0x7D3A6058)),
	({ k: [0x261EB2E2, 0x525F3673, 0x65136930, 0x7E7099A9], p: (0xE6791B2E, 0xBB6CC6CF) }, (0x5435552D, 0x271CC2C2)),
	({ k: [0x44FDE85C, 0xD0102765, 0x9FFFBC3A, 0x5A1900EB], p: (0x5BAF2E48, 0x7D60D4E1) }, (0x9F9E77FB, 0x5DB816EF)),
	({ k: [0xAA1D6206, 0xB904C0C7, 0xDAACE6F4, 0x5EB4DE1D], p: (0x961D9892, 0x0202A263) }, (0x770F8781, 0x46F0663A)),
	({ k: [0x642B7E60, 0x05463F19, 0xCC78ABDE, 0x1F7301BF], p: (0x473A208C, 0xC1F2B3D5) }, (0x3FFBC166, 0x0A9602A7)),
	({ k: [0xB2DFA7EA, 0x975FFADB, 0x52AEB978, 0x5BB7B851], p: (0x270858B6, 0xFC5969B7) }, (0xA6659525, 0xDC23269A)),
	({ k: [0xEAD1F524, 0xB1EE888D, 0xDA394A42, 0x9010EA53], p: (0xCDCB3F90, 0x46482089) }, (0xDA58783A, 0xD8B25B9F)),
]

expect vectors.all(|(input, want)| Tea.encrypt_block(input.k, input.p) == want)

# Decryption inverts encryption, both from the vectors and back from them.
expect vectors.all(|(input, c)| Tea.decrypt_block(input.k, c) == input.p and Tea.decrypt_block(input.k, Tea.encrypt_block(input.k, c)) == c)

key : List(U32)
key = [0x01234567, 0x89ABCDEF, 0xFEDCBA98, 0x76543210]

sample : U64 -> List(U8)
sample = |n| {
	var $out = []
	var $i = 0
	while $i < n {
		$out = $out.append(($i * 37 + 11).to_u8_wrap())
		$i = $i + 1
	}
	$out
}

# Counter mode is its own inverse for every length, including partial blocks,
# and the ciphertext is not the plaintext.
expect {
	lengths = [0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 300]
	lengths.all(
		|n| {
			plain = sample(n)
			cipher = Tea.ctr(key, 0xDEADBEEF, plain)
			cipher.len() == n and Tea.ctr(key, 0xDEADBEEF, cipher) == plain and (n == 0 or cipher != plain)
		},
	)
}

# A different nonce or key gives a different keystream.
expect {
	plain = sample(64)
	c = Tea.ctr(key, 1, plain)
	c != Tea.ctr(key, 2, plain) and c != Tea.ctr([1, 2, 3, 4], 1, plain)
}

# The keystream is TEA(key, (nonce, block index)) per 8-byte block, so XORing
# zeros reveals it; consecutive blocks differ because the counter advances.
expect {
	le = |w| [w.to_u8_wrap(), w.shr_zf_wrap(8).to_u8_wrap(), w.shr_zf_wrap(16).to_u8_wrap(), w.shr_zf_wrap(24).to_u8_wrap()]
	block = |i| {
		(a, b) = Tea.encrypt_block(key, (7, i))
		List.concat(le(a), le(b))
	}
	Tea.ctr(key, 7, List.repeat(0, 20)) == List.concat(block(0), block(1)).concat(block(2).take_first(4))
}
