# reference_replay BIN OUTDIR: deterministic headless sessions whose outputs
# (event log, rendered frames in three color/glyph modes, PCM audio) must be
# byte-identical on every platform. The Linux build produces the reference;
# other platforms' builds are compared against it. Source this file.
reference_replay() (
	local bin="$1" out="$2"
	# Same results whatever the caller exported.
	unset PINTERM_MUTE PINTERM_SCORES
	mkdir -p "$out" || return 1
	# The replay_test session: plunger every 10 s, steady flipping, a full game.
	awk 'BEGIN { print "5 space"; for (f = 30; f < 6000; f++) { if (f % 600 == 0) print f " space"; else if (f % 600 >= 300 && f % 600 < 303) print f " /"; else if (f % 23 == 0) print f " z"; else if (f % 29 == 0) print f " /" } }' >"$out/session" || return 1
	"$bin" --headless --size 100x40 --frames 6000 --seed 7 --colors truecolor --script "$out/session" \
		--log-out "$out/game.log" --frames-out "$out/game.frames" --audio-out "$out/game.pcm" || return 1
	"$bin" --headless --size 80x24 --frames 300 --seed 3 --colors 256 --full-frames --script "$out/session" \
		--frames-out "$out/color256.frames" || return 1
	"$bin" --headless --size 120x40 --frames 300 --seed 3 --ascii --full-frames --script "$out/session" \
		--frames-out "$out/ascii.frames" || return 1
)
