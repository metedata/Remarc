
/**
 * Lifecycle tests: drive the extension's handlers directly against a fake
 * pi + a temp REMARC_WAKE_DIR. Exception to the static-import rule: the
 * module computes its data paths from REMARC_WAKE_DIR at import time, so the
 * env var MUST be set before import - this file is a deliberate module
 * loading-boundary test. Timer exception: this is an integration test of a
 * real fs.watch/poll pipeline; the advisor's deterministic-clock alternatives
 * cannot drive macOS fs events.
 */

import type * as WakeModule from "./index.ts";

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

interface StubCtx {
	mode: string;
	isIdle(): boolean;
	sessionManager: { getSessionFile(): string | null; getSessionId(): string };
	ui: { notifications: [string, string][]; notify(m: string, t?: string): void };
}

function makeCtx(sid: string, transcriptFile: string | null = null): StubCtx {
	const notifications: [string, string][] = [];
	return {
		mode: "tui",
		isIdle: () => true,
		sessionManager: {
			getSessionFile: () => transcriptFile,
			getSessionId: () => sid,
		},
		ui: {
			notifications,
			notify(m: string, t = "info") {
				notifications.push([m, t]);
			},
		},
	};
}

let dir: string;
let mod: typeof WakeModule;

let handlers: Record<string, (...a: never[]) => unknown>;
let commands: Record<string, { handler: (args: string, ctx: unknown) => Promise<void> }>;
let sent: { customType?: string; content: unknown; details?: unknown; options: unknown }[];
let ackSynchronously: boolean;

const SESSION_B = "33333333-3333-4333-8333-333333333333";
const SESSION_A = "22222222-2222-4222-8222-222222222222";

function writeComments(comments: object[], active = SESSION_A): void {
	fs.writeFileSync(
		path.join(dir, "comments.json"),
		JSON.stringify({
			activeSessionID: active,
			sessions: [{ id: active, name: "inbox" }],
			comments,
		}),
	);
}

const WAKE_COMMENT = {
	id: "11111111-1111-4111-8111-111111111111",
	sessionID: SESSION_A,
	commentText: "wake me",
	status: "handedOff",
	wakeRequestedAt: 800_000_000,
	isDeleted: false,
};

before(async () => {
	dir = fs.mkdtempSync(path.join(os.tmpdir(), "rw-life-"));
	process.env.REMARC_WAKE_DIR = dir;
	mod = await import("./index.ts");
	handlers = {};
	commands = {};
	sent = [];
	ackSynchronously = false;
	const pi = {
		on(event: string, fn: unknown) {
			handlers[event] = fn as (...a: never[]) => unknown;
		},
		registerCommand(name: string, def: never) {
			commands[name] = def;
		},
		sendMessage(
			msg: { customType?: string; content?: unknown; details?: unknown },
			options: unknown,
		) {
			sent.push({
				customType: msg.customType,
				content: msg.content,
				details: msg.details,
				options,
			});
			if (ackSynchronously) {
				handlers.message_end({
					type: "message_end",
					message: {
						role: "custom",
						customType: msg.customType,
						content: msg.content,
						display: true,
						details: msg.details,
						timestamp: Date.now(),
					},
				});
			}
		},
	};
	mod.default(pi as never);
});

function tick(ms = 50): Promise<void> {
	return new Promise((r) => setTimeout(r, ms));
}

test("pair -> wake -> correlated message ack -> shutdown disables", async () => {
	writeComments([]); // pair requires the data file to exist
	const ctx = makeCtx("sess-a");
	handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await tick();
	await commands["remarc-pair"].handler("", ctx);
	await tick(500); // pair lock + marker write + arm

	// marker exists and advertises
	const markerPath = path.join(dir, "claude", "markers", "omp-sess-a.json");
	const armed = mod.coerceMarker(mod.readJsonFile(markerPath));
	assert.equal(armed?.wakeCapable, true, JSON.stringify(armed));
	assert.equal(armed?.remarcSessionId, SESSION_A);

	// A real sendMessage can emit message_end synchronously. The extension
	// must register correlated pending state before the call.
	ackSynchronously = true;
	writeComments([WAKE_COMMENT]);
	await tick(900); // debounce + backoff + emit + correlated record
	ackSynchronously = false;
	assert.equal(sent.length, 1, "wake message emitted");
	assert.ok(String(sent[0].content).includes(WAKE_COMMENT.id));
	assert.ok(String(sent[0].content).includes("REMARC-DATA-"));
	const deliveryDetails = sent[0].details;
	assert.ok(
		deliveryDetails !== null &&
			typeof deliveryDetails === "object" &&
			"deliveryId" in deliveryDetails &&
			typeof deliveryDetails.deliveryId === "string",
	);

	const m1 = mod.coerceMarker(mod.readJsonFile(markerPath))!;
	assert.equal(
		m1.wakedAt[WAKE_COMMENT.id],
		800_000_000,
		"synchronous correlated message_end records the emitted generation",
	);

	// re-waking the same comment with a NEWER generation delivers again
	sent = [];
	writeComments([{ ...WAKE_COMMENT, wakeRequestedAt: 800_000_500 }]);
	await tick(900);
	assert.equal(sent.length, 1, "re-wake on newer generation");

	// shutdown flips wakeCapable off, ON DISK, awaited
	await handlers.session_shutdown({ type: "session_shutdown" }, ctx);
	await tick(300);
	const off = mod.coerceMarker(mod.readJsonFile(markerPath));
	assert.equal(off?.wakeCapable, false);
	assert.equal(Object.keys(off?.wakedAt ?? {}).length >= 1, true, "wakedAt survives for resume");
});

test("resume conflict disables the old wake-capable marker", async () => {
	fs.mkdirSync(path.join(dir, "claude", "markers"), { recursive: true });
	const ownFile = path.join(dir, "claude", "markers", "omp-sess-b.json");
	fs.writeFileSync(
		ownFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: true,
			remarcSessionId: SESSION_A,
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	fs.writeFileSync(
		path.join(dir, "claude", "markers", "other.json"),
		JSON.stringify({
			harness: "omp",
			wakeCapable: true,
			remarcSessionId: SESSION_A,
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);

	const ctxB = makeCtx("sess-b");
	handlers.session_start({ type: "session_start", reason: "startup" }, ctxB);
	await tick(500);
	const own = mod.coerceMarker(mod.readJsonFile(ownFile));
	assert.ok(
		own === null || own.wakeCapable === false,
		"a refused resume must not leave a dead target wake-capable",
	);
});

test("unpair deletes only our own marker and stops delivery", async () => {
	fs.rmSync(path.join(dir, "claude", "markers", "other.json"), { force: true });
	writeComments([]);
	fs.mkdirSync(path.join(dir, "claude", "markers"), { recursive: true });
	const ctxC = makeCtx("sess-c");
	handlers.session_start({ type: "session_start", reason: "startup" }, ctxC);
	await tick(100);
	await commands["remarc-pair"].handler("", ctxC);
	await tick(500);
	const fileC = path.join(dir, "claude", "markers", "omp-sess-c.json");
	assert.ok(fs.existsSync(fileC));

	sent = [];
	await commands["remarc-unpair"].handler("", ctxC);
	await tick(400);
	assert.ok(!fs.existsSync(fileC));

	// wake after unpair: nothing is delivered anywhere from ctxC
	writeComments([{ ...WAKE_COMMENT, wakeRequestedAt: 800_001_000 }]);
	await tick(900);
	assert.equal(sent.length, 0);
});


test("re-pair with the same session is a no-op (marker stays armed)", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-d");
	handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await tick(100);
	await commands["remarc-pair"].handler("", ctx);
	await tick(700);
	const fileD = path.join(dir, "claude", "markers", "omp-sess-d.json");
	const first = mod.coerceMarker(mod.readJsonFile(fileD));
	assert.equal(first?.wakeCapable, true);
	const firstActivity = first?.lastActivity;

	await commands["remarc-pair"].handler("", ctx);
	await tick(400);
	const second = mod.coerceMarker(mod.readJsonFile(fileD));
	assert.equal(second?.wakeCapable, true); // not flipped to false
	assert.equal(second?.remarcSessionId, SESSION_A);
	assert.ok(ctx.ui.notifications.some(([m]) => m.includes("already paired")));
	assert.equal(second?.lastActivity, firstActivity); // genuinely untouched

	await handlers.session_shutdown({ type: "session_shutdown" }, ctx);
	await tick(300);
});


test("unacknowledged delivery is not queued again", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-e");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	sent = [];
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 1);

	// The same generation changes the file again before message_end.
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 1, "one unacknowledged generation queues once");

	const markerPath = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-e.json",
	);
	handlers.message_end({
		type: "message_end",
		message: { role: "user", content: "unrelated", timestamp: Date.now() },
	});
	handlers.message_end({
		type: "message_end",
		message: {
			role: "custom",
			customType: "remarc-wake",
			content: "wrong delivery",
			display: true,
			details: { deliveryId: "wrong-id" },
			timestamp: Date.now(),
		},
	});
	await tick(200);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerPath))?.wakedAt[WAKE_COMMENT.id],
		undefined,
	);

	handlers.message_end({
		type: "message_end",
		message: {
			role: "custom",
			customType: sent[0].customType,
			content: sent[0].content,
			display: true,
			details: sent[0].details,
			timestamp: Date.now(),
		},
	});
	await tick(500);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerPath))?.wakedAt[WAKE_COMMENT.id],
		WAKE_COMMENT.wakeRequestedAt,
	);

	await handlers.session_shutdown({ type: "session_shutdown" }, ctx);
});

test("manual pair waits for startup resume and changes ownership cleanly", async () => {
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-f.json");
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: false,
			remarcSessionId: SESSION_A,
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	writeComments([], SESSION_B);
	const ctx = makeCtx("sess-f");

	const releasePairLock = await mod.acquireMarkerLock(
		path.join(markerDir, "pairing"),
	);
	assert.ok(releasePairLock);
	let resume: unknown;
	let pair = Promise.resolve();
	try {
		resume = handlers.session_start(
			{ type: "session_start", reason: "startup" },
			ctx,
		);
		pair = commands["remarc-pair"].handler("", ctx);
	} finally {
		releasePairLock();
	}
	await Promise.all([resume, pair]);
	await tick(700);
	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(marker?.wakeCapable, true);
	assert.equal(marker?.remarcSessionId, SESSION_B);

	sent = [];
	writeComments([{ ...WAKE_COMMENT, sessionID: SESSION_B }], SESSION_B);
	await tick(900);
	assert.equal(sent.length, 1, "the new pairing has the active delivery loop");

	await handlers.session_shutdown({ type: "session_shutdown" }, ctx);
});
test("session replacement disables the old marker and resumes the new one", async () => {
	writeComments([], SESSION_A);
	const oldCtx = makeCtx("sess-g");
	await handlers.session_start(
		{ type: "session_start", reason: "startup" },
		oldCtx,
	);
	await commands["remarc-pair"].handler("", oldCtx);
	await tick(500);
	const markerDir = path.join(dir, "claude", "markers");
	const oldFile = path.join(markerDir, "omp-sess-g.json");
	assert.equal(mod.coerceMarker(mod.readJsonFile(oldFile))?.wakeCapable, true);

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "resume" },
		oldCtx,
	);
	assert.equal(mod.coerceMarker(mod.readJsonFile(oldFile))?.wakeCapable, false);

	const newFile = path.join(markerDir, "omp-sess-h.json");
	fs.writeFileSync(
		newFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: false,
			remarcSessionId: SESSION_B,
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	const newCtx = makeCtx("sess-h");
	await handlers.session_start(
		{ type: "session_start", reason: "resume", previousSessionFile: "old.jsonl" },
		newCtx,
	);
	assert.equal(mod.coerceMarker(mod.readJsonFile(newFile))?.wakeCapable, true);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		newCtx,
	);
});
after(async () => {
	await handlers.session_shutdown({ type: "session_shutdown" });
	fs.rmSync(dir, { recursive: true, force: true });
});
