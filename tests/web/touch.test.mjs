// Unit tests for the touch-control state machine (pure, injected clock).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createTouchControls, ZONE, PULL_FULL_FRACTION, PLUNGER_FULL_MS, STROKE_MIN_PX, SWIPE_MIN_PX } from "../../web/site/touch-controls.js";

const W = 1000, H = 800;
const mk = () => createTouchControls({ width: W, height: H });
const keys = (actions) => actions.map((a) => `${a.key}:${a.type}`);

test("corner zones classify a grid of touch-start points", () => {
	for (let x = 5; x < W; x += 50) {
		for (let y = 5; y < H; y += 50) {
			const lower = y >= H * (1 - ZONE.height);
			const want = lower && x < W * ZONE.width ? ["z:down"]
				: lower && x >= W * (1 - ZONE.width) ? ["/:down"] : [];
			assert.deepEqual(keys(mk().start(1, x, y, 0)), want, `start at ${x},${y}`);
		}
	}
});

test("a flipper stays up until its finger lifts or is cancelled", () => {
	const t = mk();
	assert.deepEqual(keys(t.start(1, 50, 780, 0)), ["z:down"]);
	assert.deepEqual(keys(t.tick(5000)), []);
	assert.deepEqual(keys(t.end(1, 5000)), ["z:up"]);
	assert.deepEqual(keys(t.start(2, 950, 780, 6000)), ["/:down"]);
	assert.deepEqual(keys(t.cancel(2, 6100)), ["/:up"]);
});

test("both flippers work at once, independently", () => {
	const t = mk();
	assert.deepEqual(keys([...t.start(1, 50, 780, 0), ...t.start(2, 950, 780, 0)]), ["z:down", "/:down"]);
	assert.deepEqual(keys(t.end(2, 100)), ["/:up"]);
	assert.deepEqual(keys(t.end(1, 200)), ["z:up"]);
});

test("a downward stroke outside the corners pulls the plunger", () => {
	const t = mk();
	assert.deepEqual(keys(t.start(1, 500, 200, 0)), []);
	assert.deepEqual(keys(t.move(1, 500, 200 + STROKE_MIN_PX - 1, 10)), [], "below threshold");
	assert.deepEqual(keys(t.move(1, 500, 200 + STROKE_MIN_PX, 20)), [" :down"]);
	assert.deepEqual(keys(t.move(1, 500, 400, 30)), [], "pull continues");
});

test("stroke distance sets launch power: a full stroke released early still launches fully", () => {
	const t = mk();
	t.start(1, 500, 100, 0);
	t.move(1, 500, 100 + STROKE_MIN_PX, 10); // pull begins at t=10
	t.move(1, 500, 100 + H * PULL_FULL_FRACTION, 40);
	assert.deepEqual(keys(t.end(1, 60)), [], "release is held back");
	assert.deepEqual(keys(t.tick(10 + PLUNGER_FULL_MS - 1)), []);
	assert.deepEqual(keys(t.tick(10 + PLUNGER_FULL_MS)), [" :up"]);
	assert.deepEqual(keys(t.tick(99999)), [], "released only once");
});

test("a half stroke gives half power; holding longer than that releases at lift", () => {
	const t = mk();
	t.start(1, 500, 100, 0);
	t.move(1, 500, 100 + STROKE_MIN_PX, 0);
	t.move(1, 500, 100 + (H * PULL_FULL_FRACTION) / 2, 50);
	t.end(1, 100);
	assert.deepEqual(keys(t.tick(PLUNGER_FULL_MS / 2 - 1)), []);
	assert.deepEqual(keys(t.tick(PLUNGER_FULL_MS / 2)), [" :up"]);
	const u = mk();
	u.start(1, 500, 100, 0);
	u.move(1, 500, 100 + STROKE_MIN_PX, 0);
	assert.deepEqual(keys(u.end(1, 2000)), [" :up"], "held past its distance target");
});

test("upward and sideways strokes do not pull; flipper touches never pull", () => {
	const t = mk();
	t.start(1, 500, 400, 0);
	assert.deepEqual(keys(t.move(1, 500, 300, 10)), []);
	assert.deepEqual(keys(t.move(1, 650, 300, 20)), []);
	assert.deepEqual(keys(t.end(1, 30)), []);
	t.start(2, 50, 700, 40);
	assert.deepEqual(keys(t.move(2, 50, 799, 50)), []);
	assert.deepEqual(keys(t.end(2, 60)), ["z:up"]);
});

test("a second stroke while a launch is pending is ignored", () => {
	const t = mk();
	t.start(1, 500, 100, 0);
	t.move(1, 500, 100 + H * PULL_FULL_FRACTION, 0);
	t.end(1, 10);
	t.start(2, 500, 100, 20);
	assert.deepEqual(keys(t.move(2, 500, 400, 30)), []);
	assert.deepEqual(keys(t.tick(PLUNGER_FULL_MS)), [" :up"]);
});

test("zones follow resizes", () => {
	const t = mk();
	t.resize(400, 900);
	assert.deepEqual(keys(t.start(1, 20, 880, 0)), ["z:down"]);
	assert.deepEqual(keys(t.start(2, 390, 880, 0)), ["/:down"]);
	assert.deepEqual(keys(t.start(3, 200, 880, 0)), []);
});

test("cancelAll (e.g. window blur) releases every held flipper and launches a pull", () => {
	const t = mk();
	t.start(1, 50, 780, 0);
	t.start(2, 950, 780, 0);
	t.start(3, 500, 100, 0);
	t.move(3, 500, 100 + H * PULL_FULL_FRACTION, 10);
	assert.deepEqual(keys(t.cancelAll(20)).sort(), ["/:up", "z:up"]);
	assert.deepEqual(keys(t.tick(10 + PLUNGER_FULL_MS)), [" :up"]);
	assert.deepEqual(keys(t.cancelAll(9999)), [], "nothing left to release");
});

// A finished stroke (start, one move, end) from mid-screen by (dx, dy).
function stroke(t, dx, dy, id = 1) {
	const x0 = 500, y0 = 150;
	return keys([...t.start(id, x0, y0, 0), ...t.move(id, x0 + dx, y0 + dy, 50), ...t.end(id, 100), ...t.tick(5000)]);
}

test("strokes classify over a grid of vectors: swipe left/right, plunger, or nothing", () => {
	for (let dx = -300; dx <= 300; dx += 20) {
		for (let dy = -300; dy <= 300; dy += 20) {
			const horizontal = Math.abs(dx) >= SWIPE_MIN_PX && Math.abs(dx) > 2 * Math.abs(dy);
			const plunger = dy >= STROKE_MIN_PX && dy > Math.abs(dx);
			const want = horizontal ? (dx < 0 ? ["]:down", "]:up"] : ["[:down", "[:up"])
				: plunger ? [" :down", " :up"] : [];
			assert.deepEqual(stroke(mk(), dx, dy), want, `stroke ${dx},${dy}`);
		}
	}
});

test("a swipe in a flipper corner stays a flipper press", () => {
	const t = mk();
	assert.deepEqual(keys([...t.start(1, 50, 780, 0), ...t.move(1, 300, 780, 10), ...t.end(1, 20)]), ["z:down", "z:up"]);
});

test("a stroke that already pulled the plunger never becomes a swipe", () => {
	const t = mk();
	const out = keys([...t.start(1, 500, 100, 0), ...t.move(1, 500, 200, 10), ...t.move(1, 900, 210, 20), ...t.end(1, 30), ...t.tick(5000)]);
	assert.deepEqual(out, [" :down", " :up"]);
});
