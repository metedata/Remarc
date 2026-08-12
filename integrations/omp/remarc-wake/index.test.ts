/**
 * Protocol tests for remarc-wake. Run: node --test index.test.ts
 *
 * Node 26 runs type-stripped TS natively; keep to erasable syntax here and in
 * index.ts so this works without a build step.
 */

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, test } from "node:test";

import {
	buildWakePayload,
	coerceMarker,
	liveMarkersRanked,
	markerIsLive,
	notYetWaked,
	sessionKeyOf,
	updateMarker,
	wakeCandidates,
	WAKE_MAX_CHARS,
	WAKE_MAX_COMMENTS,
	type CommentsFile,
	type RemarcComment,
	type RemarcSession,
} from "./index.ts";

function tmpdir(prefix = "remarc-wake-test-"): string {
	return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

const BASE_COMMENT: RemarcComment = {
	id: "11111111-1111-4111-8111-111111111111",
	sessionID: "22222222-2222-4222-8222-222222222222",
	commentText: "hello",
	status: "handedOff",
	wakeRequestedAt: 800_000_000, // Apple reference-date seconds
	isDeleted: false,
};

describe("wakeCandidates", () => {
	test("filters: handedOff + numeric wakeRequestedAt + not deleted", () => {
		const file: CommentsFile = {
			comments: [
				BASE_COMMENT,
				{ ...BASE_COMMENT, id: "a", status: "open" },
				{ ...BASE_COMMENT, id: "b", isDeleted: true },
				{ ...BASE_COMMENT, id: "c", wakeRequestedAt: undefined },
				{ ...BASE_COMMENT, id: "d", status: "resolved" },
				{ ...BASE_COMMENT, id: "e" },
			],
		};
		const got = wakeCandidates(file).map((c) => c.id);
		assert.deepEqual(got, [BASE_COMMENT.id, "e"]);
	});
});

describe("notYetWaked generations", () => {
	const marker = (wakedAt: Record<string, number>) =>
		coerceMarker({ harness: "omp", remarcSessionId: "s", wakedAt })!;

	test("re-wake works when wakeRequestedAt advances past the recorded generation", () => {
		const m = marker({ [BASE_COMMENT.id]: 100 });
		assert.deepEqual(
			notYetWaked([{ ...BASE_COMMENT, wakeRequestedAt: 100 }], m),
			[],
		);
		assert.equal(
			notYetWaked([{ ...BASE_COMMENT, wakeRequestedAt: 101 }], m).length,
			1,
		);
	});

	test("legacy wakedIds migrate to generation 0 (one benign re-wake)", () => {
		const m = coerceMarker({
			harness: "omp",
			remarcSessionId: "s",
			wakedIds: [BASE_COMMENT.id],
		})!;
		assert.equal(notYetWaked([BASE_COMMENT], m).length, 1);
	});
});

describe("marker lock + updateMarker", () => {
	test("concurrent updates do not lose writer data", async () => {
		const dir = tmpdir();
		const file = path.join(dir, "m.json");
		// ten writers increment the same counter through the lock
		await Promise.all(
			Array.from({ length: 10 }, () =>
				updateMarker(file, (onDisk) => {
					const prev = onDisk ?? {
						harness: "omp",
						remarcSessionId: "s",
						wakedAt: {},
					};
					return {
						...prev,
						counter: ((prev.counter as number | undefined) ?? 0) + 1,
					};
				}),
			),
		);
		const final = JSON.parse(fs.readFileSync(file, "utf8"));
		assert.equal(final.counter, 10);
		fs.rmSync(dir, { recursive: true, force: true });
	});

	test("abandoned lock with dead pid is reclaimed", async () => {
		const dir = tmpdir();
		const file = path.join(dir, "m.json");
		const lockDir = `${file}.lock`;
		fs.mkdirSync(lockDir, { recursive: true });
		fs.writeFileSync(
			path.join(lockDir, "owner.json"),
			JSON.stringify({ pid: 999_999_999, at: Date.now() }),
		);
		// Ancient mtime makes the lock stale regardless of pid liveness.
		const longAgo = new Date(Date.now() - 60_000);
		fs.utimesSync(lockDir, longAgo, longAgo);
		const ok = await updateMarker(file, (d) => d ?? { wakedAt: {}, remarcSessionId: "s", harness: "omp" });
		assert.equal(ok, "written");
		fs.rmSync(dir, { recursive: true, force: true });
	});

	test("lock owned by a LIVE process is never reclaimed, even when stale", async () => {
		const dir = tmpdir();
		const file = path.join(dir, "m.json");
		const lockDir = `${file}.lock`;
		fs.mkdirSync(lockDir, { recursive: true });
		// owner.json names OUR pid (alive); mtime is ancient. Vendored semantics:
		// readable owner + live pid beats staleness.
		fs.writeFileSync(
			path.join(lockDir, "owner.json"),
			JSON.stringify({ pid: process.pid, at: Date.now() - 60_000 }),
		);
		const longAgo = new Date(Date.now() - 60_000);
		fs.utimesSync(lockDir, longAgo, longAgo);
		const result = await updateMarker(file, () => ({ touched: true }));
		assert.equal(result, "timeout"); // we waited and gave up instead
		assert.ok(fs.existsSync(lockDir)); // and never stole the lock
		fs.rmSync(dir, { recursive: true, force: true });
	});
});

describe("patch-only liveness write (stale-memory safety)", () => {
	test("a heartbeat never erases wakedAt recorded by a concurrent drain", async () => {
		const dir = tmpdir();
		const file = path.join(dir, "m.json");
		// create pairing
		await updateMarker(file, () => ({
			harness: "omp",
			remarcSessionId: "s",
			dataFilePath: "/tmp/comments.json",
			transcriptPath: null,
			lastActivity: new Date().toISOString(),
			wakeCapable: true,
			deliveredIds: [],
			wakedAt: {},
		}));
		// drain records a generation
		await updateMarker(file, (onDisk) => ({
			...(onDisk as unknown as Record<string, unknown>),
			wakedAt: { [BASE_COMMENT.id]: 800_000_000 },
		}));
		// heartbeat with an m snapshot captured BEFORE the drain: patch-only
		// semantics write wakeCapable/lastActivity onto disk state, keeping wakedAt.
		const staleMem = {
			harness: "omp",
			remarcSessionId: "s",
			wakedAt: {},
		};
		await updateMarker(file, (onDisk) => {
			if (!onDisk || onDisk.remarcSessionId !== "s") return null;
			return {
				...onDisk,
				harness: staleMem.harness,
				wakeCapable: true,
				lastActivity: new Date().toISOString(),
			};
		});
		const final = coerceMarker(JSON.parse(fs.readFileSync(file, "utf8")))!;
		assert.equal(final.wakedAt[BASE_COMMENT.id], 800_000_000);
		fs.rmSync(dir, { recursive: true, force: true });
	});
});

describe("buildWakePayload", () => {
	const sessions: RemarcSession[] = [
		{ id: BASE_COMMENT.sessionID, name: "design pass" },
	];

	test("sentinel-wrapped, capped at N comments, total under maxChars", () => {
		const many = Array.from({ length: 20 }, (_, i) => ({
			...BASE_COMMENT,
			id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
		}));
		const p = buildWakePayload(many, sessions)!;
		assert.equal(p.emitted.length, WAKE_MAX_COMMENTS);
		assert.ok(p.text.length <= WAKE_MAX_CHARS); // wrapper + truncation slack
		assert.match(p.text, /<<<REMARC-DATA-[0-9a-f]{8}>>>/);
		assert.match(p.text, /design pass/);
		assert.ok(!p.text.includes("not-included-comment"));
	});

	test("single oversized comment truncates with fetch pointer and is emitted", () => {
		const huge = { ...BASE_COMMENT, commentText: "x".repeat(10_000) };
		const p = buildWakePayload([huge], sessions)!;
		assert.equal(p.emitted.length, 1);
		assert.match(p.text, /TRUNCATED/);
		assert.ok(p.text.length <= WAKE_MAX_CHARS);
	});

	test("comments beyond the budget are NOT emitted (wake later)", () => {
		const comments = Array.from({ length: 8 }, (_, i) => ({
			...BASE_COMMENT,
			id: `00000000-0000-4000-8000-0000000000${i}0`,
			commentText: "y".repeat(1500),
		}));
		const p = buildWakePayload(comments, sessions)!;
		assert.ok(p.emitted.length < comments.length);
		assert.ok(p.text.length <= WAKE_MAX_CHARS);
	});
});

describe("markerIsLive + liveMarkersRanked", () => {
	test("ranks wake-capable live markers, skips dead/uncapable", () => {
		const dir = tmpdir();
		const transcript = path.join(dir, "t.jsonl");
		fs.writeFileSync(transcript, "{}");
		fs.writeFileSync(
			path.join(dir, "old.json"),
			JSON.stringify({
				wakeCapable: true,
				lastActivity: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
			}),
		);
		fs.writeFileSync(
			path.join(dir, "dead.json"),
			JSON.stringify({
				wakeCapable: true,
				lastActivity: new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString(),
			}),
		);
		fs.writeFileSync(
			path.join(dir, "off.json"),
			JSON.stringify({
				wakeCapable: false,
				lastActivity: new Date().toISOString(),
			}),
		);
		const ranked = liveMarkersRanked(dir).map((m) => path.basename(m.file));
		assert.deepEqual(ranked, ["old.json"]); // dead and off excluded
		fs.rmSync(dir, { recursive: true, force: true });
	});

	test("uses PID liveness for leased markers regardless of activity time", () => {
		const dir = tmpdir();
		fs.writeFileSync(
			path.join(dir, "live-stale.json"),
			JSON.stringify({
				wakeCapable: true,
				ownerPid: process.pid,
				ownerToken: "live",
				lastActivity: new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString(),
			}),
		);
		fs.writeFileSync(
			path.join(dir, "dead-fresh.json"),
			JSON.stringify({
				wakeCapable: true,
				ownerPid: 999_999_999,
				ownerToken: "dead",
				lastActivity: new Date().toISOString(),
			}),
		);

		const ranked = liveMarkersRanked(dir).map((marker) =>
			path.basename(marker.file),
		);
		assert.deepEqual(ranked, ["live-stale.json"]);
		fs.rmSync(dir, { recursive: true, force: true });
	});
});

describe("Sol review findings coverage", () => {
	test("long session names cannot strand the payload", () => {
		const hugeName = "z".repeat(6000);
		const p = buildWakePayload(
			[BASE_COMMENT],
			[{ id: BASE_COMMENT.sessionID, name: hugeName }],
		)!;
		assert.ok(p);
		assert.equal(p.emitted.length, 1);
		assert.ok(p.text.length <= WAKE_MAX_CHARS);
	});

	test("legacy stackID-only comments are wake-eligible (vendored fallback)", () => {
		const legacy = { ...BASE_COMMENT, sessionID: undefined, stackID: "s1" } as unknown as RemarcComment;
		const scoped = wakeCandidates({ comments: [legacy] }).filter(
			(c) => sessionKeyOf(c) === "s1",
		);
		assert.equal(scoped.length, 1);
	});

	test("updateMarker distinguishes noop from written", async () => {
		const dir = tmpdir();
		const file = path.join(dir, "m.json");
		const r1 = await updateMarker(file, () => null);
		assert.equal(r1, "noop");
		assert.ok(!fs.existsSync(file));
		const r2 = await updateMarker(file, () => ({ harness: "omp", remarcSessionId: "s", wakedAt: {} }));
		assert.equal(r2, "written");
		fs.rmSync(dir, { recursive: true, force: true });
	});
});
