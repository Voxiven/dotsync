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

# Emit one encoded project name per line.
project_names() {
  jq -r '.projects[].encoded' "$PROJECTS_REGISTRY"
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
