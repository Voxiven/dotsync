# Phase 4 — Syncthing engine swap

**Status:** design (2026-05-01)
**Target version:** v0.4

## Why

The v0.3 sync engine uses `git rebase` against a working tree that live
processes (Claude Code) write into. Today's session shipped 5 fixes for
bugs in that exact class:

- Empty-blob roundtrip through git-crypt's clean filter (85980cf)
- Working-tree dirty during rebase from concurrent CC writes (c0285ed)
- Per-machine encoded paths breaking cross-machine sync (d4be655)
- Branch confusion on initial clone (d6a9beb)
- SIGPIPE+pipefail on `launchctl list | grep -q` (229bc37)

Each fix took ~30 minutes of debugging. The bug class is *inherent* to
running `git rebase` on a tree being written to by another process. We
will keep finding new ones. The structural fix is to stop using git as
the replication mechanism.

[Syncthing](https://syncthing.net/) is a peer-to-peer file
synchronization tool: each device runs a local daemon, devices discover
each other (via discovery servers that don't see content), pairs of
devices replicate folders over TLS. There is no checkout step, no
rebase, no working-tree-must-match-index invariant. Conflicts produce
suffixed sidecar files (`*.sync-conflict-<host>-<ts>`) instead of
halting sync.

## What stays the same

The user-facing dotsync surface does not change:

- `dotsync init / pair / join / restore / uninstall`
- `dotsync status / ui / sync / pause / resume / logs`
- `dotsync profiles / enable / disable / track / untrack / list`
- The profile schema in `profiles/*.json`
- Capture/deploy semantics (read from `$HOME/.claude/...`, write to
  `$DOTSYNC_DATA_DIR/...`, mirror back)
- Per-machine path remapping (`${PROJECT}` / `${CC_ENCODED}`)

## What changes

| Component | v0.3 (today) | v0.4 (after) |
|---|---|---|
| **Replication** | custom launchd cron + `git fetch/rebase/push` every 60s | Syncthing's own daemon, real-time (~few sec propagation) |
| **`$DOTSYNC_DATA_DIR`** | git working tree | plain directory, Syncthing-managed |
| **Daemon** | `~/Library/LaunchAgents/<svc>.plist` running `env-sync` every 60s | Syncthing's `syncthing.plist` (one process, well-tested) |
| **Encryption** | git-crypt + age-in-Keychain on the data repo | TLS-in-transit between peers; data on each peer's disk in plaintext (same as `~/.claude/projects/` already is locally) |
| **Identity transfer** | wormhole + age key | Syncthing device-ID exchange (still uses wormhole as the convenience layer) |
| **Conflict handling** | git merge → manual `dotsync resolve` | `*.sync-conflict-<host>-<ts>` sidecars; `dotsync resolve` becomes a curator |
| **Sync trigger** | `env-sync` invokes capture/deploy/commit/fetch/rebase/push | Capture writes to folder; Syncthing replicates; deploy reads from folder. `env-sync` becomes thin: capture → wait briefly → deploy |
| **Off-site backup** | the GitHub data repo | none by default; user can opt into a separate snapshot-to-git side-feature later |

## Decisions

### D1: Encryption — TLS only, no at-rest envelope

**Decision:** Files live in `~/.dotsync-data/` in **plaintext**. Syncthing
encrypts only in transit (TLS between trusted peers).

**Rationale:**
- Today's `~/.claude/projects/.../*.jsonl` and `~/.claude/settings.json`
  are already plaintext on disk on every peer. Encrypting the dotsync
  data dir while CC's primary data is plaintext was always pretending to
  add security that wasn't there.
- Syncthing peer-to-peer means there is no third-party storage server
  holding our content. Discovery servers see only device IDs.
- Adding age-on-write would re-introduce the smudge filter complexity
  we just escaped from.

**Future:** if we want offsite backup to an untrusted device (e.g. a
NAS), Syncthing has an "untrusted" device mode that encrypts data sent
to that specific device. Adopt then, not now.

### D2: Identity is the Syncthing device ID

**Decision:** No more age identity for sync. The Syncthing-generated
device ID (a base32 public identifier per peer) is the only credential.

**Rationale:**
- Without at-rest encryption, there's nothing to encrypt — no need for
  age keys.
- Syncthing's pairing model is: `peer A introduces peer B by ID, peer
  B accepts; the folder is then shared`. Device IDs are public; the
  trust comes from explicit acceptance on both sides.
- Eliminates ~200 lines of `_crypt.sh` + the age + git-crypt brew deps.

**Migration path for existing users:** their existing age identity in
Keychain becomes vestigial. `dotsync uninstall` (post-Phase 4) will
clean it up. Until then it's harmless.

### D3: Pairing UX — keep magic-wormhole

**Decision:** `dotsync pair` and `dotsync join` continue to use
magic-wormhole, but the payload is now the Syncthing device ID + folder
ID instead of an age private key.

**Rationale:**
- Device IDs are 56 chars long. Cumbersome to type. wormhole's
  3-or-4-word codes carry them perfectly.
- The pair → join flow is already familiar from v0.3.
- magic-wormhole continues to be a great fit even when the payload
  is non-secret.

### D4: Conflict resolution — sidecar files

**Decision:** When two peers edit the same file simultaneously,
Syncthing creates `<name>.sync-conflict-<host>-<ts>.<ext>`. We don't
auto-merge. `dotsync resolve` (rewritten) becomes:

- List all sync-conflict files
- For each: show the modification times, sizes, both contents
- User picks which to keep; the other is moved to
  `~/.dotsync-conflicts-resolved/<ts>/`

**Rationale:**
- For session jsonls: CC ignores them (UUID mismatch with the canonical
  filename). They accumulate harmlessly until cleaned up.
- For dotfiles: rare in practice (config files don't change every
  second). When they do, manual merge is the honest answer.

### D5: Backwards compat — opt-in migration

**Decision:** Phase 4 ships as a parallel implementation. The legacy
`env-*` git engine stays in place during the transition.

- New machines: `dotsync init` configures Syncthing.
- Existing machines: continue working on git until the user runs
  `dotsync upgrade` (a new command).
- After ~30 days of clean operation, drop the legacy code.

**Rationale:**
- Mac A and Mac B are real production usage. Don't break them.
- The git path is well-debugged at this point. Keep it as a fallback.

### D6: `dotsync sync` semantics

**Decision:** Becomes a thin trigger: capture local state into the data
folder, request a Syncthing rescan via REST API, run deploy. No more
commit/fetch/rebase/push.

```
v0.3 (git)               v0.4 (syncthing)
─────────────             ─────────────────
capture                   capture
git add -A                rescan via API
git commit                (Syncthing replicates async)
git fetch                 wait briefly (or skip — rely on the daemon)
git rebase                deploy
deploy
git push
```

The 60-second daemon cycle stays, but most of the work happens
continuously in Syncthing's daemon, not ours.

## Implementation phases

Each phase is independently committable. Order matters — earlier phases
unblock later ones.

### Phase 4.1: capture/deploy refactor

**Files:** `bin/env-sync`, new `bin/_syncthing.sh`

- Detect Syncthing mode (presence of `~/.dotsync-data/.stfolder` —
  Syncthing's marker for "this is a managed folder")
- If Syncthing mode: skip git ops, do capture → rescan → wait → deploy
- If git mode: existing behavior unchanged
- Add `_syncthing.sh` with helpers:
  - `st_running()` — daemon up?
  - `st_rescan(folder)` — POST to /rest/db/scan
  - `st_status(folder)` — GET /rest/db/status; returns "in-sync" / "syncing" / etc.
  - `st_wait_idle(folder, timeout=30)` — block until idle

### Phase 4.2: `dotsync init` — Syncthing variant

**Files:** `bin/dotsync-init`

- New flag `--engine syncthing` (later default)
- Steps:
  1. `brew install syncthing`
  2. Generate Syncthing config (uses `syncthing generate --config <path>`)
  3. Install + load `homebrew.mxcl.syncthing.plist`
  4. Wait for daemon ready (`curl 127.0.0.1:8384`)
  5. Configure folder: `~/.dotsync-data/` with deterministic folder ID
  6. Print device ID + folder ID for the pairing payload
  7. Same registry/profile setup as today

The data dir gets a `.stignore` to keep large or transient files out
(rsync-style).

### Phase 4.3: `dotsync pair` / `dotsync join`

**Files:** `bin/dotsync-pair`, `bin/dotsync-join`

- `pair` sends `{device_id, folder_id, address}` via wormhole
- `join` receives, calls Syncthing's REST API to add the device + share
  the folder, waits for handshake
- No age identity in the payload anymore

### Phase 4.4: `dotsync ui`

**Files:** `bin/dotsync-ui`

- Replace git-log peer detection with Syncthing's `/rest/system/connections`
- Replace last-sync-file with `/rest/db/status` per folder
- Add per-folder progress bars (Syncthing knows %)
- Conflicts pulled from filesystem scan (same as today, different path)

### Phase 4.5: `dotsync upgrade`

**Files:** new `bin/dotsync-upgrade`

A one-shot migration. Runs on each machine independently:

1. Pause the v0.3 daemon
2. Run a final `env-sync` to drain in-flight changes to GitHub
3. Note the current `$DOTSYNC_DATA_DIR` contents
4. Initialize Syncthing on this machine
5. Move `$DOTSYNC_DATA_DIR/.git/` aside (preserve as backup, don't delete)
6. Decrypt all git-crypt'd files in place (so the contents are
   plaintext for Syncthing to replicate)
7. Add the folder to Syncthing pointing at `$DOTSYNC_DATA_DIR`
8. Print device ID + folder ID
9. After the user has run `upgrade` on the second machine and pairing
   completed, drop the v0.3 launchd plist and uninstall git-crypt
   metadata

The flow across two machines:
- Mac A: `dotsync upgrade` → prints code
- Mac B: `dotsync upgrade --pair-from <code>` → joins
- Both: `dotsync status` shows Syncthing folder in sync
- After 24h of clean operation: `dotsync upgrade --finalize` removes
  the v0.3 cruft and the GitHub data repo can be archived

### Phase 4.6: drop legacy

After ~30 days of clean Phase 4.5 operation:

- Delete `bin/env-sync`, `bin/env-resolve`, `bin/env-bootstrap`,
  `bin/env-track`, `bin/env-status`, `bin/_crypt.sh`, `bin/_registry.sh`'s
  git-crypt-aware bits, `bin/_profile.sh`'s git-aware bits
- Drop `git-crypt` and `age` from the brew install list (only when
  no longer needed for legacy detection)
- Repo gets ~30% smaller

## Migration plan for Mac A + Mac B

After Phase 4.5 lands:

```bash
# Mac A (run first)
dotsync upgrade
# prints: "Pair code: <wormhole code>"

# Mac B
dotsync upgrade --pair-from <code>
# pairs Syncthing devices, accepts shared folder

# Both
dotsync status
# expect: "syncthing — folder in-sync — peer mac-A connected"

# After 24h of clean operation, on either machine
dotsync upgrade --finalize
```

## Rollback plan

If Phase 4 has issues during the transition window:

```bash
dotsync upgrade --rollback
```

This:
- Stops Syncthing for the dotsync folder
- Restores `$DOTSYNC_DATA_DIR/.git/` from the preserved backup
- Re-encrypts files via git-crypt
- Reloads the v0.3 launchd daemon

Possible because Phase 4.5 doesn't delete the git layer until
`--finalize`, and `--finalize` is a separate explicit user action.

## Open questions

- **Syncthing daemon resource use** — is the always-running daemon a
  problem on small machines? Empirically: no, ~30MB RAM, idle CPU.
- **Folder ID collision** — if two unrelated dotsync setups happen to
  use the same data folder name, Syncthing's hashes prevent
  accidental sync. Folder IDs are user-chosen; pick a deterministic
  one based on the dotsync setup name.
- **Discovery servers** — Syncthing defaults to public discovery
  servers. For maximum privacy, point at self-hosted or use static
  addresses. Defer.
- **iOS / mobile peers** — out of scope for v0.4. Syncthing has iOS via
  third-party apps; not a clean story today.

## Out of scope (deliberately)

- Replacing chezmoi for shell dotfiles. dotsync remains AI-tool-focused.
- Cloud backup (B2 / S3 untrusted device).
- Web dashboard auth (it's localhost-only by design).
- Conflict auto-merge for jsonl (Syncthing's sidecar files are fine).
