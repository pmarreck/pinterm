// Shake-to-nudge detector for phones and tablets. Pure: fed timestamped
// accelerometer samples, it reports when a firm bump should nudge the table.
// Prefers user acceleration (gravity removed by the OS); when only
// gravity-including readings exist, a low-pass gravity estimate is subtracted.

// m/s² of user acceleration for a nudge: above handling noise (~3), well
// below a violent shake (~25).
export const NUDGE_THRESHOLD = 7.5;
// One bump spans several samples over threshold; collapse them into one nudge.
export const NUDGE_COOLDOWN_MS = 400;
// Gravity low-pass time constant for gravity-including sensors.
const GRAVITY_TAU_MS = 250;

export function createShakeDetector() {
	let gravity = null; // { x, y, z } estimate, gravity-including sensors only
	let lastT = null;
	let lastNudge = -Infinity;

	function sample({ t, x, y, z, includesGravity }) {
		if (x == null || y == null || z == null) return false;
		let ux = x, uy = y, uz = z;
		if (includesGravity) {
			if (gravity === null) {
				gravity = { x, y, z };
			} else {
				const dt = Math.max(0, t - (lastT ?? t));
				const k = dt / (GRAVITY_TAU_MS + dt);
				gravity = { x: gravity.x + (x - gravity.x) * k, y: gravity.y + (y - gravity.y) * k, z: gravity.z + (z - gravity.z) * k };
			}
			ux = x - gravity.x;
			uy = y - gravity.y;
			uz = z - gravity.z;
		}
		lastT = t;
		const magnitude = Math.hypot(ux, uy, uz);
		if (magnitude >= NUDGE_THRESHOLD && t - lastNudge >= NUDGE_COOLDOWN_MS) {
			lastNudge = t;
			return true;
		}
		return false;
	}
	return { sample };
}
