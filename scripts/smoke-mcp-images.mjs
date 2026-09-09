#!/usr/bin/env node
// Exercise the exact bundled server over stdio with disposable image/comment
// fixtures. The child process substitutes os.homedir; no user defaults, HOME
// environment variable, or live Remarc files are changed.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundle = resolve(process.argv[2] ?? join(repository, "mcp/vendor/remarc-mcp.js"));
const fixtureRoot = await mkdtemp(join(tmpdir(), "remarc-mcp-image-smoke-"));
const dataDirectory = join(fixtureRoot, "Library/Application Support/Remarc");
const customDirectory = join(fixtureRoot, "Project screenshots (custom)");
const dataFile = join(dataDirectory, "comments.json");
const legacyPath = "images/11111111-1111-4111-8111-111111111111.png";
const customPath = join(customDirectory, "22222222-2222-4222-8222-222222222222.png");
const missingPath = join(customDirectory, "missing.png");
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMZkAAAAASUVORK5CYII=", "base64");
const sessionID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const comments = [
  { id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", type: { screenshot: { imagePath: legacyPath } }, attachments: [] },
  { id: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", type: { screenshot: { imagePath: customPath } }, attachments: [] },
  { id: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", type: { quickNote: {} }, attachments: [customPath, legacyPath, missingPath] },
].map(comment => ({ ...comment, sessionID, commentText: "Inspect this fixture", source: "MCP image smoke",
  createdAt: 0, updatedAt: 0, isDeleted: false, status: "open" }));

let child;
let lines;
let nextID = 1;
const pending = new Map();
let stderr = "";
try {
  await mkdir(join(dataDirectory, "images"), { recursive: true });
  await mkdir(customDirectory, { recursive: true });
  await writeFile(join(dataDirectory, legacyPath), png);
  await writeFile(customPath, png);
  await writeFile(dataFile, JSON.stringify({ comments, sessions: [{ id: sessionID, name: "Image smoke",
    createdAt: 0, isDeleted: false }], activeSessionID: sessionID, totalCommentsCreated: comments.length }));

  child = spawn(process.execPath, ["--input-type=module", "-e", `
    import os from "node:os";
    import { syncBuiltinESMExports } from "node:module";
    import { pathToFileURL } from "node:url";
    os.homedir = () => process.env.REMARC_SMOKE_ROOT;
    syncBuiltinESMExports();
    await import(pathToFileURL(process.env.REMARC_SMOKE_BUNDLE).href);
  `], { env: { ...process.env, REMARC_SMOKE_ROOT: fixtureRoot, REMARC_SMOKE_BUNDLE: bundle },
    stdio: ["pipe", "pipe", "pipe"] });
  child.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-4000); });
  lines = createInterface({ input: child.stdout });
  lines.on("line", line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
    else waiter.resolve(message.result);
  });
  const failPending = error => {
    for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(error); }
    pending.clear();
  };
  child.on("error", failPending);
  child.on("exit", code => failPending(new Error(`MCP exited (${code}): ${stderr}`)));
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextID++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out: ${method}. ${stderr}`)); }, 10000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const initialized = await request("initialize", { protocolVersion: "2025-03-26", capabilities: {},
    clientInfo: { name: "remarc-storage-smoke", version: "1.0.0" } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const call = (name, args) => request("tools/call", { name, arguments: args });
  const textOf = result => result.content.filter(item => item.type === "text").map(item => item.text).join("\n");
  for (const [index, expectedCount] of [1, 1, 2].entries()) {
    const result = await call("remarc_get_comment", { id: comments[index].id });
    assert.ok(!result.isError, textOf(result));
    const images = result.content.filter(item => item.type === "image");
    assert.equal(images.length, expectedCount, `Comment ${index}: ${textOf(result)}`);
    for (const image of images) {
      assert.equal(image.mimeType, "image/png");
      assert.deepEqual(Buffer.from(image.data, "base64"), png);
    }
    assert.ok(textOf(result).includes(index === 0 ? join(dataDirectory, legacyPath) : customPath));
    if (index === 2) {
      assert.ok(textOf(result).includes(join(dataDirectory, legacyPath)));
      assert.ok(textOf(result).includes(missingPath));
      assert.match(textOf(result), /missing|unreadable/i);
    }
  }
  const listed = await call("remarc_list_comments", { session_id: sessionID });
  assert.ok(listed.content.every(item => item.type === "text"));
  assert.match(textOf(listed), /attachments?.*3|3.*attachments?/i);
  const updated = await call("remarc_set_status", { id: comments[2].id, status: "inProgress" });
  assert.ok(!updated.isError, textOf(updated));
  const saved = JSON.parse(await readFile(dataFile, "utf8"));
  for (const comment of comments) {
    const after = saved.comments.find(item => item.id === comment.id);
    assert.deepEqual(after.type, comment.type);
    assert.deepEqual(after.attachments ?? [], comment.attachments);
  }
  console.log(`PASS: bundled MCP ${initialized.serverInfo.version}; default/custom screenshots, pasted attachments, missing-file fallback, text-only listing, and status-write path preservation.`);
} finally {
  lines?.close();
  child?.kill();
  for (const waiter of pending.values()) clearTimeout(waiter.timer);
  await rm(fixtureRoot, { recursive: true, force: true });
}
