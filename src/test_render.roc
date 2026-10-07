import Render
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

# Full redraws position the cursor at every row start (autowrap is disabled by the host).
expect {
	lay = Render.layout(60, 20)
	cells = Render.compose(started, color_opts, lay, Render.static_pixels(lay))
	text = Str.from_utf8_lossy(Render.encode([], cells, 60, 0))
	text.contains("\u(1b)[2;1H") and text.contains("\u(1b)[20;1H")
}
