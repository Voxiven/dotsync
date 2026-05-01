#!/usr/bin/env bats
# Tests for profile listing + enable/disable.

load test_helper

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "profiles command lists all profiles in profiles/" {
  run_dotsync profiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code"* ]]
  [[ "$output" == *"project-secrets"* ]]
  # All start unchecked since enabled-profiles.json was empty.
  [[ "$output" == *"[ ] claude-code"* ]]
}

@test "profiles --json emits valid JSON" {
  run_dotsync profiles --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.profiles | length > 0' >/dev/null
}

@test "enable adds a profile to enabled-profiles.json" {
  run_dotsync enable claude-code
  [ "$status" -eq 0 ]
  enabled=$(jq -r '.profiles[]' "$DOTSYNC_DATA_DIR/registry/enabled-profiles.json")
  [[ "$enabled" == "claude-code" ]]
}

@test "enable is idempotent" {
  run_dotsync enable claude-code
  run_dotsync enable claude-code
  [ "$status" -eq 0 ]
  count=$(jq -r '.profiles | length' "$DOTSYNC_DATA_DIR/registry/enabled-profiles.json")
  [[ "$count" == "1" ]]
}

@test "disable removes a profile" {
  run_dotsync enable claude-code
  run_dotsync enable project-secrets
  run_dotsync disable claude-code
  [ "$status" -eq 0 ]
  enabled=$(jq -r '.profiles[]' "$DOTSYNC_DATA_DIR/registry/enabled-profiles.json")
  [[ "$enabled" == "project-secrets" ]]
}

@test "disable is idempotent on a not-enabled profile" {
  run_dotsync disable claude-code
  [ "$status" -eq 0 ]
}

@test "enable rejects unknown profile names" {
  run_dotsync enable nonexistent-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such profile"* ]]
}

@test "profiles shows [x] for enabled profiles" {
  run_dotsync enable claude-code
  run_dotsync profiles
  [[ "$output" == *"[x] claude-code"* ]]
  [[ "$output" == *"[ ] project-secrets"* ]]
}
