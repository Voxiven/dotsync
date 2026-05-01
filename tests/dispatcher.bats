#!/usr/bin/env bats
# Tests for the top-level dotsync dispatcher.

load test_helper

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "dotsync help prints usage" {
  run_dotsync help
  [ "$status" -eq 0 ]
  [[ "$output" == *"multi-machine continuity"* ]]
  [[ "$output" == *"Setup"* ]]
  [[ "$output" == *"Daily use"* ]]
}

@test "dotsync (no args) prints usage and exits 0" {
  run_dotsync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "dotsync version prints version line" {
  run_dotsync version
  [ "$status" -eq 0 ]
  [[ "$output" == *"dotsync 0."* ]]
}

@test "dotsync --version is also accepted" {
  run_dotsync --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"dotsync 0."* ]]
}

@test "unknown command exits 1 with hint" {
  run_dotsync nonexistent-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command"* ]]
  [[ "$output" == *"dotsync help"* ]]
}

@test "help routes to subcommand --help" {
  run_dotsync help status
  [ "$status" -eq 0 ]
  [[ "$output" == *"dotsync status"* ]]
}

@test "subcommand --help works directly" {
  run_dotsync status --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "every subcommand has --help" {
  # The "implements --help" contract for every dotsync-* script.
  for sub in "$TOOL_DIR"/bin/dotsync-*; do
    [[ -L "$sub" ]] && continue   # skip symlinks (disable, resume)
    [[ -x "$sub" ]] || continue
    name="$(basename "$sub")"
    run "$sub" --help
    [ "$status" -eq 0 ] || {
      echo "FAIL: $name --help exited $status" >&2
      echo "$output" >&2
      false
    }
  done
}
