import Audio
import Loop

main! = |_args| Ok({})

# ---------- audio ----------

# Silence: an idle mixer produces exactly rate*dt zero samples.
expect {
	(_, samples) = Audio.render(Audio.new(22050), 0.1)
	samples.len() == 2205 and samples.all(|s| s == 0)
}

# Fractional samples carry over so long runs do not drift.
expect {
	var $m = Audio.new(22050)
	var $total = 0
	var $i = 0
	while $i < 60 {
		(m2, s) = Audio.render($m, 1.0 / 60.0)
		$m = m2
		$total = $total + s.len()
		$i = $i + 1
	}
	$total >= 22049 and $total <= 22050
}

# Every gameplay effect makes audible, bounded sound that then decays to silence.
expect {
	effects = [Bumper(3), Sling, Flip, Launch(1.0), Drain, Rollover, LanesDone, Target, TargetsDone, Saucer, Multiball, Jackpot, Saved, Warn, Tilt, Skill, GameOver, Begin, Wall(120.0)]
	effects.all(
		|fx| {
			(m1, s1) = Audio.render(Audio.trigger(Audio.new(22050), fx), 0.25)
			s2 = drain_audio(m1, 20)
			loud = s1.any(|s| s > 2000 or s < -2000)
			tail_silent = s2.drop_first(s2.len() - 100).all(|s| s == 0)
			loud and tail_silent and m1.voices.len() <= Audio.max_voices
		},
	)
}

# The voice pool is capped even under a flood of effects.
expect {
	flooded = List.repeat(Jackpot, 10).fold(Audio.new(22050), |m, fx| Audio.trigger(m, fx))
	flooded.voices.len() == Audio.max_voices
}

# Deterministic synthesis.
expect {
	(_, a) = Audio.render(Audio.trigger(Audio.new(22050), Bumper(2)), 0.1)
	(_, b) = Audio.render(Audio.trigger(Audio.new(22050), Bumper(2)), 0.1)
	a == b
}

## Render `chunks` 0.15 s blocks and return the last block.
drain_audio : Audio.Mixer, U64 -> List(I16)
drain_audio = |m, chunks| {
	var $m = m
	var $last = []
	var $i = 0
	while $i < chunks {
		(m2, s) = Audio.render($m, 0.15)
		$m = m2
		$last = s
		$i = $i + 1
	}
	$last
}

# ---------- loop (host packet -> frame) ----------

packet : U64, U64, U64, U8, List(U8) -> List(U8)
packet = |now_us, cols, rows, flags, input| {
	var $p = []
	var $k = 0
	while $k < 8 {
		$p = $p.append(now_us.shr_zf_wrap(($k * 8).to_u8_wrap()).bitwise_and(0xFF).to_u8_wrap())
		$k = $k + 1
	}
	List.concat($p.append(cols.bitwise_and(0xFF).to_u8_wrap()).append(cols.shr_zf_wrap(8).to_u8_wrap()).append(rows.bitwise_and(0xFF).to_u8_wrap()).append(rows.shr_zf_wrap(8).to_u8_wrap()).append(flags), input)
}

loop_cfg : Loop.Config
loop_cfg = Loop.config_from([100, 40, 0, 0, 1, 7, 22050, 1, 0, 60])

expect loop_cfg.cols == 100 and loop_cfg.sound and loop_cfg.fps == 60 and loop_cfg.color == 0

expect {
	first = Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 2, []))
	second = Loop.frame(first.state, packet(33333, 100, 40, 0, []))
	Str.from_utf8_lossy(first.bytes).contains("\u(1b)[2J") and second.bytes.len() < first.bytes.len() / 4 and !first.quit
}

expect Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 1, [])).quit
expect Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 0, ['q'])).quit
expect Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 0, [26])).suspend

# Space in attract mode starts a game; audio flows while sound is on, stops on mute.
expect {
	started_loop = Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 2, [' ']))
	muted = Loop.frame(started_loop.state, packet(33333, 100, 40, 0, ['m']))
	started_loop.state.game.mode == Playing and started_loop.samples.len() > 300 and muted.samples.is_empty() and !muted.state.sound
}

# Resizing recomputes the layout and forces a full redraw.
expect {
	a = Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 2, []))
	b = Loop.frame(a.state, packet(33333, 140, 50, 2, []))
	b.state.lay.cols == 140 and Str.from_utf8_lossy(b.bytes).contains("\u(1b)[2J")
}

# Gameplay events are logged with frame numbers for headless evidence.
expect {
	a = Loop.frame(Loop.init(loop_cfg), packet(16666, 100, 40, 2, [' ']))
	Str.from_utf8_lossy(a.log).contains("event start")
}
