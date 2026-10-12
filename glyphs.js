// Procedural cell glyphs. ghostty-web draws every cell with fillText, so a
// glyph's look depends on the device's fonts: iOS has no font with the
// Unicode 16 ball characters (they show as empty boxes), and font block glyphs
// rarely fill a cell exactly (thin seams between pixel rows). The few glyphs
// the game's playfield is built from are drawn here as canvas shapes instead,
// with edges snapped to device pixels so neighboring cells tile exactly.

const UPPER_HALF = 0x2580, LOWER_HALF = 0x2584, FULL_BLOCK = 0x2588;
// The two-cell ball is the octants U+1CDAA/U+1CD6E, a 4x4 block octagon that
// terminals draw without a font; it is drawn here as the same blocks.
const BALL_DOT = 0x25cf, BALL_LEFT = 0x1cdaa, BALL_RIGHT = 0x1cd6e;
export const GLYPHS = [UPPER_HALF, LOWER_HALF, FULL_BLOCK, BALL_DOT, BALL_LEFT, BALL_RIGHT];

// Filled eighths of each octant, top row first, as [left, right] per row
// (U+1CDAA is BLOCK OCTANT-234568, U+1CD6E is BLOCK OCTANT-134567).
const OCTANTS = {
	[BALL_LEFT]: [[0, 1], [1, 1], [1, 1], [0, 1]],
	[BALL_RIGHT]: [[1, 0], [1, 1], [1, 1], [1, 0]],
};
const DOT_RADIUS = 0.42;

/** Draw code point `cp` in cell (col, row) with the context's current fill
 * style. Returns false, drawing nothing, for code points left to the font. */
export function drawCellGlyph(ctx, cp, col, row, metrics, dpr) {
	if (!GLYPHS.includes(cp)) return false;
	const { width: w, height: h } = metrics;
	const snap = (v) => Math.round(v * dpr) / dpr;
	const left = snap(col * w), right = snap((col + 1) * w);
	const top = snap(row * h), bottom = snap((row + 1) * h), mid = snap((row + 0.5) * h);
	switch (cp) {
		case UPPER_HALF: ctx.fillRect(left, top, right - left, mid - top); return true;
		case LOWER_HALF: ctx.fillRect(left, mid, right - left, bottom - mid); return true;
		case FULL_BLOCK: ctx.fillRect(left, top, right - left, bottom - top); return true;
	}
	const octant = OCTANTS[cp];
	if (octant) {
		const xs = [left, snap((col + 0.5) * w), right];
		const ys = [0, 1, 2, 3, 4].map((i) => snap((row + i / 4) * h));
		octant.forEach((cells, r) => cells.forEach((on, c) => {
			if (on) ctx.fillRect(xs[c], ys[r], xs[c + 1] - xs[c], ys[r + 1] - ys[r]);
		}));
		return true;
	}
	// The small ball dot: a circle clipped to its cell.
	const cx = (col + 0.5) * w, cy = (row + 0.5) * h;
	const rx = DOT_RADIUS * Math.min(w, h), ry = rx;
	ctx.save();
	ctx.beginPath();
	ctx.rect(left, top, right - left, bottom - top);
	ctx.clip();
	ctx.beginPath();
	ctx.ellipse(cx, cy, rx, ry, 0, 0, 2 * Math.PI);
	ctx.fill();
	ctx.restore();
	return true;
}

/** Snap a cell rectangle's edges to device pixels, so neighboring cell
 * backgrounds meet exactly instead of blending at fractional edges. */
export function snapRect(x, y, w, h, dpr) {
	const snap = (v) => Math.round(v * dpr) / dpr;
	const left = snap(x), top = snap(y);
	return [left, top, snap(x + w) - left, snap(y + h) - top];
}
