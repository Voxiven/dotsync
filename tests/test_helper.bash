# Common test setup, sourced by every *.bats file.
#
# Every test gets an isolated sandbox: its own DOTSYNC_DATA_DIR,
# DOTSYNC_STATE_DIR, DOTSYNC_CONFIG, DOTSYNC_KC_SERVICE. Nothing touches
# the host's real dotsync setup.

# Locate the tool dir from this file's location.
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTSYNC="$TOOL_DIR/bin/dotsync"

# Per-test sandbox. Bats provides $BATS_TEST_TMPDIR but we set up the
# dotsync env vars so subprocesses inherit them.
sandbox_setup() {
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME/.config/dotsync" "$TEST_HOME/.claude"

  # Override dotsync's view of paths so we never touch the real ones.
  export DOTSYNC_CONFIG="$TEST_HOME/.config/dotsync/config.sh"
  export DOTSYNC_DATA_DIR="$BATS_TEST_TMPDIR/data"
  export DOTSYNC_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export DOTSYNC_KC_SERVICE="test.dotsync.bats"

  mkdir -p "$DOTSYNC_DATA_DIR/registry" "$DOTSYNC_STATE_DIR"

  # Minimal config.
  cat > "$DOTSYNC_CONFIG" <<EOF
DOTSYNC_DATA_DIR="$DOTSYNC_DATA_DIR"
DOTSYNC_STATE_DIR="$DOTSYNC_STATE_DIR"
DOTSYNC_KC_SERVICE="$DOTSYNC_KC_SERVICE"
DOTSYNC_PROJECT_ROOT="$TEST_HOME/code"
SYNCTHING_FOLDER_ID="dotsync-data-test"
SYNCTHING_API_BASE="http://127.0.0.1:65535"
EOF

  # Pretend $HOME is the sandbox so any "$HOME/..." path expansion in
  # scripts doesn't touch the real home.
  export HOME="$TEST_HOME"

  # Empty registries (most tests start from blank).
  echo '{"profiles":[]}'                 > "$DOTSYNC_DATA_DIR/registry/enabled-profiles.json"
  echo '{"version":2,"projects":[]}'     > "$DOTSYNC_DATA_DIR/registry/projects.json"
  echo '{"secrets":[]}'                  > "$DOTSYNC_DATA_DIR/registry/secrets.json"
}

# Clean up after each test. Bats's $BATS_TEST_TMPDIR is auto-removed,
# but if anything escapes (Keychain entry from a test that called
# `dotsync init` for real, etc.), clean it here.
sandbox_teardown() {
  # If a test created a Keychain entry under our test service, remove it.
  security delete-generic-password -s "$DOTSYNC_KC_SERVICE" -a default 2>/dev/null || true
  # Unload any test launchd plist that leaked through.
  local plist="$HOME/Library/LaunchAgents/$DOTSYNC_KC_SERVICE.plist"
  [[ -f "$plist" ]] && {
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  } || true
}

# Run dotsync subcommand, capture stdout/stderr/status into bats's
# $output and $status. Wraps `run` for readability.
run_dotsync() {
  run "$DOTSYNC" "$@"
}

# Source a script's helpers in the current shell so tests can call
# internal functions directly (e.g. profile_run_all, _expand_template).
source_internals() {
  # shellcheck source=/dev/null
  source "$TOOL_DIR/bin/_common.sh"
  # shellcheck source=/dev/null
  source "$TOOL_DIR/bin/_registry.sh"
  # shellcheck source=/dev/null
  source "$TOOL_DIR/bin/_profile.sh"
}
