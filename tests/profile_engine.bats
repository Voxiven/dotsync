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

# 0.8.0+: profile uses ${MACHINE}/${PROJECT}/ in the to-path. Each peer
# only writes to its own subdir; deploy unions all peers' subdirs +
# legacy <project>/ location and atomically writes the merged result.
_write_sessions_profile() {
  local src="$1"
  cat > "$TEST_PROFILE_DIR/test.json" <<JSON
{"name":"test","schema_version":2,"iterates_per_project":false,
 "paths":[{"id":"sessions","type":"session_jsonls",
           "from":"${src}/","to":"test/sessions/\${MACHINE}/proj/",
           "max_file_mb":50}]}
JSON
  echo '{"profiles":["test"]}' > "$ENABLED_PROFILES_FILE"
}

@test "_machine_id sanitizes to filesystem-safe characters" {
  source_internals
  DOTSYNC_MACHINE_ID="hello world!@#$%" run _machine_id
  [[ "$output" == "helloworld" ]]
}

@test "_machine_id falls back to hostname -s when DOTSYNC_MACHINE_ID unset" {
  source_internals
  unset DOTSYNC_MACHINE_ID
  run _machine_id
  [[ -n "$output" ]]
  [[ "$output" != *" "* ]]
}

@test "_expand_template substitutes \${MACHINE}" {
  source_internals
  DOTSYNC_MACHINE_ID="mac-a" run _expand_template 'sessions/${MACHINE}/proj/' ""
  [[ "$output" == "sessions/mac-a/proj/" ]]
}

@test "session_jsonls: capture writes to per-machine subdir (no idle gate)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/freshly-written.jsonl"
  _write_sessions_profile "$src"

  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" capture

  # 0.8.0: even just-modified files capture immediately; no idle gate.
  [[ -f "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/freshly-written.jsonl" ]]
  # And NOT in the legacy non-machine path.
  [[ ! -f "$DOTSYNC_DATA_DIR/test/sessions/proj/freshly-written.jsonl" ]]
}

@test "session_jsonls: capture skips sync-conflict sidecars in source" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src"
  echo '{"line":1}' > "$src/abc.jsonl"
  echo '{"line":2}' > "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"
  _write_sessions_profile "$src"

  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" capture

  [[ -f "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl" ]]
  [[ ! -f "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl" ]]
}

@test "session_jsonls: deploy line-union merges two peers' versions of same session" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" \
           "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj" \
           "$DOTSYNC_DATA_DIR/test/sessions/mac-b/proj"

  # mac-a wrote lines 1, 2.
  printf '{"timestamp":"2026-05-02T10:00:00Z","line":1}\n{"timestamp":"2026-05-02T10:01:00Z","line":2}\n' \
    > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  # mac-b wrote line 3 in between, line 4 after.
  printf '{"timestamp":"2026-05-02T10:00:30Z","line":3}\n{"timestamp":"2026-05-02T10:02:00Z","line":4}\n' \
    > "$DOTSYNC_DATA_DIR/test/sessions/mac-b/proj/abc.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  # Merged result: 4 unique lines, sorted by timestamp (1, 3, 2, 4).
  [[ -f "$src/abc.jsonl" ]]
  [[ "$(wc -l < "$src/abc.jsonl")" -eq 4 ]]
  [[ "$(awk 'NR==1' "$src/abc.jsonl")" == *'"line":1'* ]]
  [[ "$(awk 'NR==2' "$src/abc.jsonl")" == *'"line":3'* ]]
  [[ "$(awk 'NR==3' "$src/abc.jsonl")" == *'"line":2'* ]]
  [[ "$(awk 'NR==4' "$src/abc.jsonl")" == *'"line":4'* ]]
}

@test "session_jsonls: deploy preserves local lines that haven't been captured yet" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj"

  # Peer wrote one line.
  printf '{"timestamp":"2026-05-02T10:00:00Z","line":"peer"}\n' \
    > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  # Local has another line CC just wrote (not yet captured to data dir).
  printf '{"timestamp":"2026-05-02T10:01:00Z","line":"local-pending"}\n' \
    > "$src/abc.jsonl"
  # Backdate so race-protection (skip-if-fresh) doesn't kick in.
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$src/abc.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  # Both lines must survive the merge.
  grep -q '"line":"peer"' "$src/abc.jsonl"
  grep -q '"line":"local-pending"' "$src/abc.jsonl"
}

@test "session_jsonls: deploy reads legacy 0.7.x location (graceful migration)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/proj"

  # Legacy: pre-0.8.0 layout, no <machine>/ prefix.
  printf '{"timestamp":"2026-05-02T10:00:00Z","line":"legacy"}\n' \
    > "$DOTSYNC_DATA_DIR/test/sessions/proj/legacy-session.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  # Deploy still picks up legacy files so users on mid-migration setups
  # don't lose access to their old sessions.
  [[ -f "$src/legacy-session.jsonl" ]]
  grep -q '"line":"legacy"' "$src/legacy-session.jsonl"
}

@test "session_jsonls: deploy excludes sync-conflict sidecars from peer subdirs" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj"
  echo '{"line":1}' > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  echo '{"line":2}' > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  [[ -f "$src/abc.jsonl" ]]
  [[ ! -f "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl" ]]
}

@test "session_jsonls: deploy is a no-op when merged content matches local (preserves CC's open fd)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj"
  printf '{"line":"x"}\n' > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  printf '{"line":"x"}\n' > "$src/abc.jsonl"
  touch -t "$(date -v-1H +%Y%m%d%H%M)" "$src/abc.jsonl"
  local inode_before
  inode_before=$(stat -f '%i' "$src/abc.jsonl")

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  # No content change → no atomic-rename → same inode (CC's open fd
  # would still be valid). Critical for not losing in-flight CC writes.
  local inode_after
  inode_after=$(stat -f '%i' "$src/abc.jsonl")
  [[ "$inode_before" == "$inode_after" ]]
}

@test "session_jsonls: deploy skips local files written within the last 2s (race protection)" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj"
  # Peer pushed a different version.
  printf '{"line":"from-peer"}\n' > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  # Local was just modified (within 2s) — CC may be mid-append.
  printf '{"line":"in-flight"}\n' > "$src/abc.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

  # Local content unchanged this cycle. Next cycle (>2s later) merges it.
  [[ "$(cat "$src/abc.jsonl")" == '{"line":"in-flight"}' ]]
}

@test "session_jsonls: deploy cleans up legacy sidecar already in destination" {
  src="$HOME/.claude/projects/test"
  mkdir -p "$src" "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj"
  echo '{"line":1}' > "$DOTSYNC_DATA_DIR/test/sessions/mac-a/proj/abc.jsonl"
  # Pre-existing legacy sidecar in $src from a 0.5.x deploy.
  echo '{"stale":1}' > "$src/abc.sync-conflict-20260501-203217-XA7N5BU.jsonl"

  _write_sessions_profile "$src"
  DOTSYNC_MACHINE_ID="mac-a" profile_run "test" deploy

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
