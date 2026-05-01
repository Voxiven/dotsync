#!/usr/bin/env bash
# End-to-end test: disjoint edits across two simulated machines auto-merge.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export ENV_REPO_ROOT
source "$ENV_REPO_ROOT/bin/_common.sh"
source "$TEST_DIR/_helpers.sh"

trap teardown_test_env EXIT

echo "Setting up test environment..."
setup_test_env
write_test_identity_file

# Build the test remote from scratch with a clean git-crypt setup.
# We do NOT seed from dev-env because the existing encrypted blobs (*.gitkeep)
# were encrypted with the production symmetric key — they cannot be unlocked
# with a fresh test identity. Instead, create an orphan branch that contains
# only non-encrypted files (bin/, registry/, .gitattributes) plus a fresh
# git-crypt key encrypted to the test identity.
SETUP_CLONE="${TEST_TMP}/setup-clone"
# Point the bare remote's HEAD to dev-env BEFORE cloning so that clones of the
# remote (including materialize_machine) can check out the branch automatically.
git -C "$TEST_REMOTE" symbolic-ref HEAD refs/heads/dev-env
git clone "$TEST_REMOTE" "$SETUP_CLONE" >/dev/null 2>&1 || true
cd "$SETUP_CLONE"

# Orphan so we start with no history (no production-encrypted blobs).
git checkout --orphan dev-env 2>/dev/null || git checkout -b dev-env 2>/dev/null || true
git rm -rf . >/dev/null 2>&1 || true

# Copy non-encrypted bootstrap files from the real repo.
cp "$ENV_REPO_ROOT/.gitattributes" .
cp "$ENV_REPO_ROOT/.gitignore"     . 2>/dev/null || true
cp -R "$ENV_REPO_ROOT/bin"         .
cp -R "$ENV_REPO_ROOT/registry"    .
mkdir -p .git-crypt/keys launchd tests
cp -R "$ENV_REPO_ROOT/tests"       .

# Init git-crypt and generate a fresh symmetric key.
git-crypt init >/dev/null 2>&1
git-crypt export-key /tmp/setup-key.raw 2>/dev/null

# Encrypt the symmetric key to the test identity's public key.
TEST_PUBKEY="$(grep '^# public key:' "$TEST_IDENTITY_FILE" | awk '{print $4}')"
age -r "$TEST_PUBKEY" -o .git-crypt/keys/default.age /tmp/setup-key.raw
rm -P /tmp/setup-key.raw 2>/dev/null || rm -f /tmp/setup-key.raw

# Seed encrypted content dirs with empty gitkeeps so the dirs exist in git.
# These are committed AFTER git-crypt init so they are encrypted with the
# fresh test key (not the production key).
for d in claude/memory claude/projects dotfiles secrets sessions; do
  mkdir -p "$d"
  touch "$d/.gitkeep"
done

git add -A
git -c user.email="test@test" -c user.name="Test" \
  commit -m "test: fresh dev-env scaffold (test git-crypt key)" --quiet

git remote set-url origin "$TEST_REMOTE" 2>/dev/null || true
git push origin dev-env --force >/dev/null 2>&1 || die "setup-clone push to test remote failed"

cd - >/dev/null

# --- Test 1: disjoint edits auto-merge cleanly ---
echo "TEST 1: disjoint edits"
materialize_machine "$TEST_MAC_A"
materialize_machine "$TEST_MAC_B"

EXPORT_STUBS="$(export_test_kc_stubs)"

# Unlock a test machine using the test identity (stubs replicate Keychain).
# No stash needed because the test remote is built from the current working
# tree; clones are identical to what materialize_machine copies in.
unlock_test_machine() {
  local dest="$1"
  cd "$dest"
  # Set ENV_REPO_ROOT AFTER sourcing _common.sh — _common.sh resets it from
  # BASH_SOURCE[0], which is empty in a bash -c context, causing it to resolve
  # incorrectly to the parent directory.  We override it explicitly afterward.
  bash -c "$EXPORT_STUBS
    export -f kc_get_identity kc_has_identity kc_set_identity
    TEST_IDENTITY_FILE='$TEST_IDENTITY_FILE'
    source bin/_common.sh
    ENV_REPO_ROOT='$dest'
    source bin/_crypt.sh
    unlock_repo
  " 2>/dev/null
  cd - >/dev/null
}
unlock_test_machine "$TEST_MAC_A"
unlock_test_machine "$TEST_MAC_B"

# Mac A: edit memory file X
mkdir -p "$TEST_MAC_A/claude/memory"
echo "content-A" > "$TEST_MAC_A/claude/memory/file-X.md"
# Mac B: edit memory file Y
mkdir -p "$TEST_MAC_B/claude/memory"
echo "content-B" > "$TEST_MAC_B/claude/memory/file-Y.md"

run_sync() {
  local dest="$1"
  local fake_home="${TEST_TMP}/_fakehome"
  mkdir -p "$fake_home"
  cd "$dest"
  # Export stubs via export -f so env-sync's re-sourcing of _crypt.sh
  # sees declare -f kc_* already defined and skips the Keychain versions.
  HOME="$fake_home" \
  ENV_REPO_ROOT="$dest" \
  ENV_CONFLICTS_DIR_OVERRIDE="${TEST_TMP}/conflicts-$(basename "$dest")" \
  TEST_IDENTITY_FILE="$TEST_IDENTITY_FILE" \
    bash -c "$EXPORT_STUBS
      export -f kc_get_identity kc_has_identity kc_set_identity
      exec bash bin/env-sync
    "
  local rc=$?
  cd - >/dev/null
  return $rc
}

run_sync "$TEST_MAC_A" || { echo "FAIL: Mac A first sync errored"; exit 1; }
run_sync "$TEST_MAC_B" || { echo "FAIL: Mac B sync errored"; exit 1; }
run_sync "$TEST_MAC_A" || { echo "FAIL: Mac A second sync errored"; exit 1; }

[[ -f "$TEST_MAC_A/claude/memory/file-X.md" ]] || { echo "FAIL: A missing file-X"; exit 1; }
[[ -f "$TEST_MAC_A/claude/memory/file-Y.md" ]] || { echo "FAIL: A missing file-Y"; exit 1; }
[[ -f "$TEST_MAC_B/claude/memory/file-X.md" ]] || { echo "FAIL: B missing file-X"; exit 1; }
[[ -f "$TEST_MAC_B/claude/memory/file-Y.md" ]] || { echo "FAIL: B missing file-Y"; exit 1; }

assert_file_eq "$TEST_MAC_A/claude/memory/file-X.md" "$TEST_MAC_B/claude/memory/file-X.md" || exit 1
assert_file_eq "$TEST_MAC_A/claude/memory/file-Y.md" "$TEST_MAC_B/claude/memory/file-Y.md" || exit 1

echo "PASS: disjoint edits converged on both machines"

# --- Test 2: same-line conflict pauses sync and preserves all three versions ---
echo "TEST 2: same-line conflict"

# Establish a shared base: create conflict.md on A, sync A, then sync B.
mkdir -p "$TEST_MAC_A/claude/memory"
printf 'shared-base-line\n' > "$TEST_MAC_A/claude/memory/conflict.md"
run_sync "$TEST_MAC_A" || { echo "FAIL: T2 Mac A base push errored"; exit 1; }
run_sync "$TEST_MAC_B" || { echo "FAIL: T2 Mac B base pull errored"; exit 1; }

# Mac A overwrites with version-from-A, syncs (push must succeed).
printf 'version-from-A\n' > "$TEST_MAC_A/claude/memory/conflict.md"
run_sync "$TEST_MAC_A" || { echo "FAIL: T2 Mac A version-A push errored"; exit 1; }

# Mac B overwrites with version-from-B without pulling, then syncs.
# This triggers a rebase conflict → env-sync must exit 2.
printf 'version-from-B\n' > "$TEST_MAC_B/claude/memory/conflict.md"
CONFLICT_DIR_B="${TEST_TMP}/conflicts-macB"
run_sync "$TEST_MAC_B" && { echo "FAIL: T2 Mac B sync should have exited non-zero"; exit 1; } || true

# 1. .sync-paused exists in Mac B's repo.
[[ -f "$TEST_MAC_B/.sync-paused" ]] || { echo "FAIL: T2 .sync-paused not created on Mac B"; exit 1; }

# 2. All three conflict versions exist under conflicts-macB/<timestamp>/.
CONFLICT_TS_DIR="$(find "$CONFLICT_DIR_B" -maxdepth 1 -mindepth 1 -type d ! -name '_resolved' | head -1)"
[[ -n "$CONFLICT_TS_DIR" ]] || { echo "FAIL: T2 no conflict timestamp dir under $CONFLICT_DIR_B"; exit 1; }
[[ -f "$CONFLICT_TS_DIR/conflict.md.local"  ]] || { echo "FAIL: T2 conflict.md.local missing";  exit 1; }
[[ -f "$CONFLICT_TS_DIR/conflict.md.remote" ]] || { echo "FAIL: T2 conflict.md.remote missing"; exit 1; }
[[ -f "$CONFLICT_TS_DIR/conflict.md.base"   ]] || { echo "FAIL: T2 conflict.md.base missing";   exit 1; }

# 3. Mac B's working tree is clean (rebase was aborted).
B_STATUS="$(cd "$TEST_MAC_B" && git status --porcelain)"
[[ -z "$B_STATUS" ]] || { echo "FAIL: T2 Mac B working tree not clean after abort: $B_STATUS"; exit 1; }

echo "PASS: same-line conflict paused B and preserved all three versions"

# --- Test 3: env-resolve --prefer local restores sync ---
echo "TEST 3: env-resolve --prefer local"

# Helper: run env-resolve on a machine with the same env overrides as run_sync.
run_resolve() {
  local dest="$1"
  shift
  local fake_home="${TEST_TMP}/_fakehome"
  mkdir -p "$fake_home"
  cd "$dest"
  HOME="$fake_home" \
  ENV_REPO_ROOT="$dest" \
  ENV_CONFLICTS_DIR_OVERRIDE="${TEST_TMP}/conflicts-$(basename "$dest")" \
  TEST_IDENTITY_FILE="$TEST_IDENTITY_FILE" \
    bash -c "$EXPORT_STUBS
      export -f kc_get_identity kc_has_identity kc_set_identity
      exec bash bin/env-resolve $*
    "
  local rc=$?
  cd - >/dev/null
  return $rc
}

# Run env-resolve --prefer local on Mac B (non-interactive: picks local = version-from-B).
run_resolve "$TEST_MAC_B" "--prefer local" || { echo "FAIL: T3 env-resolve exited non-zero"; exit 1; }

# 1. .sync-paused is gone.
[[ ! -f "$TEST_MAC_B/.sync-paused" ]] || { echo "FAIL: T3 .sync-paused still exists on Mac B"; exit 1; }

# 2. The conflict timestamp dir was moved into _resolved/.
RESOLVED_DIR="${CONFLICT_DIR_B}/_resolved"
[[ -d "$RESOLVED_DIR" ]] || { echo "FAIL: T3 _resolved dir not created"; exit 1; }
RESOLVED_TS_DIR="$(find "$RESOLVED_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
[[ -n "$RESOLVED_TS_DIR" ]] || { echo "FAIL: T3 conflict ts dir not moved to _resolved"; exit 1; }

# 3. Mac B's conflict.md now contains version-from-B (local preference).
B_CONTENT="$(cat "$TEST_MAC_B/claude/memory/conflict.md")"
[[ "$B_CONTENT" == "version-from-B" ]] || { echo "FAIL: T3 Mac B conflict.md='$B_CONTENT', want 'version-from-B'"; exit 1; }

# 4. After A syncs, A also sees version-from-B.
run_sync "$TEST_MAC_A" || { echo "FAIL: T3 Mac A final sync errored"; exit 1; }
A_CONTENT="$(cat "$TEST_MAC_A/claude/memory/conflict.md")"
[[ "$A_CONTENT" == "version-from-B" ]] || { echo "FAIL: T3 Mac A conflict.md='$A_CONTENT', want 'version-from-B'"; exit 1; }

echo "PASS: env-resolve --prefer local restored sync"
