#!/usr/bin/env bash
# Shared functions for dotsync. Source, do not exec.
set -uo pipefail

# Config: ~/.config/dotsync/config.sh sets these. Defaults below.
DOTSYNC_CONFIG="${DOTSYNC_CONFIG:-${HOME}/.config/dotsync/config.sh}"
if [[ -f "$DOTSYNC_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$DOTSYNC_CONFIG"
fi

DOTSYNC_DATA_DIR="${DOTSYNC_DATA_DIR:-${HOME}/.dotsync-data}"
DOTSYNC_DATA_BRANCH="${DOTSYNC_DATA_BRANCH:-main}"
DOTSYNC_KC_SERVICE="${DOTSYNC_KC_SERVICE:-dev.dotsync.envsync}"
DOTSYNC_KC_ACCOUNT="${DOTSYNC_KC_ACCOUNT:-default}"

# Internal vars (still named ENV_* for now; will rebrand to DOTSYNC_* in v0.2).
ENV_REPO_ROOT="$DOTSYNC_DATA_DIR"
ENV_CONFLICTS_DIR="${ENV_CONFLICTS_DIR_OVERRIDE:-${HOME}/.dotsync-conflicts}"
ENV_LOG_FILE="${HOME}/Library/Logs/dotsync.log"

# Per-machine state — MUST live OUTSIDE $DOTSYNC_DATA_DIR. These files
# describe THIS machine's local sync state (last-sync timestamp, pause
# flag, mutex lock); replicating them produces .sync-conflict-* files
# every cycle because each machine writes its own value to the same
# path. Keep them per-machine.
DOTSYNC_STATE_DIR="${DOTSYNC_STATE_DIR:-${HOME}/.dotsync-state}"
ENV_PAUSE_FLAG="${DOTSYNC_STATE_DIR}/sync-paused"
ENV_LASTSYNC_FILE="${DOTSYNC_STATE_DIR}/last-sync"
ENV_LOCK_DIR="${DOTSYNC_STATE_DIR}/sync.lock"

mkdir -p "$(dirname "$ENV_LOG_FILE")" "$ENV_CONFLICTS_DIR" "$DOTSYNC_STATE_DIR"

# Migration shim: if state files exist at the legacy v0.3 location
# (inside $ENV_REPO_ROOT), move them to the new per-machine location
# and clean up any sync-conflict siblings Syncthing may have created.
if [[ -d "$ENV_REPO_ROOT" ]]; then
  for legacy_name in .last-sync .sync-paused; do
    new_name="${legacy_name#.}"
    if [[ -e "$ENV_REPO_ROOT/$legacy_name" && ! -e "$DOTSYNC_STATE_DIR/$new_name" ]]; then
      mv "$ENV_REPO_ROOT/$legacy_name" "$DOTSYNC_STATE_DIR/$new_name" 2>/dev/null || true
    fi
  done
  # Drop legacy lock dir; new ENV_LOCK_DIR is per-machine.
  [[ -d "$ENV_REPO_ROOT/.sync.lock" ]] && rmdir "$ENV_REPO_ROOT/.sync.lock" 2>/dev/null || true
  # Clean up any sync-conflict files Syncthing made for these state files —
  # they're nonsense (per-machine timestamps that should never have been
  # synced). Match both legacy names and conflict suffix.
  find "$ENV_REPO_ROOT" -maxdepth 1 -name '.sync-conflict-*-*.last-sync' -delete 2>/dev/null || true
  find "$ENV_REPO_ROOT" -maxdepth 1 -name '.sync-conflict-*-*.sync-paused' -delete 2>/dev/null || true
fi

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" \
    | tee -a "$ENV_LOG_FILE" >&2
}
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

die() { log_error "$@"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

is_paused() { [[ -f "$ENV_PAUSE_FLAG" ]]; }
set_paused()   { touch "$ENV_PAUSE_FLAG"; }
clear_paused() { rm -f "$ENV_PAUSE_FLAG"; }

notify_user() {
  local title="$1"; local body="$2"
  osascript -e "display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null || true
}

# Expand ${HOME} and ${PROJECT_ROOT} in a path string from the registry.
# PROJECT_ROOT is the per-machine base where source code projects live.
# Default: $HOME (i.e. registry paths are relative to home if PROJECT_ROOT
# isn't set in config).
expand_path() {
  local p="$1"
  local proot="${DOTSYNC_PROJECT_ROOT:-$HOME}"
  p="${p//\$\{HOME\}/$HOME}"
  p="${p//\$\{PROJECT_ROOT\}/$proot}"
  echo "$p"
}

# Emit pairs: "<repo_path>\t<real_path>" for tracked dotfiles.
# Synced via capture/deploy (cp), NOT symlinks — a live process like Claude
# Code writes to ~/.claude/settings.json on every state change, which
# would race the rebase's internal checkout when the symlink target lives
# in the data repo's working tree.
dotfile_pairs() {
  cat <<EOF
dotfiles/settings.json	${HOME}/.claude/settings.json
dotfiles/CLAUDE.md	${HOME}/.claude/CLAUDE.md
EOF
}
