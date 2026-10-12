// Browser storage for the saved high-score file. The core produces and reads
// the file's bytes (UTF-8 text); this only moves them in and out of a
// Storage-like object, and keeps a damaged entry rather than overwrite it.
// Storage may be blocked (private windows, disabled site data), so every
// access is guarded and the game simply plays without saved scores.

export const SCORES_KEY = "pinterm.scores";

export function createScoreStore(storage, now = Date.now) {
	const guarded = (f, fallback) => {
		try {
			return storage ? f() : fallback;
		} catch {
			return fallback;
		}
	};
	return {
		read: () => new TextEncoder().encode(guarded(() => storage.getItem(SCORES_KEY), null) ?? ""),
		write: (bytes) => guarded(() => storage.setItem(SCORES_KEY, new TextDecoder().decode(bytes))),
		quarantine: () =>
			guarded(() => {
				const old = storage.getItem(SCORES_KEY);
				if (old === null) return;
				storage.setItem(`${SCORES_KEY}.bad-${now()}`, old);
				storage.removeItem(SCORES_KEY);
			}),
	};
}
