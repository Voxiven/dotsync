#!/usr/bin/env bats
# Tests for per-machine state location — these MUST live in
# $DOTSYNC_STATE_DIR (per-machine, never replicated), NOT in
# $DOTSYNC_DATA_DIR (the Syncthing-replicated folder). This was the
# root cause of the .sync-conflict-* loop fixed in Phase 4.8.

load test_helper

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

_load_syncthing() {
  source_internals
  # shellcheck source=/dev/null
  source "$TOOL_DIR/bin/_syncthing.sh"
}

@test "ENV_LASTSYNC_FILE is in DOTSYNC_STATE_DIR, not DOTSYNC_DATA_DIR" {
  source_internals
  [[ "$ENV_LASTSYNC_FILE" == "$DOTSYNC_STATE_DIR/last-sync" ]]
  [[ "$ENV_LASTSYNC_FILE" != *"$DOTSYNC_DATA_DIR"* ]]
}

@test "ENV_PAUSE_FLAG is in DOTSYNC_STATE_DIR" {
  source_internals
  [[ "$ENV_PAUSE_FLAG" == "$DOTSYNC_STATE_DIR/sync-paused" ]]
  [[ "$ENV_PAUSE_FLAG" != *"$DOTSYNC_DATA_DIR"* ]]
}

@test "ENV_LOCK_DIR is in DOTSYNC_STATE_DIR" {
  source_internals
  [[ "$ENV_LOCK_DIR" == "$DOTSYNC_STATE_DIR/sync.lock" ]]
  [[ "$ENV_LOCK_DIR" != *"$DOTSYNC_DATA_DIR"* ]]
}

@test "pause writes flag to state dir, not data dir" {
  run_dotsync pause
  [ "$status" -eq 0 ]
  [[ -f "$DOTSYNC_STATE_DIR/sync-paused" ]]
  [[ ! -f "$DOTSYNC_DATA_DIR/.sync-paused" ]]
  [[ ! -f "$DOTSYNC_DATA_DIR/sync-paused" ]]
}

@test "resume removes the state-dir flag" {
  run_dotsync pause
  run_dotsync resume
  [ "$status" -eq 0 ]
  [[ ! -f "$DOTSYNC_STATE_DIR/sync-paused" ]]
}

@test "is_paused detects the flag" {
  source_internals
  set_paused
  is_paused
  clear_paused
  ! is_paused
}

@test "st_write_stignore: creates .stignore when missing" {
  _load_syncthing
  [[ ! -f "$DOTSYNC_DATA_DIR/.stignore" ]]
  st_write_stignore
  [[ -f "$DOTSYNC_DATA_DIR/.stignore" ]]
  grep -q "*.sync-conflict-*" "$DOTSYNC_DATA_DIR/.stignore"
  grep -q "subagents" "$DOTSYNC_DATA_DIR/.stignore"
}

@test "st_write_stignore: idempotent — no rewrite when content matches" {
  _load_syncthing
  st_write_stignore
  local mt1; mt1=$(stat -f '%m' "$DOTSYNC_DATA_DIR/.stignore")
  sleep 1
  st_write_stignore
  local mt2; mt2=$(stat -f '%m' "$DOTSYNC_DATA_DIR/.stignore")
  [[ "$mt1" == "$mt2" ]]
}

@test "env-sync: reclaims stale lock when holder PID is dead" {
  source_internals
  mkdir -p "$DOTSYNC_DATA_DIR"
  # Stale lock with a guaranteed-dead PID.
  mkdir "$DOTSYNC_STATE_DIR/sync.lock"
  echo "9999999" > "$DOTSYNC_STATE_DIR/sync.lock/pid"

  # Run env-sync. Without Syncthing in the sandbox it'll exit at the
  # st_running check, but lock reclaim happens before that and the
  # cleanup trap should remove the lock on exit.
  run "$TOOL_DIR/bin/env-sync"
  [[ ! -d "$DOTSYNC_STATE_DIR/sync.lock" ]]
}

@test "env-sync: respects live lock (no reclaim, exits cleanly)" {
  source_internals
  mkdir -p "$DOTSYNC_DATA_DIR"
  # Lock with the test runner's own PID — definitely alive.
  mkdir "$DOTSYNC_STATE_DIR/sync.lock"
  echo "$$" > "$DOTSYNC_STATE_DIR/sync.lock/pid"

  run "$TOOL_DIR/bin/env-sync"
  # Lock still there with our PID (env-sync did not touch it).
  [[ -d "$DOTSYNC_STATE_DIR/sync.lock" ]]
  [[ "$(cat "$DOTSYNC_STATE_DIR/sync.lock/pid")" == "$$" ]]
}

@test "st_write_stignore: heals when content drifted" {
  _load_syncthing
  echo "bad content" > "$DOTSYNC_DATA_DIR/.stignore"
  st_write_stignore
  grep -q "*.sync-conflict-*" "$DOTSYNC_DATA_DIR/.stignore"
  ! grep -q "bad content" "$DOTSYNC_DATA_DIR/.stignore"
}
