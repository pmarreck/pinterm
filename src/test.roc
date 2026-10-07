import Physics
import Table
import Game
import Input
import Render
import Audio
import Loop

main! = |_args| Ok({})

# ---------- physics ----------

# A ball falling onto a horizontal floor segment is pushed out and bounces up.
expect {
	ball = { pos: { x: 5.0, y: 9.5 }, vel: { x: 0.0, y: 10.0 }, r: 1.0 }
	floor = { a: { x: 0.0, y: 10.0 }, b: { x: 10.0, y: 10.0 } }
	res = Physics.collide_segment(ball, floor, 0.5)
	res.hit and res.ball.vel.y == -5.0 and res.ball.pos.y == 9.0
}

# A ball moving away from a wall it overlaps is pushed out but keeps its velocity.
expect {
	ball = { pos: { x: 5.0, y: 9.5 }, vel: { x: 0.0, y: -3.0 }, r: 1.0 }
	floor = { a: { x: 0.0, y: 10.0 }, b: { x: 10.0, y: 10.0 } }
	res = Physics.collide_segment(ball, floor, 0.5)
	res.ball.vel.y == -3.0 and res.impact == 0.0
}

# Far balls do not collide.
expect {
	ball = { pos: { x: 5.0, y: 5.0 }, vel: { x: 0.0, y: 3.0 }, r: 1.0 }
	floor = { a: { x: 0.0, y: 10.0 }, b: { x: 10.0, y: 10.0 } }
	!Physics.collide_segment(ball, floor, 0.5).hit
}

# A bumper kicks the ball outward faster than it arrived.
expect {
	ball = { pos: { x: 0.0, y: -3.0 }, vel: { x: 0.0, y: 10.0 }, r: 1.0 }
	res = Physics.collide_circle(ball, { x: 0.0, y: 0.0 }, 2.5, 0.5, 40.0)
	res.hit and res.ball.vel.y < -40.0
}

# A rising flipper (moving surface) launches a resting ball upward hard.
expect {
	ball = { pos: { x: 5.0, y: -1.5 }, vel: { x: 0.0, y: 0.0 }, r: 1.0 }
	# Flipper pointing right from the pivot, rotating counter-clockwise (up) on screen.
	res = Physics.collide_flipper(ball, { x: 0.0, y: 0.0 }, { x: 6.0, y: 0.0 }, 0.8, -25.0, 0.3)
	res.hit and res.ball.vel.y < -100.0
}

# Integration applies gravity and caps speed.
expect {
	ball = { pos: { x: 0.0, y: 0.0 }, vel: { x: 1000.0, y: 0.0 }, r: 1.0 }
	moved = Physics.integrate(ball, 50.0, 0.01, 100.0)
	Physics.length(moved.vel) <= 100.0001 and moved.pos.x > 0.0
}

# ---------- table ----------

expect Table.walls.len() > 30
expect Table.standups.len() == 4

# ---------- helpers ----------

frame : F64
frame = 1.0 / 60.0

run_frames : Game.State, U64 -> Game.State
run_frames = |g, n| {
	var $g = g
	var $i = 0
	while $i < n {
		$g = Game.step($g, frame, [])
		$i = $i + 1
	}
	$g
}

press : Game.State, Game.Key -> Game.State
press = |g, key| Game.step(g, frame, [Press(key)])

started : Game.State
started = press(Game.new(42), Start)

# Put one ball in play at a position with a velocity, nothing on the plunger.
in_play : Game.State, F64, F64, F64, F64 -> Game.State
in_play = |g, x, y, vx, vy| {
	..g,
	balls: [{ pos: { x, y }, vel: { x: vx, y: vy }, r: Table.ball_radius }],
	on_plunger: Bool.False,
	save_until: 0.0,
}

# ---------- game flow ----------

expect Game.new(1).mode == Attract

expect started.mode == Playing and started.ball_number == 1 and started.score == 0 and started.on_plunger

# Holding then releasing the plunger launches the ball up the lane and into play.
expect {
	pulled = Game.step(started, frame, [Press(Plunger)])
	held = run_frames(pulled, 30)
	launched = Game.step(held, frame, [Release(Plunger)])
	after = run_frames(launched, 90)
	ball_left_lane = after.balls.any(|b| b.pos.x < Table.lane_left)
	!after.on_plunger and ball_left_lane
}

# Baseline terminals send no key release: a single plunger tap still launches.
expect {
	tapped = press(started, Plunger)
	after = run_frames(tapped, 150)
	!after.on_plunger and after.balls.any(|b| b.pos.x < Table.lane_left)
}

# Hitting a pop bumper scores 100 (times multiplier) and requests a sound.
expect {
	bumper = Table.bumpers.first() ?? { pos: { x: 0.0, y: 0.0 }, r: 1.0 }
	g = in_play(started, bumper.pos.x, bumper.pos.y - 4.5, 0.0, 60.0)
	after = run_frames(g, 6)
	after.score >= 100 and after.bumpers_hit >= 1
}

# A drained ball (no save) advances to the next ball after the bonus pause.
expect {
	g = in_play(started, 22.0, 80.0, 0.0, 50.0)
	drained = run_frames(g, 10)
	next = run_frames(drained, 240)
	drained.mode == BallOver and next.mode == Playing and next.ball_number == 2 and next.on_plunger
}

# Ball save returns a quickly drained ball without using up a ball.
expect {
	g = { ..in_play(started, 22.0, 80.0, 0.0, 50.0), save_until: 5.0 }
	after = run_frames(g, 10)
	after.mode == Playing and after.ball_number == 1 and after.on_plunger
}

# Draining the third ball ends the game; Start begins a fresh game.
expect {
	last = { ..in_play(started, 22.0, 80.0, 0.0, 50.0), ball_number: 3, score: 1234 }
	over = run_frames(last, 240)
	again = press(run_frames(over, 120), Start)
	over.mode == GameOver and over.high >= 1234 and again.mode == Playing and again.score == 0 and again.ball_number == 1
}

# Flipper press raises the flipper; baseline timeout lowers it without a release.
expect {
	g = in_play(started, 22.0, 30.0, 0.0, 0.0)
	up = run_frames(press(g, LeftFlip), 4)
	down = run_frames(up, 60)
	up.left.angle < Table.left_rest - 0.5 and down.left.angle > Table.left_rest - 0.05
}

# Enhanced keyboards: a release event lowers the flipper promptly.
expect {
	g = in_play(started, 22.0, 30.0, 0.0, 0.0)
	up = run_frames(press(g, RightFlip), 4)
	released = run_frames(Game.step(up, frame, [Release(RightFlip)]), 4)
	up.right.angle > Table.right_rest + 0.5 and released.right.angle < Table.right_rest + 0.05 and released.exact_keys
}

# A ball cradled on the left flipper is shot up the table when flipped.
expect {
	g = in_play(started, 18.0, 71.0, 0.0, 0.0)
	settled = run_frames(g, 8)
	flipped = run_frames(press(settled, LeftFlip), 3)
	flipped.balls.any(|b| b.vel.y < -60.0)
}

# Fast balls never tunnel through the cabinet walls (sweep of speeds/angles).
expect {
	var $ok = Bool.True
	for vx in [-160.0, -120.0, -80.0, 80.0, 120.0, 160.0] {
		for vy in [-150.0, -40.0, 0.0, 40.0] {
			g = in_play(started, 22.0, 45.0, vx, vy)
			after = run_frames(g, 40)
			for b in after.balls {
				if b.pos.x < 0.9 or b.pos.x > 47.1 or b.pos.y < 0.0 {
					$ok = Bool.False
				}
			}
		}
	}
	$ok
}

# Completing the three top lanes raises the bonus multiplier.
expect {
	g = { ..in_play(started, 15.0, 24.0, 0.0, -1.0), lanes_lit: [Bool.False, Bool.True, Bool.True] }
	after = run_frames({ ..g, balls: [{ pos: { x: 15.0, y: 18.0 }, vel: { x: 0.0, y: 5.0 }, r: 1.0 }] }, 2)
	after.mult == 2
}

# Completing T-E-R-M lights the saucer; a lit saucer starts two-ball multiball.
expect {
	g = { ..in_play(started, 22.0, 46.0, 0.0, 0.0), lock_lit: Bool.True }
	captured = run_frames(g, 2)
	later = run_frames(captured, 200)
	captured.saucer_hold.len() == 1 and later.multiball and (later.balls.len() + later.saucer_hold.len()) >= 2
}

expect {
	g = { ..in_play(started, 4.0, 35.0, -60.0, 0.0), targets_lit: [Bool.False, Bool.True, Bool.True, Bool.True] }
	after = run_frames(g, 6)
	after.lock_lit
}

# Excessive nudging tilts: flippers die until the ball drains.
expect {
	g = in_play(started, 22.0, 30.0, 0.0, 0.0)
	nudged = Game.step(Game.step(Game.step(Game.step(g, frame, [Press(Nudge)]), frame, [Press(Nudge)]), frame, [Press(Nudge)]), frame, [Press(Nudge)])
	flipped = run_frames(press(nudged, LeftFlip), 4)
	nudged.tilted and flipped.left.angle > Table.left_rest - 0.05
}

# Consecutive scoring within the combo window builds a combo.
expect {
	g = { ..started, combo: 2, combo_until: started.time + 1.0 }
	bumper = Table.bumpers.first() ?? { pos: { x: 0.0, y: 0.0 }, r: 1.0 }
	after = run_frames(in_play(g, bumper.pos.x, bumper.pos.y - 4.5, 0.0, 60.0), 6)
	after.combo >= 3
}

# Pausing freezes the simulation.
expect {
	g = in_play(started, 22.0, 30.0, 0.0, 0.0)
	paused = run_frames(press(g, Pause), 30)
	ys = paused.balls.map(|b| b.pos.y)
	paused.paused and ys == [30.0]
}

# Steps are deterministic for the same seed and inputs.
expect {
	a = run_frames(press(started, Plunger), 300)
	b = run_frames(press(started, Plunger), 300)
	a.balls.map(|x| x.pos) == b.balls.map(|x| x.pos) and a.score == b.score
}

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

# ---------- render ----------

expect Render.commas(0) == "0" and Render.commas(1234567) == "1,234,567" and Render.commas(1005) == "1,005"

# The layout fits inside the terminal at several sizes and keeps the panel when wide.
expect {
	sizes = [(80, 24), (120, 40), (200, 60), (40, 16), (60, 30)]
	sizes.all(
		|(c, r)| {
			lay = Render.layout(c, r)
			lay.ox + lay.tw <= (if lay.panel lay.px else c) and lay.oy + lay.th <= r and lay.ok
		},
	)
}
expect Render.layout(120, 40).panel and !Render.layout(50, 30).panel
expect !Render.layout(20, 8).ok

render_rows : U64, U64, Render.Opts -> List(Str)
render_rows = |cols, rows, opts| {
	lay = Render.layout(cols, rows)
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay))
	{
		var $out = []
		var $r = 0
		while $r < rows {
			$out = $out.append(Render.row_text(cells, cols, $r))
			$r = $r + 1
		}
		$out
	}
}

color_opts : Render.Opts
color_opts = { color: 0, ascii: Bool.False, sound: Bool.False, help: Bool.False, fps: 60 }

expect {
	lines = render_rows(100, 40, color_opts)
	joined = Str.join_with(lines, "\n")
	joined.contains("SCORE") and joined.contains("BALL 1/3") and joined.contains("●")
}

# ASCII mode output is pure 7-bit ASCII and still shows the ball on the plunger.
expect {
	lay = Render.layout(100, 40)
	opts = { ..color_opts, ascii: Bool.True, color: 3 }
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay))
	bytes = Render.encode([], cells, 100, 3)
	bytes.all(|b| b < 128) and cells.any(|c| c.cp == '@')
}

# Monochrome mode never emits color escape codes.
expect {
	lay = Render.layout(100, 40)
	opts = { ..color_opts, color: 3 }
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay))
	text = Str.from_utf8_lossy(Render.encode([], cells, 100, 3))
	!text.contains("38;2;") and !text.contains("48;5;") and !text.contains(";4")
}

# Diff encoding: an unchanged frame emits only the sync wrapper; one changed cell is small.
expect {
	lay = Render.layout(100, 40)
	cells = Render.compose(started, color_opts, lay, Render.static_pixels(lay))
	same = Render.encode(cells, cells, 100, 0)
	changed = cells.set(5, { cp: 'X', fg: 0xFFFFFF, bg: 0 }) ?? cells
	one = Render.encode(cells, changed, 100, 0)
	same.len() < 40 and one.len() < 80 and Str.from_utf8_lossy(one).contains("X")
}

# Tiny terminals get a readable request to enlarge instead of a broken table.
expect {
	lay = Render.layout(30, 10)
	cells = Render.compose(started, color_opts, lay, [])
	Render.row_text(cells, 30, 0).contains("Enlarge")
}

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

# Full redraws position the cursor at every row start (autowrap is disabled by the host).
expect {
	lay = Render.layout(60, 20)
	cells = Render.compose(started, color_opts, lay, Render.static_pixels(lay))
	text = Str.from_utf8_lossy(Render.encode([], cells, 60, 0))
	text.contains("\u(1b)[2;1H") and text.contains("\u(1b)[20;1H")
}

# Ball save is granted once per ball: a relaunched saved ball that drains is lost.
expect {
	g = { ..in_play(started, 22.0, 80.0, 0.0, 50.0), save_until: 5.0 }
	saved = run_frames(g, 10)
	relaunched = run_frames(press(saved, Plunger), 60)
	drained = run_frames({ ..relaunched, balls: [{ pos: { x: 22.0, y: 80.0 }, vel: { x: 0.0, y: 50.0 }, r: 1.0 }] }, 10)
	saved.on_plunger and drained.mode == BallOver
}

# Cradling a ball on a held flipper is legitimate: ball search must not kick it.
expect {
	g = { ..in_play(started, 17.0, 64.0, 0.0, 0.0), exact_keys: Bool.True }
	(held, lines) = run_logged(Game.step(g, frame, [Press(LeftFlip)]), 330)
	held.balls.all(|b| b.pos.y > 64.0) and !lines.any(|l| l.contains("ball_search"))
}

# A ball stuck elsewhere on the playfield is eventually kicked loose.
expect {
	g = in_play(started, 22.0, 40.0, 0.0, 0.0)
	frozen = { ..g, still_time: 2.99 }
	kicked = Game.step({ ..frozen, balls: [{ pos: { x: 30.0, y: 50.0 }, vel: { x: 0.0, y: 0.0 }, r: 1.0 }] }, frame, [])
	kicked.log.any(|l| l.contains("ball_search")) or kicked.balls.any(|b| b.vel.y < -10.0)
}

## Run frames with no input, collecting every frame's event log lines.
run_logged : Game.State, U64 -> (Game.State, List(Str))
run_logged = |g, n| {
	var $g = g
	var $lines = []
	var $i = 0
	while $i < n {
		$g = Game.step($g, frame, [])
		$lines = List.concat($lines, $g.log)
		$i = $i + 1
	}
	($g, $lines)
}
