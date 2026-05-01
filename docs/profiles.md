# Profile Schema (v1)

A profile is a JSON file in `profiles/` describing one tool's syncable
state. The capture/deploy engine reads the profile and translates it
into rsync calls.

## Top-level fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Profile identifier; matches the filename. Used in CLI: `dotsync enable <name>`. |
| `schema_version` | int | 1 today. |
| `description` | string | One-liner shown in `dotsync profiles`. |
| `homepage` | string (optional) | Tool's homepage URL. |
| `experimental` | bool (optional) | If true, marked as such in CLI listings. |
| `iterates_per_project` | bool | If true, paths with `${PROJECT}` / `${CC_ENCODED}` are expanded once per project in the projects registry. |
| `paths` | array | One entry per syncable item. |

## Path entries

All entries support these fields:

| Field | Type | Description |
|---|---|---|
| `id` | string | Stable identifier within the profile. |
| `type` | enum | See "Path types" below. |
| `from` / `to` / `real` / `shared` | string | Path templates. Variables: `${HOME}`, `${DOTSYNC_PROJECT_ROOT}`, `${PROJECT}`, `${CC_ENCODED}`. |
| `skip_if_empty` | bool | Don't capture if source file is zero bytes. |
| `skip_if_missing` | bool | Don't error if source doesn't exist (treat as no-op). |

## Path types

### `file`
Single file. Captured via `rsync -a --checksum`. Encrypted automatically if the destination falls under a git-crypt-encrypted prefix in `.gitattributes`.

```json
{ "type": "file", "from": "${HOME}/.foo/config.json", "to": "foo/config.json" }
```

### `directory`
Whole directory tree. Captured via `rsync -a --checksum --delete`.

```json
{ "type": "directory", "from": "${HOME}/.foo/snippets/", "to": "foo/snippets/" }
```

### `session_jsonls`
Per-project JSONL files (Claude Code sessions). Filters by include globs, excludes specified subdirs, drops files above `max_file_mb`.

```json
{
  "type": "session_jsonls",
  "from": "${HOME}/.claude/projects/${CC_ENCODED}/",
  "to": "claude-code/sessions/${PROJECT}/",
  "include_globs": ["*.jsonl"],
  "exclude_dirs": ["subagents"],
  "max_file_mb": 50
}
```

### `shared_per_project_symlink`
A single shared directory in the repo, symlinked from a per-project location on disk. Used by Claude Code memory: every project's `memory/` symlinks to one shared store. Different from `directory` because the on-disk paths are per-project but the storage is unified.

```json
{
  "type": "shared_per_project_symlink",
  "real": "${HOME}/.claude/projects/${CC_ENCODED}/memory",
  "shared": "claude-code/memory/"
}
```

## Variables

| Variable | Resolved per | Source |
|---|---|---|
| `${HOME}` | machine | `$HOME` env var |
| `${DOTSYNC_PROJECT_ROOT}` | machine | `~/.config/dotsync/config.sh` |
| `${PROJECT}` | project | `projects.json` schema v2 `name` |
| `${CC_ENCODED}` | project + machine | `${DOTSYNC_PROJECT_ROOT}/${PROJECT}` with `/` → `-`; matches Claude Code's encoding |

## Encryption

Encryption is a property of the destination path under git-crypt's
`.gitattributes`, not the profile. Convention: anything under
`<profile-name>/` is encrypted by default. Plaintext exceptions
(e.g. README files inside the data repo) are explicitly listed in
`.gitattributes`.

## Adding a new profile

1. Drop a JSON file at `profiles/<name>.json` matching this schema.
2. The user runs `dotsync enable <name>` to turn it on.
3. Sync engine picks up the profile on its next cycle; no code change
   needed for tools that fit the existing path types.

If a tool needs custom logic (e.g. a tool-specific path remap), add a
new `type` to the schema and implement its capture/deploy in the
engine. Avoid this when possible.
