// Headless-Chromium driver over the DevTools protocol (no npm dependencies):
// loads the built site, records console output and exceptions, sends real
// keyboard events, evaluates page state and captures screenshots.
// Usage: node browser.mjs SITE_DIR COMMAND...
//   check            play a scripted session; print JSON evidence
//   shot OUT.png     capture a demo-mode screenshot after gameplay
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, normalize } from "node:path";

const [siteDir, command, outPath] = process.argv.slice(2);
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".txt": "text/plain" };

function serve(root) {
	return new Promise((resolve) => {
		const server = createServer(async (req, res) => {
			const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
			const file = join(root, path.endsWith("/") ? path + "index.html" : path);
			try {
				const body = await readFile(file);
				res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
				res.end(body);
			} catch {
				res.writeHead(404);
				res.end();
			}
		});
		server.listen(0, "127.0.0.1", () => resolve(server));
	});
}

async function launch() {
	const profile = mkdtempSync(join(tmpdir(), "pinterm-chrome-"));
	const chrome = spawn(process.env.CHROMIUM ?? "chromium", [
		"--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--mute-audio",
		"--autoplay-policy=no-user-gesture-required", `--user-data-dir=${profile}`,
		"--remote-debugging-port=0", "--window-size=1400,900", "about:blank",
	], { stdio: ["ignore", "ignore", "pipe"] });
	const wsUrl = await new Promise((resolve, reject) => {
		let buf = "";
		chrome.stderr.on("data", (d) => {
			buf += d;
			const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
			if (m) resolve(m[1]);
		});
		chrome.on("exit", (code) => reject(new Error(`chromium exited ${code}`)));
	});
	const list = await (await fetch(wsUrl.replace("ws://", "http://").replace(/\/devtools\/browser\/.*/, "/json/list"))).json();
	const page = list.find((t) => t.type === "page");
	const ws = new WebSocket(page.webSocketDebuggerUrl);
	await new Promise((r) => ws.addEventListener("open", r, { once: true }));
	let id = 0;
	const waiting = new Map();
	const events = [];
	ws.addEventListener("message", (m) => {
		const msg = JSON.parse(m.data);
		if (msg.id && waiting.has(msg.id)) {
			const { resolve, reject } = waiting.get(msg.id);
			waiting.delete(msg.id);
			msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
		} else if (msg.method) events.push(msg);
	});
	const send = (method, params = {}) => new Promise((resolve, reject) => {
		const n = ++id;
		waiting.set(n, { resolve, reject });
		ws.send(JSON.stringify({ id: n, method, params }));
	});
	return { chrome, send, events, close: () => { ws.close(); chrome.kill("SIGKILL"); } };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const server = await serve(siteDir);
const base = `http://127.0.0.1:${server.address().port}/`;
const b = await launch();
const { send, events } = b;
const evalPage = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })).result.value;
const problems = () => events.filter((e) => e.method === "Runtime.exceptionThrown" || (e.method === "Runtime.consoleAPICalled" && e.params.type === "error"))
	.map((e) => e.params.exceptionDetails?.exception?.description ?? e.params.exceptionDetails?.text ?? e.params.args?.map((a) => a.value ?? a.description).join(" "));

// Poll a page expression until truthy (bounded), rather than guessing delays.
async function waitFor(expr, ms) {
	const end = Date.now() + ms;
	while (Date.now() < end) {
		if (await evalPage(expr)) return true;
		await sleep(25);
	}
	return false;
}

// Wait for a game event line matching `re` in the page's event log.
async function waitForEvent(re, ms = 10000) {
	const end = Date.now() + ms;
	while (Date.now() < end) {
		const lines = await evalPage("window.pinterm ? window.pinterm.eventLog : []");
		const hit = lines.find((l) => re.test(l));
		if (hit) return hit;
		await sleep(25);
	}
	return "";
}

async function key(k, code, type) {
	const text = k.length === 1 ? k : undefined;
	await send("Input.dispatchKeyEvent", { type: type === "down" ? (text ? "keyDown" : "rawKeyDown") : "keyUp", key: k, code, text, windowsVirtualKeyCode: k === " " ? 32 : k.toUpperCase().charCodeAt(0) });
}

try {
	await send("Runtime.enable");
	await send("Page.enable");
	if (command === "shot") {
		await send("Page.navigate", { url: `${base}?demo&seed=7` });
		// Capture shortly after a launch so a ball is in play.
		await waitForEvent(/event launch/, 20000);
		await sleep(1200);
		const shot = await send("Page.captureScreenshot", { format: "png" });
		writeFileSync(outPath, Buffer.from(shot.data, "base64"));
		console.log(JSON.stringify({ problems: problems(), lastEvent: await evalPage("document.body.dataset.lastEvent ?? null") }));
	} else if (command === "check") {
		await send("Page.navigate", { url: `${base}?seed=7` });
		await waitFor("window.pinterm !== undefined", 20000);
		const overlayBefore = await evalPage("document.getElementById('start').hidden");
		await key(" ", "Space", "down"); // dismiss start overlay
		await key(" ", "Space", "up");
		await waitFor("document.getElementById('start').hidden", 5000);
		await key(" ", "Space", "down"); // start the game
		await key(" ", "Space", "up");
		const started = await waitForEvent(/event start/);
		await key(" ", "Space", "down"); // pull plunger, release later -> exact power
		await sleep(400);
		await key(" ", "Space", "up");
		const launched = await waitForEvent(/event launch/);
		await key("z", "KeyZ", "down");
		const flipped = await waitForEvent(/event flip side=left/);
		await key("z", "KeyZ", "up");
		const audio = await evalPage("(() => { try { return typeof AudioContext } catch { return 'none' } })()");
		console.log(JSON.stringify({ overlayBefore, started, launched, flipped, audio, problems: problems() }));
	}
} finally {
	b.close();
	server.close();
}
