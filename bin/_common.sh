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
DOTSYNC_KC_SERVICE="${DOTSYNC_KC_SERVICE:-dev.dotsync.envsync}"

# Internal vars.
ENV_REPO_ROOT="$DOTSYNC_DATA_DIR"
ENV_CONFLICTS_DIR="${ENV_CONFLICTS_DIR_OVERRIDE:-${HOME}/.dotsync-conflicts}"
ENV_LOG_FILE="${HOME}/Library/Logs/dotsync.log"

# Per-machine state — lives OUTSIDE $DOTSYNC_DATA_DIR (which is the
# Syncthing-replicated folder). These files describe THIS machine's
# local sync state (last-sync timestamp, pause flag, mutex lock);
# replicating them would produce .sync-conflict-* files every cycle
# as each peer overwrites with its own value.
DOTSYNC_STATE_DIR="${DOTSYNC_STATE_DIR:-${HOME}/.dotsync-state}"
ENV_PAUSE_FLAG="${DOTSYNC_STATE_DIR}/sync-paused"
ENV_LASTSYNC_FILE="${DOTSYNC_STATE_DIR}/last-sync"
ENV_LOCK_DIR="${DOTSYNC_STATE_DIR}/sync.lock"

mkdir -p "$(dirname "$ENV_LOG_FILE")" "$ENV_CONFLICTS_DIR" "$DOTSYNC_STATE_DIR"

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

