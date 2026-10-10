// Procedural cell glyphs. ghostty-web draws every cell with fillText, so a
// glyph's look depends on the device's fonts: iOS has no font with the
// Unicode 16 ball halves (they show as empty boxes), and font block glyphs
// rarely fill a cell exactly (thin seams between pixel rows). The few glyphs
// the game's playfield is built from are drawn here as canvas shapes instead,
// with edges snapped to device pixels so neighboring cells tile exactly.

const UPPER_HALF = 0x2580, LOWER_HALF = 0x2584, FULL_BLOCK = 0x2588;
const BALL_DOT = 0x25cf, BALL_LEFT = 0x1fbe9, BALL_RIGHT = 0x1fbeb;
export const GLYPHS = [UPPER_HALF, LOWER_HALF, FULL_BLOCK, BALL_DOT, BALL_LEFT, BALL_RIGHT];

// Ball radius as a share of the cell height; the two-cell ball is capped at
// the cell width so it stays inside its pair of cells.
const BALL_RADIUS = 0.45;
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
	// Ball shapes: an ellipse clipped to this cell. The halves share one
	// ellipse centered on the edge between their cells.
	const cy = (row + 0.5) * h;
	let cx, rx, ry;
	if (cp === BALL_DOT) {
		cx = (col + 0.5) * w;
		rx = ry = DOT_RADIUS * Math.min(w, h);
	} else {
		cx = cp === BALL_LEFT ? right : left;
		ry = BALL_RADIUS * h;
		rx = Math.min(ry, 0.95 * w);
	}
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
