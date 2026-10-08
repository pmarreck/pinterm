// Touch controls for phones and tablets as a pure state machine with an
// injected clock: lower corners are the flippers (held while touched), and a
// downward stroke elsewhere pulls the plunger. The game measures plunger power
// as press-to-release time, so stroke distance is converted to that time by
// holding the release back until the matching moment.

// Corner zones: the lower ZONE.height of the screen, outer ZONE.width per side.
export const ZONE = { width: 0.35, height: 0.45 };
// Downward travel (px) before a stroke counts as pulling the plunger.
export const STROKE_MIN_PX = 24;
// A stroke this fraction of the screen height gives full power.
export const PULL_FULL_FRACTION = 0.35;
// Hold time the core treats as full plunger power (plunger_full_time, 0.9 s).
export const PLUNGER_FULL_MS = 900;
// Sideways travel (px) for a horizontal swipe, which changes table between
// games (left = next, right = previous); it must exceed twice the vertical travel.
export const SWIPE_MIN_PX = 60;

export function createTouchControls({ width, height }) {
	let w = width, h = height;
	const touches = new Map(); // id -> { kind: "left"|"right"|"stroke", x0, y0, x, y, maxDy }
	let pull = null; // { id, startMs, powerFraction, releaseAt (ms) | null }

	const action = (key, type) => ({ key, type });

	function zoneOf(x, y) {
		if (y < h * (1 - ZONE.height)) return "stroke";
		if (x < w * ZONE.width) return "left";
		if (x >= w * (1 - ZONE.width)) return "right";
		return "stroke";
	}

	function start(id, x, y, _now) {
		const kind = zoneOf(x, y);
		touches.set(id, { kind, x0: x, y0: y, x, y, maxDy: 0 });
		if (kind === "left") return [action("z", "down")];
		if (kind === "right") return [action("/", "down")];
		return [];
	}

	function move(id, x, y, now) {
		const t = touches.get(id);
		if (!t || t.kind !== "stroke") return [];
		t.x = x;
		t.y = y;
		t.maxDy = Math.max(t.maxDy, y - t.y0);
		// Only a mostly-downward stroke pulls; a sideways one may be a swipe.
		if (pull === null && t.maxDy >= STROKE_MIN_PX && y - t.y0 > Math.abs(x - t.x0)) {
			pull = { id, startMs: now, powerFraction: 0, releaseAt: null };
			pull.powerFraction = Math.min(1, t.maxDy / (h * PULL_FULL_FRACTION));
			return [action(" ", "down")];
		}
		if (pull && pull.id === id) pull.powerFraction = Math.min(1, t.maxDy / (h * PULL_FULL_FRACTION));
		return [];
	}

	function finish(id, now) {
		const t = touches.get(id);
		touches.delete(id);
		if (!t) return [];
		if (t.kind === "left") return [action("z", "up")];
		if (t.kind === "right") return [action("/", "up")];
		if (pull && pull.id === id && pull.releaseAt === null) {
			pull.releaseAt = pull.startMs + pull.powerFraction * PLUNGER_FULL_MS;
			return tick(now);
		}
		if (!(pull && pull.id === id)) {
			const dx = t.x - t.x0, dy = t.y - t.y0;
			if (Math.abs(dx) >= SWIPE_MIN_PX && Math.abs(dx) > 2 * Math.abs(dy)) {
				const k = dx < 0 ? "]" : "[";
				return [action(k, "down"), action(k, "up")];
			}
		}
		return [];
	}

	function tick(now) {
		if (pull && pull.releaseAt !== null && now >= pull.releaseAt) {
			pull = null;
			return [action(" ", "up")];
		}
		return [];
	}

	return {
		start,
		move,
		end: finish,
		cancel: finish,
		// Release everything (window blur, page hidden): flippers drop now, a pull
		// finishes as if its finger lifted.
		cancelAll(now) {
			const out = [];
			for (const id of [...touches.keys()]) out.push(...finish(id, now));
			return out;
		},
		tick,
		resize(nw, nh) { w = nw; h = nh; },
	};
}
