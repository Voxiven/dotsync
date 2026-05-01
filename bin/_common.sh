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
ENV_PAUSE_FLAG="${ENV_REPO_ROOT}/.sync-paused"
ENV_LASTSYNC_FILE="${ENV_REPO_ROOT}/.last-sync"
ENV_LOG_FILE="${HOME}/Library/Logs/dotsync.log"

mkdir -p "$(dirname "$ENV_LOG_FILE")" "$ENV_CONFLICTS_DIR"

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

# Expand ${HOME} (and only ${HOME}) in a path string from the registry.
expand_path() {
  local p="$1"
  echo "${p//\$\{HOME\}/$HOME}"
}
