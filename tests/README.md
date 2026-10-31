# Tests

- End-to-end tests for `proton-sync-tui.sh`, run with the standard library `unittest` plus PyYAML (installed with `yq` by `scripts/setup.sh`).
- Full run, about 2 minutes, uses your logged-in `proton-drive` CLI: `python3 tests/run_tests.py`
  - Offline tests run first; then the Proton tests run 6 at a time, each in its own process (`--jobs N` changes that), with the continuous-sync test, which waits for a 1-minute Proton check, started first.
  - Each run ends with the slowest tests and the cleanup time.
- Offline only, about 10 seconds, no Proton calls: `python3 tests/run_tests.py --offline`
- One area only: `python3 tests/run_tests.py -k conflict` (`-k` repeats and matches test names).

## Isolation

- Each test copies into `tests/sandboxes/<test>/repo` only the files git would commit (`git ls-files --cached --others --exclude-standard`, without `tests/`), so gitignored files such as `settings.yaml` and `.agents/` never reach a test.
- Each test also gets its own HOME and XDG folders (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`) inside its sandbox, so its sync history, run log, installed command, launcher and systemd units stay there and never touch yours.
- `systemctl`, `crontab`, `sudo` and `notify-send` are stubs that only record their arguments, so your running continuous sync is never touched.
- Sandboxes are deleted after each test; set `PROTON_SYNC_KEEP_SANDBOXES=1` to keep them for debugging (`tests/sandboxes/` is gitignored).
- Proton tests work in a new `/my-files/proton-sync-tests-<timestamp>` folder; afterwards it is trashed and permanently deleted together with every test file the syncs trashed, but a trashed name your own items also use is left in the trash and reported.

## Files

- `run_tests.py`: entry point; creates and cleans up the Proton test folder.
- `harness.py`: sandboxes, settings writer, script runner and `proton-drive` helpers.
- `test_cli.py`: options, `--status`, `--log`, `--schedule`, `--install`/`--uninstall`, `scripts/setup.sh` and the settings file.
- `test_sync.py`: real syncs: both directions, edits, deletions, renames, conflicts, exclusions, modes, safety stops, dry run, start fresh, lock, run log, continuous sync.
