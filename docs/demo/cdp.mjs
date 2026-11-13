// Minimal Chrome DevTools Protocol driver: no dependencies (Node 26 WebSocket).
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export async function browser({ width = 1440, height = 1000 } = {}) {
  const port = 9300 + Math.floor(Math.random() * 500);
  const profile = mkdtempSync(join(tmpdir(), "lightpath-chrome-"));
  const proc = spawn("chromium", ["--headless=new", "--disable-gpu", "--hide-scrollbars", `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`, `--window-size=${width},${height}`, "about:blank"], { stdio: "ignore" });
  let targets;
  for (let i = 0; i < 50; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); break; } catch { await sleep(200); }
  }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  let id = 0; const waiting = new Map();
  ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } });
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; waiting.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
  await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
  const api = {
    send,
    go: async (url, wait = 2500) => { await send("Page.navigate", { url }); await sleep(wait); },
    eval: async (expr) => (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value,
    shot: async (file) => { const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(file, Buffer.from(r.result.data, "base64")); },
    close: () => { ws.close(); proc.kill("SIGKILL"); setTimeout(() => rmSync(profile, { recursive: true, force: true }), 500); },
  };
  return api;
}
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
