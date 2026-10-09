## Pinball table layouts as data, in world units (x right, y down; one unit is
## one half-cell pixel). Every table shares the cabinet, plunger lane and lower
## playfield (flippers, slingshots, inlanes, drain) so flipper feel is
## constant; each layout supplies its own upper playfield, rules features
## (lanes, stand-up and drop targets, saucers, ramps, upper flippers),
## gravity and palette. Physics and rendering read the same layout value.
Table :: [].{
	Ramp : { name : Str, entry : V, entry_r : F64, min_speed : F64, path : List(V), exit_speed : F64 }
	Upper : { pivot : V, side : [Left, Right], length : F64, rest : F64, up : F64 }
	Palette : {
		wall_top : U32,
		wall_bottom : U32,
		bumper_ring : U32,
		bumper_in : U32,
		bumper_out : U32,
		sling : U32,
		sling_fill : U32,
		flipper : U32,
		bg_top : U32,
		bg_bottom : U32,
		grid : U32,
		lane_lit : U32,
		target_lit : U32,
		ramp : U32,
	}
	Layout : {
		name : Str,
		blurb : Str,
		gravity : F64,
		walls : List(Seg),
		bumpers : List({ pos : V, r : F64 }),
		slings : List(Seg),
		lanes : List(V),
		lane_names : List(Str),
		standups : List(Seg),
		standup_names : List(Str),
		drops : List(Seg),
		drop_names : List(Str),
		saucers : List(V),
		ramps : List(Ramp),
		ramp_cars_for_lock : U64,
		uppers : List(Upper),
		left_flipper : Upper,
		right_flipper : Upper,
		palette : Palette,
	}

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

	## The standard lower flipper pair; a table may place its own.
	main_left : Upper
	main_left = { pivot: Table.left_pivot, side: Left, length: Table.flipper_length, rest: Table.left_rest, up: Table.left_up }

	main_right : Upper
	main_right = { pivot: Table.right_pivot, side: Right, length: Table.flipper_length, rest: Table.right_rest, up: Table.right_up }

	## The one-way gate at the top of the plunger lane: solid only for balls on
	## the playfield side, so launched balls pass but play cannot fall back in.
	gate : Seg
	gate = { a: { x: 43.0, y: 19.0 }, b: { x: 47.0, y: 14.0 } }

	lane_sensor_radius : F64
	lane_sensor_radius = 2.2

	saucer_radius : F64
	saucer_radius = 1.4

	## Slingshot triangles (shared lower playfield), for rendering fills.
	sling_triangles : List(List(V))
	sling_triangles = [
		[{ x: 8.5, y: 54.0 }, { x: 8.5, y: 62.0 }, { x: 12.5, y: 64.5 }],
		[{ x: 35.5, y: 54.0 }, { x: 35.5, y: 62.0 }, { x: 31.5, y: 64.5 }],
	]

	all : List(Layout)
	all = [classic_layout, orbital, iron_horse, graveyard]

	count : U64
	count = 4

	## Layout by index, wrapping around (index 0 is the classic table).
	at : U64 -> Layout
	at = |i| Table.all.get(i % Table.count) ?? classic_layout

	classic : Layout
	classic = classic_layout
}

V : { x : F64, y : F64 }

Seg : { a : V, b : V }

seg : F64, F64, F64, F64 -> Seg
seg = |ax, ay, bx, by| { a: { x: ax, y: ay }, b: { x: bx, y: by } }

## Elliptical top arch from the left wall (1, 13) over to the right wall (47, 13).
arch : F64 -> List(Seg)
arch = |flatten| {
	steps = 18
	var $segs = []
	var $i = 0
	while $i < steps {
		t0 = F64.pi + F64.pi * $i.to_f64() / steps.to_f64()
		t1 = F64.pi + F64.pi * ($i + 1).to_f64() / steps.to_f64()
		a = { x: 24.0 + 23.0 * t0.cos(), y: 13.0 + 23.0 * t0.sin() * flatten }
		b = { x: 24.0 + 23.0 * t1.cos(), y: 13.0 + 23.0 * t1.sin() * flatten }
		$segs = $segs.append({ a, b })
		$i = $i + 1
	}
	$segs
}

## Cabinet sides, plunger lane and the shared lower playfield.
lower_walls : List(Seg)
lower_walls = [
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
	# Left orbit exit guide: turns balls running down the left wall back into
	# play instead of letting full launches fall into the left outlane. It
	# slopes down to the right, so nothing can come to rest against it.
	seg(1.0, 25.0, 6.5, 30.5),
]

shared_slings : List(Seg)
shared_slings = [
	{ a: { x: 8.5, y: 54.0 }, b: { x: 12.5, y: 64.5 } },
	{ a: { x: 35.5, y: 54.0 }, b: { x: 31.5, y: 64.5 } },
]

## Original neon table: P-I-N lanes, three pop bumpers, T-E-R-M targets and a
## center saucer that starts multiball.
classic_layout : Table.Layout
classic_layout = {
	name: "NEON CLASSIC",
	blurb: "Light T-E-R-M, sink the saucer",
	gravity: 72.0,
	walls: List.concat(
		List.concat(arch(0.55), lower_walls),
		[
			# Top lane dividers.
			seg(11.5, 15.0, 11.5, 21.0),
			seg(18.5, 15.0, 18.5, 21.0),
			seg(25.5, 15.0, 25.5, 21.0),
			seg(32.5, 15.0, 32.5, 21.0),
		],
	),
	bumpers: [
		{ pos: { x: 15.0, y: 25.0 }, r: 2.6 },
		{ pos: { x: 29.0, y: 25.0 }, r: 2.6 },
		{ pos: { x: 22.0, y: 33.0 }, r: 2.6 },
	],
	slings: shared_slings,
	lanes: [{ x: 15.0, y: 18.0 }, { x: 22.0, y: 18.0 }, { x: 29.0, y: 18.0 }],
	lane_names: ["P", "I", "N"],
	standups: [
		{ a: { x: 1.6, y: 33.0 }, b: { x: 1.6, y: 37.0 } },
		{ a: { x: 1.6, y: 40.0 }, b: { x: 1.6, y: 44.0 } },
		{ a: { x: 42.4, y: 33.0 }, b: { x: 42.4, y: 37.0 } },
		{ a: { x: 42.4, y: 40.0 }, b: { x: 42.4, y: 44.0 } },
	],
	standup_names: ["T", "E", "R", "M"],
	drops: [],
	drop_names: [],
	saucers: [{ x: 22.0, y: 46.0 }],
	ramps: [],
	ramp_cars_for_lock: 0,
	uppers: [],
	left_flipper: Table.main_left,
	right_flipper: Table.main_right,
	palette: {
		wall_top: 0x00E5FF,
		wall_bottom: 0xB44DFF,
		bumper_ring: 0xFF2A8A,
		bumper_in: 0xFFD23F,
		bumper_out: 0xFF7A2A,
		sling: 0x9DFF00,
		sling_fill: 0x2D5C00,
		flipper: 0xFFB000,
		bg_top: 0x0B0E24,
		bg_bottom: 0x1A0A26,
		grid: 0x2A3A6A,
		lane_lit: 0x00FF9C,
		target_lit: 0xFF5EF0,
		ramp: 0x3A6AA0,
	},
}

## Space table after the rocket-launch digital tables: W-A-R-P lanes, a
## diamond of attack bumpers, an I-G-N-I-T-E drop bank across midfield, a
## launch ramp up the left side into the top lanes and a black-hole saucer.
orbital : Table.Layout
orbital = {
	name: "ORBITAL",
	blurb: "Drop I-G-N-I-T-E, ride the launch ramp",
	gravity: 70.0,
	walls: List.concat(
		List.concat(arch(0.62), lower_walls),
		[
			# Top lane dividers for four W-A-R-P lanes.
			seg(9.5, 14.0, 9.5, 20.0),
			seg(15.75, 14.0, 15.75, 20.0),
			seg(22.0, 14.0, 22.0, 20.0),
			seg(28.25, 14.0, 28.25, 20.0),
			seg(34.5, 14.0, 34.5, 20.0),
			# Launch ramp mouth: a short guide that funnels shots up the left side.
			seg(10.5, 47.0, 10.5, 42.5),
		],
	),
	bumpers: [
		{ pos: { x: 22.0, y: 24.5 }, r: 2.3 },
		{ pos: { x: 16.0, y: 29.0 }, r: 2.3 },
		{ pos: { x: 28.0, y: 29.0 }, r: 2.3 },
		{ pos: { x: 22.0, y: 33.5 }, r: 2.3 },
	],
	slings: shared_slings,
	lanes: [{ x: 12.6, y: 17.0 }, { x: 18.9, y: 17.0 }, { x: 25.1, y: 17.0 }, { x: 31.4, y: 17.0 }],
	lane_names: ["W", "A", "R", "P"],
	standups: [],
	standup_names: [],
	drops: [
		{ a: { x: 13.0, y: 42.0 }, b: { x: 15.4, y: 42.0 } },
		{ a: { x: 16.6, y: 42.0 }, b: { x: 19.0, y: 42.0 } },
		{ a: { x: 20.2, y: 42.0 }, b: { x: 22.6, y: 42.0 } },
		{ a: { x: 23.8, y: 42.0 }, b: { x: 26.2, y: 42.0 } },
		{ a: { x: 27.4, y: 42.0 }, b: { x: 29.8, y: 42.0 } },
		{ a: { x: 31.0, y: 42.0 }, b: { x: 33.4, y: 42.0 } },
	],
	drop_names: ["I", "G", "N", "I", "T", "E"],
	saucers: [{ x: 37.5, y: 36.0 }],
	ramps: [
		{
			name: "LAUNCH RAMP",
			entry: { x: 7.0, y: 45.0 },
			entry_r: 2.4,
			min_speed: 55.0,
			path: [{ x: 7.0, y: 45.0 }, { x: 4.0, y: 34.0 }, { x: 4.0, y: 20.0 }, { x: 8.0, y: 12.0 }, { x: 12.5, y: 13.0 }],
			exit_speed: 30.0,
		},
	],
	ramp_cars_for_lock: 0,
	uppers: [],
	left_flipper: Table.main_left,
	right_flipper: Table.main_right,
	palette: {
		wall_top: 0x4CC9FF,
		wall_bottom: 0x7B2CFF,
		bumper_ring: 0xFF6A00,
		bumper_in: 0xFFF3B0,
		bumper_out: 0xFFCC00,
		sling: 0x4CFFE1,
		sling_fill: 0x0B3A44,
		flipper: 0xE8E8FF,
		bg_top: 0x050818,
		bg_bottom: 0x0B0430,
		grid: 0x1C2A5A,
		lane_lit: 0x4CFFE1,
		target_lit: 0xFFCC00,
		ramp: 0x2C6CFF,
	},
}

## Steam-train table after the Old West ramp tables: two crossing ramps feed
## the opposite inlanes, every ramp adds a car to the train and four cars
## light the lock for multiball. W-E-S-T lanes and C-O-A-L targets.
iron_horse : Table.Layout
iron_horse = {
	name: "IRON HORSE",
	blurb: "Ramps add cars: four cars, all aboard",
	gravity: 74.0,
	walls: List.concat(
		List.concat(arch(0.5), lower_walls),
		[
			seg(10.0, 15.0, 10.0, 20.5),
			seg(16.5, 15.0, 16.5, 20.5),
			seg(23.0, 15.0, 23.0, 20.5),
			seg(29.5, 15.0, 29.5, 20.5),
			seg(36.0, 15.0, 36.0, 20.5),
			# Ramp mouth posts flanking the center saucer lane.
			seg(16.0, 38.0, 16.0, 42.0),
			seg(28.0, 38.0, 28.0, 42.0),
		],
	),
	bumpers: [
		{ pos: { x: 16.5, y: 26.0 }, r: 2.4 },
		{ pos: { x: 27.5, y: 26.0 }, r: 2.4 },
		{ pos: { x: 22.0, y: 31.0 }, r: 2.4 },
	],
	slings: shared_slings,
	lanes: [{ x: 13.25, y: 18.0 }, { x: 19.75, y: 18.0 }, { x: 26.25, y: 18.0 }, { x: 32.75, y: 18.0 }],
	lane_names: ["W", "E", "S", "T"],
	standups: [
		{ a: { x: 42.4, y: 30.0 }, b: { x: 42.4, y: 33.0 } },
		{ a: { x: 42.4, y: 35.0 }, b: { x: 42.4, y: 38.0 } },
		{ a: { x: 42.4, y: 40.0 }, b: { x: 42.4, y: 43.0 } },
		{ a: { x: 42.4, y: 45.0 }, b: { x: 42.4, y: 48.0 } },
	],
	standup_names: ["C", "O", "A", "L"],
	drops: [],
	drop_names: [],
	saucers: [{ x: 22.0, y: 40.0 }],
	ramps: [
		{
			name: "LEFT RAMP",
			entry: { x: 12.5, y: 41.0 },
			entry_r: 2.3,
			min_speed: 60.0,
			path: [{ x: 12.5, y: 41.0 }, { x: 15.0, y: 22.0 }, { x: 24.0, y: 11.0 }, { x: 38.0, y: 16.0 }, { x: 40.5, y: 34.0 }, { x: 37.3, y: 50.5 }],
			exit_speed: 18.0,
		},
		{
			name: "RIGHT RAMP",
			entry: { x: 31.5, y: 41.0 },
			entry_r: 2.3,
			min_speed: 60.0,
			path: [{ x: 31.5, y: 41.0 }, { x: 29.0, y: 22.0 }, { x: 20.0, y: 11.0 }, { x: 6.0, y: 16.0 }, { x: 3.5, y: 34.0 }, { x: 6.7, y: 50.5 }],
			exit_speed: 18.0,
		},
	],
	ramp_cars_for_lock: 4,
	uppers: [],
	left_flipper: Table.main_left,
	right_flipper: Table.main_right,
	palette: {
		wall_top: 0xFFB347,
		wall_bottom: 0xC0392B,
		bumper_ring: 0xD35400,
		bumper_in: 0xFFE7A0,
		bumper_out: 0xFFB347,
		sling: 0xF4D03F,
		sling_fill: 0x4A3000,
		flipper: 0xE0E0E0,
		bg_top: 0x140A04,
		bg_bottom: 0x2A1206,
		grid: 0x4A2A14,
		lane_lit: 0xF4D03F,
		target_lit: 0xFF7043,
		ramp: 0x8A6A3A,
	},
}

## Haunted table after the steep graveyard tables: stronger gravity, a skull
## saucer at center, two ramps that build the jackpot, an R-I-P drop bank and
## an upper right flipper aimed at the left ramp.
graveyard : Table.Layout
graveyard = {
	name: "GRAVEYARD",
	blurb: "Steep and fast: feed the skull",
	gravity: 90.0,
	walls: List.concat(
		List.concat(arch(0.58), lower_walls),
		[
			seg(13.5, 14.5, 13.5, 20.0),
			seg(19.5, 14.5, 19.5, 20.0),
			seg(24.5, 14.5, 24.5, 20.0),
			seg(30.5, 14.5, 30.5, 20.0),
			# Upper flipper mount: a short wall the flipper sits under.
			seg(39.0, 38.0, 41.5, 36.0),
		],
	),
	bumpers: [
		{ pos: { x: 12.0, y: 26.0 }, r: 2.2 },
		{ pos: { x: 32.0, y: 26.0 }, r: 2.2 },
		{ pos: { x: 22.0, y: 25.5 }, r: 2.2 },
	],
	slings: shared_slings,
	lanes: [{ x: 16.5, y: 17.5 }, { x: 22.0, y: 17.5 }, { x: 27.5, y: 17.5 }],
	lane_names: ["B", "O", "O"],
	standups: [],
	standup_names: [],
	drops: [
		{ a: { x: 7.0, y: 44.0 }, b: { x: 9.6, y: 44.0 } },
		{ a: { x: 10.8, y: 44.0 }, b: { x: 13.4, y: 44.0 } },
		{ a: { x: 14.6, y: 44.0 }, b: { x: 17.2, y: 44.0 } },
	],
	drop_names: ["R", "I", "P"],
	saucers: [{ x: 22.0, y: 34.0 }],
	ramps: [
		{
			name: "SOUL RAMP",
			entry: { x: 8.5, y: 36.0 },
			entry_r: 2.3,
			min_speed: 55.0,
			path: [{ x: 8.5, y: 36.0 }, { x: 6.0, y: 20.0 }, { x: 14.0, y: 10.0 }, { x: 30.0, y: 10.0 }, { x: 38.0, y: 18.0 }, { x: 37.3, y: 50.5 }],
			exit_speed: 18.0,
		},
		{
			name: "CRYPT RAMP",
			entry: { x: 33.0, y: 46.0 },
			entry_r: 2.3,
			min_speed: 60.0,
			path: [{ x: 33.0, y: 46.0 }, { x: 36.0, y: 30.0 }, { x: 30.0, y: 12.0 }, { x: 14.0, y: 12.0 }, { x: 4.0, y: 24.0 }, { x: 6.7, y: 50.5 }],
			exit_speed: 18.0,
		},
	],
	ramp_cars_for_lock: 0,
	uppers: [{ pivot: { x: 40.0, y: 40.0 }, side: Right, length: 4.6, rest: F64.pi - 0.45, up: F64.pi + 0.35 }],
	left_flipper: Table.main_left,
	right_flipper: Table.main_right,
	palette: {
		wall_top: 0x7DFF6A,
		wall_bottom: 0x6A2CFF,
		bumper_ring: 0xB44DFF,
		bumper_in: 0xE6FFD8,
		bumper_out: 0x7DFF6A,
		sling: 0xB44DFF,
		sling_fill: 0x2A0A3A,
		flipper: 0xD8FFD0,
		bg_top: 0x050A05,
		bg_bottom: 0x120518,
		grid: 0x1E3A1E,
		lane_lit: 0x7DFF6A,
		target_lit: 0xFF3B3B,
		ramp: 0x3A7A3A,
	},
}
