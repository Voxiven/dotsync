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

# Helper: emit a session_jsonls profile pointing at $src (a project-local
# sessions dir) and into $repo_subpath inside DOTSYNC_DATA_DIR.
_write_sessions_profile() {
  local src="$1" repo_subpath="$2"
  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{"name":"test","schema_version":2,"iterates_per_project":false,
 "paths":[{"id":"sessions","type":"session_jsonls",
           "from":"${src}/","to":"${repo_subpath}/",
           "max_file_mb":50}]}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"
}

@test "session_jsonls: capture skips active session (mtime within idle threshold)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/active-session.jsonl"
  # mtime is now (just created) → within default 300s idle threshold
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" capture

  [[ ! -f "$DOTSYNC_DATA_DIR/test/sessions/active-session.jsonl" ]]
}

@test "session_jsonls: capture catches idle session (mtime older than threshold)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/idle-session.jsonl"
  # Backdate mtime to 1 hour ago (well past 300s default threshold).
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$src/idle-session.jsonl"
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" capture

  [[ -f "$DOTSYNC_DATA_DIR/test/sessions/idle-session.jsonl" ]]
}

@test "session_jsonls: capture honors DOTSYNC_SESSION_IDLE_THRESHOLD override" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/recent.jsonl"
  # Just-created file. With threshold=0 it should be treated as idle.
  _write_sessions_profile "$src" "test/sessions"

  DOTSYNC_SESSION_IDLE_THRESHOLD=0 profile_run "test" capture

  [[ -f "$DOTSYNC_DATA_DIR/test/sessions/recent.jsonl" ]]
}

@test "session_jsonls: capture skips sync-conflict sidecars in source" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/abc.jsonl"
  echo '{"line":2}' > "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$src/abc.jsonl" "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" capture

  [[ -f "$DOTSYNC_DATA_DIR/test/sessions/abc.jsonl" ]]
  [[ ! -f "$DOTSYNC_DATA_DIR/test/sessions/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl" ]]
}

@test "session_jsonls: deploy preserves active local session (local newer than data dir)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  repo="$DOTSYNC_DATA_DIR/test/sessions"
  mkdir -p "$repo"

  # Older version in the data dir (would arrive via Syncthing from a peer).
  echo '{"line":"old"}' > "$repo/contested.jsonl"
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$repo/contested.jsonl"

  # Newer local version (CC actively writing).
  echo '{"line":"local-active"}' > "$src/contested.jsonl"
  # mtime is now → newer than data dir's mtime
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" deploy

  [[ "$(cat "$src/contested.jsonl")" == '{"line":"local-active"}' ]]
}

@test "session_jsonls: deploy overwrites local when data dir is newer" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  repo="$DOTSYNC_DATA_DIR/test/sessions"
  mkdir -p "$repo"

  # Older local version.
  echo '{"line":"local-old"}' > "$src/closed.jsonl"
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$src/closed.jsonl"

  # Newer data-dir version (peer just sent us the closed session).
  echo '{"line":"peer-fresh"}' > "$repo/closed.jsonl"
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" deploy

  [[ "$(cat "$src/closed.jsonl")" == '{"line":"peer-fresh"}' ]]
}

@test "session_jsonls: deploy excludes sync-conflict sidecars from data dir" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  repo="$DOTSYNC_DATA_DIR/test/sessions"
  mkdir -p "$repo"
  echo '{"line":1}' > "$repo/abc.jsonl"
  echo '{"line":2}' > "$repo/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" deploy

  [[ -f "$src/abc.jsonl" ]]
  [[ ! -f "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl" ]]
}

@test "session_jsonls: deploy cleans up legacy sidecar already in destination" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  repo="$DOTSYNC_DATA_DIR/test/sessions"
  mkdir -p "$repo"
  echo '{"line":1}' > "$repo/abc.jsonl"
  # Pre-existing legacy sidecar in $src from a 0.5.x deploy.
  echo '{"stale":1}' > "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"
  _write_sessions_profile "$src" "test/sessions"

  profile_run "test" deploy

  [[ -f "$src/abc.jsonl" ]]
  [[ ! -f "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl" ]]
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
