import Physics
import Table
import Game
import TestKit

main! = |_args| Ok({})

frame = TestKit.frame

run_frames = TestKit.run_frames

press = TestKit.press

started = TestKit.started

in_play = TestKit.in_play

run_logged = TestKit.run_logged

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

expect Table.classic.walls.len() > 30
expect Table.classic.standups.len() == 4

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
	bumper = Table.classic.bumpers.first() ?? { pos: { x: 0.0, y: 0.0 }, r: 1.0 }
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
	bumper = Table.classic.bumpers.first() ?? { pos: { x: 0.0, y: 0.0 }, r: 1.0 }
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

# Regression: strong launches orbited the arch, hugged the left wall and fell
# straight into the left outlane. No launch power may feed the outlane directly.
expect {
	var $ok = Bool.True
	for seed in [1, 2, 3] {
		var $hold = 6
		while $hold <= 54 {
			g0 = { ..Game.step(Game.new(seed), frame, [Press(Start)]), exact_keys: Bool.True }
			var $g = Game.step(g0, frame, [Press(Plunger)])
			$g = run_frames($g, $hold)
			$g = Game.step($g, frame, [Release(Plunger)])
			var $i = 0
			while $i < 240 {
				$g = Game.step($g, frame, [])
				for b in $g.balls {
					if b.pos.x < 5.0 and b.pos.y > 53.0 {
						$ok = Bool.False
					}
				}
				$i = $i + 1
			}
			$hold = $hold + 4
		}
	}
	$ok
}

# Every nudge is logged (headless evidence; the web build checks motion nudges).
expect {
	g = in_play(started, 22.0, 30.0, 0.0, 0.0)
	nudged = press(g, Nudge)
	nudged.log.any(|l| l.starts_with("event nudge"))
}

# ---------- tables ----------

attract : Game.State
attract = Game.new(42)

# Between games, ] and [ cycle through every table and wrap both ways.
expect {
	var $g = attract
	var $seen = []
	var $i = 0
	while $i < Table.count {
		$g = press($g, NextTable)
		$seen = $seen.append($g.table_index)
		$i = $i + 1
	}
	back = press(attract, PrevTable)
	$seen == $seen.map_with_index(|_, i| (i + 1) % Table.count) and $seen.len() == Table.count and back.table_index == Table.count - 1 and back.table.name == (Table.at(Table.count - 1)).name
}

# The switch is animated: the slide is under way at once and done after transition_time.
expect {
	g = press(attract, NextTable)
	later = run_frames(g, 40)
	Game.transition(g) < 0.1 and g.transition_from == 0 and g.transition_dir == 1 and Game.transition(later) == 1.0 and Game.transition(attract) == 1.0
}

# Tables cannot change mid-game.
expect {
	g = press(started, NextTable)
	g.table_index == 0 and g.table.name == started.table.name
}

# Switching emits a sound cue and a log line naming the table.
expect {
	g = press(attract, NextTable)
	g.fx.contains(TableSwitch) and g.log.any(|l| l == "event table index=1 name=${(Table.at(1)).name}")
}

# Each table keeps its own high score, and a game starts on the selected table.
expect {
	g = press({ ..attract, highs: [100, 200, 300, 400] }, NextTable)
	playing = press(g, Start)
	g.high == 200 and playing.table_index == 1 and playing.table.name == (Table.at(1)).name and playing.high == 200
}

# Every table: every launch power reaches the playfield (leaves the shooter lane).
expect {
	var $ok = Bool.True
	var $t = 0
	while $t < Table.count {
		var $hold = 10
		while $hold <= 54 {
			g0 = { ..Game.step(Game.new_on(5, $t), frame, [Press(Start)]), exact_keys: Bool.True }
			var $g = Game.step(g0, frame, [Press(Plunger)])
			$g = run_frames($g, $hold)
			$g = Game.step($g, frame, [Release(Plunger)])
			var $left = Bool.False
			var $i = 0
			while $i < 360 {
				$g = Game.step($g, frame, [])
				if $g.balls.any(|b| b.pos.x < Table.lane_left - 2.0) {
					$left = Bool.True
				}
				$i = $i + 1
			}
			if !$left {
				$ok = Bool.False
			}
			$hold = $hold + 11
		}
		$t = $t + 1
	}
	$ok
}

# Every table: under seeded random flipping no ball leaves the cabinet bounds,
# and play keeps progressing: relaunching whenever a ball waits, every table scores.
expect {
	var $ok = Bool.True
	var $t = 0
	while $t < Table.count {
		var $g = { ..Game.step(Game.new_on(9, $t), frame, [Press(Start)]), exact_keys: Bool.True }
		$g = Game.step($g, frame, [Press(Plunger)])
		$g = run_frames($g, 40)
		$g = Game.step($g, frame, [Release(Plunger)])
		var $r = 12345.U64
		var $i = 0
		while $i < 3600 {
			$r = $r.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
			roll = $r.shr_zf_wrap(59)
			ev = if $g.on_plunger and $i % 90 == 0 [Press(Plunger)] else if $g.on_plunger and $i % 90 == 40 [Release(Plunger)] else if roll == 0 [Press(LeftFlip)] else if roll == 1 [Release(LeftFlip)] else if roll == 2 [Press(RightFlip)] else if roll == 3 [Release(RightFlip)] else []
			$g = Game.step($g, frame, ev)
			for b in $g.balls {
				if b.pos.x < -1.0 or b.pos.x > Table.width + 1.0 or b.pos.y < -1.0 {
					$ok = Bool.False
				}
			}
			$i = $i + 1
		}
		if $g.score == 0 {
			$ok = Bool.False
		}
		$t = $t + 1
	}
	$ok
}

started_on : U64 -> Game.State
started_on = |t| press(Game.new_on(42, t), Start)

# Orbital: a ball fired into a drop target knocks it down and bounces back.
expect {
	g = in_play(started_on(1), 14.2, 45.0, 0.0, -60.0)
	after = run_frames(g, 20)
	(after.drops_down.get(0) ?? Bool.False) and after.score >= 750 and after.balls.any(|b| b.vel.y > 0.0 or b.pos.y > 42.0)
}

# A downed drop target no longer blocks: the ball passes through its slot.
expect {
	g0 = started_on(1)
	g = in_play({ ..g0, drops_down: [Bool.True, Bool.False, Bool.False, Bool.False, Bool.False, Bool.False] }, 14.2, 45.0, 0.0, -60.0)
	after = run_frames(g, 6)
	after.balls.any(|b| b.pos.y < 41.0)
}

# Completing a bank lights the lock, scores the bonus and resets after the delay.
expect {
	g0 = started_on(1)
	g = in_play({ ..g0, drops_down: [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False] }, 32.2, 45.0, 0.0, -60.0)
	(done, lines) = run_logged(g, 20)
	reset = run_frames({ ..done, balls: [], on_plunger: Bool.True }, 300)
	lines.any(|l| l.starts_with("event drops_complete")) and done.lock_lit and reset.drops_down.all(|d| !d)
}

# Iron Horse: a fast shot into a ramp mouth rides the ramp, then exits with
# a ramp award and a train car; a second ramp inside the window is a combo.
expect {
	g = in_play(started_on(2), 12.5, 42.5, 8.0, -90.0)
	riding = run_frames(g, 3)
	(back, lines) = run_logged(riding, 70)
	riding.riders.len() == 1 and riding.balls.is_empty() and back.riders.is_empty() and back.cars == 1 and back.ramps_hit == 1 and lines.any(|l| l.starts_with("event ramp")) and back.balls.len() == 1
}

expect {
	g = in_play({ ..started_on(2), ramp_combo: 1, ramp_combo_until: 1.0e9 }, 31.5, 42.5, -8.0, -90.0)
	(back, _) = run_logged(g, 70)
	back.ramp_combo == 2 and back.ramps_hit == 1
}

# A slow ball does not climb the ramp.
expect {
	g = in_play(started_on(2), 12.5, 42.5, 2.0, -20.0)
	after = run_frames(g, 3)
	after.riders.is_empty()
}

# Graveyard: the upper right flipper swings with the right flipper button.
expect {
	g = started_on(3)
	up = run_frames(press(g, RightFlip), 6)
	rest = (g.uppers.get(0) ?? { angle: 0.0, omega: 0.0, down: Bool.False, until: 0.0 }).angle
	moved = (up.uppers.get(0) ?? { angle: 0.0, omega: 0.0, down: Bool.False, until: 0.0 }).angle
	g.uppers.len() == 1 and (moved - rest).abs() > 0.5
}

# A table key mid-game is refused visibly (a swipe would otherwise do nothing).
expect {
	g = press(started, NextTable)
	g.table_index == 0 and g.message == "CHANGE TABLES BETWEEN GAMES" and g.log.any(|l| l.starts_with("event table_locked"))
}

# Every table: in a minute of seeded random play (relaunching whenever a ball
# waits), no ball gets trapped. A trap shows up as repeated ball searches,
# since the search kicks a still ball after 3 s.
expect {
	var $worst = 0.U64
	var $t = 0
	while $t < Table.count {
		for seed in [3, 8] {
			var $g = { ..Game.step(Game.new_on(seed, $t), frame, [Press(Start)]), exact_keys: Bool.True }
			var $r = seed.times_wrap(2654435761)
			var $searches = 0.U64
			var $i = 0
			while $i < 3600 {
				$r = $r.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
				roll = $r.shr_zf_wrap(59)
				ev = if $g.on_plunger and $i % 90 == 0 [Press(Plunger)] else if $g.on_plunger and $i % 90 == 40 [Release(Plunger)] else if roll == 0 [Press(LeftFlip)] else if roll == 1 [Release(LeftFlip)] else if roll == 2 [Press(RightFlip)] else if roll == 3 [Release(RightFlip)] else []
				$g = Game.step($g, frame, ev)
				if $g.log.any(|l| l == "event ball_search") {
					$searches = $searches + 1
				}
				$i = $i + 1
			}
			if $searches > $worst {
				$worst = $searches
			}
		}
		$t = $t + 1
	}
	$worst <= 2
}
