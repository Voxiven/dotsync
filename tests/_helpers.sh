#!/usr/bin/env bash
# Test harness: simulate two machines syncing through a bare local remote.
set -uo pipefail

TEST_TMP=""
TEST_REMOTE=""
TEST_MAC_A=""
TEST_MAC_B=""

setup_test_env() {
  TEST_TMP="$(mktemp -d -t devenv-test.XXXXXX)"
  TEST_REMOTE="${TEST_TMP}/remote.git"
  TEST_MAC_A="${TEST_TMP}/macA"
  TEST_MAC_B="${TEST_TMP}/macB"
  git init --bare "$TEST_REMOTE" >/dev/null
  echo "test-tmp: $TEST_TMP"
}

teardown_test_env() {
  [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# Override Keychain helpers for tests — read identity from a file.
export TEST_IDENTITY_FILE=""
write_test_identity_file() {
  TEST_IDENTITY_FILE="${TEST_TMP}/identity"
  age-keygen -o "$TEST_IDENTITY_FILE" 2>/dev/null
  chmod 600 "$TEST_IDENTITY_FILE"
}

# Re-export Keychain stubs into a child shell (eval this output before running env-* scripts).
export_test_kc_stubs() {
  cat <<'STUB'
kc_get_identity() { grep '^AGE-SECRET-KEY' "$TEST_IDENTITY_FILE"; }
kc_has_identity() { [[ -f "$TEST_IDENTITY_FILE" ]]; }
kc_set_identity() { printf '%s\n' "$1" > "$TEST_IDENTITY_FILE"; chmod 600 "$TEST_IDENTITY_FILE"; }
STUB
}

# Clone the bare remote into a "machine" dir, populate with bin/ + registry/ + .gitattributes
# from the source repo so the machine has the scripts to run.
materialize_machine() {
  local dest="$1"
  git clone "$TEST_REMOTE" "$dest" >/dev/null 2>&1 || die "clone failed"
  cp -R "$ENV_REPO_ROOT/bin"      "$dest/"
  cp -R "$ENV_REPO_ROOT/registry" "$dest/"
  cp    "$ENV_REPO_ROOT/.gitattributes" "$dest/"
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL${msg:+: $msg}"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
  fi
}

assert_file_eq() {
  local f1="$1" f2="$2"
  if ! diff -q "$f1" "$f2" >/dev/null; then
    echo "FAIL: $f1 differs from $f2"
    diff "$f1" "$f2" | head -20
    return 1
  fi
}
