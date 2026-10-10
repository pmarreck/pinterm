import Render
import Game
import Table
import TestKit

main! = |_args| Ok({})

started = TestKit.started

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
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay, started.table), [])
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
	joined.contains("SCORE") and joined.contains("BALL 1/3") and joined.contains("🯩🯫")
}

# ASCII mode output is pure 7-bit ASCII and still shows the ball on the plunger.
expect {
	lay = Render.layout(100, 40)
	opts = { ..color_opts, ascii: Bool.True, color: 3 }
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay, started.table), [])
	bytes = Render.encode([], cells, 100, 3)
	bytes.all(|b| b < 128) and cells.any(|c| c.cp == '(') and cells.any(|c| c.cp == ')')
}

# Monochrome mode never emits color escape codes.
expect {
	lay = Render.layout(100, 40)
	opts = { ..color_opts, color: 3 }
	cells = Render.compose(started, opts, lay, Render.static_pixels(lay, started.table), [])
	text = Str.from_utf8_lossy(Render.encode([], cells, 100, 3))
	!text.contains("38;2;") and !text.contains("48;5;") and !text.contains(";4")
}

# Diff encoding: an unchanged frame emits only the sync wrapper; one changed cell is small.
expect {
	lay = Render.layout(100, 40)
	cells = Render.compose(started, color_opts, lay, Render.static_pixels(lay, started.table), [])
	same = Render.encode(cells, cells, 100, 0)
	changed = cells.set(5, { cp: 'X', fg: 0xFFFFFF, bg: 0 }) ?? cells
	one = Render.encode(cells, changed, 100, 0)
	same.len() < 40 and one.len() < 80 and Str.from_utf8_lossy(one).contains("X")
}

# Tiny terminals get a readable request to enlarge instead of a broken table.
expect {
	lay = Render.layout(30, 10)
	cells = Render.compose(started, color_opts, lay, [], [])
	Render.row_text(cells, 30, 0).contains("Enlarge")
}

# Full redraws position the cursor at every row start (autowrap is disabled by the host).
expect {
	lay = Render.layout(60, 20)
	cells = Render.compose(started, color_opts, lay, Render.static_pixels(lay, started.table), [])
	text = Str.from_utf8_lossy(Render.encode([], cells, 60, 0))
	text.contains("\u(1b)[2;1H") and text.contains("\u(1b)[20;1H")
}

# On wide terminals the table and panel are centered together, not split apart.
expect {
	lay = Render.layout(220, 60)
	gap = lay.px - (lay.ox + lay.tw)
	gap <= 3 and lay.ox > 10
}

# Table switch slide: a pure wipe between two rasters. Progress 0 is the old
# table, 1 the new one; mid-way the old table's columns are shifted by the
# eased offset (smoothstep(0.5) = 0.5) in the swipe direction.
expect {
	lay = Render.layout(80, 24)
	old = Render.static_pixels(lay, Table.at(0))
	new = Render.static_pixels(lay, Table.at(1))
	half = lay.pw // 2
	left = Render.slide(old, new, lay, 0.5, 1)
	right = Render.slide(old, new, lay, 0.5, -1)
	row = lay.pw * (lay.ph // 2)
	ends = Render.slide(old, new, lay, 0.0, 1) == old and Render.slide(old, new, lay, 1.0, 1) == new and Render.slide(old, new, lay, 0.0, -1) == old
	shifted = left.get(row) == old.get(row + half) and left.get(row + lay.pw - half) == new.get(row) and right.get(row + half) == old.get(row) and right.get(row) == new.get(row + lay.pw - half)
	ends and shifted and left != old and left != new and left.len() == old.len()
}

# Mid-slide the screen differs from the plain new table and the layout's
# letters stay hidden; once finished the old raster is no longer consulted.
expect {
	lay = Render.layout(80, 24)
	g0 = TestKit.press(Game.new(42), NextTable)
	old = Render.static_pixels(lay, Table.at(0))
	new = Render.static_pixels(lay, Table.at(1))
	view = |g, from| Render.compose(g, color_opts, lay, new, from)
	mid = TestKit.run_frames(g0, 13)
	done = TestKit.run_frames(g0, 40)
	in_table = |i| i % lay.cols >= lay.ox and i % lay.cols < lay.ox + lay.tw and i // lay.cols >= lay.oy and i // lay.cols < lay.oy + lay.th
	letters = |cells| (Table.at(1)).lane_names.all(|name| cells.map_with_index(|c, i| in_table(i) and c.cp == (name.to_utf8().first() ?? 0).to_u32()).any(|hit| hit))
	view(mid, old) != view(mid, []) and !letters(view(mid, old)) and letters(view(done, old)) and view(done, old) == view(done, [])
}

# The help overlay explains the current table's own rules and the table keys.
help_text : Game.State -> Str
help_text = |g| {
	lay = Render.layout(100, 40)
	cells = Render.compose(g, { ..color_opts, help: Bool.True }, lay, Render.static_pixels(lay, g.table), [])
	var $s = ""
	var $r = 0
	while $r < 40 {
		$s = Str.concat($s, Render.row_text(cells, 100, $r))
		$r = $r + 1
	}
	$s
}

expect {
	classic = help_text(Game.new(42))
	orbital = help_text(Game.new_on(42, 1))
	iron = help_text(Game.new_on(42, 2))
	grave = help_text(Game.new_on(42, 3))
	classic.contains("P-I-N lanes") and classic.contains("T-E-R-M") and classic.contains("[ ] new table")
		and orbital.contains("W-A-R-P lanes") and orbital.contains("I-G-N-I-T-E") and !orbital.contains("T-E-R-M")
			and iron.contains("C-O-A-L") and iron.contains("4 cars")
				and grave.contains("R-I-P") and grave.contains("B-O-O lanes")
}

# ---------- table toys are drawn where the physics puts them ----------

bare : Table.Layout
bare = { ..started.table, bumpers: [], slings: [], lanes: [], lane_names: [], standups: [], standup_names: [], saucers: [], ramps: [] }

toy_lay : Render.Layout
toy_lay = Render.layout(100, 40)

# The playfield pixel at world point p for state g.
pix : Game.State, { x : F64, y : F64 } -> U32
pix = |g, p| Render.pixel_at(toy_lay, Render.playfield(g, toy_lay, Render.static_pixels(toy_lay, g.table)), p)

spot : { x : F64, y : F64 }
spot = { x: 22.0, y: 50.0 }

# Each toy changes the pixel at its own position.
expect {
	plain = pix({ ..started, table: bare }, spot)
	shows = |table| pix({ ..started, table }, spot) != plain
	shows({ ..bare, kickbacks: [spot] })
		and shows({ ..bare, magnets: [spot] })
			and shows({ ..bare, portals: [{ a: spot, b: { x: 30.0, y: 20.0 } }] })
				and shows({ ..bare, spinners: [{ a: { x: 20.0, y: 50.0 }, b: { x: 24.0, y: 50.0 } }] })
					and shows({ ..bare, rotors: [{ center: spot, length: 4.0, speed: 0.0 }] })
						and shows({ ..bare, ghosts: [{ pos: spot, r: 2.4, period: 2.0, solid: 1.0 }] })
}

# A mover is drawn at its current centre, not where it started.
expect {
	m = { a: { x: 10.0, y: 50.0 }, b: { x: 34.0, y: 50.0 }, half: 2.0, period: 4.0 }
	g = { ..started, table: { ..bare, movers: [m] }, time: 2.0 }
	empty = { ..started, table: bare, time: 2.0 }
	pix(g, m.b) != pix(empty, m.b) and pix(g, m.a) == pix(empty, m.a)
}

# A ghost bumper looks different solid and faded; a lit kickback differs from an unlit one.
expect {
	gh = { pos: spot, r: 2.4, period: 2.0, solid: 1.0 }
	g = { ..started, table: { ..bare, ghosts: [gh] } }
	k = { ..started, table: { ..bare, kickbacks: [spot] } }
	pix({ ..g, time: 0.5 }, spot) != pix({ ..g, time: 1.5 }, spot) and pix({ ..k, kickback_lit: Bool.True }, spot) != pix({ ..k, kickback_lit: Bool.False }, spot)
}

# ---------- per-table background art ----------

# Art changes a real share of the background, never a gameplay pixel, and
# each alternate table's art is its own (Classic keeps the plain grid).
expect {
	lay = Render.layout(100, 40)
	kind = |p| p.shr_zf_wrap(24)
	check = |i| {
		table = Table.at(i)
		with_art = Render.static_pixels(lay, table)
		plain = Render.static_pixels(lay, { ..table, art: Grid })
		pairs = List.map2(with_art, plain, |a, b| (a, b))
		changed = pairs.count_if(|(a, b)| a != b)
		gameplay_same = pairs.all(|(a, b)| kind(b) != 0 or kind(a) == 0)
		gameplay_kept = pairs.all(|(a, b)| kind(b) == 0 or a == b)
		changed * 50 > with_art.len() and gameplay_same and gameplay_kept
	}
	(Table.at(0)).art == Grid and check(1) and check(2) and check(3) and check(4)
}

# The help overlay also names each table's toys.
expect {
	orbital = help_text(Game.new_on(42, 1))
	iron = help_text(Game.new_on(42, 2))
	grave = help_text(Game.new_on(42, 3))
	clock = help_text(Game.new_on(42, 4))
	orbital.contains("Wormhole") and orbital.contains("Spinner")
		and iron.contains("Train") and iron.contains("Kickback") and iron.contains("4 cars")
			and grave.contains("Magnet") and grave.contains("Ghost")
				and clock.contains("Rotor") and clock.contains("G-E-A-R") and clock.contains("T-O-C-K")
}

# ---------- the ball ----------

# The ball glyph cells (table column, code point) for a lone ball at world x.
ball_cells : U64, U64, Render.Opts, F64 -> List((U64, U32))
ball_cells = |cols, rows, opts, x| {
	lay = Render.layout(cols, rows)
	g = TestKit.in_play(started, x, 50.0, 0.0, 0.0)
	cells = Render.compose(g, opts, lay, Render.static_pixels(lay, g.table), [])
	glyphs = [0x25CF, 0x1FBE9, 0x1FBEB, '@', '(', ')']
	cells.map_with_index(|c, i| (i, c.cp)).keep_if(|(i, cp)| i % cols >= lay.ox and i % cols < lay.ox + lay.tw and glyphs.contains(cp)).map(|(i, cp)| (i % cols - lay.ox, cp))
}

# When the ball spans about two columns it is drawn as two half circles
# centred on it; when it would cover about one column it stays a single dot.
expect {
	big = ball_cells(100, 40, color_opts, 22.25)
	big_shifted = ball_cells(100, 40, color_opts, 22.75)
	small = ball_cells(80, 24, color_opts, 22.25)
	big == [(21, 0x1FBE9), (22, 0x1FBEB)] and big_shifted == [(22, 0x1FBE9), (23, 0x1FBEB)] and small.len() == 1 and small.map(|(_, cp)| cp) == [0x25CF]
}

# ASCII mode draws the big ball as "()" and the small one as "@".
expect ball_cells(100, 40, { ..color_opts, ascii: Bool.True, color: 3 }, 22.25) == [(21, '('), (22, ')')] and ball_cells(80, 24, { ..color_opts, ascii: Bool.True, color: 3 }, 22.25).map(|(_, cp)| cp) == ['@']
