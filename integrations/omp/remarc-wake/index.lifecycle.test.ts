
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

function makeCtx(
	sid: string,
	transcriptFile: string | null = null,
	isIdle: () => boolean = () => true,
): StubCtx {
	const notifications: [string, string][] = [];
	return {
		mode: "tui",
		isIdle,
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
	process.env.REMARC_WAKE_PENDING_TTL_MS = "1000";
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

test("resume conflict preserves a live ownerless legacy marker", async () => {
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
	assert.equal(
		own?.wakeCapable,
		true,
		"a live legacy marker has unknown ownership and must remain untouched",
	);
	fs.rmSync(ownFile, { force: true });
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

test("unpair retries marker deletion after lock contention", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-unpair-lock");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-unpair-lock.json",
	);
	const releaseMarkerLock = await mod.acquireMarkerLock(markerFile);
	assert.ok(releaseMarkerLock);

	await commands["remarc-unpair"].handler("", ctx);
	releaseMarkerLock();
	await tick(700);

	assert.equal(
		fs.existsSync(markerFile),
		false,
		"an unpaired live process must not leave a wake-capable marker",
	);
});


test("shutdown does not cancel an in-flight unpair cleanup", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-unpair-shutdown");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-unpair-shutdown.json",
	);
	const releaseMarkerLock = await mod.acquireMarkerLock(markerFile);
	assert.ok(releaseMarkerLock);

	await commands["remarc-unpair"].handler("", ctx);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	releaseMarkerLock();
	await tick(700);

	assert.equal(
		fs.existsSync(markerFile),
		false,
		"shutdown must not cancel owner-guarded cleanup from unpair",
	);
});

test("a replacement pairing does not suppress old-marker retirement", async () => {
	writeComments([], SESSION_A);
	const oldCtx = makeCtx("sess-retire-old");
	await handlers.session_start(
		{ type: "session_start", reason: "startup" },
		oldCtx,
	);
	await commands["remarc-pair"].handler("", oldCtx);
	await tick(500);

	const markerDir = path.join(dir, "claude", "markers");
	const oldFile = path.join(markerDir, "omp-sess-retire-old.json");
	const releaseOldLock = await mod.acquireMarkerLock(oldFile);
	assert.ok(releaseOldLock);

	await commands["remarc-unpair"].handler("", oldCtx);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "new" },
		oldCtx,
	);

	writeComments([], SESSION_B);
	const newCtx = makeCtx("sess-retire-new");
	await handlers.session_start(
		{ type: "session_start", reason: "new" },
		newCtx,
	);
	await commands["remarc-pair"].handler("", newCtx);
	releaseOldLock();
	await tick(700);

	const newFile = path.join(markerDir, "omp-sess-retire-new.json");
	assert.equal(fs.existsSync(oldFile), false);
	assert.equal(mod.coerceMarker(mod.readJsonFile(newFile))?.wakeCapable, true);

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		newCtx,
	);
});

test("shutdown retries cleanup after every synchronous lock attempt times out", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-shutdown-lock");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-shutdown-lock.json",
	);
	const releaseMarkerLock = await mod.acquireMarkerLock(markerFile);
	assert.ok(releaseMarkerLock);

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "reload" },
		ctx,
	);
	releaseMarkerLock();
	await tick(700);

	assert.equal(
		fs.existsSync(markerFile),
		false,
		"shutdown must retire an owned marker after prolonged contention",
	);
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

test("failed cross-session re-pair retires the old marker", async () => {
	writeComments([], SESSION_A);
	const ctx = makeCtx("sess-repair-lock");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-repair-lock.json",
	);
	const releaseMarkerLock = await mod.acquireMarkerLock(markerFile);
	assert.ok(releaseMarkerLock);

	writeComments([], SESSION_B);
	await commands["remarc-pair"].handler("", ctx);
	releaseMarkerLock();
	await tick(700);

	assert.equal(
		fs.existsSync(markerFile),
		false,
		"a failed replacement must not leave the old pairing wake-capable",
	);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
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


test("dropped follow-up becomes eligible after the pending timeout", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-i");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	sent = [];
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 1);

	// No message_end arrives. After the test timeout, another file event must
	// make the same generation eligible again.
	await tick(1100);
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 2, "a dropped follow-up is retried");

	await handlers.session_shutdown({ type: "session_shutdown" }, ctx);
});

test("shutdown waits for an in-flight manual pair", async () => {
	writeComments([], SESSION_A);
	const ctx = makeCtx("sess-j");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	const markerDir = path.join(dir, "claude", "markers");
	const releasePairLock = await mod.acquireMarkerLock(
		path.join(markerDir, "pairing"),
	);
	assert.ok(releasePairLock);

	const pair = commands["remarc-pair"].handler("", ctx);
	await tick(50);
	let shutdownDone = false;
	const shutdown = Promise.resolve(
		handlers.session_shutdown(
			{ type: "session_shutdown", reason: "quit" },
			ctx,
		),
	).then(() => {
		shutdownDone = true;
	});
	await tick(100);
	const shutdownWaitedForPair = !shutdownDone;
	releasePairLock();
	await Promise.all([pair, shutdown]);
	assert.equal(shutdownWaitedForPair, true);

	const marker = mod.coerceMarker(
		mod.readJsonFile(path.join(markerDir, "omp-sess-j.json")),
	);
	assert.ok(
		marker === null || marker.wakeCapable === false,
		"shutdown cannot leave an in-flight pair wake-capable",
	);
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
			remarcSessionId: SESSION_B,
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
			ownerPid: 999_999_999,
			ownerToken: "dead-session-h",

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
test("replacement lifecycle operations remain FIFO", async () => {
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const oldFile = path.join(markerDir, "omp-sess-k.json");
	const newFile = path.join(markerDir, "omp-sess-l.json");
	for (const [file, pairing] of [
		[oldFile, SESSION_A],
		[newFile, SESSION_B],
	] as const) {
		fs.writeFileSync(
			file,
			JSON.stringify({
				harness: "omp",
				wakeCapable: false,
				remarcSessionId: pairing,
				ownerPid: 999_999_999,
				ownerToken: `dead-${pairing}`,
				lastActivity: new Date().toISOString(),
				transcriptPath: null,
				wakedAt: {},
			}),
		);
	}
	const releasePairLock = await mod.acquireMarkerLock(
		path.join(markerDir, "pairing"),
	);
	assert.ok(releasePairLock);
	const oldCtx = makeCtx("sess-k");
	const newCtx = makeCtx("sess-l");

	const oldStart = handlers.session_start(
		{ type: "session_start", reason: "startup" },
		oldCtx,
	);
	const oldShutdown = handlers.session_shutdown(
		{ type: "session_shutdown", reason: "resume" },
		oldCtx,
	);
	const newStart = handlers.session_start(
		{ type: "session_start", reason: "resume" },
		newCtx,
	);
	await tick(100);
	releasePairLock();
	await Promise.all([oldStart, oldShutdown, newStart]);

	assert.equal(mod.coerceMarker(mod.readJsonFile(oldFile))?.wakeCapable, false);
	assert.equal(mod.coerceMarker(mod.readJsonFile(newFile))?.wakeCapable, true);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		newCtx,
	);
});

test("a live process-instance owner blocks same-path resume", async () => {
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-m.json");
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: true,
			remarcSessionId: SESSION_A,
			ownerPid: process.pid,
			ownerToken: "foreign-extension-instance",
			lastActivity: new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	const ctx = makeCtx("sess-m");

	await handlers.session_start(
		{ type: "session_start", reason: "resume" },
		ctx,
	);

	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(marker?.ownerToken, "foreign-extension-instance");
	assert.equal(marker?.wakeCapable, true);
	assert.equal(
		ctx.ui.notifications.some(([message]) => message.includes("armed")),
		false,
	);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	assert.ok(fs.existsSync(markerFile), "shutdown cannot delete another owner");
	fs.rmSync(markerFile, { force: true });
});

test("resume claims a same-path marker whose leased owner is dead", async () => {
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-dead-owner.json");
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: true,
			remarcSessionId: SESSION_A,
			ownerPid: 999_999_999,
			ownerToken: "dead-instance",
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);

	const ctx = makeCtx("sess-dead-owner");
	await handlers.session_start({ type: "session_start", reason: "resume" }, ctx);
	await tick(500);

	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(marker?.ownerPid, process.pid);
	assert.notEqual(marker?.ownerToken, "dead-instance");
	assert.ok(ctx.ui.notifications.some(([message]) => message.includes("armed")));

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
});

test("an ownerless same-path marker requires explicit pairing", async () => {
	writeComments([], SESSION_A);
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-n.json");
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: true,
			remarcSessionId: SESSION_A,
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	const ctx = makeCtx("sess-n");

	await handlers.session_start(
		{ type: "session_start", reason: "resume" },
		ctx,
	);

	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(marker?.ownerToken, undefined);
	assert.equal(marker?.wakeCapable, true);
	assert.equal(
		ctx.ui.notifications.some(([message]) => message.includes("armed")),
		false,
	);

	await commands["remarc-pair"].handler("", ctx);
	const claimed = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(typeof claimed?.ownerToken, "string");
	assert.equal(claimed?.wakeCapable, true);

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
});

test("manual pair does not overwrite a foreign same-path marker", async () => {
	writeComments([], SESSION_A);
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-foreign-harness.json");
	const foreign = {
		harness: "claude",
		wakeCapable: true,
		remarcSessionId: SESSION_A,
		lastActivity: new Date().toISOString(),
		transcriptPath: null,
		wakedAt: {},
	};
	fs.writeFileSync(markerFile, JSON.stringify(foreign));
	const ctx = makeCtx("sess-foreign-harness");

	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);

	assert.deepEqual(mod.readJsonFile(markerFile), foreign);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	fs.rmSync(markerFile, { force: true });
});

test("manual pair does not overwrite a mismatched same-path pairing", async () => {
	writeComments([], SESSION_B);
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-mismatched-pairing.json");
	const mismatched = {
		harness: "omp",
		wakeCapable: false,
		remarcSessionId: SESSION_A,
		lastActivity: new Date().toISOString(),
		transcriptPath: null,
		wakedAt: {},
	};
	fs.writeFileSync(markerFile, JSON.stringify(mismatched));
	const ctx = makeCtx("sess-mismatched-pairing");

	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);

	assert.deepEqual(mod.readJsonFile(markerFile), mismatched);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	fs.rmSync(markerFile, { force: true });
});

test("an armed instance stops after its marker is taken over", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-o");
	await handlers.session_start(
		{ type: "session_start", reason: "startup" },
		ctx,
	);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);
	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-o.json",
	);
	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.ok(marker);
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			...marker,
			ownerPid: process.pid,
			ownerToken: "replacement-instance",
		}),
	);

	sent = [];
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 0, "the replaced owner cannot emit");
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerFile))?.ownerToken,
		"replacement-instance",
	);
	fs.rmSync(markerFile, { force: true });
});

test("shutdown never overwrites a disabled foreign same-path owner", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-disabled-owner");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-disabled-owner.json",
	);
	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.ok(marker);
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			...marker,
			wakeCapable: false,
			ownerPid: process.pid,
			ownerToken: "replacement-instance",
		}),
	);

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	const after = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(after?.ownerToken, "replacement-instance");
	assert.equal(after?.wakeCapable, false);
	fs.rmSync(markerFile, { force: true });
});

test("shutdown never claims a disabled ownerless marker", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-disabled-ownerless");
	await handlers.session_start({ type: "session_start", reason: "startup" }, ctx);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-disabled-ownerless.json",
	);
	const marker = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.ok(marker);
	const ownerless = {
		...marker,
		wakeCapable: false,
	};
	delete ownerless.ownerPid;
	delete ownerless.ownerToken;
	fs.writeFileSync(markerFile, JSON.stringify(ownerless));

	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
	const after = mod.coerceMarker(mod.readJsonFile(markerFile));
	assert.equal(after?.ownerToken, undefined);
	assert.equal(after?.wakeCapable, false);
	fs.rmSync(markerFile, { force: true });
});

test("out-of-order acknowledgements cannot regress a wake generation", async () => {
	writeComments([]);
	const ctx = makeCtx("sess-p");
	await handlers.session_start(
		{ type: "session_start", reason: "startup" },
		ctx,
	);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	sent = [];
	writeComments([WAKE_COMMENT]);
	await tick(900);
	writeComments([{ ...WAKE_COMMENT, wakeRequestedAt: 800_000_001 }]);
	await tick(900);
	assert.equal(sent.length, 2);

	for (const delivery of [sent[1], sent[0]]) {
		handlers.message_end({
			type: "message_end",
			message: {
				role: "custom",
				customType: delivery.customType,
				content: delivery.content,
				display: true,
				details: delivery.details,
				timestamp: Date.now(),
			},
		});
		await tick(100);
	}
	const markerFile = path.join(
		dir,
		"claude",
		"markers",
		"omp-sess-p.json",
	);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerFile))?.wakedAt[WAKE_COMMENT.id],
		800_000_001,
	);

	writeComments([{ ...WAKE_COMMENT, wakeRequestedAt: 800_000_001 }]);
	await tick(900);
	assert.equal(sent.length, 2, "the latest generation remains deduplicated");
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
});

test("busy sessions wait until agent settlement before emitting", async () => {
	writeComments([]);
	let idle = false;
	const ctx = makeCtx("sess-q", null, () => idle);
	await handlers.session_start(
		{ type: "session_start", reason: "startup" },
		ctx,
	);
	await commands["remarc-pair"].handler("", ctx);
	await tick(500);

	sent = [];
	writeComments([WAKE_COMMENT]);
	await tick(900);
	assert.equal(sent.length, 0, "busy sessions cannot accumulate a follow-up");

	idle = true;
	handlers.agent_settled({ type: "agent_settled" }, ctx);
	await tick(500);
	assert.equal(sent.length, 1);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
});

test("resume retries after pairing-lock contention clears", async () => {
	const markerDir = path.join(dir, "claude", "markers");
	fs.mkdirSync(markerDir, { recursive: true });
	const markerFile = path.join(markerDir, "omp-sess-r.json");
	fs.writeFileSync(
		markerFile,
		JSON.stringify({
			harness: "omp",
			wakeCapable: false,
			remarcSessionId: SESSION_A,
			ownerPid: 999_999_999,
			ownerToken: "dead-session-r",
			lastActivity: new Date().toISOString(),
			transcriptPath: null,
			wakedAt: {},
		}),
	);
	const releasePairLock = await mod.acquireMarkerLock(
		path.join(markerDir, "pairing"),
	);
	assert.ok(releasePairLock);
	const ctx = makeCtx("sess-r");

	await handlers.session_start(
		{ type: "session_start", reason: "resume" },
		ctx,
	);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerFile))?.wakeCapable,
		false,
	);
	releasePairLock();
	await tick(500);
	assert.equal(
		mod.coerceMarker(mod.readJsonFile(markerFile))?.wakeCapable,
		true,
	);
	await handlers.session_shutdown(
		{ type: "session_shutdown", reason: "quit" },
		ctx,
	);
});
after(async () => {
	await handlers.session_shutdown({ type: "session_shutdown" });
	fs.rmSync(dir, { recursive: true, force: true });
});
