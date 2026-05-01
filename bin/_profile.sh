#!/usr/bin/env bash
# Profile-driven capture/deploy. Source, do not exec.
#
# Reads profile JSONs from <tool_dir>/profiles/<name>.json and dispatches
# capture/deploy for each declared path entry based on its type. Activated
# when $DOTSYNC_DATA_DIR/registry/enabled-profiles.json exists; otherwise
# the legacy hardcoded paths in env-sync are used.
set -uo pipefail

: "${ENV_REPO_ROOT:?source _common.sh first}"
require_cmd jq
require_cmd rsync

_profile_tool_dir() {
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dirname "$script_dir"
}

PROFILES_DIR="$(_profile_tool_dir)/profiles"
ENABLED_PROFILES_FILE="$ENV_REPO_ROOT/registry/enabled-profiles.json"

# Returns 0 if profile mode is active (an enabled-profiles.json with at
# least one profile listed). Engine falls back to legacy mode otherwise.
profile_mode_active() {
  [[ -f "$ENABLED_PROFILES_FILE" ]] || return 1
  local count
  count=$(jq -r '.profiles | length' "$ENABLED_PROFILES_FILE" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]]
}

enabled_profiles() {
  [[ -f "$ENABLED_PROFILES_FILE" ]] || return 0
  jq -r '.profiles[]? // empty' "$ENABLED_PROFILES_FILE"
}

# Expand template variables in a string.
# ${HOME}, ${DOTSYNC_PROJECT_ROOT}, ${PROJECT}, ${CC_ENCODED}.
# CC_ENCODED is computed from project root + project name with '/' → '-',
# matching Claude Code's per-machine encoded path scheme.
_expand_template() {
  local s="$1"
  local project="${2:-}"
  local proot="${DOTSYNC_PROJECT_ROOT:-$HOME}"

  s="${s//\$\{HOME\}/$HOME}"
  s="${s//\$\{DOTSYNC_PROJECT_ROOT\}/$proot}"
  s="${s//\$\{PROJECT\}/$project}"

  if [[ -n "$project" ]]; then
    local encoded
    encoded="$(echo "${proot}/${project}" | tr '/' '-')"
    s="${s//\$\{CC_ENCODED\}/$encoded}"
  fi

  echo "$s"
}

# Run all enabled profiles for the given action (capture or deploy).
profile_run_all() {
  local action="$1"
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    profile_run "$name" "$action" || log_warn "profile $name failed during $action"
  done < <(enabled_profiles)
}

# Run a single profile for one action. Iterates per project if the
# profile declares iterates_per_project=true.
profile_run() {
  local name="$1"
  local action="$2"
  local pf="$PROFILES_DIR/$name.json"

  [[ -f "$pf" ]] || { log_warn "profile $name not found at $pf"; return 1; }

  local iterates
  iterates="$(jq -r '.iterates_per_project // false' "$pf")"

  if [[ "$iterates" == "true" ]]; then
    local projects_file="$ENV_REPO_ROOT/registry/projects.json"
    local project_count=0
    if [[ -f "$projects_file" ]]; then
      project_count=$(jq -r '.projects | length' "$projects_file" 2>/dev/null || echo 0)
    fi

    # ALWAYS run paths that don't reference ${PROJECT}/${CC_ENCODED} —
    # those are tool-global (settings.json, CLAUDE.md, agents/, etc.).
    # We pass an empty project; templates that DO use ${PROJECT} will
    # render to invalid paths and the type handlers skip them.
    _profile_run_paths "$name" "$pf" "$action" "" "non-per-project"

    # Then iterate the per-project paths once per registered project.
    if [[ "$project_count" -gt 0 ]]; then
      local proj
      while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        _profile_run_paths "$name" "$pf" "$action" "$proj" "per-project"
      done < <(jq -r '.projects[]?.name // empty' "$projects_file")
    fi
  else
    _profile_run_paths "$name" "$pf" "$action" ""
  fi
}

_profile_run_paths() {
  local name="$1" pf="$2" action="$3" project="$4" mode="${5:-all}"

  local n i entry type from to real shared skip_empty skip_missing
  n=$(jq '.paths | length' "$pf")
  for ((i=0; i<n; i++)); do
    entry="$(jq -c ".paths[$i]" "$pf")"
    type=$(echo "$entry" | jq -r '.type')
    from=$(echo "$entry" | jq -r '.from // empty')
    to=$(echo "$entry" | jq -r '.to // empty')
    real=$(echo "$entry" | jq -r '.real // empty')
    shared=$(echo "$entry" | jq -r '.shared // empty')
    skip_empty=$(echo "$entry" | jq -r '.skip_if_empty // false')
    skip_missing=$(echo "$entry" | jq -r '.skip_if_missing // false')

    # Determine if this path entry references the project (uses
    # ${PROJECT} or ${CC_ENCODED} in any template). Used to gate
    # iteration when iterates_per_project=true.
    local entry_raw="$from $to $real $shared"
    local is_per_project="false"
    [[ "$entry_raw" == *'${PROJECT}'* || "$entry_raw" == *'${CC_ENCODED}'* ]] && is_per_project="true"

    case "$mode" in
      non-per-project) [[ "$is_per_project" == "true" ]] && continue ;;
      per-project)     [[ "$is_per_project" == "false" ]] && continue ;;
      all)             ;;  # run everything
    esac

    [[ -n "$from"   ]] && from="$(_expand_template "$from" "$project")"
    [[ -n "$to"     ]] && to="$(_expand_template "$to" "$project")"
    [[ -n "$real"   ]] && real="$(_expand_template "$real" "$project")"
    [[ -n "$shared" ]] && shared="$(_expand_template "$shared" "$project")"

    case "$type" in
      file)
        _profile_path_file "$action" "$from" "$to" "$skip_empty" "$skip_missing"
        ;;
      directory)
        _profile_path_directory "$action" "$from" "$to" "$skip_missing"
        ;;
      session_jsonls)
        local max_mb; max_mb=$(echo "$entry" | jq -r '.max_file_mb // 50')
        _profile_path_session_jsonls "$action" "$from" "$to" "$max_mb"
        ;;
      shared_per_project_symlink)
        _profile_path_shared_symlink "$action" "$real" "$shared"
        ;;
      symlink_file)
        # Real file at $from is a symlink to $repo/$to. Daemon-less:
        # CC writes through the symlink directly into the Syncthing folder.
        _profile_path_symlink_file "$action" "$from" "$to"
        ;;
      symlink_directory)
        # Real dir at $from is a symlink to $repo/$to. CC writes through.
        # Use for whole-tree replication (e.g. ~/.claude/agents/, project dirs).
        _profile_path_symlink_directory "$action" "$from" "$to"
        ;;
      *)
        log_warn "unknown path type: $type (profile=$name id=$(echo "$entry" | jq -r '.id // "?"'))"
        ;;
    esac
  done
}

# ── Path type handlers ────────────────────────────────────────────────

_profile_path_file() {
  local action="$1" from="$2" to="$3" skip_empty="$4" skip_missing="$5"
  local repo_full="$ENV_REPO_ROOT/$to"

  case "$action" in
    capture)
      # Skip symlinks (legacy install pattern), missing files, empties.
      [[ -L "$from" ]] && return 0
      [[ ! -f "$from" ]] && return 0
      [[ ! -s "$from" && "$skip_empty" == "true" ]] && return 0
      mkdir -p "$(dirname "$repo_full")"
      rsync -a --checksum "$from" "$repo_full"
      ;;
    deploy)
      [[ -s "$repo_full" ]] || return 0
      [[ -L "$from" ]] && return 0   # don't clobber legacy symlink
      mkdir -p "$(dirname "$from")"
      rsync -a --checksum "$repo_full" "$from"
      ;;
  esac
}

_profile_path_directory() {
  local action="$1" from="$2" to="$3" skip_missing="$4"
  local repo_full="$ENV_REPO_ROOT/$to"

  # Normalize trailing slashes for rsync semantics.
  from="${from%/}/"
  repo_full="${repo_full%/}/"

  case "$action" in
    capture)
      [[ -d "${from%/}" ]] || return 0
      mkdir -p "$repo_full"
      # --delete so removed local files don't accumulate in the repo.
      rsync -a --checksum --delete "$from" "$repo_full"
      ;;
    deploy)
      [[ -d "${repo_full%/}" ]] || return 0
      mkdir -p "$from"
      # No --delete on deploy: respect machine-local files.
      rsync -a --checksum "$repo_full" "$from"
      ;;
  esac
}

_profile_path_session_jsonls() {
  local action="$1" from="$2" to="$3" max_mb="$4"
  local repo_full="$ENV_REPO_ROOT/$to"
  local skip="${DOTSYNC_SKIP_PROJECTS:-}"
  # Sessions modified more recently than this are "active" and stay
  # local — only captured/deployed once the writer has paused. This
  # prevents the dual-machine same-session conflict storm: when both
  # peers append to the same active JSONL, Syncthing creates a sidecar
  # every few seconds and no merge cadence can keep up. Idle-gating
  # means convergence only happens once per close, not per write.
  local idle_secs="${DOTSYNC_SESSION_IDLE_THRESHOLD:-300}"

  # Honor skip list — if to-path's last segment matches a skip token,
  # don't capture or deploy.
  local last="${to%/}"; last="${last##*/}"
  if [[ " $skip " == *" $last "* ]]; then
    case "$action" in
      capture) rm -rf "$repo_full" 2>/dev/null || true ;;
    esac
    return 0
  fi

  case "$action" in
    capture)
      [[ -d "${from%/}" ]] || return 0
      mkdir -p "$repo_full"
      local now epoch_cutoff
      now=$(date +%s)
      epoch_cutoff=$((now - idle_secs))
      # Skip active sessions (mtime within $idle_secs) and any
      # sync-conflict sidecars that may have leaked into the source dir
      # from earlier 0.5.x deploys.
      find "${from%/}" -maxdepth 1 -name '*.jsonl' -size "-${max_mb}M" \
        ! -name '*.sync-conflict-*' 2>/dev/null \
        | while read -r jf; do
            local mt
            mt=$(stat -f '%m' "$jf" 2>/dev/null || echo 0)
            [[ "$mt" -gt "$epoch_cutoff" ]] && continue
            rsync -a --checksum "$jf" "$repo_full/$(basename "$jf")"
          done
      ;;
    deploy)
      [[ -d "${repo_full%/}" ]] || return 0
      mkdir -p "${from%/}"
      # Per-file deploy: only overwrite local if the data-dir copy is
      # newer or local doesn't exist. Protects an active local session
      # from being clobbered by stale state replicated from a peer.
      # Also excludes sync-conflict sidecars — they'd otherwise show up
      # in CC's session picker as ghost resumable sessions.
      find "${repo_full%/}" -maxdepth 1 -name '*.jsonl' \
        ! -name '*.sync-conflict-*' 2>/dev/null \
        | while read -r src; do
            local dst="${from%/}/$(basename "$src")"
            if [[ -f "$dst" ]]; then
              local src_mt dst_mt
              src_mt=$(stat -f '%m' "$src" 2>/dev/null || echo 0)
              dst_mt=$(stat -f '%m' "$dst" 2>/dev/null || echo 0)
              [[ "$dst_mt" -gt "$src_mt" ]] && continue
            fi
            rsync -a --checksum "$src" "$dst"
          done
      # Cleanup: any sidecar left over in $from from earlier 0.5.x
      # deploys gets removed. Idempotent — safe to run every cycle.
      find "${from%/}" -maxdepth 1 -name '*.sync-conflict-*.jsonl' -type f \
        -delete 2>/dev/null || true
      ;;
  esac
}

_profile_path_symlink_file() {
  # In syncthing engine, CC writes through a symlink directly into the
  # Syncthing folder. capture/deploy is "ensure the symlink is correct"
  # — idempotent on subsequent calls, no content copy.
  #
  # Migration: if $from is currently a regular file (e.g. v0.3 setup),
  # move its content to $repo_full and replace with a symlink.
  local action="$1" from="$2" to="$3"
  local repo_full="$ENV_REPO_ROOT/$to"

  case "$action" in
    capture|deploy)
      mkdir -p "$(dirname "$repo_full")"
      mkdir -p "$(dirname "$from")"

      # Already the right symlink? Done.
      if [[ -L "$from" ]]; then
        local target; target="$(readlink "$from")"
        if [[ "$target" == "$repo_full" ]]; then
          # Ensure the target file exists (so reads don't fail).
          [[ -e "$repo_full" ]] || touch "$repo_full"
          return 0
        fi
        # Symlink points elsewhere — replace.
        rm "$from"
      elif [[ -f "$from" ]]; then
        # Real file: migrate content into the Syncthing folder if repo
        # doesn't already have it.
        if [[ -s "$from" && ! -s "$repo_full" ]]; then
          cp "$from" "$repo_full"
        fi
        rm "$from"
      elif [[ -e "$from" ]]; then
        log_warn "cannot symlink: $from exists but is not a file or symlink"
        return 1
      fi

      # Ensure the target exists, then create the symlink.
      [[ -e "$repo_full" ]] || touch "$repo_full"
      ln -s "$repo_full" "$from"
      ;;
  esac
}

_profile_path_symlink_directory() {
  # Same as symlink_file, but for whole directories. Use for
  # ~/.claude/agents/, ~/.claude/commands/, and per-project dirs.
  #
  # Migration: if $from is currently a real dir, rsync its contents
  # into $repo_full (preserving any existing peer content), then remove
  # $from and replace with a symlink.
  local action="$1" from="$2" to="$3"
  local repo_full="$ENV_REPO_ROOT/$to"
  from="${from%/}"
  repo_full="${repo_full%/}"

  case "$action" in
    capture|deploy)
      mkdir -p "$(dirname "$repo_full")"
      mkdir -p "$(dirname "$from")"

      if [[ -L "$from" ]]; then
        local target; target="$(readlink "$from")"
        if [[ "$target" == "$repo_full" ]]; then
          mkdir -p "$repo_full"
          return 0
        fi
        rm "$from"
      elif [[ -d "$from" ]]; then
        # Real dir: merge contents into the Syncthing folder (peer
        # content takes precedence on overlap; rsync without --delete).
        mkdir -p "$repo_full"
        rsync -a "$from/" "$repo_full/"
        rm -rf "$from"
      elif [[ -e "$from" ]]; then
        log_warn "cannot symlink: $from exists but is not a directory or symlink"
        return 1
      fi

      mkdir -p "$repo_full"
      ln -s "$repo_full" "$from"
      ;;
  esac
}

_profile_path_shared_symlink() {
  local action="$1" real="$2" shared="$3"
  local shared_full="$ENV_REPO_ROOT/$shared"
  shared_full="${shared_full%/}"

  case "$action" in
    capture)
      # Capture is implicit: writes through the symlink already land in
      # shared_full. Just ensure shared_full exists.
      mkdir -p "$shared_full"
      ;;
    deploy)
      mkdir -p "$shared_full"
      mkdir -p "$(dirname "$real")"
      if [[ -L "$real" ]]; then
        local target
        target="$(readlink "$real")"
        [[ "$target" == "$shared_full" ]] && return 0
        rm "$real"
      elif [[ -d "$real" && ! -L "$real" ]]; then
        # User has a regular dir at "real" — merge contents into shared,
        # then replace with symlink.
        rsync -a "$real/" "$shared_full/"
        rm -rf "$real"
      fi
      ln -sfn "$shared_full" "$real"
      ;;
  esac
}
