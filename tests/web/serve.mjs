// Minimal static file server for testing the built web site locally.
// Usage: node serve.mjs SITE_DIR PORT
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
const [root, port] = process.argv.slice(2);
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".txt": "text/plain", ".png": "image/png" };
createServer(async (req, res) => {
	const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
	const file = join(root, path.endsWith("/") ? path + "index.html" : path);
	try {
		const body = await readFile(file);
		res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
		res.end(body);
	} catch {
		res.writeHead(404);
		res.end("not found");
	}
}).listen(Number(port), "127.0.0.1", () => console.log(`serving ${root} on ${port}`));
