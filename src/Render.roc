import Physics
import Table
import Game

## Pure terminal renderer. Rasterizes the table into half-cell pixels (two per
## character cell via upper-half-block glyphs), overlays the ball, text and a
## score panel, degrades to 256/16-color, monochrome block and plain ASCII
## modes, and encodes only changed cells as ANSI escape sequences.
Render :: [].{
	Cell : { cp : U32, fg : U32, bg : U32 }
	Layout : {
		cols : U64,
		rows : U64,
		s : F64,
		ox : U64,
		oy : U64,
		tw : U64,
		th : U64,
		pw : U64,
		ph : U64,
		panel : Bool,
		px : U64,
		ok : Bool,
	}
	Opts : { color : U8, ascii : Bool, sound : Bool, help : Bool, fps : U64 }

	color_true : U8
	color_true = 0

	color_256 : U8
	color_256 = 1

	color_16 : U8
	color_16 = 2

	color_mono : U8
	color_mono = 3

	min_cols : U64
	min_cols = 36

	min_rows : U64
	min_rows = 14

	panel_width : U64
	panel_width = 26

	## Fit the table (48x80 world units, two pixels per cell row) and an
	## optional side panel into the terminal, preserving the table's aspect.
	layout : U64, U64 -> Layout
	layout = |cols, rows| {
		ok = cols >= Render.min_cols and rows >= Render.min_rows
		panel = cols >= 48 + Render.panel_width
		avail_cols = if panel cols - Render.panel_width - 1 else cols
		top = if panel 0 else 2
		avail_rows = if rows > top rows - top else 1
		s_cols = avail_cols.to_f64() / Table.width
		s_rows = (avail_rows * 2).to_f64() / Table.height
		s0 = if s_cols < s_rows s_cols else s_rows
		s = Physics.clamp(s0, 0.2, 2.5)
		tw = floor_u64(Table.width * s)
		th = floor_u64(Table.height * s / 2.0)
		# Center the table (plus the panel beside it, when shown) horizontally.
		group = if panel tw + 1 + Render.panel_width else tw
		ox = if cols > group (cols - group) / 2 else 0
		oy = top + (if avail_rows > th (avail_rows - th) / 2 else 0)
		{ cols, rows, s, ox, oy, tw, th, pw: tw, ph: th * 2, panel, px: if panel ox + tw + 1 else 0, ok }
	}

	## Static table raster, recomputed only when the layout changes.
	static_pixels : Layout -> List(U32)
	static_pixels = |lay| {
		var $buf = List.with_capacity(lay.pw * lay.ph)
		var $py = 0
		while $py < lay.ph {
			var $px = 0
			while $px < lay.pw {
				$buf = $buf.append(static_at(lay, $px, $py))
				$px = $px + 1
			}
			$py = $py + 1
		}
		$buf
	}

	## Compose the full screen as cells for one frame.
	compose : Game.State, Opts, Layout, List(U32) -> List(Cell)
	compose = |g, opts, lay, base| {
		blank = { cp: ' ', fg: ink_text, bg: panel_bg }
		cells0 = List.repeat(blank, lay.cols * lay.rows)
		if !lay.ok {
			msg = "Enlarge terminal to ${Render.min_cols.to_str()}x${Render.min_rows.to_str()}"
			put_text(cells0, lay.cols, 0, 0, msg, ink_warn, panel_bg)
		} else {
			pixels = dynamic_pixels(g, lay, base)
			cells1 = blit_table(cells0, lay, pixels, opts)
			cells2 = overlay_table(cells1, g, lay, opts)
			cells3 = if lay.panel draw_panel(cells2, g, lay, opts) else draw_hud(cells2, g, lay, opts)
			cells4 = if opts.help draw_help(cells3, lay) else cells3
			if opts.color == Render.color_mono or opts.ascii cells4.map(strip_color) else cells4
		}
	}

	## Encode the changed cells (all cells when `prev` is empty or sized
	## differently) into ANSI bytes, wrapped in a synchronized-update block.
	encode : List(Cell), List(Cell), U64, U8 -> List(U8)
	encode = |prev, next, cols, mode| {
		full = prev.len() != next.len()
		var $out = Str.to_utf8("\u(1b)[?2026h")
		if full {
			$out = List.concat($out, Str.to_utf8("\u(1b)[0m\u(1b)[2J"))
		}
		var $pen_fg = 0xFFFFFFFE
		var $pen_bg = 0xFFFFFFFE
		var $cursor = 0xFFFFFFFFFFFFFFFF
		var $i = 0
		n = next.len()
		while $i < n {
			cell = next.get($i) ?? { cp: ' ', fg: default_color, bg: default_color }
			changed = full or (prev.get($i) ?? cell) != cell or !(prev.get($i).is_ok())
			if changed {
				if $cursor != $i or $i % cols == 0 {
					row = $i // cols
					col = $i % cols
					$out = List.concat($out, Str.to_utf8("\u(1b)[${(row + 1).to_str()};${(col + 1).to_str()}H"))
				}
				if cell.fg != $pen_fg or cell.bg != $pen_bg {
					$out = List.concat($out, sgr(cell.fg, cell.bg, mode))
					$pen_fg = cell.fg
					$pen_bg = cell.bg
				}
				$out = utf8_append($out, cell.cp)
				$cursor = $i + 1
			}
			$i = $i + 1
		}
		List.concat($out, Str.to_utf8("\u(1b)[0m\u(1b)[?2026l"))
	}

	## Text in a frame's cells (row-major), for tests and the headless log.
	row_text : List(Cell), U64, U64 -> Str
	row_text = |cells, cols, row| {
		slice = cells.sublist({ start: row * cols, len: cols })
		bytes = slice.fold([], |acc, c| utf8_append(acc, c.cp))
		Str.from_utf8_lossy(bytes)
	}

	## Format a score with thousands separators.
	commas : I64 -> Str
	commas = |n| commas_impl(n)
}

# ---------- palette (0xRRGGBB; kind in the top byte for ASCII/mono) ----------

default_color : U32
default_color = 0x80000000

bold_flag : U32
bold_flag = 0x01000000

panel_bg : U32
panel_bg = 0x07050E

ink_text : U32
ink_text = 0xC9C3E6

ink_dim : U32
ink_dim = 0x6A6390

ink_warn : U32
ink_warn = 0xFFB000

ink_score : U32
ink_score = 0xFFF2A8

ink_ball : U32
ink_ball = 0xFFFFFF

kind_bg : U32
kind_bg = 0

kind_wall : U32
kind_wall = 1

kind_bumper : U32
kind_bumper = 2

kind_sling : U32
kind_sling = 3

kind_flipper : U32
kind_flipper = 4

kind_light_off : U32
kind_light_off = 5

kind_light_on : U32
kind_light_on = 6

kind_trail : U32
kind_trail = 7

kind_plunger : U32
kind_plunger = 8

kind_saucer : U32
kind_saucer = 9

px_of : U32, U32 -> U32
px_of = |kind, rgb| kind.shl_wrap(24).bitwise_or(rgb)

kind_of : U32 -> U32
kind_of = |p| p.shr_zf_wrap(24)

rgb_of : U32 -> U32
rgb_of = |p| p.bitwise_and(0xFFFFFF)

floor_u64 : F64 -> U64
floor_u64 = |x| {
	if x <= 0.0 {
		0
	} else {
		x.floor_to_u64_try() ?? 0
	}
}

## Linear blend of two RGB colors, t in [0, 1].
mix : U32, U32, F64 -> U32
mix = |a, b, t| {
	ch = |c, shift| c.shr_zf_wrap(shift).bitwise_and(0xFF).to_f64()
	blend = |shift| {
		v = ch(a, shift) * (1.0 - t) + ch(b, shift) * t
		(floor_u64(Physics.clamp(v, 0.0, 255.0))).to_u32_wrap().shl_wrap(shift)
	}
	blend(16).bitwise_or(blend(8)).bitwise_or(blend(0))
}

# ---------- static raster ----------

world_of : Render.Layout, U64, U64 -> { x : F64, y : F64 }
world_of = |lay, px, py| { x: (px.to_f64() + 0.5) / lay.s, y: (py.to_f64() + 0.5) / lay.s }

static_at : Render.Layout, U64, U64 -> U32
static_at = |lay, px, py| {
	p = world_of(lay, px, py)
	line = Physics.clamp(0.62 / lay.s, 0.45, 1.6)
	in_bumper = Table.bumpers.find_first(|b| Physics.length(Physics.sub(p, b.pos)) <= b.r)
	match in_bumper {
		Ok(b) => {
			d = Physics.length(Physics.sub(p, b.pos)) / b.r
			if d > 0.72 px_of(kind_bumper, 0xFF2A8A) else px_of(kind_bumper, mix(0xFFD23F, 0xFF7A2A, d))
		}
		Err(_) =>
			if in_sling(p) {
				px_of(kind_sling, 0x2D5C00)
			} else if Table.slings.any(|sl| seg_dist(p, sl) <= line) {
				px_of(kind_sling, 0x9DFF00)
			} else if Table.walls.any(|w| seg_dist(p, w) <= line) {
				t = Physics.clamp(p.y / Table.height, 0.0, 1.0)
				px_of(kind_wall, mix(0x00E5FF, 0xB44DFF, t))
			} else if seg_dist(p, Table.gate) <= line * 0.7 {
				px_of(kind_wall, 0x3F8FA8)
			} else if Physics.length(Physics.sub(p, Table.saucer)) <= Table.saucer_radius {
				px_of(kind_saucer, 0x1A1030)
			} else {
				background(p)
			}
	}
}

background : { x : F64, y : F64 } -> U32
background = |p| {
	t = Physics.clamp(p.y / Table.height, 0.0, 1.0)
	base = mix(0x0B0E24, 0x1A0A26, t)
	gx = ((floor_u64(p.x)) % 6 == 0)
	gy = ((floor_u64(p.y)) % 6 == 0)
	inside = p.x > 1.0 and p.x < 47.0 and p.y > 2.0
	if inside and gx and gy {
		px_of(kind_bg, mix(base, 0x2A3A6A, 0.5))
	} else {
		px_of(kind_bg, base)
	}
}

seg_dist : { x : F64, y : F64 }, { a : { x : F64, y : F64 }, b : { x : F64, y : F64 } } -> F64
seg_dist = |p, s| Physics.length(Physics.sub(p, Physics.closest_on_segment(p, s.a, s.b)))

## Point inside either slingshot triangle (barycentric sign test).
in_sling : { x : F64, y : F64 } -> Bool
in_sling = |p| {
	tri = |a, b, c| {
		d1 = cross(p, a, b)
		d2 = cross(p, b, c)
		d3 = cross(p, c, a)
		neg = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
		pos = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
		!(neg and pos)
	}
	tri({ x: 8.5, y: 54.0 }, { x: 8.5, y: 62.0 }, { x: 12.5, y: 64.5 }) or tri({ x: 35.5, y: 54.0 }, { x: 35.5, y: 62.0 }, { x: 31.5, y: 64.5 })
}

cross = |p, a, b| (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)

# ---------- dynamic raster ----------

## Paint pixels within `radius` (world units) of segment a-b (a capsule).
paint_capsule : List(U32), Render.Layout, { x : F64, y : F64 }, { x : F64, y : F64 }, F64, U32 -> List(U32)
paint_capsule = |buf, lay, a, b, radius, color| {
	r = if radius * lay.s < 0.55 0.55 / lay.s else radius
	x0b = floor_u64((if a.x < b.x a.x else b.x) * lay.s - r * lay.s)
	x1 = floor_u64((if a.x > b.x a.x else b.x) * lay.s + r * lay.s + 1.0)
	y0 = floor_u64((if a.y < b.y a.y else b.y) * lay.s - r * lay.s)
	y1 = floor_u64((if a.y > b.y a.y else b.y) * lay.s + r * lay.s + 1.0)
	var $buf = buf
	var $py = y0
	while $py <= y1 and $py < lay.ph {
		var $px = x0b
		while $px <= x1 and $px < lay.pw {
			p = world_of(lay, $px, $py)
			if Physics.length(Physics.sub(p, Physics.closest_on_segment(p, a, b))) <= r {
				$buf = $buf.set($py * lay.pw + $px, color) ?? $buf
			}
			$px = $px + 1
		}
		$py = $py + 1
	}
	$buf
}

paint_disc : List(U32), Render.Layout, { x : F64, y : F64 }, F64, U32 -> List(U32)
paint_disc = |buf, lay, c, r, color| paint_capsule(buf, lay, c, c, r, color)

dynamic_pixels : Game.State, Render.Layout, List(U32) -> List(U32)
dynamic_pixels = |g, lay, base| {
	t = g.time
	var $buf = base
	# Bumper flashes.
	var $i = 0
	for b in Table.bumpers {
		until = g.bumper_flash.get($i) ?? 0.0
		if until > t {
			$buf = paint_disc($buf, lay, b.pos, b.r + 0.6, px_of(kind_bumper, 0xFFFFFF))
		}
		$i = $i + 1
	}
	# Slingshot flashes.
	var $si = 0
	for sl in Table.slings {
		until = g.sling_flash.get($si) ?? 0.0
		if until > t {
			$buf = paint_capsule($buf, lay, sl.a, sl.b, 0.8, px_of(kind_sling, 0xF4FFD0))
		}
		$si = $si + 1
	}
	# Rollover lane lights.
	var $li = 0
	for lane in Table.lanes {
		lit = g.lanes_lit.get($li) ?? Bool.False
		skill = g.skill_live and g.skill_lane == $li and blink(t, 4.0)
		color = if lit px_of(kind_light_on, 0x00FF9C) else if skill px_of(kind_light_on, 0xFFFFFF) else px_of(kind_light_off, 0x24304A)
		$buf = paint_disc($buf, lay, { x: lane.x, y: lane.y + 3.5 }, 0.9, color)
		$li = $li + 1
	}
	# Stand-up targets.
	var $ti = 0
	for target in Table.standups {
		lit = g.targets_lit.get($ti) ?? Bool.False
		flash = (g.target_flash.get($ti) ?? -10.0) > t - 0.2
		color = if flash px_of(kind_light_on, 0xFFFFFF) else if lit px_of(kind_light_on, 0xFF5EF0) else px_of(kind_light_off, 0x5A2050)
		$buf = paint_capsule($buf, lay, target.a, target.b, 0.55, color)
		$ti = $ti + 1
	}
	# Saucer: pulses when lit or holding a ball.
	saucer_color =
		if !g.saucer_hold.is_empty() {
			px_of(kind_saucer, if blink(t, 8.0) 0xFFFFFF else 0xFFEA00)
		} else if g.lock_lit or g.multiball {
			px_of(kind_saucer, if blink(t, 3.0) 0xFFEA00 else 0x6A5A00)
		} else {
			px_of(kind_saucer, 0x3A2A5A)
		}
	$buf = paint_disc($buf, lay, Table.saucer, Table.saucer_radius, saucer_color)
	# Plunger spring in the lane: compresses with pull.
	spring_top = Table.plunger_top + 0.6 + 3.0 * g.pull
	$buf = paint_capsule($buf, lay, { x: 45.0, y: spring_top }, { x: 45.0, y: 79.0 }, 0.7, px_of(kind_plunger, mix(0xFF6A00, 0xFF2020, g.pull)))
	# Ball trails.
	for b in g.balls {
		back = Physics.sub(b.pos, Physics.scale(b.vel, 0.018))
		if Physics.length(b.vel) > 35.0 {
			$buf = paint_capsule($buf, lay, back, b.pos, 0.5, px_of(kind_trail, 0x4250C8))
		}
	}
	# Flippers.
	flip_color = if g.tilted px_of(kind_flipper, 0x5A4A20) else px_of(kind_flipper, 0xFFB000)
	lt = Game.flipper_tip(Table.left_pivot, g.left.angle)
	rt = Game.flipper_tip(Table.right_pivot, g.right.angle)
	$buf = paint_capsule($buf, lay, Table.left_pivot, lt, Table.flipper_thickness, flip_color)
	$buf = paint_capsule($buf, lay, Table.right_pivot, rt, Table.flipper_thickness, flip_color)
	$buf
}

blink : F64, F64 -> Bool
blink = |t, hz| {
	phase = floor_u64(t * hz * 2.0)
	((phase) % 2 == 0)
}

# ---------- cells ----------

set_cell : List(Render.Cell), U64, U64, U64, Render.Cell -> List(Render.Cell)
set_cell = |cells, cols, x, y, cell| if x < cols cells.set(y * cols + x, cell) ?? cells else cells

ascii_for : U32 -> U32
ascii_for = |k| {
	if k == kind_wall {
		'#'
	} else if k == kind_bumper {
		'O'
	} else if k == kind_sling {
		'%'
	} else if k == kind_flipper {
		'='
	} else if k == kind_light_on {
		'*'
	} else if k == kind_light_off {
		'.'
	} else if k == kind_trail {
		' '
	} else if k == kind_plunger {
		'|'
	} else if k == kind_saucer {
		'o'
	} else {
		' '
	}
}

## Draw-order priority so ASCII mode shows the most important half-pixel.
ascii_rank : U32 -> U64
ascii_rank = |k| {
	if k == kind_flipper {
		6
	} else if k == kind_light_on {
		5
	} else if k == kind_bumper {
		4
	} else if k == kind_saucer {
		3
	} else if k == kind_bg or k == kind_trail {
		0
	} else {
		2
	}
}

is_ink : U32 -> Bool
is_ink = |p| {
	k = kind_of(p)
	k != kind_bg and k != kind_trail
}

blit_table : List(Render.Cell), Render.Layout, List(U32), Render.Opts -> List(Render.Cell)
blit_table = |cells, lay, pixels, opts| {
	var $cells = cells
	var $cy = 0
	while $cy < lay.th {
		var $cx = 0
		while $cx < lay.tw {
			top = pixels.get(2 * $cy * lay.pw + $cx) ?? 0
			bot = pixels.get((2 * $cy + 1) * lay.pw + $cx) ?? 0
			cell =
				if opts.ascii {
					kt = kind_of(top)
					kb = kind_of(bot)
					k = if ascii_rank(kt) >= ascii_rank(kb) kt else kb
					{ cp: ascii_for(k), fg: default_color, bg: default_color }
				} else if opts.color == Render.color_mono {
					cp =
						if is_ink(top) and is_ink(bot) {
							0x2588
						} else if is_ink(top) {
							0x2580
						} else if is_ink(bot) {
							0x2584
						} else {
							' '
						}
					{ cp, fg: default_color, bg: default_color }
				} else if rgb_of(top) == rgb_of(bot) {
					{ cp: ' ', fg: rgb_of(bot), bg: rgb_of(bot) }
				} else {
					{ cp: 0x2580, fg: rgb_of(top), bg: rgb_of(bot) }
				}
			$cells = set_cell($cells, lay.cols, lay.ox + $cx, lay.oy + $cy, cell)
			$cx = $cx + 1
		}
		$cy = $cy + 1
	}
	$cells
}

## Cell coordinates of a world point, if on screen.
cell_of : Render.Layout, { x : F64, y : F64 } -> Try((U64, U64), [Off])
cell_of = |lay, p| {
	if p.x < 0.0 or p.y < 0.0 {
		Err(Off)
	} else {
		cx = floor_u64(p.x * lay.s)
		cy = floor_u64(p.y * lay.s / 2.0)
		if cx < lay.tw and cy < lay.th Ok((lay.ox + cx, lay.oy + cy)) else Err(Off)
	}
}

bg_at : List(Render.Cell), U64, U64, U64 -> U32
bg_at = |cells, cols, x, y| (cells.get(y * cols + x) ?? { cp: ' ', fg: 0, bg: panel_bg }).bg

overlay_table : List(Render.Cell), Game.State, Render.Layout, Render.Opts -> List(Render.Cell)
overlay_table = |cells, g, lay, opts| {
	var $cells = cells
	# Lane letters P I N and target letters T E R M.
	letters = ['P', 'I', 'N']
	var $li = 0
	for lane in Table.lanes {
		lit = g.lanes_lit.get($li) ?? Bool.False
		match cell_of(lay, { x: lane.x, y: lane.y - 1.0 }) {
			Ok((x, y)) => {
				fg = if lit 0x00FF9C.U32 else 0x3E5A7A.U32
				$cells = set_cell($cells, lay.cols, x, y, { cp: letters.get($li) ?? '?', fg: fg.bitwise_or(bold_flag), bg: bg_at($cells, lay.cols, x, y) })
			}
			Err(_) => {}
		}
		$li = $li + 1
	}
	term = ['T', 'E', 'R', 'M']
	var $ti = 0
	for target in Table.standups {
		lit = g.targets_lit.get($ti) ?? Bool.False
		mid = { x: (target.a.x + target.b.x) / 2.0 + (if target.a.x < 20.0 2.2 else -2.2), y: (target.a.y + target.b.y) / 2.0 }
		match cell_of(lay, mid) {
			Ok((x, y)) => {
				fg = if lit 0xFF5EF0.U32 else 0x6A3A66.U32
				$cells = set_cell($cells, lay.cols, x, y, { cp: term.get($ti) ?? '?', fg: fg.bitwise_or(bold_flag), bg: bg_at($cells, lay.cols, x, y) })
			}
			Err(_) => {}
		}
		$ti = $ti + 1
	}
	# Floating score popups.
	for p in g.popups {
		if p.until > g.time {
			match cell_of(lay, { x: p.pos.x - 2.0, y: p.pos.y - 3.0 - 6.0 * (0.9 - (p.until - g.time)) }) {
				Ok((x, y)) => {
					fade = Physics.clamp((p.until - g.time) / 0.9, 0.0, 1.0)
					$cells = put_text($cells, lay.cols, x, y, p.text, mix(0x806020, 0xFFF06A, fade).bitwise_or(bold_flag), bg_at($cells, lay.cols, x, y))
				}
				Err(_) => {}
			}
		}
	}
	# Balls on top of everything, including the one waiting on the plunger.
	plunger_ball = if g.on_plunger and g.mode == Playing [{ x: Table.plunger_rest.x, y: Table.plunger_rest.y + 3.0 * g.pull }] else []
	positions = List.concat(List.concat(g.balls.map(|b| b.pos), g.saucer_hold.map(|b| b.pos)), plunger_ball)
	for pos in positions {
		match cell_of(lay, pos) {
			Ok((x, y)) => {
				cp = if opts.ascii '@' else 0x25CF
				$cells = set_cell($cells, lay.cols, x, y, { cp, fg: ink_ball.bitwise_or(bold_flag), bg: bg_at($cells, lay.cols, x, y) })
			}
			Err(_) => {}
		}
	}
	# Centre banner for attract / game over / pause / big messages.
	banner =
		if g.mode == Attract {
			["P I N T E R M", "", "SPACE to launch", "h for help"]
		} else if g.mode == GameOver {
			["GAME OVER", "SCORE ${Render.commas(g.score)}", "", if g.time >= g.mode_until "SPACE / n: new game" else ""]
		} else if g.paused {
			["PAUSED", "p to resume"]
		} else if g.mode == BallOver {
			[g.message]
		} else {
			[]
		}
	center_x = lay.ox + lay.tw / 2
	center_y = lay.oy + lay.th * 2 / 5
	var $row = 0
	for line in banner {
		width = Str.count_utf8_bytes(line)
		x = if center_x > width / 2 center_x - width / 2 else 0
		fg = if $row == 0 (if blink(g.time, 1.5) 0xFF4FD8.U32 else 0x00E5FF.U32) else 0xFFF2A8.U32
		$cells = put_text($cells, lay.cols, x, center_y + $row, line, fg.bitwise_or(bold_flag), 0x100820)
		$row = $row + 1
	}
	$cells
}

## ASCII text into cells (non-ASCII bytes are decoded as UTF-8 code points).
put_text : List(Render.Cell), U64, U64, U64, Str, U32, U32 -> List(Render.Cell)
put_text = |cells, cols, x, y, text, fg, bg| {
	var $cells = cells
	var $x = x
	for cp in codepoints(text) {
		$cells = set_cell($cells, cols, $x, y, { cp, fg, bg })
		$x = $x + 1
	}
	$cells
}

## Minimal UTF-8 decoder (input comes from our own literals, so it is valid).
codepoints : Str -> List(U32)
codepoints = |text| {
	bytes = Str.to_utf8(text)
	var $out = []
	var $i = 0
	n = bytes.len()
	while $i < n {
		b0 = (bytes.get($i) ?? 0).to_u32()
		if b0 < 0x80 {
			$out = $out.append(b0)
			$i = $i + 1
		} else if b0 < 0xE0 {
			b1 = (bytes.get($i + 1) ?? 0).to_u32()
			$out = $out.append(b0.bitwise_and(0x1F).shl_wrap(6).bitwise_or(b1.bitwise_and(0x3F)))
			$i = $i + 2
		} else if b0 < 0xF0 {
			b1 = (bytes.get($i + 1) ?? 0).to_u32()
			b2 = (bytes.get($i + 2) ?? 0).to_u32()
			$out = $out.append(b0.bitwise_and(0x0F).shl_wrap(12).bitwise_or(b1.bitwise_and(0x3F).shl_wrap(6)).bitwise_or(b2.bitwise_and(0x3F)))
			$i = $i + 3
		} else {
			b1 = (bytes.get($i + 1) ?? 0).to_u32()
			b2 = (bytes.get($i + 2) ?? 0).to_u32()
			b3 = (bytes.get($i + 3) ?? 0).to_u32()
			$out = $out.append(b0.bitwise_and(0x07).shl_wrap(18).bitwise_or(b1.bitwise_and(0x3F).shl_wrap(12)).bitwise_or(b2.bitwise_and(0x3F).shl_wrap(6)).bitwise_or(b3.bitwise_and(0x3F)))
			$i = $i + 4
		}
	}
	$out
}

utf8_append : List(U8), U32 -> List(U8)
utf8_append = |out, cp| {
	if cp < 0x80 {
		out.append(cp.to_u8_wrap())
	} else if cp < 0x800 {
		out.append((0xC0.U32).bitwise_or(cp.shr_zf_wrap(6)).to_u8_wrap()).append((0x80.U32).bitwise_or(cp.bitwise_and(0x3F.U32)).to_u8_wrap())
	} else if cp < 0x10000 {
		out
			.append((0xE0.U32).bitwise_or(cp.shr_zf_wrap(12)).to_u8_wrap())
			.append((0x80.U32).bitwise_or(cp.shr_zf_wrap(6).bitwise_and(0x3F.U32)).to_u8_wrap())
			.append((0x80.U32).bitwise_or(cp.bitwise_and(0x3F.U32)).to_u8_wrap())
	} else {
		out
			.append((0xF0.U32).bitwise_or(cp.shr_zf_wrap(18)).to_u8_wrap())
			.append((0x80.U32).bitwise_or(cp.shr_zf_wrap(12).bitwise_and(0x3F.U32)).to_u8_wrap())
			.append((0x80.U32).bitwise_or(cp.shr_zf_wrap(6).bitwise_and(0x3F.U32)).to_u8_wrap())
			.append((0x80.U32).bitwise_or(cp.bitwise_and(0x3F.U32)).to_u8_wrap())
	}
}

strip_color : Render.Cell -> Render.Cell
strip_color = |c| {
	bold = c.fg.bitwise_and(bold_flag) != 0
	{ ..c, fg: if bold default_color.bitwise_or(bold_flag) else default_color, bg: default_color }
}

# ---------- panel ----------

box_top : U64 -> Str
box_top = |w| Str.concat(Str.concat("╭", Str.repeat("─", w - 2)), "╮")

box_bottom : U64 -> Str
box_bottom = |w| Str.concat(Str.concat("╰", Str.repeat("─", w - 2)), "╯")

lights : List(Bool), List(Str) -> Str
lights = |lit, names| {
	var $s = ""
	var $i = 0
	for name in names {
		on = lit.get($i) ?? Bool.False
		$s = Str.concat($s, if on "[${name}]" else " ${name.with_ascii_lowercased()} ")
		$i = $i + 1
	}
	$s
}

draw_panel : List(Render.Cell), Game.State, Render.Layout, Render.Opts -> List(Render.Cell)
draw_panel = |cells, g, lay, opts| {
	x = lay.px
	w = Render.panel_width - 1
	ascii = opts.ascii
	frame_color = if g.multiball (if blink(g.time, 2.0) 0xFF4FD8 else 0xFFEA00) else 0x4A3A8A
	top = if ascii Str.concat(Str.concat("+", Str.repeat("-", w - 2)), "+") else box_top(w)
	bottom = if ascii Str.concat(Str.concat("+", Str.repeat("-", w - 2)), "+") else box_bottom(w)
	side = if ascii "|" else "│"
	height = if lay.rows > 2 lay.rows else 2
	var $c = put_text(cells, lay.cols, x, 0, top, frame_color, panel_bg)
	var $r = 1
	while $r + 1 < height {
		$c = put_text($c, lay.cols, x, $r, side, frame_color, panel_bg)
		$c = put_text($c, lay.cols, x + w - 1, $r, side, frame_color, panel_bg)
		$r = $r + 1
	}
	$c = put_text($c, lay.cols, x, height - 1, bottom, frame_color, panel_bg)
	tx = x + 2
	logo = ["P", "I", "N", "T", "E", "R", "M"]
	logo_colors = [0xFF2A8A.U32, 0xFF7A2A.U32, 0xFFD23F.U32, 0x9DFF00.U32, 0x00E5FF.U32, 0x5B6CFF.U32, 0xB44DFF.U32]
	var $li = 0
	for ch in logo {
		$c = put_text($c, lay.cols, tx + $li * 2, 1, ch, (logo_colors.get($li) ?? 0xFFFFFF).bitwise_or(bold_flag), panel_bg)
		$li = $li + 1
	}
	score_color = ink_score.bitwise_or(bold_flag)
	save = Game.save_left(g)
	save_text = if save > 0.0 and g.mode == Playing (if blink(g.time, 2.0) "SAVE" else "    ") else ""
	ball_text = if g.mode == Attract "BALL -" else "BALL ${g.ball_number.to_str()}/${Game.balls_per_game.to_str()}"
	combo_text = if g.combo >= 2 and g.time < g.combo_until "COMBO x${g.combo.to_str()}" else ""
	sound_text = if opts.sound "sound on (m)" else "sound off (m)"
	message = if g.time < g.message_until g.message else ""
	rows = [
		(3, "SCORE", ink_dim),
		(4, Render.commas(g.score), score_color),
		(6, "${ball_text}   X${g.mult.to_str()}", ink_text),
		(7, "HIGH ${Render.commas(g.high)}", ink_dim),
		(9, "LANES ${lights(g.lanes_lit, ["P", "I", "N"])}", 0x00FF9C),
		(10, "TERM ${lights(g.targets_lit, ["T", "E", "R", "M"])}", 0xFF5EF0),
		(11, if g.lock_lit "SAUCER LIT" else if g.multiball "MULTIBALL  JP ${Render.commas(g.jackpot)}" else "", 0xFFEA00),
		(13, combo_text, 0xFF7A2A),
		(14, save_text, 0x00E5FF),
		(15, if g.tilted "TILT" else if g.tilt >= 1.9 "DANGER" else "", ink_warn),
		(16, message, 0xFF4FD8),
	]
	for (row, text, color) in rows {
		if row + 1 < height {
			$c = put_text($c, lay.cols, tx, row, truncate(text, w - 3), color, panel_bg)
		}
	}
	help_rows = [
		"z / <-    left flip",
		"/ / ->    right flip",
		"space     plunger",
		"t / up    nudge",
		"p pause h help q quit",
		sound_text,
	]
	start_row = if height > 25 height - 8 else 18
	var $hi = 0
	for line in help_rows {
		row = start_row + $hi
		if row + 1 < height {
			$c = put_text($c, lay.cols, tx, row, truncate(line, w - 3), ink_dim, panel_bg)
		}
		$hi = $hi + 1
	}
	$c
}

truncate : Str, U64 -> Str
truncate = |s, n| {
	bytes = Str.to_utf8(s)
	if bytes.len() <= n s else Str.from_utf8_lossy(bytes.take_first(n))
}

## Narrow terminals: a two-line heads-up display above the table.
draw_hud : List(Render.Cell), Game.State, Render.Layout, Render.Opts -> List(Render.Cell)
draw_hud = |cells, g, lay, _opts| {
	line1 = "${Render.commas(g.score)}  B${g.ball_number.to_str()}/${Game.balls_per_game.to_str()} X${g.mult.to_str()}"
	message = if g.time < g.message_until g.message else if g.combo >= 2 and g.time < g.combo_until "COMBO x${g.combo.to_str()}" else ""
	c1 = put_text(cells, lay.cols, 0, 0, truncate(line1, lay.cols), ink_score.bitwise_or(bold_flag), panel_bg)
	put_text(c1, lay.cols, 0, 1, truncate(message, lay.cols), 0xFF4FD8, panel_bg)
}

draw_help : List(Render.Cell), Render.Layout -> List(Render.Cell)
draw_help = |cells, lay| {
	lines = [
		"  HOW TO PLAY  ",
		"",
		" Space: pull plunger, release",
		"   (tap = full launch)",
		" z or Left:  left flipper",
		" / or Right: right flipper",
		" t or Up: nudge (3 = TILT)",
		"",
		" Light P-I-N lanes: bonus X",
		" Hit T-E-R-M: lights saucer",
		" Lit saucer: MULTIBALL",
		" Saucer in multiball: JACKPOT",
		" Quick hits chain COMBOS",
		"",
		" p pause  m mute  n new game",
		" q quit   h close help",
	]
	width = 32
	x0 = if lay.cols > width (lay.cols - width) / 2 else 0
	y0 = if lay.rows > lines.len() + 2 (lay.rows - lines.len() - 2) / 2 else 0
	var $c = cells
	var $i = 0
	for line in lines {
		padded = Str.concat(line, Str.repeat(" ", if width > Str.count_utf8_bytes(line) width - Str.count_utf8_bytes(line) else 0))
		color = if $i == 0 (0xFFEA00.U32).bitwise_or(bold_flag) else ink_text
		$c = put_text($c, lay.cols, x0, y0 + $i, padded, color, 0x1A1238)
		$i = $i + 1
	}
	$c
}

commas_impl : I64 -> Str
commas_impl = |n| {
	if n < 0 {
		Str.concat("-", commas_impl(-n))
	} else if n < 1000 {
		n.to_str()
	} else {
		rest = n % 1000
		pad = if rest < 10 "00" else if rest < 100 "0" else ""
		"${commas_impl(n // 1000)},${pad}${rest.to_str()}"
	}
}

# ---------- ANSI color encoding ----------

sgr : U32, U32, U8 -> List(U8)
sgr = |fg, bg, mode| {
	bold = fg.bitwise_and(bold_flag) != 0
	fg_rgb = fg.bitwise_and(0xFFFFFF)
	bold_part = if bold "1;" else ""
	if mode == Render.color_mono {
		Str.to_utf8("\u(1b)[0;${bold_part}m")
	} else {
		fg_part = if fg.bitwise_and(default_color) != 0 "39" else color_code(fg_rgb, mode, Bool.True)
		bg_part = if bg.bitwise_and(default_color) != 0 "49" else color_code(bg.bitwise_and(0xFFFFFF), mode, Bool.False)
		Str.to_utf8("\u(1b)[0;${bold_part}${fg_part};${bg_part}m")
	}
}

color_code : U32, U8, Bool -> Str
color_code = |rgb, mode, is_fg| {
	r = rgb.shr_zf_wrap(16).bitwise_and(0xFF)
	g = rgb.shr_zf_wrap(8).bitwise_and(0xFF)
	b = rgb.bitwise_and(0xFF)
	if mode == Render.color_true {
		lead = if is_fg "38;2;" else "48;2;"
		"${lead}${r.to_str()};${g.to_str()};${b.to_str()}"
	} else if mode == Render.color_256 {
		lead = if is_fg "38;5;" else "48;5;"
		"${lead}${xterm256(r, g, b).to_str()}"
	} else {
		idx = ansi16(r, g, b)
		base = if is_fg (if idx >= 8 90 else 30) else (if idx >= 8 100 else 40)
		(base + idx % 8).to_str()
	}
}

## Nearest xterm-256 color: 6x6x6 cube or the 24-step gray ramp.
xterm256 : U32, U32, U32 -> U32
xterm256 = |r, g, b| {
	q = |v| if v < 48 0 else if v < 115 1 else (v - 35) / 40
	cube = 16 + 36 * q(r) + 6 * q(g) + q(b)
	if r == g and g == b {
		if r < 8 16 else if r > 248 231 else 232 + (r - 8) / 10
	} else {
		cube
	}
}

## Nearest of the 16 ANSI colors by thresholding each channel.
ansi16 : U32, U32, U32 -> U32
ansi16 = |r, g, b| {
	mx = if r > g (if r > b r else b) else (if g > b g else b)
	bright = if mx > 170 8 else 0
	cut = mx / 2
	bit = |v, w| if v > cut and v > 40 w else 0
	code = bit(r, 1) + bit(g, 2) + bit(b, 4)
	if mx < 40 0 else code + bright
}
