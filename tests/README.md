# Tests

[bats-core](https://github.com/bats-core/bats-core) test suite. Each test
runs in its own sandbox `$BATS_TEST_TMPDIR` with isolated `DOTSYNC_*`
env vars — no test touches the host's real dotsync setup.

## Run

```bash
brew install bats-core
bats tests/
```

Or run a single file:

```bash
bats tests/dispatcher.bats
```

Or run a single test by name match:

```bash
bats tests/ --filter "track an absolute path"
```

## What's covered

| File | What |
|---|---|
| `dispatcher.bats` | help, version, unknown commands, `--help` on every subcommand |
| `profiles.bats` | `dotsync profiles / enable / disable` registry manipulation |
| `track.bats` | `dotsync track / untrack / list` — `${HOME}` templating, `--to` override, idempotency |
| `state.bats` | per-machine state files live in `$DOTSYNC_STATE_DIR`, NEVER inside the synced data dir (regression test for the .sync-conflict-loop bug) |
| `profile_engine.bats` | `_profile.sh` path-type dispatch — `symlink_file`, `symlink_directory`, `_expand_template` substitutions, `iterates_per_project` edge cases |

## What's not covered (intentional)

- **Live Syncthing integration.** Spinning up a real daemon per test is
  too slow + flaky. The Syncthing-API helpers (`_st_curl`, `st_running`,
  etc.) are tested manually via `dotsync doctor`.
- **End-to-end pair/join flow.** Requires magic-wormhole's rendezvous
  server + two cooperating processes. Smoke-tested manually.
- **`dotsync init` on a fresh machine.** Touches Homebrew, launchd, the
  user's actual Keychain. Tested by running on a real fresh machine.

## Adding tests

1. Create `tests/<feature>.bats`
2. `load test_helper` at the top
3. `setup() { sandbox_setup; }` and `teardown() { sandbox_teardown; }`
4. Use `run_dotsync` to invoke the CLI; bats sets `$status` and `$output`
5. For testing internal helpers, call `source_internals` and call them directly

The `test_helper.bash` provides a clean isolated env per test: a fake
`$HOME`, a fresh `$DOTSYNC_DATA_DIR`/`$DOTSYNC_STATE_DIR`, and an empty
registry. Tear-down is automatic.

## CI

Not yet wired up. To-do: GitHub Actions workflow that runs `bats tests/`
on macOS and (eventually) Linux runners.
