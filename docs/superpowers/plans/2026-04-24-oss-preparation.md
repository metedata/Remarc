# Remarc Open Source Preparation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the Remarc repository to be published publicly on GitHub (MIT licensed, no CLA) with the safety, documentation, and automation needed for a credible open-source launch.

**Architecture:** All work happens in worktree `.worktrees/oss-prep` on branch `chore/oss-preparation`. Execution is local-only; the final push to public GitHub is gated on user approval after review.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Sparkle, Cloudflare R2, Supabase, GitHub Actions (macos-26 runner), MIT license.

---

## Assumed Decisions (lock in before execution)

- **License:** MIT
- **CLA:** none (DCO-style trust-on-submission)
- **Scope:** whole repo public (Mac app + `mcp/` + `extension/` + `supabase/` + `website/`). Callouts required for any internal-only content before push.
- **GitHub org + repo:** `github.com/metedata/Remarc` (already referenced in `appcast.xml`)
- **Trademark:** "Remarc" name and icon are NOT covered by MIT license. Explicit notice in README.

---

## Phase 1: Secrets audit (highest risk, do first)

**Files:** n/a (read-only audit)

- [ ] **1.1 Install gitleaks**

```bash
brew install gitleaks 2>/dev/null || true
which gitleaks
```

- [ ] **1.2 Scan full git history for secrets**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
gitleaks detect --no-banner --redact --report-format json --report-path /tmp/gitleaks-report.json || true
cat /tmp/gitleaks-report.json | jq 'length'
```

Expected: review findings. Anything flagged must be triaged (false positive, scrub from history, or start fresh).

- [ ] **1.3 Manual pattern sweep**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
rg -n --hidden --glob '!.git' --glob '!node_modules' --glob '!*.lock' \
  -e 'sk_live' -e 'sk_test' -e 'pk_live' \
  -e 'SUPABASE_SERVICE_ROLE_KEY' -e 'supabase.co' \
  -e 'BEGIN PRIVATE KEY' -e 'BEGIN CERTIFICATE' \
  -e 'api[_-]?key.*=.*["'\''][A-Za-z0-9]{20,}' \
  -e 'sentry.io/[0-9]+' \
  -e 'lemonsqueezy' \
  -e '/Users/example/' \
  || true
```

Triage each hit: is it a legitimate reference (env var name, example) or a real secret?

- [ ] **1.4 Git history grep for sensitive patterns**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
git log --all -p -S 'SUPABASE_SERVICE_ROLE_KEY' --oneline | head -20
git log --all -p -S 'api_key' --oneline | head -20
git log --all -p -S 'sk_live' --oneline | head -20
git log --all --full-history -- '*.p12' '*.p8' '*.provisionprofile' '*.env' | head -20
```

- [ ] **1.5 Report findings to user, decide path forward**

If clean: proceed. If history contaminated: decide between `git filter-repo` scrub vs fresh repo init. STOP here for user decision if anything is found.

---

## Phase 2: Internal-only content relocation

Internal planning/bug-tracker docs should not be in the public repo root.

**Files:**
- Delete/relocate: `Improvements.md`, `cheerful-drifting-kitten.md`
- Possibly relocate: `DESIGN.md`, `docs/pricing-and-licensing.md`

- [ ] **2.1 Move `Improvements.md` to private internal tracker**

It's a bug list. Options: (a) convert to GitHub Issues post-launch, (b) move to `docs/internal/improvements.md` and add `docs/internal/` to `.gitignore`, (c) delete. Pick (b) for this pass to preserve content without exposing it.

```bash
cd $REPO_ROOT/.worktrees/oss-prep
mkdir -p docs/internal
git mv Improvements.md docs/internal/improvements.md
```

- [ ] **2.2 Move `cheerful-drifting-kitten.md` to docs/internal/**

Legacy implementation plan. Keep for reference but out of public view.

```bash
git mv cheerful-drifting-kitten.md docs/internal/initial-implementation-plan.md
```

- [ ] **2.3 Review `DESIGN.md`**

Read the first 50 lines. If it's product vision / roadmap it's fine public. If it has confidential strategy, move to `docs/internal/`. Default: keep public.

- [ ] **2.4 Review `docs/pricing-and-licensing.md`**

Given the free-pivot, this may be outdated. Move to `docs/internal/` to avoid confusing the public about pricing.

```bash
git mv docs/pricing-and-licensing.md docs/internal/pricing-and-licensing-historical.md
```

- [ ] **2.5 Add `docs/internal/` to `.gitignore`** (NO — we WANT these tracked privately, not ignored. Instead: keep them tracked but acknowledge they are private-historical docs.)

Skip the gitignore entry. Files under `docs/internal/` stay tracked but are clearly labeled as historical/internal. Better approach is just delete if truly unwanted, but moving preserves history.

Actually: for this phase, just move the files. They'll be committed and visible in the public repo under `docs/internal/` — that's fine, since they document history. If anything in them is truly sensitive (keys, customer data), that would be caught by Phase 1.

- [ ] **2.6 Commit phase 2**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
git add -A
git commit -m "chore(oss): relocate internal-only docs under docs/internal/"
```

---

## Phase 3: Public-facing documentation

**Files:**
- Create: `LICENSE`
- Create: `README.md`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`

- [ ] **3.1 Create `LICENSE` (MIT)**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
```

Content: standard MIT, copyright holder "Mete Polat", year 2026.

- [ ] **3.2 Create `README.md`**

Sections:
1. Title + one-line description
2. Screenshot/gif placeholder
3. Features (bullet list)
4. Install (download signed build from remarcapp.com or GitHub Releases)
5. Build from source (xcodebuild command, prerequisites)
6. Tech stack
7. Contributing (link to CONTRIBUTING.md)
8. Security (link to SECURITY.md)
9. License + trademark notice

- [ ] **3.3 Create `CONTRIBUTING.md`**

Sections:
1. Prerequisites (Xcode 26, macOS 14.4+)
2. Clone + build instructions
3. Project structure overview
4. Code style (Swift 6, no em dashes in copy, `remarc*` color tokens)
5. PR checklist (builds, launches, tested on current macOS)
6. How to sign locally for dev (ad-hoc sign with `-` identity, or self-signed cert)

- [ ] **3.4 Create `SECURITY.md`**

Critical for an app with accessibility + mic permissions.

Sections:
1. Supported versions (latest release only)
2. Reporting a vulnerability: email (metepolat.a@gmail.com), expected response SLA (7 days acknowledgement, 30 days fix for critical)
3. Scope (in-scope: the shipped app, `mcp/`, `supabase/functions/`; out-of-scope: Chrome extension if shipped via store, website static content)
4. Please do NOT open public GitHub Issues for vulnerabilities

- [ ] **3.5 Create `CHANGELOG.md`**

Start with a "Keep a Changelog"-style header. Backfill entries from git tags if easy, otherwise start from current version forward.

- [ ] **3.6 Commit phase 3**

```bash
git add LICENSE README.md CONTRIBUTING.md SECURITY.md CHANGELOG.md
git commit -m "docs(oss): add MIT LICENSE, public README, CONTRIBUTING, SECURITY, CHANGELOG"
```

---

## Phase 4: GitHub templates

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/feature_request.md`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

- [ ] **4.1 Create bug_report template**

Fields: macOS version, Remarc version, steps to reproduce, expected, actual, logs from `/tmp/remarc_debug.log`.

- [ ] **4.2 Create feature_request template**

Fields: problem, proposed solution, alternatives considered.

- [ ] **4.3 Create config.yml**

Disable blank issues. Add contact link to discussions (once created) and security policy.

- [ ] **4.4 Create pull request template**

Fields: summary, testing done, screenshots/gifs for UI changes, linked issues.

- [ ] **4.5 Commit phase 4**

```bash
git add .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE.md
git commit -m "chore(oss): add GitHub issue + PR templates"
```

---

## Phase 5: CI for PR builds (no signing)

**Files:**
- Create: `.github/workflows/ci.yml`

The existing `release.yml` handles signed release builds (workflow_dispatch only). We need an automatic PR build workflow that verifies the Swift package builds without requiring secrets.

- [ ] **5.1 Write `ci.yml`**

Triggers: `pull_request` on `main`. Runs on `macos-26`. Steps: checkout, select Xcode 26.2, `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath DerivedData CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.

- [ ] **5.2 Verify the ci.yml syntax**

```bash
# Use actionlint if available, else just syntax check
brew list actionlint >/dev/null 2>&1 || brew install actionlint
actionlint .github/workflows/ci.yml
```

- [ ] **5.3 Commit phase 5**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(oss): add pull request build workflow without signing"
```

---

## Phase 6: `.gitignore` completeness check

**Files:**
- Modify: `.gitignore`

- [ ] **6.1 Audit current `.gitignore` coverage**

Verify these patterns are covered:
- DerivedData/, build/
- .worktrees/
- *.p12, *.p8, *.provisionprofile
- .env, .env.*
- node_modules/ (for `mcp/` and `extension/`)
- mcp/dist/ (built artifact)
- .swiftpm/, .build/
- *.xcuserdata, xcuserdata/
- *.log, *_debug.log

- [ ] **6.2 Add missing patterns**

Currently missing (spot-checked): `node_modules/`, `mcp/dist/`. Add them.

- [ ] **6.3 Commit phase 6**

```bash
git add .gitignore
git commit -m "chore(oss): tighten .gitignore (node_modules, mcp/dist)"
```

---

## Phase 7: Trademark + copy review

- [ ] **7.1 Review README for trademark notice placement**

Verify README explicitly states: "The Remarc name, logo, and icon are trademarks of Mete Polat and are not licensed under the MIT license. Do not ship a fork under the Remarc name."

- [ ] **7.2 Scan copy for em dashes**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
rg -n '—' README.md CONTRIBUTING.md SECURITY.md CHANGELOG.md LICENSE || echo "clean"
```

Per CLAUDE.md style rule, replace any em dash (—) with a hyphen (-) in public-facing docs.

---

## Phase 8: Final review + hand-off

- [ ] **8.1 Verify build still passes in worktree**

```bash
cd $REPO_ROOT/.worktrees/oss-prep/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **8.2 Summary diff**

```bash
cd $REPO_ROOT/.worktrees/oss-prep
git log --oneline main..HEAD
git diff --stat main..HEAD
```

- [ ] **8.3 Present to user**

Report what was changed, what's still required from them (GitHub org creation if not exists, public push decision, website update). STOP. Do not push to remote without explicit approval.

---

## Self-review checklist

- [x] Spec coverage: all phases from conversation covered (secrets, docs, templates, CI, gitignore, trademark, review)
- [x] No placeholders (every file content specified by section)
- [x] Consistent naming (worktree `.worktrees/oss-prep`, branch `chore/oss-preparation`, org `metedata`, repo `Remarc`)
- [x] Stop-gates for user approval (Phase 1.5 if secrets found, Phase 8.3 before any push)

---

## Execution approach

Inline execution in this session via executing-plans. User requested "build a plan and execute." Batch through phases, report at phase boundaries, STOP at risk gates (any finding in Phase 1, final push in Phase 8).
