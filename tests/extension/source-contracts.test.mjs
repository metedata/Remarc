import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const extensionRoot = path.join(repoRoot, "extension");

async function source(name) {
  return readFile(path.join(extensionRoot, name), "utf8");
}

test("manifest makes the localhost socket extension-owned and alarm-wakeable", async () => {
  const manifest = JSON.parse(await source("manifest.json"));

  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background?.service_worker, "background.js");
  assert.equal(manifest.background?.type, "module");
  assert.ok(Number.parseInt(manifest.minimum_chrome_version, 10) >= 120);
  assert.ok(manifest.permissions.includes("alarms"));
  assert.deepEqual(manifest.host_permissions, ["http://127.0.0.1/*"]);
  assert.match(manifest.version, /^(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){0,3}$/);
  assert.ok(
    manifest.version.split(".").every((component) => Number(component) <= 65_535),
    "manifest version components must remain valid for Chrome releases"
  );
});

test("page-owned scripts contain no WebSocket or loopback endpoint", async () => {
  for (const name of ["content.js", "main-world.js"]) {
    const text = await source(name);
    assert.doesNotMatch(text, /\bWebSocket\b/, `${name} must not construct or reference WebSocket`);
    assert.doesNotMatch(text, /127\.0\.0\.1|localhost/i, `${name} must not reference loopback`);
  }
});

test("one production module owns the loopback WebSocket constructor", async () => {
  const files = (await readdir(extensionRoot)).filter((name) => /\.(?:js|mjs)$/.test(name));
  const owners = [];
  const endpoints = [];

  for (const name of files) {
    const text = await source(name);
    if (/new\s+(?:(?:this\.)?_?WebSocket(?:Impl)?|WebSocket)\b/.test(text)) owners.push(name);
    if (text.includes("ws://127.0.0.1:9274")) endpoints.push(name);
  }

  assert.deepEqual(owners, ["native-bridge.mjs"]);
  assert.deepEqual(endpoints, ["background.js"]);
});

test("all established content-to-native message types remain represented", async () => {
  const text = await source("content.js");
  for (const type of [
    "selectionContext",
    "elementGrab",
    "regionContext",
    "regionRect",
    "regionHighlightDismissed",
    "openExtensionSettings",
    "tabActivity",
    "hfQuickNote",
  ]) {
    assert.match(text, new RegExp(`(?:send|sendToNative)\\([\\"']${type}[\\"']`), type);
  }
});

test("obsolete per-site LNA remediation is absent from extension UI", async () => {
  const text = ["content.js", "popup.js", "popup.html", "popup.css"]
    .map((name) => source(name));
  const combined = (await Promise.all(text)).join("\n");
  assert.doesNotMatch(combined, /lnaBlocked|Apps on Device|Loopback Network|siteDetails|\.lna\b/i);
});

test("tests and development package metadata are not shipped in extension directory", async () => {
  const files = await readdir(extensionRoot, { withFileTypes: true });
  assert.equal(files.some((entry) => entry.name === "tests"), false);
  assert.equal(files.some((entry) => entry.name === "package.json"), false);
});
