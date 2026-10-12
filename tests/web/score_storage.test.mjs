// Unit tests for browser high-score storage over an injected Storage-like map.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createScoreStore, SCORES_KEY } from "../../web/site/score-storage.js";

const fakeStorage = (initial = {}) => {
	const data = new Map(Object.entries(initial));
	return {
		data,
		getItem: (k) => (data.has(k) ? data.get(k) : null),
		setItem: (k, v) => data.set(k, String(v)),
		removeItem: (k) => data.delete(k),
	};
};
const text = (s) => new TextEncoder().encode(s);

test("nothing saved reads as empty bytes", () => {
	assert.deepEqual(createScoreStore(fakeStorage()).read(), new Uint8Array(0));
});

test("saved text round-trips as UTF-8 bytes, including non-ASCII glyphs", () => {
	const s = fakeStorage();
	const store = createScoreStore(s);
	const body = "pinterm scores 1\n␀λ✓\n";
	store.write(text(body));
	assert.equal(s.data.get(SCORES_KEY), body);
	assert.deepEqual(store.read(), text(body));
});

test("a damaged entry is kept under a timestamped key and removed from the main key", () => {
	const s = fakeStorage({ [SCORES_KEY]: "garbage" });
	createScoreStore(s, () => 1234).quarantine();
	assert.equal(s.data.has(SCORES_KEY), false);
	assert.equal(s.data.get(`${SCORES_KEY}.bad-1234`), "garbage");
});

test("blocked or missing storage never throws and reads as empty", () => {
	const throwing = { getItem() { throw new Error("blocked"); }, setItem() { throw new Error("blocked"); }, removeItem() { throw new Error("blocked"); } };
	for (const storage of [throwing, null, undefined]) {
		const store = createScoreStore(storage);
		assert.deepEqual(store.read(), new Uint8Array(0));
		assert.doesNotThrow(() => store.write(text("x")));
		assert.doesNotThrow(() => store.quarantine());
	}
});
