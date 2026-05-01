# dotsync

**Multi-machine continuity for Claude Code and other AI dev tools.**
Peer-to-peer, real-time, no cloud, no GitHub data repo, no copy-pasting secrets.

> **Status: alpha.** Works for the author on two Macs. macOS-only today; Linux on the roadmap.

---

## The problem

If you use [Claude Code](https://docs.claude.com/en/docs/claude-code) on more than one machine, your **memory** (cumulative knowledge Claude has built about your projects), **session transcripts** (so `claude --resume` works), **settings.json**, **agents**, **commands**, and **per-project `.env` files** all live on whichever machine you used last. Walk to the other one and you're starting from scratch.

`dotsync` keeps them converged across N machines — peer-to-peer, real-time, with one command to set up.

```
                 ~/.claude/settings.json
   (CC writes here)──┐                    ┌──(Mac B's CC reads here)
                     ▼                    ▼
                  symlink              symlink
                     │                    │
                     ▼                    ▼
            ~/.dotsync-data/  ◀──Syncthing──▶  ~/.dotsync-data/
            (TLS, peer-to-peer, no third party in the path)
```

After a one-time `dotsync init` + `dotsync pair`/`join`, edits propagate within a few seconds. No `git push`, no Dropbox folder, no SaaS of the week.

## What gets synced

| Thing | Where it lives on disk | Why it matters |
|---|---|---|
| Claude Code **memory** | `~/.claude/projects/*/memory/` | What Claude knows about your work — load-bearing context. |
| Claude Code **sessions** | `~/.claude/projects/*/*.jsonl` | So `claude --resume` works on either machine. |
| Claude Code **settings** | `~/.claude/settings.json` | Hooks, permissions, model preferences. |
| Claude Code **CLAUDE.md** | `~/.claude/CLAUDE.md` | Your global Claude instructions. |
| Claude Code **agents** | `~/.claude/agents/` | Custom subagents. |
| Claude Code **commands** | `~/.claude/commands/` | Custom slash commands. |
| Project **`.env` files** | `<your project root>/<project>/.env` | Stop emailing yourself secrets. |

Other tools (Cursor, Aider, etc.) ship as experimental [profiles](#profiles) and can be enabled per-machine.

## Quickstart (5 min)

### Install

```bash
# Once the tap is published:
brew tap voxiven/tap
brew install dotsync
```

Until the tap lands, you can clone + symlink:

```bash
git clone https://github.com/Voxiven/dotsync.git ~/.dotsync-tool
ln -sf ~/.dotsync-tool/bin/dotsync /usr/local/bin/dotsync
```

### Mac A — first machine

```bash
# One-command setup. Installs Syncthing, configures the folder, picks
# default profiles (claude-code + project-secrets), prints your device ID.
dotsync init

# Print a pairing code for the next machine.
dotsync pair
# → "Wormhole code is: 4-foo-bar-baz" (codes expire after a few minutes)
```

### Mac B — second machine

```bash
# Same install (brew tap voxiven/tap && brew install dotsync, or clone).

# Join with the code from Mac A.
dotsync join --code 4-foo-bar-baz

# join prints something like:
#   "On the FIRST machine, run: dotsync add-peer XA7N5BU-..."
```

### Mac A — finish pairing

```bash
# Paste the add-peer command join printed.
dotsync add-peer XA7N5BU-HBXJHWS-PMZRHZU-...
```

Done. Both Syncthing daemons connect, the folder replicates, your CC content syncs automatically. Verify:

```bash
dotsync status         # one-line health
dotsync ui             # opens dashboard at http://127.0.0.1:7878
```

## How it works

Two pieces:

1. **[Syncthing](https://syncthing.net/)** does peer-to-peer file replication. TLS in transit between paired peers. Discovery servers see only device IDs (no content). No third-party storage, no cloud.

2. **`dotsync`** wires CC's canonical paths (`~/.claude/settings.json`, etc.) into the Syncthing-replicated folder via **symlinks**. CC writes through the symlink → file lands directly in the Syncthing folder → replicated to peers in real time.

Per-machine encoded paths are bridged transparently: Mac A's `~/.claude/projects/-Users-stan-Workspace-Omphalis/` and Mac B's `~/.claude/projects/-Users-jen-Code-Omphalis/` both map to the same `claude-code/sessions/Omphalis/` in the Syncthing folder.

For files that can't be symlinked (per-project session jsonls, ad-hoc tracked items), there's a small launchd agent that runs every 60s and `rsync`s in/out — but most paths need no daemon work.

## What dotsync is *not*

- **Not [chezmoi](https://www.chezmoi.io/) or yadm.** Those are for shell dotfiles (`.zshrc`, `.gitconfig`) with templating across machines. dotsync is for AI/dev-tool state. Use chezmoi *and* dotsync — they don't overlap.
- **Not Syncthing itself.** Syncthing is the engine; dotsync is the curated layer on top — opinionated profiles, CC path-encoding bridging, single-command pairing, dashboard.
- **Not Dropbox / iCloud Drive.** Those upload your data to a third-party cloud. dotsync is peer-to-peer; data only exists on machines you trust.
- **Not a backup tool.** Use Time Machine / Backblaze for backup. dotsync syncs *active* state.

## Profiles

A **profile** is a JSON file in `profiles/` that declares which paths a particular tool wants synced. Built-ins:

| Profile | Status | What it syncs |
|---|---|---|
| `claude-code` | production | Sessions, memory, settings, CLAUDE.md, agents, commands |
| `project-secrets` | production | `.env` files at `${PROJECT_ROOT}/<project>/.env` |
| `cursor` | experimental | Cursor settings, keybindings, snippets |
| `aider` | experimental | Aider config + chat history |

Enable / disable:

```bash
dotsync profiles                  # list available + enabled
dotsync enable cursor             # turn on
dotsync disable aider             # turn off
dotsync list                      # show paths covered by enabled profiles
```

Adding new profiles is a JSON file change — see [`docs/profiles.md`](docs/profiles.md).

## Commands

```
Setup
  init              First machine: install Syncthing, configure folder, set up symlinks
  pair              Generate a one-time pairing code (uses magic-wormhole)
  join              Second machine: receive pairing code, configure
  add-peer          Finish bidirectional pairing on the first machine

Daily use
  status            One-line health (last sync, daemon, conflicts)
  sync              Force a sync now (daemon does this every 60s)
  ui                Open status dashboard at http://127.0.0.1:7878
  pause / resume    Halt or restart the dotsync agent

Profiles
  profiles          List available + enabled profiles
  enable <name>     Turn on a profile
  disable <name>    Turn off a profile

Tracked items (ad-hoc, beyond profiles)
  track <path>      Add a file or directory to sync
  untrack <pattern> Remove
  list              Show everything tracked

Maintenance
  setup-symlinks    Re-wire profile symlinks (idempotent)
  no-daemon         Disable our 60s agent (only if you don't sync sessions)
  clean-conflicts   Remove Syncthing's *.sync-conflict-* files
  logs [--tail]     View ~/Library/Logs/dotsync.log
  uninstall         Tear down dotsync on this machine
```

Run `dotsync <command> --help` for per-command details.

## Security & privacy

| Threat | Result |
|---|---|
| **Network sniffer** between paired Macs | TLS encrypted in transit (Syncthing) — sees nothing useful |
| **Syncthing's discovery servers** | See only device IDs (public identifiers) — never content |
| **Cloud provider** | None involved. dotsync is peer-to-peer; your data never leaves your machines |
| **Stolen Mac** | macOS user-account login + FileVault is your defense — same as for CC's own data, which already lives in `~/.claude/` plaintext |

Files on disk are plaintext on each peer. This is **the same security envelope CC's own data already has** — `~/.claude/projects/*/*.jsonl` and `~/.claude/settings.json` are already plaintext on every machine that runs CC. Encrypting them in the dotsync folder while leaving them plaintext at their canonical path would be theater, not security.

If you want at-rest encryption for the dotsync folder specifically, encrypt the volume (FileVault) or move the folder to an encrypted disk image.

## Configuration

`dotsync init` writes `~/.config/dotsync/config.sh`. Defaults:

```bash
DOTSYNC_DATA_DIR="${HOME}/.dotsync-data"
DOTSYNC_KC_SERVICE="dev.dotsync.envsync"      # launchd service label
DOTSYNC_PROJECT_ROOT="${HOME}/code"           # where your projects live
DOTSYNC_SESSION_MAX_MB=50                     # skip oversize jsonls
DOTSYNC_SKIP_PROJECTS=""                      # space-separated names
SYNCTHING_FOLDER_ID="dotsync-data"
SYNCTHING_API_BASE="http://127.0.0.1:8384"
```

Multiple parallel setups (work + personal) are supported by overriding `DOTSYNC_CONFIG`, `DOTSYNC_DATA_DIR`, and `DOTSYNC_KC_SERVICE` per-instance.

## Roadmap

**Done (v0.4):**
- Syncthing engine, peer-to-peer, no GitHub data repo
- Symlinks for most paths (real-time sync, no daemon work for those)
- Profile system: `claude-code`, `project-secrets`, plus experimental `cursor`/`aider`
- One-command setup (`init` → `pair` → `join` → `add-peer`)
- Web dashboard at `localhost:7878`
- `dotsync uninstall` / `dotsync setup-symlinks` / `dotsync no-daemon`

**Next:**
- Linux support (systemd-user units instead of launchd; libsecret instead of Keychain)
- Homebrew tap for one-line install
- `dotsync doctor` self-diagnostic command
- Bats-core test suite
- Full project-dir symlinks for sessions (eliminate the polling agent entirely)
- More tested profiles (Cursor, Aider, Continue.dev, Zed assistant)

## Contributing

Issues and PRs welcome. Quick-start for hacking:

```bash
git clone https://github.com/Voxiven/dotsync.git
cd dotsync
# Run a command directly without symlinks:
./bin/dotsync help
```

Code is ~2500 LOC of bash + one Python file (the dashboard). Keep it that way.

Conventions:
- Each subcommand is `bin/dotsync-<name>` (the dispatcher routes via `git`-style)
- Profile schemas are JSON in `profiles/`
- New CC paths to sync = profile change, no code
- New tools to support = new profile JSON, no code (mostly)

## License

MIT — see [LICENSE](LICENSE).

## Why this exists

The author uses Claude Code on a laptop and a desktop. After enough times of "wait, that conversation was on the other Mac," and after enough generic-sync tools that didn't get the path-encoding nuance right, this got built. Open-sourced because the problem clearly isn't unique.

Built by [Voxiven](https://voxiven.com).
