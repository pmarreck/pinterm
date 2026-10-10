// Unit tests for the procedural cell glyphs (pure: drawing goes to a
// recording fake canvas context).
import { test } from "node:test";
import assert from "node:assert/strict";
import { drawCellGlyph, GLYPHS, snapRect } from "../../web/site/glyphs.js";

// A fake 2D context that records rectangles filled directly and the paths
// (arcs and clip rectangles) used for filled shapes.
function recorder() {
	const ops = [];
	let path = [];
	return {
		ops,
		fillRect: (x, y, w, h) => ops.push({ op: "rect", x, y, w, h }),
		save: () => ops.push({ op: "save" }),
		restore: () => ops.push({ op: "restore" }),
		beginPath: () => { path = []; },
		rect: (x, y, w, h) => path.push({ rect: [x, y, w, h] }),
		arc: (x, y, r) => path.push({ arc: [x, y, r] }),
		ellipse: (x, y, rx, ry) => path.push({ ellipse: [x, y, rx, ry] }),
		clip: () => ops.push({ op: "clip", path }),
		fill: () => ops.push({ op: "fill", path }),
	};
}

const metricsSets = [
	{ width: 9, height: 15 },
	{ width: 9.03, height: 15.6 },
	{ width: 6.2, height: 12.2 },
];
const dprs = [1, 2, 3];
const BLOCKS = { upper: 0x2580, lower: 0x2584, full: 0x2588 };

const rectOf = (cp, col, row, m, dpr) => {
	const ctx = recorder();
	assert.equal(drawCellGlyph(ctx, cp, col, row, m, dpr), true);
	const rects = ctx.ops.filter((o) => o.op === "rect");
	assert.equal(rects.length, 1);
	const { x, y, w, h } = rects[0];
	return { left: x, top: y, right: x + w, bottom: y + h };
};

test("only the handled code points are drawn; everything else is left to the font", () => {
	const handled = new Set([0x2580, 0x2584, 0x2588, 0x25cf, 0x1fbe9, 0x1fbeb]);
	assert.deepEqual(new Set(GLYPHS), handled);
	for (let cp = 0x20; cp < 0x3000; cp++) {
		const ctx = recorder();
		const drawn = drawCellGlyph(ctx, cp, 3, 4, metricsSets[0], 2);
		assert.equal(drawn, handled.has(cp), `U+${cp.toString(16)}`);
		if (!drawn) assert.deepEqual(ctx.ops, [], `U+${cp.toString(16)} drew nothing`);
	}
	for (const cp of [0x1fbe8, 0x1fbea, 0x1fbec, 0x1f600]) assert.equal(drawCellGlyph(recorder(), cp, 0, 0, metricsSets[0], 1), false);
});

test("block halves tile their cells exactly, on device pixels, with no seams", () => {
	const near = (a, b) => Math.abs(a - b) < 1e-9;
	for (const m of metricsSets) for (const dpr of dprs) {
		const onDevicePixel = (v) => near(v * dpr, Math.round(v * dpr));
		for (let row = 0; row < 40; row++) for (const col of [0, 1, 7, 55, 99]) {
			const up = rectOf(BLOCKS.upper, col, row, m, dpr);
			const low = rectOf(BLOCKS.lower, col, row, m, dpr);
			const full = rectOf(BLOCKS.full, col, row, m, dpr);
			const below = rectOf(BLOCKS.upper, col, row + 1, m, dpr);
			const right = rectOf(BLOCKS.full, col + 1, row, m, dpr);
			const where = `col ${col} row ${row} ${JSON.stringify(m)} dpr ${dpr}`;
			for (const r of [up, low, full]) for (const v of Object.values(r)) assert.ok(onDevicePixel(v), `${where}: ${v} on a device pixel`);
			assert.ok(near(up.bottom, low.top), `${where}: halves meet`);
			assert.ok(near(up.top, full.top) && near(low.bottom, full.bottom), `${where}: halves span the full block`);
			assert.ok(near(full.bottom, below.top), `${where}: rows meet`);
			assert.ok(near(full.right, right.left), `${where}: columns meet`);
			assert.ok(Math.abs(full.left - col * m.width) <= 0.5 / dpr && Math.abs(full.top - row * m.height) <= 0.5 / dpr, `${where}: block sits on its cell`);
		}
	}
});

// The filled shape for a ball glyph: its circle and the clip that bounds it.
const shapeOf = (cp, col, row, m, dpr) => {
	const ctx = recorder();
	assert.equal(drawCellGlyph(ctx, cp, col, row, m, dpr), true);
	const clip = ctx.ops.find((o) => o.op === "clip");
	const fill = ctx.ops.find((o) => o.op === "fill");
	assert.ok(clip && fill, "clipped fill");
	assert.equal(ctx.ops.filter((o) => o.op === "save").length, ctx.ops.filter((o) => o.op === "restore").length);
	const shape = fill.path.find((p) => p.ellipse);
	return { clip: clip.path[0].rect, ellipse: shape.ellipse };
};

test("the two ball halves are one ellipse centered on their shared edge, each clipped to its own cell", () => {
	for (const m of metricsSets) for (const dpr of dprs) {
		const left = shapeOf(0x1fbe9, 10, 5, m, dpr);
		const right = shapeOf(0x1fbeb, 11, 5, m, dpr);
		assert.deepEqual(left.ellipse, right.ellipse);
		const [cx, cy, rx, ry] = left.ellipse;
		assert.ok(Math.abs(cx - 11 * m.width) <= 0.5 / dpr, "centered on the shared edge");
		assert.ok(Math.abs(cy - 5.5 * m.height) < 1e-9, "centered on the row");
		assert.ok(rx <= m.width && ry <= m.height / 2 && rx > 0.7 * m.width && ry > 0.35 * m.height, "fills most of the two cells");
		assert.ok(Math.abs(rx - ry) < 0.2 * ry, "round, not stretched");
		const [lx, , lw] = left.clip, [rxc, , rw] = right.clip;
		assert.ok(Math.abs(lx + lw - rxc) < 1e-9, "clips meet");
		assert.ok(lx + lw <= cx + 0.5 / dpr && rxc >= cx - 0.5 / dpr && rw > 0 && lw > 0, "each half on its own side");
	}
});

test("the small ball dot is a circle inside its cell", () => {
	for (const m of metricsSets) {
		const { clip, ellipse: [cx, cy, rx, ry] } = shapeOf(0x25cf, 2, 3, m, 2);
		assert.ok(Math.abs(cx - 2.5 * m.width) < 1e-9 && Math.abs(cy - 3.5 * m.height) < 1e-9);
		assert.ok(rx === ry && rx <= m.width / 2 && rx > 0.3 * m.width);
		assert.ok(clip[2] > 0 && clip[3] > 0);
	}
});

test("snapped background rectangles tile a grid of cells with no gaps or overlaps", () => {
	const near = (a, b) => Math.abs(a - b) < 1e-9;
	for (const m of metricsSets) for (const dpr of dprs) {
		for (let row = 0; row < 40; row++) for (let col = 0; col < 100; col += 9) {
			const [x, y, w, h] = snapRect(col * m.width, row * m.height, m.width, m.height, dpr);
			const [x2] = snapRect((col + 1) * m.width, row * m.height, m.width, m.height, dpr);
			const [, y2] = snapRect(col * m.width, (row + 1) * m.height, m.width, m.height, dpr);
			assert.ok(near(x + w, x2) && near(y + h, y2), `${col},${row} dpr ${dpr}`);
			for (const v of [x, y, w, h]) assert.ok(near(v * dpr, Math.round(v * dpr)));
			const full = rectOf(BLOCKS.full, col, row, m, dpr);
			assert.ok(near(full.left, x) && near(full.top, y) && near(full.right, x + w) && near(full.bottom, y + h), "same edges as the glyphs");
		}
	}
});
