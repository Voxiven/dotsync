#!/usr/bin/env bash
# Keychain + git-crypt + age helpers. Source, do not exec.
set -uo pipefail

: "${ENV_REPO_ROOT:?source _common.sh first}"

KC_SERVICE="${DOTSYNC_KC_SERVICE:-dev.dotsync.envsync}"
KC_ACCOUNT="${DOTSYNC_KC_ACCOUNT:-default}"
GC_KEY_PATH="${ENV_REPO_ROOT}/.git-crypt/keys/default.age"

# Returns the age identity (private key) from Keychain. Single line.
# These three functions are intentionally NOT redefined if already declared —
# tests inject stub versions before sourcing this file.
if ! declare -f kc_get_identity >/dev/null 2>&1; then
kc_get_identity() {
  security find-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w 2>/dev/null \
    || die "no age identity in Keychain (service=$KC_SERVICE account=$KC_ACCOUNT)"
}
fi

if ! declare -f kc_set_identity >/dev/null 2>&1; then
kc_set_identity() {
  local identity="$1"
  security add-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$identity" -U
}
fi

if ! declare -f kc_has_identity >/dev/null 2>&1; then
kc_has_identity() {
  security find-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w >/dev/null 2>&1
}
fi

# Returns 0 if the working tree is currently unlocked (plaintext visible).
is_repo_unlocked() {
  cd "$ENV_REPO_ROOT" || return 1
  # Find the first NON-EMPTY encrypted file and check for git-crypt's magic
  # header (10 bytes: "\0GITCRYPT\0"). NUL bytes can't pass through bash
  # strings or argv, so we hex-encode the first 10 bytes and string-compare.
  local sample magic
  while IFS= read -r sample; do
    [[ -n "$sample" && -s "$sample" ]] || continue
    magic="$(head -c 10 "$sample" 2>/dev/null | xxd -p | tr -d '\n')"
    [[ "$magic" == "00474954435259505400" ]] && return 1   # \0GITCRYPT\0 → locked
    return 0
  done < <(git-crypt status -e 2>/dev/null | awk '$1 == "encrypted:" {print $2}')
  return 0   # no non-empty encrypted files seen → considered unlocked
}

# Decrypts the age-encrypted git-crypt key with the identity from Keychain
# (piped via /dev/stdin so the secret never lands on disk), then runs
# `git-crypt unlock`.
unlock_repo() {
  cd "$ENV_REPO_ROOT" || die "cannot cd to $ENV_REPO_ROOT"
  if is_repo_unlocked; then
    log_info "repo already unlocked"
    return 0
  fi
  [[ -f "$GC_KEY_PATH" ]] || die "missing $GC_KEY_PATH"

  local raw_key; raw_key="$(mktemp -t git-crypt-key.XXXXXX)"
  trap 'rm -P "$raw_key" 2>/dev/null || rm -f "$raw_key"; trap - RETURN' RETURN

  if ! kc_get_identity | age -i /dev/stdin -d -o "$raw_key" "$GC_KEY_PATH" 2>/dev/null; then
    die "age decryption failed (Keychain identity wrong or missing?)"
  fi
  git-crypt unlock "$raw_key" || die "git-crypt unlock failed"
  log_info "repo unlocked"
}
