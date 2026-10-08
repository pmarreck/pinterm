import Physics
import Table

## Pure pinball game state machine: fixed-timestep ball physics against the
## table, flipper/plunger control (with key-release emulation for terminals
## that only report presses), scoring rules, combos, multiball, ball save,
## tilt, and per-frame effect events for the renderer and synthesizer.
Game :: [].{
	Key : [LeftFlip, RightFlip, Plunger, Start, Nudge, Pause, New]
	Event : [Press(Key), Release(Key)]
	Mode : [Attract, Playing, BallOver, GameOver]
	Ball : { pos : V, vel : V, r : F64 }
	Flipper : { angle : F64, omega : F64, down : Bool, until : F64 }
	Fx : [
		Bumper(I64),
		Sling,
		Flip,
		Launch(F64),
		Drain,
		Rollover,
		LanesDone,
		Target,
		TargetsDone,
		Saucer,
		Multiball,
		Jackpot,
		Saved,
		Warn,
		Tilt,
		Skill,
		GameOver,
		Begin,
		Wall(F64),
	]
	Popup : { pos : V, text : Str, until : F64 }
	State : {
		mode : Mode,
		time : F64,
		acc : F64,
		rng : U64,
		score : I64,
		high : I64,
		ball_number : I64,
		balls : List(Ball),
		on_plunger : Bool,
		pulling : Bool,
		pull : F64,
		pull_start : F64,
		pull_last : F64,
		pull_repeats : I64,
		left : Flipper,
		right : Flipper,
		exact_keys : Bool,
		mult : I64,
		lanes_lit : List(Bool),
		lane_cool : List(F64),
		targets_lit : List(Bool),
		lock_lit : Bool,
		multiball : Bool,
		jackpot : I64,
		saucer_hold : List(Ball),
		saucer_until : F64,
		saucer_cool : F64,
		combo : I64,
		combo_until : F64,
		save_until : F64,
		save_spent : Bool,
		tilt : F64,
		tilted : Bool,
		bumper_flash : List(F64),
		sling_flash : List(F64),
		target_flash : List(F64),
		popups : List(Popup),
		bumpers_hit : I64,
		targets_hit : I64,
		lanes_hit : I64,
		mode_until : F64,
		message : Str,
		message_until : F64,
		paused : Bool,
		skill_lane : U64,
		skill_live : Bool,
		still_time : F64,
		fx : List(Fx),
		log : List(Str),
		frame : U64,
		bonus_award : I64,
	}

	balls_per_game : I64
	balls_per_game = 3

	## Fixed physics substep (seconds); small enough that the fastest ball
	## moves less than its radius per step, so thin walls cannot be tunneled.
	substep : F64
	substep = 1.0 / 480.0

	new : U64 -> State
	new = |seed| {
		mode: Attract,
		time: 0.0,
		acc: 0.0,
		rng: mix_seed(seed),
		score: 0,
		high: 0,
		ball_number: 0,
		balls: [],
		on_plunger: Bool.False,
		pulling: Bool.False,
		pull: 0.0,
		pull_start: 0.0,
		pull_last: 0.0,
		pull_repeats: 0,
		left: { angle: Table.left_rest, omega: 0.0, down: Bool.False, until: 0.0 },
		right: { angle: Table.right_rest, omega: 0.0, down: Bool.False, until: 0.0 },
		exact_keys: Bool.False,
		mult: 1,
		lanes_lit: [Bool.False, Bool.False, Bool.False],
		lane_cool: [0.0, 0.0, 0.0],
		targets_lit: [Bool.False, Bool.False, Bool.False, Bool.False],
		lock_lit: Bool.False,
		multiball: Bool.False,
		jackpot: jackpot_base,
		saucer_hold: [],
		saucer_until: 0.0,
		saucer_cool: 0.0,
		combo: 0,
		combo_until: 0.0,
		save_until: 0.0,
		save_spent: Bool.False,
		tilt: 0.0,
		tilted: Bool.False,
		bumper_flash: [0.0, 0.0, 0.0],
		sling_flash: [0.0, 0.0],
		target_flash: [-10.0, -10.0, -10.0, -10.0],
		popups: [],
		bumpers_hit: 0,
		targets_hit: 0,
		lanes_hit: 0,
		mode_until: 0.0,
		message: "PRESS SPACE TO PLAY",
		message_until: 1.0e9,
		paused: Bool.False,
		skill_lane: 1,
		skill_live: Bool.False,
		still_time: 0.0,
		fx: [],
		log: [],
		frame: 0,
		bonus_award: 0,
	}

	## Advance one rendered frame: apply input events, then run whole physics
	## substeps for the elapsed (clamped) time. Clears last frame's effects.
	step : State, F64, List(Event) -> State
	step = |g0, dt_raw, events| {
		dt = Physics.clamp(dt_raw, 0.0, max_frame_dt)
		g1 = { ..g0, fx: [], log: [], frame: g0.frame + 1 }
		g2 = events.fold(g1, apply_event)
		if g2.paused {
			g2
		} else {
			g3 = { ..g2, time: g2.time + dt }
			match g3.mode {
				Playing => play(g3, dt)
				BallOver => {
					moved = settle_flippers(g3, dt)
					if moved.time >= moved.mode_until next_ball(moved) else moved
				}
				Attract => settle_flippers(g3, dt)
				GameOver => settle_flippers(g3, dt)
			}
		}
	}

	## Flipper end point for rendering and collision.
	flipper_tip : V, F64 -> V
	flipper_tip = |pivot, angle| {
		x: pivot.x + Table.flipper_length * angle.cos(),
		y: pivot.y + Table.flipper_length * angle.sin(),
	}

	## Seconds of ball save remaining (0 when inactive).
	save_left : State -> F64
	save_left = |g| if g.save_until > g.time g.save_until - g.time else 0.0
}

V : { x : F64, y : F64 }

max_frame_dt : F64
max_frame_dt = 0.1

gravity : F64
gravity = 72.0

max_speed : F64
max_speed = 170.0

wall_restitution : F64
wall_restitution = 0.42

flipper_restitution : F64
flipper_restitution = 0.22

bumper_kick : F64
bumper_kick = 44.0

sling_kick : F64
sling_kick = 36.0

flip_up_speed : F64
flip_up_speed = 32.0

flip_down_speed : F64
flip_down_speed = 15.0

## Without key-release reports, a press holds the flipper this long and each
## autorepeat extends it; long enough to bridge typical autorepeat delays.
hold_initial : F64
hold_initial = 0.42

hold_repeat : F64
hold_repeat = 0.12

## Baseline plunger: launch after this long without another press.
plunger_idle : F64
plunger_idle = 0.65

plunger_full_time : F64
plunger_full_time = 0.9

combo_window : F64
combo_window = 1.6

ball_save_time : F64
ball_save_time = 9.0

tilt_limit : F64
tilt_limit = 3.0

tilt_warn : F64
tilt_warn = 1.9

tilt_decay : F64
tilt_decay = 0.45

## Below this height a resting ball is on (or against) the flippers.
cradle_zone_y : F64
cradle_zone_y = 64.0

jackpot_base : I64
jackpot_base = 10000

bonus_pause : F64
bonus_pause = 2.6

# ---------- random numbers (xorshift64*) ----------

mix_seed : U64 -> U64
mix_seed = |seed| {
	s = seed.bitwise_xor(0x9E3779B97F4A7C15)
	if s == 0 0x2545F4914F6CDD1D else s
}

## Returns a uniform F64 in [0, 1) and the advanced generator state.
next_unit : U64 -> (F64, U64)
next_unit = |s0| {
	s1 = s0.bitwise_xor(s0.shr_zf_wrap(12))
	s2 = s1.bitwise_xor(s1.shl_wrap(25))
	s3 = s2.bitwise_xor(s2.shr_zf_wrap(27))
	out = s3.times_wrap(0x2545F4914F6CDD1D).shr_zf_wrap(11)
	(out.to_f64() / 9007199254740992.0, s3)
}

rand : State -> (F64, State)
rand = |g| {
	(u, s) = next_unit(g.rng)
	(u, { ..g, rng: s })
}

# ---------- small helpers ----------

emit : State, Game.Fx -> State
emit = |g, fx| { ..g, fx: g.fx.append(fx) }

note : State, Str -> State
note = |g, line| { ..g, log: g.log.append(line) }

announce : State, Str, F64 -> State
announce = |g, text, secs| { ..g, message: text, message_until: g.time + secs }

set_at : List(a), U64, a -> List(a)
set_at = |list, i, v| list.set(i, v) ?? list

get_bool : List(Bool), U64 -> Bool
get_bool = |list, i| list.get(i) ?? Bool.False

get_f64 : List(F64), U64 -> F64
get_f64 = |list, i| list.get(i) ?? 0.0

int_str : F64 -> Str
int_str = |x| {
	n = x.round_to_i64_try() ?? 0
	n.to_str()
}

popup : State, V, Str -> State
popup = |g, pos, text| {
	kept = g.popups.keep_if(|p| p.until > g.time)
	trimmed = if kept.len() >= 6 kept.drop_first(1) else kept
	{ ..g, popups: trimmed.append({ pos, text, until: g.time + 0.9 }) }
}

## Award points with the bonus multiplier and advance the combo chain.
award : State, I64, V -> State
award = |g, base, pos| {
	combo = if g.time < g.combo_until g.combo + 1 else 1
	combo_points = if combo >= 3 25 * combo else 0
	points = base * g.mult + combo_points
	label = if combo >= 3 "+${points.to_str()} x${combo.to_str()}" else "+${points.to_str()}"
	g1 = { ..g, score: g.score + points, combo, combo_until: g.time + combo_window }
	popup(g1, pos, label)
}

# ---------- input ----------

apply_event : State, Game.Event -> State
apply_event = |g, event| {
	match event {
		Press(key) => press(g, key)
		Release(key) => release({ ..g, exact_keys: Bool.True }, key)
	}
}

press : State, Game.Key -> State
press = |g, key| {
	match key {
		Pause => if g.mode == Playing { ..g, paused: !g.paused } else g
		New => start_game(g)
		Start => if g.mode == Attract or (g.mode == GameOver and g.time >= g.mode_until) start_game(g) else g
		Plunger =>
			if g.mode == Attract or (g.mode == GameOver and g.time >= g.mode_until) {
				start_game(g)
			} else if g.mode == Playing and g.on_plunger and !g.paused {
				if g.pulling {
					{ ..g, pull_last: g.time, pull_repeats: g.pull_repeats + 1 }
				} else {
					{ ..g, pulling: Bool.True, pull_start: g.time, pull_last: g.time, pull_repeats: 0, pull: 0.0 }
				}
			} else {
				g
			}
		LeftFlip => if g.paused g else flip_press(g, Left)
		RightFlip => if g.paused g else flip_press(g, Right)
		Nudge => if g.mode == Playing and !g.paused nudge(g) else g
	}
}

release : State, Game.Key -> State
release = |g, key| {
	match key {
		LeftFlip => { ..g, left: { ..g.left, down: Bool.False, until: 0.0 } }
		RightFlip => { ..g, right: { ..g.right, down: Bool.False, until: 0.0 } }
		Plunger => if g.pulling launch(g) else g
		_ => g
	}
}

flip_press : State, [Left, Right] -> State
flip_press = |g, side| {
	f = match side {
		Left => g.left
		Right => g.right
	}
	extend = if f.until > g.time hold_repeat else hold_initial
	fresh = !(f.down or f.until > g.time)
	f2 = { ..f, down: Bool.True, until: Physics.clamp(g.time + extend, f.until, 1.0e12) }
	g1 = match side {
		Left => { ..g, left: f2 }
		Right => { ..g, right: f2 }
	}
	if fresh and g.mode == Playing and !g.tilted {
		# Classic lane change: flippers rotate the lit top-lane pattern.
		rotated = match side {
			Left => rotate_left(g1.lanes_lit)
			Right => rotate_right(g1.lanes_lit)
		}
		side_name = match side {
			Left => "left"
			Right => "right"
		}
		note(emit({ ..g1, lanes_lit: rotated, skill_lane: rotate_index(g1.skill_lane, side) }, Flip), "event flip side=${side_name}")
	} else {
		g1
	}
}

rotate_left : List(Bool) -> List(Bool)
rotate_left = |l| l.drop_first(1).append(l.first() ?? Bool.False)

rotate_right : List(Bool) -> List(Bool)
rotate_right = |l| l.drop_last(1).prepend(l.last() ?? Bool.False)

rotate_index : U64, [Left, Right] -> U64
rotate_index = |i, side| {
	match side {
		Left => if i == 0 2 else i - 1
		Right => if i == 2 0 else i + 1
	}
}

nudge : State -> State
nudge = |g| {
	(u, g1) = rand(g)
	push = { x: (u - 0.5) * 30.0, y: -18.0 }
	tilt = g1.tilt + 1.0
	nudged0 = { ..g1, tilt, balls: g1.balls.map(|b| { ..b, vel: Physics.add(b.vel, push) }) }
	nudged = note(nudged0, "event nudge tilt=${int_str(tilt * 10.0)}")
	if tilt >= tilt_limit and !g1.tilted {
		tilted = announce({ ..nudged, tilted: Bool.True }, "TILT", 3.0)
		note(emit(tilted, Tilt), "event tilt score=${g.score.to_str()}")
	} else if tilt >= tilt_warn {
		emit(announce(nudged, "DANGER", 1.0), Warn)
	} else {
		nudged
	}
}

# ---------- game flow ----------

start_game : State -> State
start_game = |g| {
	fresh = { ..Game.new(g.rng), frame: g.frame }
	(u, g1) = rand({ ..fresh, high: g.high, exact_keys: g.exact_keys, rng: g.rng })
	lane = if u < 0.34 0 else if u < 0.67 1 else 2
	g2 = {
		..g1,
		mode: Playing,
		time: g.time,
		ball_number: 1,
		on_plunger: Bool.True,
		skill_lane: lane,
		skill_live: Bool.True,
		message: "BALL 1",
		message_until: g.time + 2.0,
	}
	note(emit(g2, Begin), "event start seed_state=${g2.rng.to_str()}")
}

next_ball : State -> State
next_ball = |g| {
	if g.ball_number >= Game.balls_per_game {
		high = if g.score > g.high g.score else g.high
		over = { ..g, mode: GameOver, high, mode_until: g.time + 1.5, message: "GAME OVER", message_until: 1.0e12 }
		note(emit(over, GameOver), "event game_over score=${g.score.to_str()} high=${high.to_str()}")
	} else {
		n = g.ball_number + 1
		(u, g1) = rand(g)
		lane = if u < 0.34 0 else if u < 0.67 1 else 2
		g2 = {
			..g1,
			mode: Playing,
			ball_number: n,
			on_plunger: Bool.True,
			balls: [],
			tilt: 0.0,
			save_spent: Bool.False,
			tilted: Bool.False,
			mult: 1,
			bumpers_hit: 0,
			targets_hit: 0,
			lanes_hit: 0,
			combo: 0,
			skill_lane: lane,
			skill_live: Bool.True,
		}
		note(announce(g2, "BALL ${n.to_str()}", 2.0), "event ball ball=${n.to_str()} score=${g.score.to_str()}")
	}
}

## The last ball left the table: grant ball save or end the ball with bonus.
ball_lost : State -> State
ball_lost = |g| {
	if g.time < g.save_until and !g.tilted {
		saved = { ..g, on_plunger: Bool.True, save_until: 0.0, save_spent: Bool.True, multiball: Bool.False }
		note(emit(announce(saved, "BALL SAVED", 2.0), Saved), "event saved ball=${g.ball_number.to_str()}")
	} else {
		bonus = if g.tilted 0 else (g.bumpers_hit * 20 + g.targets_hit * 150 + g.lanes_hit * 100 + 500) * g.mult
		over = {
			..g,
			mode: BallOver,
			score: g.score + bonus,
			bonus_award: bonus,
			mode_until: g.time + bonus_pause,
			multiball: Bool.False,
			pulling: Bool.False,
			left: { ..g.left, down: Bool.False, until: 0.0 },
			right: { ..g.right, down: Bool.False, until: 0.0 },
		}
		text = if g.tilted "TILTED - NO BONUS" else "BONUS ${bonus.to_str()}"
		note(emit(announce(over, text, bonus_pause), Drain), "event drain ball=${g.ball_number.to_str()} bonus=${bonus.to_str()} score=${over.score.to_str()}")
	}
}

launch : State -> State
launch = |g| {
	power = if g.exact_keys or g.pull_repeats > 0 Physics.clamp((g.pull_last - g.pull_start + 0.05) / plunger_full_time, 0.0, 1.0) else 1.0
	power2 = if g.exact_keys Physics.clamp((g.time - g.pull_start) / plunger_full_time, 0.0, 1.0) else power
	(u, g1) = rand(g)
	speed = (78.0 + 66.0 * power2) * (0.985 + 0.03 * u)
	ball = { pos: Table.plunger_rest, vel: { x: 0.0, y: -speed }, r: Table.ball_radius }
	save = if g1.save_until > g1.time g1.save_until else if g1.save_spent 0.0 else g1.time + ball_save_time
	g2 = { ..g1, balls: g1.balls.append(ball), on_plunger: Bool.False, pulling: Bool.False, pull: 0.0, save_until: save }
	note(emit(g2, Launch(power2)), "event launch power=${int_str(power2 * 100.0)}")
}

auto_launch : State -> State
auto_launch = |g| {
	(u, g1) = rand(g)
	ball = { pos: Table.plunger_rest, vel: { x: 0.0, y: -(132.0 + 8.0 * u) }, r: Table.ball_radius }
	emit({ ..g1, balls: g1.balls.append(ball) }, Launch(1.0))
}

# ---------- per-frame play ----------

play : State, F64 -> State
play = |g0, dt| {
	g1 = update_plunger(g0)
	g2 = { ..g1, tilt: Physics.clamp(g1.tilt - tilt_decay * dt, 0.0, 10.0) }
	var $g = { ..g2, acc: g2.acc + dt }
	while $g.acc >= Game.substep {
		$g = substep_all({ ..$g, acc: $g.acc - Game.substep })
	}
	g3 = update_saucer($g)
	g4 = unstick(g3, dt)
	if g4.balls.is_empty() and g4.saucer_hold.is_empty() and !g4.on_plunger ball_lost(g4) else g4
}

update_plunger : State -> State
update_plunger = |g| {
	if !g.pulling {
		g
	} else {
		pull = Physics.clamp((g.time - g.pull_start) / plunger_full_time, 0.0, 1.0)
		g1 = { ..g, pull }
		if !g.exact_keys and g.time - g.pull_last > plunger_idle launch(g1) else g1
	}
}

flipper_target : State, Game.Flipper, F64, F64 -> F64
flipper_target = |g, f, rest, up| {
	held = (if g.exact_keys f.down else f.until > g.time) and !g.tilted and g.mode == Playing
	if held up else rest
}

move_flipper : Game.Flipper, F64, F64, F64 -> Game.Flipper
move_flipper = |f, target, dt, up_is_negative| {
	going_up = (target - f.angle) * up_is_negative < 0.0
	speed = if going_up flip_up_speed else flip_down_speed
	max_step = speed * dt
	diff = target - f.angle
	step = Physics.clamp(diff, -max_step, max_step)
	{ ..f, angle: f.angle + step, omega: step / dt }
}

settle_flippers : State, F64 -> State
settle_flippers = |g, dt| {
	left = move_flipper(g.left, Table.left_rest, dt, 1.0)
	right = move_flipper(g.right, Table.right_rest, dt, -1.0)
	{ ..g, left, right }
}

substep_all : State -> State
substep_all = |g0| {
	dt = Game.substep
	left = move_flipper(g0.left, flipper_target(g0, g0.left, Table.left_rest, Table.left_up), dt, 1.0)
	right = move_flipper(g0.right, flipper_target(g0, g0.right, Table.right_rest, Table.right_up), dt, -1.0)
	g1 = { ..g0, left, right }
	var $g = { ..g1, balls: [] }
	for ball in g1.balls {
		$g = step_ball($g, ball)
	}
	$g
}

## One ball, one substep: integrate, resolve contacts, then sensors.
step_ball : State, Game.Ball -> State
step_ball = |g, b0| {
	b1 = Physics.integrate(b0, gravity, Game.substep, max_speed)
	# Static walls.
	var $b = b1
	var $wall_impact = 0.0
	for w in Table.walls {
		c = Physics.collide_segment($b, w, wall_restitution)
		if c.hit {
			$b = c.ball
			if c.impact > $wall_impact {
				$wall_impact = c.impact
			}
		}
	}
	# One-way gate: solid only from the playfield side.
	gate = Table.gate
	side = (gate.b.x - gate.a.x) * ($b.pos.y - gate.a.y) - (gate.b.y - gate.a.y) * ($b.pos.x - gate.a.x)
	if side < 0.0 {
		gc = Physics.collide_segment($b, gate, wall_restitution)
		if gc.hit {
			$b = gc.ball
		}
	}
	var $g = g
	if $wall_impact > 25.0 {
		$g = emit($g, Wall($wall_impact))
	}
	# Pop bumpers.
	var $bi = 0
	for bumper in Table.bumpers {
		c = Physics.collide_circle($b, bumper.pos, bumper.r, 0.55, bumper_kick)
		if c.hit {
			$b = c.ball
			if c.impact > 1.0 {
				$g = award({ ..$g, bumpers_hit: $g.bumpers_hit + 1, bumper_flash: set_at($g.bumper_flash, $bi, $g.time + 0.18) }, 100, bumper.pos)
				$g = emit($g, Bumper($g.combo))
			}
		}
		$bi = $bi + 1
	}
	# Slingshots.
	var $si = 0
	for sling in Table.slings {
		c0 = Physics.collide_segment($b, sling, wall_restitution)
		if c0.hit {
			if c0.impact > 9.0 {
				c = Physics.collide_kicker($b, sling, 0.4, sling_kick)
				$b = c.ball
				$g = award({ ..$g, sling_flash: set_at($g.sling_flash, $si, $g.time + 0.15) }, 10, $b.pos)
				$g = emit($g, Sling)
			} else {
				$b = c0.ball
			}
		}
		$si = $si + 1
	}
	# Stand-up targets T, E, R, M.
	var $ti = 0
	for target in Table.standups {
		c = Physics.collide_segment($b, target, 0.5)
		if c.hit {
			$b = c.ball
			if c.impact > 6.0 and get_f64($g.target_flash, $ti) < $g.time - 0.25 {
				$g = hit_target($g, $ti, $b.pos)
			}
		}
		$ti = $ti + 1
	}
	# Flippers.
	lt = Game.flipper_tip(Table.left_pivot, $g.left.angle)
	lc = Physics.collide_flipper($b, Table.left_pivot, lt, Table.flipper_thickness, $g.left.omega, flipper_restitution)
	if lc.hit {
		$b = lc.ball
	}
	rt = Game.flipper_tip(Table.right_pivot, $g.right.angle)
	rc = Physics.collide_flipper($b, Table.right_pivot, rt, Table.flipper_thickness, $g.right.omega, flipper_restitution)
	if rc.hit {
		$b = rc.ball
	}
	sensors($g, $b)
}

hit_target : State, U64, V -> State
hit_target = |g, i, pos| {
	lit = set_at(g.targets_lit, i, Bool.True)
	g1 = award({ ..g, targets_lit: lit, targets_hit: g.targets_hit + 1, target_flash: set_at(g.target_flash, i, g.time) }, 500, pos)
	if lit.all(|x| x) {
		g2 = { ..g1, targets_lit: [Bool.False, Bool.False, Bool.False, Bool.False], lock_lit: Bool.True, score: g1.score + 2500 * g1.mult }
		note(emit(announce(g2, "TERM COMPLETE - SAUCER LIT", 2.5), TargetsDone), "event targets_complete score=${g2.score.to_str()}")
	} else {
		emit(g1, Target)
	}
}

## Rollover lanes, saucer capture, plunger-lane rest and drain detection.
sensors : State, Game.Ball -> State
sensors = |g, b| {
	if b.pos.y > Table.drain_y {
		note(g, "event ball_out x=${int_str(b.pos.x)}")
	} else if b.pos.x > Table.lane_left and b.pos.y > 71.5 and Physics.length(b.vel) < 4.0 and !g.on_plunger {
		{ ..g, on_plunger: Bool.True }
	} else {
		dsq = Physics.sub(b.pos, Table.saucer)
		speed = Physics.length(b.vel)
		if Physics.length(dsq) < Table.saucer_radius and speed < 95.0 and g.time >= g.saucer_cool {
			capture_saucer(g, b)
		} else {
			lanes_check({ ..g, balls: g.balls.append(b) }, b)
		}
	}
}

lanes_check : State, Game.Ball -> State
lanes_check = |g, b| {
	var $g = g
	var $i = 0
	for lane in Table.lanes {
		if Physics.length(Physics.sub(b.pos, lane)) < Table.lane_sensor_radius and $g.time >= get_f64($g.lane_cool, $i) {
			$g = rollover($g, $i, lane)
		}
		$i = $i + 1
	}
	$g
}

rollover : State, U64, V -> State
rollover = |g, i, pos| {
	cooled = { ..g, lane_cool: set_at(g.lane_cool, i, g.time + 0.5) }
	skill = cooled.skill_live and cooled.skill_lane == i
	g1 = if skill note(emit(announce(award({ ..cooled, skill_live: Bool.False }, 2500, pos), "SKILL SHOT!", 2.0), Skill), "event skill_shot") else { ..cooled, skill_live: Bool.False }
	lit = set_at(g1.lanes_lit, i, Bool.True)
	g2 = award({ ..g1, lanes_lit: lit, lanes_hit: g1.lanes_hit + 1 }, 250, pos)
	if lit.all(|x| x) {
		mult = if g2.mult < 5 g2.mult + 1 else 5
		g3 = { ..g2, lanes_lit: [Bool.False, Bool.False, Bool.False], mult, score: g2.score + 1000 }
		note(emit(announce(g3, "BONUS X${mult.to_str()}", 2.0), LanesDone), "event lanes_complete mult=${mult.to_str()}")
	} else {
		emit(g2, Rollover)
	}
}

capture_saucer : State, Game.Ball -> State
capture_saucer = |g, b| {
	held = { ..b, pos: Table.saucer, vel: { x: 0.0, y: 0.0 } }
	g1 = { ..g, saucer_hold: g.saucer_hold.append(held) }
	if g.lock_lit and !g.multiball {
		g2 = { ..g1, lock_lit: Bool.False, multiball: Bool.True, saucer_until: g.time + 1.8, score: g1.score + 5000 * g1.mult }
		g3 = auto_launch(note(emit(announce(g2, "MULTIBALL!", 3.0), Multiball), "event multiball score=${g2.score.to_str()}"))
		{ ..g3, save_until: g3.time + 12.0 }
	} else if g.multiball {
		jp = g.jackpot
		g2 = { ..g1, saucer_until: g.time + 0.9, jackpot: jp + 5000, score: g1.score + jp }
		popup(note(emit(announce(g2, "JACKPOT ${jp.to_str()}", 2.5), Jackpot), "event jackpot value=${jp.to_str()}"), Table.saucer, "JACKPOT")
	} else {
		g2 = award({ ..g1, saucer_until: g.time + 0.7 }, 250, Table.saucer)
		emit(g2, Saucer)
	}
}

update_saucer : State -> State
update_saucer = |g| {
	if g.saucer_hold.is_empty() or g.time < g.saucer_until {
		g
	} else {
		var $g = { ..g, saucer_hold: [], saucer_cool: g.time + 0.8 }
		for b in g.saucer_hold {
			(u, g1) = rand($g)
			out = { ..b, pos: { x: Table.saucer.x, y: Table.saucer.y - 2.5 }, vel: { x: (u - 0.5) * 50.0, y: -70.0 } }
			$g = { ..g1, balls: g1.balls.append(out) }
		}
		emit($g, Saucer)
	}
}

## Ball search: a ball sitting still outside the plunger lane gets a kick.
unstick : State, F64 -> State
unstick = |g, dt| {
	# Balls resting on the flippers are being cradled on purpose, not stuck.
	slow = g.balls.any(|b| Physics.length(b.vel) < 3.0 and b.pos.x < Table.lane_left and b.pos.y < cradle_zone_y)
	all_slow = slow and g.balls.all(|b| Physics.length(b.vel) < 3.0)
	if all_slow {
		t = g.still_time + dt
		if t > 3.0 {
			(u, g1) = rand(g)
			kicked = g1.balls.map(|b| { ..b, vel: { x: (u - 0.5) * 40.0, y: -45.0 } })
			note({ ..g1, balls: kicked, still_time: 0.0 }, "event ball_search")
		} else {
			{ ..g, still_time: t }
		}
	} else {
		{ ..g, still_time: 0.0 }
	}
}
