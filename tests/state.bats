#!/usr/bin/env bats
# Tests for per-machine state location — these MUST live in
# $DOTSYNC_STATE_DIR (per-machine, never replicated), NOT in
# $DOTSYNC_DATA_DIR (the Syncthing-replicated folder). This was the
# root cause of the .sync-conflict-* loop fixed in Phase 4.8.

load test_helper

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

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
