import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const contentSource = await readFile(
  new URL("../../extension/content.js", import.meta.url),
  "utf8"
);

test("content messages cross the worker boundary in native-message wrappers", () => {
  const wrappedSends = contentSource.match(
    /sendRuntimeMessage\(\{ type: "native-message", envelope \}/g
  ) || [];

  assert.equal(wrappedSends.length, 2, "queued captures and unqueued activity must both be wrapped");
  assert.match(contentSource, /const envelope = \{ type, data \};/);
  assert.doesNotMatch(contentSource, /sendRuntimeMessage\(envelope/);
});

test("the FIFO distinguishes delivery, permanent rejection, and disconnect", () => {
  assert.match(contentSource, /response\?\.delivered === true/);
  assert.match(contentSource, /response\?\.rejected === true/);
  assert.match(
    contentSource,
    /function cancelCaptureInteractions\(\) \{[\s\S]*?pendingMessages = \[\];[\s\S]*?exitGrabMode\(\);/
  );
  assert.match(contentSource, /nudgeBridge\(\);/);
});

test("persisted Pause starts fail-closed before asynchronous storage resolves", () => {
  assert.match(contentSource, /let extensionEnabled = false;/);
  assert.match(
    contentSource,
    /extensionEnabled = result\.extensionEnabled !== false;/
  );
});

test("bridge state callbacks carry a worker session and monotonic epoch", () => {
  assert.match(contentSource, /let bridgeInstanceId = null;/);
  assert.match(contentSource, /if \(incomingEpoch <= bridgeStateEpoch\) return false;/);
  assert.match(contentSource, /incomingInstanceId: state\.bridgeInstanceId/);
  assert.match(contentSource, /incomingEpoch: msg\.bridgeStateEpoch/);
});
