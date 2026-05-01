#!/usr/bin/env bats
# Tests for _profile.sh path-type dispatch.
#
# Each path type has a small isolated test: capture/deploy a fixture,
# verify the side effect (file copied, symlink created, etc.).

load test_helper

setup() {
  sandbox_setup
  source_internals
  # Stand up a tiny custom profile at runtime so we can vary path types.
  TEST_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$TEST_PROFILE_DIR"
  PROFILES_DIR="$TEST_PROFILE_DIR"
  ENABLED_PROFILES_FILE="$DOTSYNC_DATA_DIR/registry/enabled-profiles.json"
}
teardown() { sandbox_teardown; }

write_profile() {
  cat > "$TEST_PROFILE_DIR/test.json"
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"
}

@test "_expand_template substitutes \${HOME} and \${PROJECT}" {
  result=$(_expand_template '${HOME}/foo/${PROJECT}/bar' "MyProject")
  [[ "$result" == "$HOME/foo/MyProject/bar" ]]
}

@test "_expand_template substitutes \${CC_ENCODED}" {
  export DOTSYNC_PROJECT_ROOT="/Users/me/code"
  result=$(_expand_template '${HOME}/.claude/projects/${CC_ENCODED}' "Omphalis")
  [[ "$result" == *"-Users-me-code-Omphalis"* ]]
}

@test "symlink_file: creates a symlink, migrates existing content" {
  # Set up: a real file at the "from" path with content.
  src="$HOME/.foo/config.json"
  mkdir -p "$(dirname "$src")"
  echo "live content" > "$src"

  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{
  "name": "test",
  "schema_version": 2,
  "iterates_per_project": false,
  "paths": [
    {"id": "config", "type": "symlink_file",
     "from": "${HOME}/.foo/config.json",
     "to": "test/config.json"}
  ]
}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"

  profile_run "test" capture

  # Now: $src should be a symlink, content should be at the repo path.
  [[ -L "$src" ]]
  target="$(readlink "$src")"
  [[ "$target" == "$DOTSYNC_DATA_DIR/test/config.json" ]]
  [[ "$(cat "$src")" == "live content" ]]
  [[ "$(cat "$DOTSYNC_DATA_DIR/test/config.json")" == "live content" ]]
}

@test "symlink_file: idempotent — re-running is a no-op" {
  src="$HOME/.foo/config.json"
  mkdir -p "$(dirname "$src")"
  echo "x" > "$src"
  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{"name":"test","schema_version":2,"iterates_per_project":false,
 "paths":[{"id":"c","type":"symlink_file",
           "from":"${HOME}/.foo/config.json","to":"test/config.json"}]}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"

  profile_run "test" capture
  inode1=$(stat -f '%i' "$DOTSYNC_DATA_DIR/test/config.json")
  profile_run "test" capture
  inode2=$(stat -f '%i' "$DOTSYNC_DATA_DIR/test/config.json")
  [[ "$inode1" == "$inode2" ]]
}

@test "symlink_directory: creates a directory symlink" {
  src="$HOME/.bar/agents"
  mkdir -p "$src"
  echo "agent-a" > "$src/a.md"

  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{"name":"test","schema_version":2,"iterates_per_project":false,
 "paths":[{"id":"a","type":"symlink_directory",
           "from":"${HOME}/.bar/agents","to":"test/agents"}]}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"

  profile_run "test" capture

  [[ -L "$src" ]]
  [[ -d "$src/" ]]
  [[ -f "$src/a.md" ]]
  [[ -f "$DOTSYNC_DATA_DIR/test/agents/a.md" ]]
}

@test "iterates_per_project=true with empty projects.json runs non-per-project paths" {
  # Regression: when projects list was empty, the entire profile got
  # skipped, including paths that don't reference \${PROJECT}.
  src="$HOME/.tool/settings"
  mkdir -p "$(dirname "$src")"
  echo "global" > "$src"

  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{"name":"test","schema_version":2,"iterates_per_project":true,
 "paths":[{"id":"settings","type":"symlink_file",
           "from":"${HOME}/.tool/settings","to":"test/settings"}]}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"
  echo '{"version":2,"projects":[]}' > "$DOTSYNC_DATA_DIR/registry/projects.json"

  profile_run "test" capture

  [[ -L "$src" ]]
}

@test "profile_mode_active: false when enabled-profiles.json missing" {
  rm -f "$ENABLED_PROFILES_FILE"
  ! profile_mode_active
}

@test "profile_mode_active: false when profiles array empty" {
  echo '{"profiles":[]}' > "$ENABLED_PROFILES_FILE"
  ! profile_mode_active
}

@test "profile_mode_active: true when at least one profile enabled" {
  echo '{"profiles":["claude-code"]}' > "$ENABLED_PROFILES_FILE"
  profile_mode_active
}
