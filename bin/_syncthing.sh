#!/usr/bin/env bash
# Syncthing helpers. Source, do not exec.
#
# Used when DOTSYNC_ENGINE=syncthing (set in $DOTSYNC_CONFIG by `dotsync init
# --engine syncthing` or `dotsync upgrade`). Falls back to no-op when
# Syncthing isn't installed/running, so legacy git-based setups never
# accidentally hit these paths.
set -uo pipefail

: "${ENV_REPO_ROOT:?source _common.sh first}"

# Engine detection. Returns 0 if this dotsync setup uses Syncthing.
syncthing_mode() {
  [[ "${DOTSYNC_ENGINE:-git}" == "syncthing" ]]
}

# Defaults — overridable via $DOTSYNC_CONFIG.
SYNCTHING_API_BASE="${SYNCTHING_API_BASE:-http://127.0.0.1:8384}"
SYNCTHING_FOLDER_ID="${SYNCTHING_FOLDER_ID:-dotsync-data}"
SYNCTHING_API_KEY_FILE="${SYNCTHING_API_KEY_FILE:-${HOME}/Library/Application Support/Syncthing/apikey}"

# Read API key (Syncthing writes one on first run; we cache it locally so
# we don't have to dig into the config XML each time).
_st_api_key() {
  if [[ -f "$SYNCTHING_API_KEY_FILE" ]]; then
    cat "$SYNCTHING_API_KEY_FILE"
    return
  fi
  # Fall back to extracting from Syncthing's config.xml if we haven't
  # cached it yet.
  local cfg="${HOME}/Library/Application Support/Syncthing/config.xml"
  [[ -f "$cfg" ]] || return 1
  local key
  key=$(grep -oE '<apikey>[^<]+</apikey>' "$cfg" 2>/dev/null \
    | head -1 | sed -E 's|</?apikey>||g')
  [[ -n "$key" ]] || return 1
  mkdir -p "$(dirname "$SYNCTHING_API_KEY_FILE")"
  printf '%s' "$key" > "$SYNCTHING_API_KEY_FILE"
  chmod 600 "$SYNCTHING_API_KEY_FILE"
  echo "$key"
}

_st_curl() {
  local method="$1" path="$2" body="${3:-}"
  local key
  key="$(_st_api_key)" || { log_warn "no Syncthing API key"; return 1; }
  if [[ -n "$body" ]]; then
    curl -fsS --max-time 5 \
      -H "X-API-Key: $key" \
      -H "Content-Type: application/json" \
      -X "$method" \
      -d "$body" \
      "${SYNCTHING_API_BASE}${path}"
  else
    curl -fsS --max-time 5 \
      -H "X-API-Key: $key" \
      -X "$method" \
      "${SYNCTHING_API_BASE}${path}"
  fi
}

# Returns 0 if the Syncthing daemon is reachable. Accepts any 1xx-5xx
# HTTP response — Syncthing v2+ returns 403 on /ping without an API key,
# but 403 still means "the server is running" which is what this checks.
st_running() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    "${SYNCTHING_API_BASE}/rest/system/ping" 2>/dev/null || echo 000)
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

# Trigger a folder rescan. Idempotent; harmless if already scanning.
st_rescan() {
  local folder="${1:-$SYNCTHING_FOLDER_ID}"
  _st_curl POST "/rest/db/scan?folder=${folder}" >/dev/null 2>&1
}

# Returns the folder's state: idle / scanning / syncing / error / unknown.
st_folder_state() {
  local folder="${1:-$SYNCTHING_FOLDER_ID}"
  local resp
  resp=$(_st_curl GET "/rest/db/status?folder=${folder}" 2>/dev/null) || {
    echo "unknown"; return
  }
  echo "$resp" | jq -r '.state // "unknown"'
}

# Block until the folder is idle (or timeout). Returns 0 on idle, non-zero
# on timeout / error. Used between capture and deploy so deploy reads the
# post-replication state.
st_wait_idle() {
  local folder="${1:-$SYNCTHING_FOLDER_ID}"
  local timeout="${2:-15}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    case "$(st_folder_state "$folder")" in
      idle)              return 0 ;;
      scanning|syncing)  ;;          # keep polling
      *)                 return 1 ;; # error / unknown
    esac
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# Number of connected peer devices (excluding ourselves).
st_peer_count() {
  local resp
  resp=$(_st_curl GET "/rest/system/connections" 2>/dev/null) || { echo 0; return; }
  echo "$resp" | jq '[.connections | to_entries[] | select(.value.connected == true)] | length' 2>/dev/null \
    || echo 0
}

# Emit JSON summary suitable for `dotsync ui` and `dotsync status`.
st_summary() {
  local folder="${1:-$SYNCTHING_FOLDER_ID}"
  if ! st_running; then
    printf '{"running":false}\n'
    return
  fi
  local state peers
  state=$(st_folder_state "$folder")
  peers=$(st_peer_count)
  printf '{"running":true,"folder":"%s","state":"%s","peers":%d}\n' \
    "$folder" "$state" "$peers"
}

# List sync-conflict files in the data dir. Output: one path per line.
st_list_conflicts() {
  find "$ENV_REPO_ROOT" -name '*.sync-conflict-*' -type f 2>/dev/null
}
