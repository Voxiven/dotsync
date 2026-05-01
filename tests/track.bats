#!/usr/bin/env bats
# Tests for ad-hoc tracked items (track / untrack / list).

load test_helper

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

@test "track an absolute path adds it to secrets.json" {
  run_dotsync track /tmp/foo.txt
  [ "$status" -eq 0 ]
  count=$(jq -r '.secrets | length' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$count" == "1" ]]

  repo_path=$(jq -r '.secrets[0].repo_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  real_path=$(jq -r '.secrets[0].real_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$repo_path" == "tracked/foo.txt" ]]
  [[ "$real_path" == "/tmp/foo.txt" ]]
}

@test "track a path under \$HOME templates with \${HOME}" {
  run_dotsync track "$HOME/.zshrc"
  [ "$status" -eq 0 ]
  real_path=$(jq -r '.secrets[0].real_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  # MUST be the literal string ${HOME}/.zshrc, not the expanded form.
  [[ "$real_path" == '${HOME}/.zshrc' ]]
}

@test "track --to overrides the default repo path" {
  run_dotsync track "$HOME/.zshrc" --to shell/zshrc
  [ "$status" -eq 0 ]
  repo_path=$(jq -r '.secrets[0].repo_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$repo_path" == "shell/zshrc" ]]
}

@test "track strips leading dot for default repo path" {
  run_dotsync track "$HOME/.tracktest"
  repo_path=$(jq -r '.secrets[0].repo_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$repo_path" == "tracked/tracktest" ]]
}

@test "untrack by substring removes matching entry" {
  run_dotsync track /tmp/foo.txt
  run_dotsync track /tmp/bar.txt
  run_dotsync untrack foo.txt
  [ "$status" -eq 0 ]
  count=$(jq -r '.secrets | length' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$count" == "1" ]]
  remaining=$(jq -r '.secrets[0].real_path' "$DOTSYNC_DATA_DIR/registry/secrets.json")
  [[ "$remaining" == "/tmp/bar.txt" ]]
}

@test "untrack with no matches reports gracefully" {
  run_dotsync untrack nonexistent
  [ "$status" -eq 0 ]
  [[ "$output" == *"no entries match"* ]]
}

@test "list shows registered items" {
  run_dotsync track /tmp/foo.txt
  run_dotsync list
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked/foo.txt"* ]]
  [[ "$output" == *"/tmp/foo.txt"* ]]
}
