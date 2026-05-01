# dotsync

Sync Claude Code memory, sessions, and `.env` files between your machines.
Encrypted at rest, no SaaS, no cloud-of-the-week. macOS-first.

> **Status: pre-alpha.** Built for one person, then extracted. Expect rough edges.
> Contributions and issues welcome.

---

## What it does

If you use [Claude Code](https://docs.claude.com/en/docs/claude-code) on more than one Mac, you've probably hit this: your *memory* (`~/.claude/projects/<project>/memory/MEMORY.md` and the per-project `*.md` files) is the cumulative knowledge Claude has built up about you, your preferences, your projects. It's load-bearing context. And it's stuck on whichever machine you used last.

`dotsync` keeps the following converged across N machines, automatically and continuously:

| What | Where it lives | Why it matters |
|---|---|---|
| **Claude memory** | `~/.claude/projects/<project>/memory/` | The signal — what Claude has learned about you. |
| **Claude session transcripts** | `~/.claude/projects/<project>/*.jsonl` | So `claude --resume` works across machines. |
| **Claude global settings** | `~/.claude/settings.json`, `~/.claude/CLAUDE.md` | Hooks, permissions, model preferences. |
| **`.env` files** | Wherever your projects live | Stop emailing yourself secrets. |

After a one-time bootstrap on each machine, edits propagate within ~60 seconds. No manual `git pull` / `git push`, no Dropbox folder, no copy-paste of API keys.

## How it works

Three pieces:

1. **A private git repo you create**, encrypted at rest with [git-crypt](https://github.com/AGWA/git-crypt). Holds the actual content. Filenames are visible; contents are not.
2. **An age identity** ([age](https://github.com/FiloSottile/age)) that wraps the git-crypt symmetric key. The identity lives in macOS Keychain on each of your machines. Lose it → locked out forever, so save a copy in 1Password.
3. **A launchd agent** that runs `env-sync` every 60 seconds: pulls remote changes, deploys them to the canonical paths (`~/.claude/...`, your `.env` paths), captures any local changes, commits, and pushes.

```
                  ┌──────────────────────┐
                  │   GitHub (private)   │
                  │  encrypted at rest   │
                  └──────────┬───────────┘
                             │ git push/pull
                ┌────────────┴────────────┐
       ┌────────▼─────────┐     ┌─────────▼────────┐
       │     Mac A        │     │      Mac B       │
       │ ┌──────────────┐ │     │ ┌──────────────┐ │
       │ │ launchd 60s  │ │     │ │ launchd 60s  │ │
       │ │   env-sync   │ │     │ │   env-sync   │ │
       │ └──────┬───────┘ │     │ └──────┬───────┘ │
       │        │         │     │        │         │
       │   ~/.claude/     │     │   ~/.claude/     │
       │   project .envs  │     │   project .envs  │
       └──────────────────┘     └──────────────────┘
```

## Conflict policy: no data loss

When the daemon sees a conflict it can't auto-merge (same lines of the same file edited on both machines), it:

1. Saves all three versions (`<file>.local`, `<file>.remote`, `<file>.base`) to `~/.dotsync-conflicts/<timestamp>/`.
2. Aborts the rebase — working tree returns to clean state, nothing half-applied.
3. Pauses the daemon (writes `.sync-paused` in the data repo).
4. Posts a macOS notification.

You run `env-resolve`, your merge tool of choice opens with the three versions, you produce a merged file, sync resumes. **The daemon never auto-picks a winner.** Every byte ever written is recoverable either from the conflict archive or `git log`.

## Threat model

- **Other people with access to your data repo** (e.g. an org-mate if you use a Voxiven-style org repo): see filenames + commit history, never plaintext.
- **GitHub itself / your hosting provider**: same — encrypted at rest. The age-encrypted git-crypt key is in the repo, but it's protected by your age identity, which never leaves your Macs.
- **A stolen Mac**: Keychain is bound to your macOS user account. With FileVault on, the thief needs your login password to unlock anything. Recovery: rotate the age identity from your other Mac, force-push the new key, rotate any `.env` secrets that may have been read.
- **Session JSONLs containing prompts that included pasted secrets**: same encrypted-at-rest treatment as `.env` files. This isn't a new threat introduced by `dotsync` — it's the existing on-disk risk, now also synced.

## Status & roadmap

**v0.1 (this release)**
- macOS only (uses `launchd`, `security`, `osascript`)
- Bootstrap is "set up the first machine manually, then `env-bootstrap` for subsequent machines"
- Claude memory is shared across all tracked projects (one `MEMORY.md` for everything) — this matches my workflow but might not match yours
- No homebrew tap yet; install via `git clone`

**v0.2 (planned)**
- Linux support (systemd timer instead of launchd)
- Per-project memory option
- Homebrew tap
- A single `dotsync` entry-point command (`dotsync sync`, `dotsync status`, etc.)
- `env-rotate-identity` for key rotation

**Open questions**
- Should the data repo be a separate repo or an orphan branch on a repo you already have? (See `docs/architecture-notes.md` once it's written.)
- Worth supporting GPG-keyed git-crypt for multi-user teams? (Currently single-user.)

## Install (manual, v0.1)

### Prerequisites

- macOS (Linux planned for v0.2)
- [Homebrew](https://brew.sh/)
- A private git remote you control (GitHub, GitLab, self-hosted) — this is your **data repo**

### First Mac — full setup

```bash
# 1. Create your private data repo on GitHub. We'll call it origin "data-repo".
#    Empty repo is fine; we'll seed it.

# 2. Clone the dotsync tool to a stable location.
git clone https://github.com/Voxiven/dotsync.git ~/.dotsync-tool

# 3. Install dependencies.
brew install git-crypt age fswatch jq

# 4. Clone your data repo.
git clone <YOUR_DATA_REPO_URL> ~/.dotsync-data
cd ~/.dotsync-data

# 5. Initialize git-crypt and seed the .gitattributes.
cat > .gitattributes <<'EOF'
claude/**     filter=git-crypt diff=git-crypt
sessions/**   filter=git-crypt diff=git-crypt
secrets/**    filter=git-crypt diff=git-crypt
dotfiles/**   filter=git-crypt diff=git-crypt
.gitattributes !filter !diff
.git-crypt/**  !filter !diff
registry/**    !filter !diff
README.md      !filter !diff
EOF
git-crypt init

# 6. Generate an age identity, encrypt the git-crypt key with the public half,
#    store the private half in Keychain, save a copy in 1Password.
git-crypt export-key /tmp/gc-key.raw
age-keygen -o /tmp/identity.txt 2>&1 | tee /tmp/pub
PUBKEY=$(grep -oE 'age1[a-z0-9]+' /tmp/pub)
mkdir -p .git-crypt/keys
age -r "$PUBKEY" -o .git-crypt/keys/default.age /tmp/gc-key.raw
rm -P /tmp/gc-key.raw /tmp/pub
cat /tmp/identity.txt   # ⚠ Save the AGE-SECRET-KEY-1... line in 1Password NOW
security add-generic-password -s "dev.dotsync.envsync" -a "default" -U -w
# Paste the AGE-SECRET-KEY-1... line when prompted (twice, hidden).
rm -P /tmp/identity.txt

# 7. Seed the registry — list the .env files you want synced + the Claude
#    project paths. See examples/registry/*.example.
mkdir -p registry claude/memory sessions secrets dotfiles
cp ~/.dotsync-tool/examples/registry/secrets.json.example registry/secrets.json
cp ~/.dotsync-tool/examples/registry/projects.json.example registry/projects.json
$EDITOR registry/secrets.json registry/projects.json   # edit to fit your setup

git add .
git commit -m "init: dotsync data repo"
git push origin main

# 8. Bootstrap.
~/.dotsync-tool/bin/env-bootstrap
```

### Second Mac (and beyond)

```bash
# 1. Clone the tool.
git clone https://github.com/Voxiven/dotsync.git ~/.dotsync-tool
brew install git-crypt age fswatch jq

# 2. Add the age identity to Keychain on this Mac.
#    On your first Mac, run:
#       security find-generic-password -s "dev.dotsync.envsync" -a "default" -w
#    Copy the output. Then on this Mac:
security add-generic-password -s "dev.dotsync.envsync" -a "default" -U -w
# Paste when prompted.

# 3. Bootstrap. It will prompt for the data repo URL.
~/.dotsync-tool/bin/env-bootstrap
```

That's it. Edits to memory or `.env` files on either Mac propagate within ~60 seconds.

## Commands

| Command | What it does |
|---|---|
| `env-bootstrap` | One-shot setup. Idempotent — safe to re-run. |
| `env-sync` | Pull, deploy, capture, push. Run by launchd every 60s; runnable manually. |
| `env-status` | Read-only diagnostic — last sync, paused state, conflict count. |
| `env-track <path>` | Add a new `.env` file to the registry. |
| `env-resolve [--prefer local\|remote]` | Resolve a paused conflict via 3-way merge. |

## Configuration

`~/.config/dotsync/config.sh`:

```bash
DOTSYNC_DATA_DIR="${HOME}/.dotsync-data"
DOTSYNC_DATA_REMOTE="git@github.com:yourname/dotsync-data.git"
DOTSYNC_DATA_BRANCH="main"
DOTSYNC_KC_SERVICE="dev.dotsync.envsync"
DOTSYNC_KC_ACCOUNT="default"
```

See `examples/config.sh.example`.

## Tests

```bash
cd ~/.dotsync-tool
bash tests/test-sync.sh
```

Spins up two mock "machines" (tmpdirs) with a bare local remote, runs the full sync flow including conflict drills. ~10 seconds end-to-end.

## License

MIT — see `LICENSE`.

## Why is it built this way?

The architectural decisions are documented in `docs/design.md` (forthcoming). Highlights:

- **Why git-crypt and not gocryptfs / age-tarballs / Syncthing?** git-crypt's per-file encryption lets git's standard 3-way text merge handle non-overlapping edits cleanly. Tarballs produce false conflicts (Mac A edits file X, Mac B edits file Y → same blob changes on both sides). Syncthing has no encryption-at-rest and no audit trail. git-crypt also gives you `git log` per file.
- **Why age identities not passphrases?** age 1.x intentionally refuses to read passphrases from stdin (TTY required) to prevent shell-history leaks. This makes passphrase-based decryption unworkable for daemons. age identity files (X25519 keys) decrypt non-interactively by design.
- **Why launchd not cron?** launchd handles `RunAtLoad`, `ThrottleInterval`, log redirection, and respawn-on-crash. Cron is fire-and-forget. For a daemon that touches user data, launchd's better.
- **Why one repo per user not one shared repo?** git-crypt does support GPG-keyed multi-user encryption, but the bootstrap UX gets dramatically more complex. v0.1 stays single-user; multi-user is on the v0.3 roadmap.

## Contributing

Issues and PRs welcome. The codebase is ~700 LOC of bash, with end-to-end tests. If you're contributing, please:

1. Open an issue first for non-trivial changes
2. Run `bash tests/test-sync.sh` before submitting
3. Keep commits atomic and conventional (`feat:`, `fix:`, `docs:`, `test:`)

---

Built by [Voxiven](https://voxiven.com). Originally an internal tool for syncing Claude Code memory across the founder's two MacBooks; extracted to OSS because the problem isn't unique to one person.
