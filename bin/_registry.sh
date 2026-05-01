#!/usr/bin/env bash
# Registry helpers. Source, do not exec.
set -uo pipefail

: "${ENV_REPO_ROOT:?source _common.sh first}"
require_cmd jq

SECRETS_REGISTRY="${ENV_REPO_ROOT}/registry/secrets.json"
PROJECTS_REGISTRY="${ENV_REPO_ROOT}/registry/projects.json"

# Emit pairs: "<repo_path>\t<expanded_real_path>" — one per line.
secrets_pairs() {
  jq -r '.secrets[] | "\(.repo_path)\t\(.real_path)"' "$SECRETS_REGISTRY" \
    | while IFS=$'\t' read -r repo_p real_p; do
        printf '%s\t%s\n' "$repo_p" "$(expand_path "$real_p")"
      done
}

# Emit one Claude Code-encoded project name per line.
# Schema v2: projects[].name is the project DIRECTORY name (e.g. "Omphalis").
# Encoded name is derived from $DOTSYNC_PROJECT_ROOT/<name> per local machine
# by replacing '/' with '-' (matches Claude Code's encoding scheme).
# Falls back to legacy v1 .encoded field if version < 2.
project_names() {
  local proot="${DOTSYNC_PROJECT_ROOT:-$HOME}"
  local version
  version="$(jq -r '.version // 1' "$PROJECTS_REGISTRY")"
  if [[ "$version" -ge 2 ]]; then
    jq -r '.projects[].name' "$PROJECTS_REGISTRY" | while read -r name; do
      echo "${proot}/${name}" | tr '/' '-'
    done
  else
    jq -r '.projects[].encoded' "$PROJECTS_REGISTRY"
  fi
}

# Emit "<portable_name>\t<local_encoded>" pairs, one per line.
# portable_name is what we use as the in-repo storage path (e.g.
# sessions/Omphalis/) — same on every machine. local_encoded is the
# Claude Code per-machine path (e.g. -Users-foo-Workspace-Omphalis).
project_pairs() {
  local proot="${DOTSYNC_PROJECT_ROOT:-$HOME}"
  local version
  version="$(jq -r '.version // 1' "$PROJECTS_REGISTRY")"
  if [[ "$version" -ge 2 ]]; then
    jq -r '.projects[].name' "$PROJECTS_REGISTRY" | while read -r name; do
      local encoded
      encoded="$(echo "${proot}/${name}" | tr '/' '-')"
      printf '%s\t%s\n' "$name" "$encoded"
    done
  else
    # v1: no portable name; fall back to encoded for both fields. This means
    # cross-machine session sync only works on v1 if both machines use the
    # same DOTSYNC_PROJECT_ROOT — which is the schema's pre-existing limit.
    jq -r '.projects[].encoded' "$PROJECTS_REGISTRY" | while read -r e; do
      printf '%s\t%s\n' "$e" "$e"
    done
  fi
}

# Add a secret idempotently (silent skip if repo_path already present).
registry_add_secret() {
  local repo_p="$1" real_p="$2"
  local tmp; tmp="$(mktemp)"
  jq --arg rp "$repo_p" --arg rl "$real_p" '
    if any(.secrets[]; .repo_path == $rp) then .
    else .secrets += [{repo_path:$rp, real_path:$rl}]
    end
  ' "$SECRETS_REGISTRY" > "$tmp" && mv "$tmp" "$SECRETS_REGISTRY"
}
