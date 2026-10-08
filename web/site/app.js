// Browser shell for pinterm: libghostty (ghostty-web) renders the exact ANSI
// frames the Roc core produces, key events become the same input bytes a
// kitty-protocol terminal would send, and the core's PCM plays via Web Audio.
import { Ghostty, Terminal, FitAddon } from "./vendor/ghostty-web.js";
import { loadGame, keyEventBytes, SAMPLE_RATE, FLAG_RESIZED } from "./pinterm-core.js";
import { createTouchControls } from "./touch-controls.js";
import { createShakeDetector } from "./shake.js";

const params = new URLSearchParams(location.search);
const demo = params.has("demo");
const seed = Number(params.get("seed") ?? Math.floor(Math.random() * 2 ** 31));
// ?table=N opens on table N (0 = Classic); the core switches with "]" between games.
const startTable = Math.max(0, Math.min(16, Math.floor(Number(params.get("table") ?? 0)) || 0));
const GAME_KEYS = new Set(["z", "Z", "/", " ", "t", "T", "p", "P", "m", "M", "h", "H", "?", "n", "N", "q", "Q", "Enter", "Escape", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "[", "]"]);

const container = document.getElementById("terminal");
const overlay = document.getElementById("start");
// Landscape: ~100 columns fit the table plus the side panel. Portrait: ~56
// columns, below the panel threshold, so the core draws its compact score bar
// on top and the table fills the screen.
const fontSize = () => {
	const cols = innerHeight > innerWidth ? 56 : 100;
	return Math.max(8, Math.floor(Math.min(innerWidth / (cols * 0.62), innerHeight / (42 * 1.22))));
};

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
// ghostty-web makes its element contenteditable with a hidden textarea and
// focuses it, which raises the on-screen keyboard on phones. The game reads
// keys itself, so make those elements inert and never focusable.
function disarmTextInput() {
	for (const el of [container, ...container.querySelectorAll("[contenteditable], textarea, input")]) {
		el.removeAttribute("contenteditable");
		el.setAttribute("tabindex", "-1");
		el.setAttribute("inputmode", "none");
		if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") el.readOnly = true;
		if (el === document.activeElement) el.blur();
	}
}
disarmTextInput();
new MutationObserver(disarmTextInput).observe(container, { subtree: true, childList: true, attributes: true, attributeFilter: ["contenteditable"] });

const wasm = await (await fetch("./pinterm.wasm")).arrayBuffer();
let game = await loadGame(wasm, { cols: term.cols, rows: term.rows, seed, sound: true });
let pending = [];
let size = { cols: 0, rows: 0 };
let quitShown = false;
let firstFrame = true;
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
// Touch: lower corners are flippers, a downward stroke pulls the plunger.
const touchLayer = document.getElementById("touch");
const touch = createTouchControls({ width: innerWidth, height: innerHeight });
addEventListener("resize", () => touch.resize(innerWidth, innerHeight));
function sendTouch(actions) {
	for (const a of actions) queue(keyEventBytes(a.key, a.type));
}
function onTouch(e, phase) {
	e.preventDefault();
	if (!overlay.hidden) return;
	if (quitShown && phase === "start") { restart(); return; }
	const now = performance.now();
	for (const t of e.changedTouches) {
		if (phase === "start") sendTouch(touch.start(t.identifier, t.clientX, t.clientY, now));
		else if (phase === "move") sendTouch(touch.move(t.identifier, t.clientX, t.clientY, now));
		else if (phase === "end") sendTouch(touch.end(t.identifier, now));
		else sendTouch(touch.cancel(t.identifier, now));
	}
}
touchLayer.addEventListener("touchstart", (e) => onTouch(e, "start"), { passive: false });
touchLayer.addEventListener("touchmove", (e) => onTouch(e, "move"), { passive: false });
touchLayer.addEventListener("touchend", (e) => onTouch(e, "end"), { passive: false });
touchLayer.addEventListener("touchcancel", (e) => onTouch(e, "cancel"), { passive: false });
// Motion: a firm bump of the device nudges the table (same as the t key).
// iOS requires DeviceMotionEvent.requestPermission() during a user gesture;
// it is retried on each completed gesture until granted or denied.
const shake = createShakeDetector();
let motionPermission = typeof globalThis.DeviceMotionEvent?.requestPermission === "function" ? "unrequested" : "implicit";
function requestMotion() {
	if (motionPermission !== "unrequested" && motionPermission !== "failed") return;
	motionPermission = "requesting";
	globalThis.DeviceMotionEvent.requestPermission()
		.then((state) => { motionPermission = state === "granted" || state === "denied" ? state : "failed"; })
		.catch(() => { motionPermission = "failed"; });
}
for (const name of ["touchend", "pointerup", "click", "keydown"]) addEventListener(name, requestMotion, { capture: true, passive: true });
addEventListener("devicemotion", (e) => {
	if (!overlay.hidden || quitShown) return;
	const user = e.acceleration?.x != null;
	const a = user ? e.acceleration : e.accelerationIncludingGravity;
	if (!a) return;
	if (shake.sample({ t: e.timeStamp, x: a.x, y: a.y, z: a.z, includesGravity: !user })) queue(keyEventBytes("t", "down"));
}, { passive: true });

// Losing focus mid-press must not leave a flipper stuck up.
addEventListener("blur", () => sendTouch(touch.cancelAll(performance.now())));
document.addEventListener("visibilitychange", () => { if (document.hidden) sendTouch(touch.cancelAll(performance.now())); });
// iOS grants audio permission only at the end of a gesture, and suspends the
// context after backgrounding, so every completed gesture retries resume().
for (const name of ["touchend", "pointerup", "click", "keydown"]) {
	addEventListener(name, () => { if (audio && audio.state !== "running") audio.resume().catch(() => {}); }, { capture: true, passive: true });
}

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
	if (firstFrame) {
		firstFrame = false;
		for (let i = 0; i < startTable; i++) queue(keyEventBytes("]", "down"));
	}
	if (demo) queue(demoInput());
	sendTouch(touch.tick(performance.now()));
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
		setTimeout(() => document.body.classList.add("playing"), 6000);
		try {
			audio = new (globalThis.AudioContext ?? globalThis.webkitAudioContext)();
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
	// iOS: end of a tap is the user activation that may start audio.
	overlay.addEventListener("touchend", (e) => { e.preventDefault(); begin(); }, { passive: false });
	addEventListener("keydown", (e) => { if (!overlay.hidden) { e.preventDefault(); begin(); } }, { capture: true });
}
window.pinterm = { seed, eventLog };

// ?diag: an on-device overlay for debugging touch input on phones, where no
// developer console is at hand. It shows the build the page loaded against
// the build the server has now (a stale cache reads STALE), raw touch event
// counts, how the last gesture was classified and which keys it sent, and the
// game's last event. Without ?diag nothing is installed.
if (params.has("diag")) {
	const loaded = document.querySelector('meta[name="pinterm-build"]')?.content ?? "?";
	let served = "pending";
	fetch("./build-id.txt", { cache: "no-store" }).then((r) => r.text()).then((t) => { served = t.trim(); }).catch(() => { served = "unavailable"; });
	const counts = { touchstart: 0, touchmove: 0, touchend: 0, touchcancel: 0 };
	for (const name of Object.keys(counts)) addEventListener(name, () => { counts[name]++; }, { capture: true, passive: true });
	const panel = document.createElement("pre");
	panel.id = "diag";
	panel.style.cssText = "position:fixed;top:0;left:0;z-index:10;margin:0;padding:.3rem .5rem;pointer-events:none;"
		+ "font:600 11px/1.3 ui-monospace,Menlo,monospace;color:#c8f7d0;background:rgba(0,0,0,.75);white-space:pre";
	document.body.append(panel);
	setInterval(() => {
		const g = touch.lastGesture();
		panel.textContent = [
			`build ${loaded} served ${served} ${served === loaded ? "ok" : served === "pending" ? "?" : "STALE"}`,
			`touch ts ${counts.touchstart} tm ${counts.touchmove} te ${counts.touchend} tc ${counts.touchcancel}`,
			g ? `gesture ${g.kind} dx ${g.dx} dy ${g.dy} keys ${g.keys.join(" ") || "-"}` : "gesture -",
			`event ${document.body.dataset.lastEvent ?? "-"}`,
			`view ${innerWidth}x${innerHeight}`,
		].join("\n");
	}, 100);
}
