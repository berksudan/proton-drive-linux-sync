# Tests

- End-to-end tests for `proton-sync-tui.sh`, run with the standard library `unittest` plus PyYAML (installed with `yq` by `scripts/setup.sh`).
- Full run, about 7 minutes, uses your logged-in `proton-drive` CLI: `python3 tests/run_tests.py`
- Offline only, about 10 seconds, no Proton calls: `python3 tests/run_tests.py --offline`
- One area only: `python3 tests/run_tests.py -k conflict` (`-k` repeats and matches test names).

## Isolation

- Each test copies the repo into `tests/sandboxes/<test>/repo`, leaving out `.git`, `.agents`, `logs`, `state`, `tests` and everything in `config/` except `settings.example.yaml`, so your settings, run log and sync history are never read or changed.
- Each test also gets its own HOME and XDG folders inside its sandbox, so the installed command, launcher and systemd units it creates stay there.
- `systemctl`, `crontab`, `sudo` and `notify-send` are stubs that only record their arguments, so your running continuous sync is never touched.
- Sandboxes are deleted after each test; set `PROTON_SYNC_KEEP_SANDBOXES=1` to keep them for debugging (`tests/sandboxes/` is gitignored).
- Proton tests work in a new `/my-files/proton-sync-tests-<timestamp>` folder; afterwards it is trashed and permanently deleted together with every test file the syncs trashed, but a trashed name your own items also use is left in the trash and reported.

## Files

- `run_tests.py`: entry point; creates and cleans up the Proton test folder.
- `harness.py`: sandboxes, settings writer, script runner and `proton-drive` helpers.
- `test_cli.py`: options, `--status`, `--log`, `--schedule`, `--install`/`--uninstall`, `scripts/setup.sh` and the settings file.
- `test_sync.py`: real syncs: both directions, edits, deletions, renames, conflicts, exclusions, modes, safety stops, dry run, start fresh, lock, run log, continuous sync.
