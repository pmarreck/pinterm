// Browser shell for pinterm: libghostty (ghostty-web) renders the exact ANSI
// frames the Roc core produces, key events become the same input bytes a
// kitty-protocol terminal would send, and the core's PCM plays via Web Audio.
import { Ghostty, Terminal, FitAddon } from "./vendor/ghostty-web.js";
import { loadGame, keyEventBytes, SAMPLE_RATE, FLAG_RESIZED } from "./pinterm-core.js";

const params = new URLSearchParams(location.search);
const demo = params.has("demo");
const seed = Number(params.get("seed") ?? Math.floor(Math.random() * 2 ** 31));
const GAME_KEYS = new Set(["z", "Z", "/", " ", "t", "T", "p", "P", "m", "M", "h", "H", "?", "n", "N", "q", "Q", "Enter", "Escape", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]);

const container = document.getElementById("terminal");
const overlay = document.getElementById("start");
const fontSize = () => Math.max(8, Math.floor(Math.min(innerWidth / (100 * 0.62), innerHeight / (42 * 1.22))));

const ghostty = await Ghostty.load("./vendor/ghostty-vt.wasm");
const term = new Terminal({
	ghostty,
	fontSize: fontSize(),
	fontFamily: "'DejaVu Sans Mono', 'Menlo', 'Consolas', ui-monospace, monospace",
	cursorBlink: false,
	disableStdin: true,
	scrollback: 0,
	theme: { background: "#07050e", foreground: "#c9c3e6" },
});
const fit = new FitAddon();
term.loadAddon(fit);
term.open(container);
fit.fit();
// Same terminal setup the native host sends: hide the cursor, no autowrap.
term.write("\x1b[?25l\x1b[?7l");

const wasm = await (await fetch("./pinterm.wasm")).arrayBuffer();
let game = await loadGame(wasm, { cols: term.cols, rows: term.rows, seed, sound: true });
let pending = [];
let size = { cols: 0, rows: 0 };
let quitShown = false;
// Recent structured game events (bounded), for tests and curious players.
const eventLog = [];

// Audio: schedule each frame's samples back-to-back on one timeline.
let audio = null;
let audioTime = 0;
function playSamples(samples) {
	if (!audio || audio.state !== "running" || samples.length === 0) return;
	const buffer = audio.createBuffer(1, samples.length, SAMPLE_RATE);
	const data = buffer.getChannelData(0);
	for (let i = 0; i < samples.length; i++) data[i] = samples[i] / 32768;
	const source = audio.createBufferSource();
	source.buffer = buffer;
	source.connect(audio.destination);
	const lead = 0.04;
	if (audioTime < audio.currentTime + 0.005 || audioTime > audio.currentTime + 0.25) audioTime = audio.currentTime + lead;
	source.start(audioTime);
	audioTime += buffer.duration;
}

function queue(bytes) {
	if (bytes) pending.push(bytes);
}

function onKey(e, type) {
	if (!overlay.hidden) return;
	if (!GAME_KEYS.has(e.key) && !(e.ctrlKey && e.key === "c")) return;
	e.preventDefault();
	if (quitShown && type === "down") return restart();
	queue(keyEventBytes(e.key, type, { ctrl: e.ctrlKey }));
}
addEventListener("keydown", (e) => onKey(e, "down"), { capture: true });
addEventListener("keyup", (e) => onKey(e, "up"), { capture: true });
addEventListener("resize", () => { term.options.fontSize = fontSize(); fit.fit(); });
// Touch: left half = left flipper, right half = right flipper, two-finger tap = plunger.
container.addEventListener("touchstart", (e) => {
	e.preventDefault();
	if (e.touches.length >= 2) { queue(keyEventBytes(" ", "down")); return; }
	for (const t of e.changedTouches) queue(keyEventBytes(t.clientX < innerWidth / 2 ? "z" : "/", "down"));
}, { passive: false });
container.addEventListener("touchend", (e) => {
	e.preventDefault();
	queue(keyEventBytes(" ", "up"));
	for (const t of e.changedTouches) queue(keyEventBytes(t.clientX < innerWidth / 2 ? "z" : "/", "up"));
}, { passive: false });

async function restart() {
	quitShown = false;
	game = await loadGame(wasm, { cols: term.cols, rows: term.rows, seed: seed + 1, sound: true });
	size = { cols: 0, rows: 0 };
}

function concat(chunks) {
	const total = chunks.reduce((n, c) => n + c.length, 0);
	const out = new Uint8Array(total);
	let at = 0;
	for (const c of chunks) { out.set(c, at); at += c.length; }
	return out;
}

// Demo mode: a fixed, seeded key script so screenshots are reproducible.
let demoFrame = 0;
function demoInput() {
	demoFrame++;
	const f = demoFrame;
	if (f === 5) return keyEventBytes(" ", "down");
	// Pull and launch at frame 40, then relaunch every 10 s if a ball is waiting.
	if (f % 600 === 40) return keyEventBytes(" ", "down");
	if (f % 600 === 100) return keyEventBytes(" ", "up");
	if (f > 140 && f % 23 === 0) return keyEventBytes("z", "down");
	if (f > 140 && f % 23 === 8) return keyEventBytes("z", "up");
	if (f > 140 && f % 29 === 0) return keyEventBytes("/", "down");
	if (f > 140 && f % 29 === 9) return keyEventBytes("/", "up");
	return null;
}

function tick(now) {
	if (quitShown) return requestAnimationFrame(tick);
	let flags = 0;
	if (term.cols !== size.cols || term.rows !== size.rows) {
		size = { cols: term.cols, rows: term.rows };
		flags |= FLAG_RESIZED;
	}
	if (demo) queue(demoInput());
	const input = concat(pending);
	pending = [];
	const nowUs = demo ? demoFrame * 1e6 / 60 : now * 1000;
	const out = game.frame(nowUs, size.cols, size.rows, flags, input);
	term.write(out.bytes);
	playSamples(out.samples);
	if (out.log) {
		const lines = out.log.trim().split("\n");
		eventLog.push(...lines);
		if (eventLog.length > 2000) eventLog.splice(0, eventLog.length - 2000);
		document.body.dataset.lastEvent = lines[lines.length - 1];
	}
	if (out.quit) {
		quitShown = true;
		term.write("\x1b[2J\x1b[H\x1b[0mThanks for playing pinterm.\r\nPress any key to play again.");
	}
	requestAnimationFrame(tick);
}

function begin() {
	if (!overlay.hidden) {
		overlay.hidden = true;
		try {
			audio = new AudioContext();
			audio.resume();
		} catch {
			audio = null;
		}
		requestAnimationFrame(tick);
	}
}
if (demo) begin();
else {
	overlay.addEventListener("click", begin);
	addEventListener("keydown", (e) => { if (!overlay.hidden) { e.preventDefault(); begin(); } }, { capture: true });
}
window.pinterm = { seed, eventLog };
