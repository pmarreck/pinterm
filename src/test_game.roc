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

expect Table.walls.len() > 30
expect Table.standups.len() == 4

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
