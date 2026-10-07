// pinterm WebAssembly driver, shared by the browser page and the Node tests.
// It owns no game logic: it packs the same tick packet the native C host
// sends (clock, terminal size, flags, raw input bytes), calls the Roc core's
// Loop.frame through the wasm exports, and copies out ANSI bytes, PCM samples
// and event-log lines.

export const SAMPLE_RATE = 22050;
export const FLAG_QUIT = 1;
export const FLAG_RESIZED = 2;
const HEADER = 13;
const MAX_INPUT = 8192;
// Config slot order matches platform/pinterm_host.h (PT_CFG_*).
const CONFIG_SLOTS = 10;

export async function loadGame(wasmBytes, options = {}) {
	let memory;
	const decoder = new TextDecoder();
	const { instance } = await WebAssembly.instantiate(wasmBytes, {
		env: {
			roc_panic(ptr, len) {
				const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
				throw new Error(`pinterm core crashed: ${text}`);
			},
		},
	});
	const x = instance.exports;
	memory = x.memory;

	const cfg = {
		cols: 80, rows: 24, color: 0, ascii: false, sound: true, seed: 1,
		rate: SAMPLE_RATE, headless: false, maxFrames: 0, fps: 60, ...options,
	};
	const values = [cfg.cols, cfg.rows, cfg.color, cfg.ascii ? 1 : 0, cfg.sound ? 1 : 0,
		cfg.seed, cfg.rate, cfg.headless ? 1 : 0, cfg.maxFrames, cfg.fps];
	if (values.length !== CONFIG_SLOTS) throw new Error("config layout mismatch");
	const configView = new DataView(memory.buffer, x.web_input(), CONFIG_SLOTS * 8);
	values.forEach((v, i) => configView.setBigInt64(i * 8, BigInt(Math.trunc(v)), true));
	x.web_init(CONFIG_SLOTS);

	// frame(nowUs, cols, rows, flags, inputBytes) -> { bytes, samples, log, quit }
	function frame(nowUs, cols, rows, flags, input = new Uint8Array(0)) {
		const n = Math.min(input.length, MAX_INPUT);
		const base = x.web_input();
		const view = new DataView(memory.buffer, base, HEADER + n);
		view.setBigUint64(0, BigInt(Math.max(0, Math.trunc(nowUs))), true);
		view.setUint16(8, cols, true);
		view.setUint16(10, rows, true);
		view.setUint8(12, flags);
		new Uint8Array(memory.buffer, base + HEADER, n).set(input.subarray(0, n));
		x.web_frame(HEADER + n);
		// Copy out before the next call: the lists are released on the next frame.
		const bytes = new Uint8Array(memory.buffer, x.web_bytes_ptr(), x.web_bytes_len()).slice();
		const samples = new Int16Array(memory.buffer.slice(x.web_samples_ptr(), x.web_samples_ptr() + 2 * x.web_samples_len()));
		const log = decoder.decode(new Uint8Array(memory.buffer, x.web_log_ptr(), x.web_log_len()));
		return { bytes, samples, log, quit: x.web_quit() !== 0 };
	}
	return { frame, memoryBytes: () => memory.buffer.byteLength };
}

// Kitty keyboard protocol sequences (the core's Input decoder understands
// these) so the browser's real key-up events give exact flipper control.
const KEY_CODES = { z: 122, Z: 122, "/": 47, " ": 32, t: 116, T: 116 };
const ARROWS = { ArrowLeft: "D", ArrowRight: "C", ArrowDown: "B", ArrowUp: "A" };

export function keyEventBytes(key, type, { ctrl = false } = {}) {
	const event = type === "up" ? 3 : 1;
	if (ARROWS[key]) return encode(`\x1b[1;1:${event}${ARROWS[key]}`);
	if (type === "up") return KEY_CODES[key] ? encode(`\x1b[${KEY_CODES[key]};1:3u`) : null;
	if (ctrl && key.length === 1) return encode(`\x1b[${key.toLowerCase().charCodeAt(0)};5u`);
	if (key === "Enter") return encode("\r");
	if (key === "Escape") return encode("\x1b[27u");
	if (key.length === 1) return encode(key);
	return null;
}

function encode(s) {
	return new TextEncoder().encode(s);
}
