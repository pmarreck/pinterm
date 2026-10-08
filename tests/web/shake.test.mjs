// Unit tests for the shake-to-nudge detector (pure, timestamped samples).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createShakeDetector, NUDGE_THRESHOLD, NUDGE_COOLDOWN_MS } from "../../web/site/shake.js";

const user = (t, x, y = 0, z = 0) => ({ t, x, y, z, includesGravity: false });
const withGravity = (t, x, y = 0, z = 9.81) => ({ t, x, y, z, includesGravity: true });

test("ordinary handling below the threshold never nudges", () => {
	const d = createShakeDetector();
	let n = 0;
	for (let t = 0; t < 5000; t += 16) n += d.sample(user(t, 3 * Math.sin(t / 50), 2 * Math.cos(t / 70))) ? 1 : 0;
	assert.equal(n, 0);
});

test("one firm bump nudges once", () => {
	const d = createShakeDetector();
	assert.equal(d.sample(user(0, 0)), false);
	assert.equal(d.sample(user(16, NUDGE_THRESHOLD + 0.5)), true);
	assert.equal(d.sample(user(32, NUDGE_THRESHOLD + 3)), false, "same bump, within cooldown");
});

test("sustained shaking nudges at most once per cooldown", () => {
	const d = createShakeDetector();
	let n = 0;
	const span = 2000;
	for (let t = 0; t < span; t += 16) n += d.sample(user(t, 14 * Math.sign(Math.sin(t / 40)))) ? 1 : 0;
	assert.ok(n >= 2 && n <= Math.ceil(span / NUDGE_COOLDOWN_MS) + 1, `nudges: ${n}`);
});

test("gravity-including sensors: a resting device does not nudge, a bump does", () => {
	const d = createShakeDetector();
	let n = 0;
	for (let t = 0; t < 3000; t += 16) n += d.sample(withGravity(t, 0.2, 0.1, 9.81)) ? 1 : 0;
	assert.equal(n, 0, "gravity alone is not a shake");
	assert.equal(d.sample(withGravity(3016, 12, 0, 9.81)), true);
});

test("tilting the device slowly (gravity moving between axes) does not nudge", () => {
	const d = createShakeDetector();
	let n = 0;
	for (let t = 0; t < 4000; t += 16) {
		const a = (t / 4000) * (Math.PI / 2);
		n += d.sample(withGravity(t, 9.81 * Math.sin(a), 0, 9.81 * Math.cos(a))) ? 1 : 0;
	}
	assert.equal(n, 0);
});

test("missing readings (null axes) are ignored", () => {
	const d = createShakeDetector();
	assert.equal(d.sample({ t: 0, x: null, y: null, z: null, includesGravity: false }), false);
});
