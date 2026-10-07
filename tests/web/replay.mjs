// Headless replay through the WebAssembly core, mirroring the native host's
// --headless semantics exactly (frame clock, first-tick resize flag, script
// timing, final-frame quit) and writing frames/log in the same format.
// Usage: node replay.mjs WASM SCRIPT FRAMES COLSxROWS SEED FRAMES_OUT LOG_OUT
import { readFileSync, writeFileSync } from "node:fs";
import { loadGame, FLAG_QUIT, FLAG_RESIZED } from "../../web/site/pinterm-core.js";

const [wasmPath, scriptPath, framesArg, sizeArg, seedArg, framesOut, logOut] = process.argv.slice(2);
const [cols, rows] = sizeArg.split("x").map(Number);
const maxFrames = Number(framesArg);
const fps = 60;
const names = { space: " ", enter: "\r", left: "\x1b[D", right: "\x1b[C", up: "\x1b[A", down: "\x1b[B",
	esc: "\x1b", "ctrl-c": "\x03", "release-z": "\x1b[122;1:3u", "release-slash": "\x1b[47;1:3u",
	"release-space": "\x1b[32;1:3u" };
const script = readFileSync(scriptPath, "utf8").split("\n")
	.map((l) => l.replace(/#.*/, "").trim()).filter(Boolean)
	.map((l) => { const [f, k] = l.split(/\s+/); return { frame: Number(f), bytes: names[k] ?? k }; });

const game = await loadGame(readFileSync(wasmPath), { cols, rows, seed: Number(seedArg), sound: false, headless: true, maxFrames, fps });
const enc = new TextEncoder();
const frames = [];
let log = "";
let next = 0;
for (let frame = 1; ; frame++) {
	let input = "";
	while (next < script.length && script[next].frame <= frame) input += script[next++].bytes;
	let flags = frame === 1 ? FLAG_RESIZED : 0;
	if (frame >= maxFrames) flags |= FLAG_QUIT;
	const nowUs = Math.floor((frame * 1000000) / fps);
	const out = game.frame(nowUs, cols, rows, flags, enc.encode(input));
	frames.push(enc.encode(`\n=== frame ${frame} ===\n`), out.bytes);
	log += out.log;
	if (out.quit) break;
}
writeFileSync(framesOut, Buffer.concat(frames));
writeFileSync(logOut, log);
