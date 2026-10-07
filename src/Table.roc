## Static geometry of the neon pinball table in world units (x right, y down;
## one unit is one half-cell pixel). Walls are line segments; the top arch is a
## polygonal approximation; bumpers, slingshots, sensors and targets are named
## so gameplay and rendering share one source of truth.
Table :: [].{
	width : F64
	width = 48.0

	height : F64
	height = 80.0

	ball_radius : F64
	ball_radius = 1.0

	## Plunger lane: ball rests here before launch; lane wall separates it.
	lane_left : F64
	lane_left = 43.0

	plunger_rest : V
	plunger_rest = { x: 45.0, y: 74.0 }

	plunger_top : F64
	plunger_top = 75.0

	drain_y : F64
	drain_y = 82.5

	flipper_length : F64
	flipper_length = 6.2

	flipper_thickness : F64
	flipper_thickness = 0.85

	left_pivot : V
	left_pivot = { x: 14.0, y: 71.0 }

	right_pivot : V
	right_pivot = { x: 30.0, y: 71.0 }

	## Flipper world angles (radians, screen coordinates: +y down).
	left_rest : F64
	left_rest = 0.52

	left_up : F64
	left_up = -0.50

	right_rest : F64
	right_rest = F64.pi - 0.52

	right_up : F64
	right_up = F64.pi + 0.50

	walls : List(Seg)
	walls = wall_list

	## The one-way gate at the top of the plunger lane: solid only for balls on
	## the playfield side, so launched balls pass but play cannot fall back in.
	gate : Seg
	gate = { a: { x: 43.0, y: 19.0 }, b: { x: 47.0, y: 14.0 } }

	bumpers : List({ pos : V, r : F64 })
	bumpers = [
		{ pos: { x: 15.0, y: 25.0 }, r: 2.6 },
		{ pos: { x: 29.0, y: 25.0 }, r: 2.6 },
		{ pos: { x: 22.0, y: 33.0 }, r: 2.6 },
	]

	## Slingshot kicking faces (the hypotenuse of each triangle).
	slings : List(Seg)
	slings = [
		{ a: { x: 8.5, y: 54.0 }, b: { x: 12.5, y: 64.5 } },
		{ a: { x: 35.5, y: 54.0 }, b: { x: 31.5, y: 64.5 } },
	]

	## Top rollover lane sensors (P, I, N).
	lanes : List(V)
	lanes = [{ x: 15.0, y: 18.0 }, { x: 22.0, y: 18.0 }, { x: 29.0, y: 18.0 }]

	lane_sensor_radius : F64
	lane_sensor_radius = 2.2

	## Stand-up targets T, E, R, M as short wall segments.
	standups : List(Seg)
	standups = [
		{ a: { x: 1.6, y: 33.0 }, b: { x: 1.6, y: 37.0 } },
		{ a: { x: 1.6, y: 40.0 }, b: { x: 1.6, y: 44.0 } },
		{ a: { x: 42.4, y: 33.0 }, b: { x: 42.4, y: 37.0 } },
		{ a: { x: 42.4, y: 40.0 }, b: { x: 42.4, y: 44.0 } },
	]

	## Kick-out saucer: captures the ball, awards, then ejects it.
	saucer : V
	saucer = { x: 22.0, y: 46.0 }

	saucer_radius : F64
	saucer_radius = 1.4

	## Outer arch centre and radius (top of the cabinet).
	arch_center : V
	arch_center = { x: 24.0, y: 13.0 }

	arch_radius : F64
	arch_radius = 23.0
}

V : { x : F64, y : F64 }

Seg : { a : V, b : V }

arch_segments : List(Seg)
arch_segments = {
	steps = 18
	var $segs = []
	var $i = 0
	while $i < steps {
		t0 = F64.pi + F64.pi * $i.to_f64() / steps.to_f64()
		t1 = F64.pi + F64.pi * ($i + 1).to_f64() / steps.to_f64()
		a = { x: 24.0 + 23.0 * t0.cos(), y: 13.0 + 23.0 * t0.sin() * 0.55 }
		b = { x: 24.0 + 23.0 * t1.cos(), y: 13.0 + 23.0 * t1.sin() * 0.55 }
		$segs = $segs.append({ a, b })
		$i = $i + 1
	}
	$segs
}

seg : F64, F64, F64, F64 -> Seg
seg = |ax, ay, bx, by| { a: { x: ax, y: ay }, b: { x: bx, y: by } }

wall_list : List(Seg)
wall_list = List.concat(
	arch_segments,
	[
		# Cabinet sides.
		seg(1.0, 13.0, 1.0, 84.0),
		seg(47.0, 13.0, 47.0, 84.0),
		# Plunger lane wall and plunger head.
		seg(43.0, 19.0, 43.0, 84.0),
		seg(43.0, 75.0, 47.0, 75.0),
		# Left inlane guide and slingshot body.
		seg(5.0, 52.0, 5.0, 64.0),
		seg(5.0, 64.0, 13.2, 70.2),
		seg(8.5, 54.0, 8.5, 62.0),
		seg(8.5, 62.0, 12.5, 64.5),
		# Right inlane guide and slingshot body.
		seg(39.0, 52.0, 39.0, 64.0),
		seg(39.0, 64.0, 30.8, 70.2),
		seg(35.5, 54.0, 35.5, 62.0),
		seg(35.5, 62.0, 31.5, 64.5),
		# Top lane dividers.
		seg(11.5, 15.0, 11.5, 21.0),
		seg(18.5, 15.0, 18.5, 21.0),
		seg(25.5, 15.0, 25.5, 21.0),
		seg(32.5, 15.0, 32.5, 21.0),
	],
)
