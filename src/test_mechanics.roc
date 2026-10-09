import Physics
import Table
import Game
import TestKit exposing [frame, in_play, run_frames, run_logged, started]

main! = |_args| Ok({})

# Each test puts one feature on a bare copy of the classic table (walls and
# flippers only) around (22, 50), and drives it through Game.step only.

on_table : Table.Layout -> Game.State
on_table = |table| { ..started, table }

classic : Table.Layout
classic = { ..started.table, bumpers: [], slings: [], lanes: [], lane_names: [], standups: [], standup_names: [], saucers: [], ramps: [] }

speed = |b| Physics.length(b.vel)

# ---------- kickback ----------

# A lit kickback fires a falling ball back up the field once, then goes dark.
expect {
	g = in_play({ ..on_table({ ..classic, kickbacks: [{ x: 22.0, y: 50.0 }] }), kickback_lit: Bool.True }, 22.0, 48.5, 0.0, 40.0)
	(after, lines) = run_logged(g, 6)
	after.balls.any(|b| b.vel.y < -60.0) and !after.kickback_lit and lines.any(|l| l == "event kickback")
}

# Unlit, it lets the ball fall.
expect {
	g = in_play({ ..on_table({ ..classic, kickbacks: [{ x: 22.0, y: 50.0 }] }), kickback_lit: Bool.False }, 22.0, 48.5, 0.0, 40.0)
	after = run_frames(g, 6)
	after.balls.all(|b| b.vel.y > 0.0)
}

# Every new ball relights it.
expect {
	g = { ..on_table({ ..classic, kickbacks: [{ x: 22.0, y: 50.0 }] }), kickback_lit: Bool.False }
	drained = run_frames(in_play({ ..g, save_until: 0.0 }, 22.0, 81.0, 0.0, 30.0), 200)
	drained.kickback_lit
}

# ---------- magnet ----------

# The magnet grabs a passing ball, holds it, then flings it hard.
expect {
	g = in_play(on_table({ ..classic, magnets: [{ x: 22.0, y: 50.0 }] }), 19.0, 50.0, 30.0, 0.0)
	held = run_frames(g, 12)
	(after, lines) = run_logged(held, 40)
	held.balls.is_empty() and held.magnet_hold.len() == 1 and after.magnet_hold.is_empty() and after.balls.any(|b| speed(b) > 50.0) and lines.any(|l| l.starts_with("event magnet_release"))
}

# A released ball is not immediately recaptured.
expect {
	g = in_play(on_table({ ..classic, magnets: [{ x: 22.0, y: 50.0 }] }), 19.0, 50.0, 30.0, 0.0)
	after = run_frames(g, 12 + 70)
	run_frames(after, 10).magnet_hold.is_empty()
}

# ---------- portals ----------

# Entering one end of a portal pair comes out of the other at the same speed.
expect {
	g = in_play(on_table({ ..classic, portals: [{ a: { x: 22.0, y: 50.0 }, b: { x: 32.0, y: 44.0 } }] }), 20.0, 50.0, 40.0, 0.0)
	(after, lines) = run_logged(g, 4)
	ball = after.balls.first() ?? { pos: { x: 0.0, y: 0.0 }, vel: { x: 0.0, y: 0.0 }, r: 1.0 }
	Physics.length(Physics.sub(ball.pos, { x: 32.0, y: 44.0 })) < 4.0 and speed(ball) > 35.0 and lines.any(|l| l == "event warp")
}

# The exit does not send the ball straight back.
expect {
	g = in_play(on_table({ ..classic, portals: [{ a: { x: 22.0, y: 50.0 }, b: { x: 32.0, y: 44.0 } }] }), 20.0, 50.0, 40.0, 0.0)
	(_, lines) = run_logged(g, 12)
	lines.count_if(|l| l == "event warp") == 1
}

# ---------- movers ----------

train : Table.Mover
train = { a: { x: 10.0, y: 50.0 }, b: { x: 34.0, y: 50.0 }, half: 3.0, period: 4.0 }

# The bar travels from a to b and back once per period.
expect {
	near = |p, q| Physics.length(Physics.sub(p, q)) < 0.001
	near(Game.mover_center(train, 0.0), train.a) and near(Game.mover_center(train, 2.0), train.b) and near(Game.mover_center(train, 4.0), train.a)
}

# A ball dropped onto the bar bounces off it and scores.
expect {
	g0 = on_table({ ..classic, movers: [train] })
	g = in_play({ ..g0, time: 0.0 }, 10.0, 47.0, 0.0, 30.0)
	(after, lines) = run_logged(g, 8)
	after.balls.any(|b| b.vel.y < 0.0) and after.score >= g.score + 1000 and lines.any(|l| l.starts_with("event mover_hit"))
}

# ---------- spinners ----------

gate : Table.Layout
gate = { ..classic, spinners: [{ a: { x: 20.0, y: 50.0 }, b: { x: 24.0, y: 50.0 } }] }

# A faster pass spins it more and scores more; it never blocks the ball.
expect {
	slow = run_logged(in_play(on_table(gate), 22.0, 53.0, 0.0, -35.0), 14)
	fast = run_logged(in_play(on_table(gate), 22.0, 53.0, 0.0, -110.0), 4)
	gain = |(s, _)| s.score - started.score
	spins = |(_, lines)| lines.any(|l| l.starts_with("event spin"))
	spins(slow) and spins(fast) and gain(fast) > gain(slow) and gain(slow) > 0 and slow.0.balls.any(|b| b.pos.y < 50.0)
}

# ---------- rotors ----------

# The rotor angle advances with game time.
expect {
	r = { center: { x: 22.0, y: 50.0 }, length: 4.0, speed: 2.0 }
	(Game.rotor_angle(r, 1.5) - 3.0).abs() < 0.000001
}

# A ball falling onto the rising side of a spinning arm is knocked back up.
expect {
	r = { center: { x: 22.0, y: 50.0 }, length: 5.0, speed: 3.0 }
	g = in_play({ ..on_table({ ..classic, rotors: [r] }), time: 0.0 }, 19.0, 47.0, 0.0, 30.0)
	after = run_frames(g, 6)
	after.balls.any(|b| b.vel.y < 0.0)
}

# ---------- ghost bumpers ----------

ghost : Table.Ghost
ghost = { pos: { x: 22.0, y: 50.0 }, r: 2.4, period: 2.0, solid: 1.2 }

expect Game.ghost_solid(ghost, 0.5) and !Game.ghost_solid(ghost, 1.5) and Game.ghost_solid(ghost, 2.5)

# Solid: the ball bounces and scores. Faded: the ball passes straight through.
expect {
	g = on_table({ ..classic, ghosts: [ghost] })
	solid = run_frames(in_play({ ..g, time: 0.2 }, 22.0, 46.0, 0.0, 30.0), 6)
	faded = run_frames(in_play({ ..g, time: 1.3 }, 22.0, 46.0, 0.0, 30.0), 6)
	solid.balls.any(|b| b.vel.y < 0.0) and solid.score > started.score and faded.balls.any(|b| b.vel.y > 0.0) and faded.score == started.score
}

# A ball lingering on a spinner does not score it again within the cooldown,
# even on a table swapped in after the game started.
expect {
	(_, lines) = run_logged(in_play(on_table(gate), 22.0, 50.5, 0.0, -2.0), 10)
	lines.count_if(|l| l.starts_with("event spin")) == 1
}
