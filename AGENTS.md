# AGENTS.md

- Bash tool that syncs local folders with Proton Drive through the `proton-drive` CLI, split into modules from `justinsloan/proton-drive-sync`'s single `proton-sync-tui.sh` at `0869b4b`.

## Layout

- `proton-sync-tui.sh`: entry point; sources each `lib/` module listed in `MODULES`, in that order, then calls `run_cli` (`lib/cli.sh`); `--help` lists the CLI options.
- `lib/`: one module per concern: `settings`, `pairs`, `state`, `logging`, `run_log`, `lock`, `execution`, `local_files`, `proton` (all `proton-drive` CLI calls), `conflicts`, `transfers`, `plan`, `engine` (`sync_engine`), `text`, `schedule`, `headless`, `watch`, `install`, `cli`.
- `lib/tui/`: the interactive menu (dialog or whiptail): `widgets` and one file per screen group, ending with `main_menu`.
- A new module loads only once it is added to `MODULES` in `proton-sync-tui.sh`.
- `scripts/setup.sh`: machine setup: apt packages, `config/settings.yaml` from the example when missing, continuous sync, then `--install`.
- `config/settings.example.yaml`: tracked settings template holding every setting at its built-in default, with no folder pairs.
- `config/settings.yaml`: this machine's settings and folder pairs (`CONFIG_FILE`, read by `load_config`, written by `save_config`), gitignored.
- `tests/`: end-to-end test suite; `tests/README.md` explains how it isolates itself.
- `LICENSE`: upstream MIT notice; keep it with the code.

## Runtime

- Program code and settings live in this repo (`APP_DIR`); the repo never changes while syncs run.
- Program state lives in `${XDG_STATE_HOME:-~/.local/state}/proton-drive-sync` (`STATE_ROOT`): `runs.log` (`RUN_LOG`), and per folder pair in `pairs/<id>/` the sync history (`snapshot`), detailed per-run logs and the local trash, plus the lock while a sync runs.
- The only other files outside the repo are the hooks the system looks for elsewhere: the `~/.local/bin/proton-drive-sync` link and desktop launcher (`install_script`, `uninstall_script`) and the systemd user units (`write_systemd_units`, `remove_automatic_sync`).
- `--install` links `~/.local/bin/proton-drive-sync` (`INSTALL_PATH`) to this repo's `proton-sync-tui.sh`, so background sync runs the repo files, uncommitted edits included, from its next restart; run `./proton-sync-tui.sh --install` to restart automatic sync on purpose.
- Moving or deleting the repo breaks the installed command and automatic sync until `scripts/setup.sh` runs from the new location.
- `scripts/setup.sh` turns on continuous sync (`--schedule watch`), a systemd user service written by `write_systemd_units`.

## Settings File

- With no folder pairs in `config/settings.yaml`, nothing is synced: `--headless` and continuous sync report that there is nothing to sync, and the menu asks for a pair first (`headless_run`, `run_cli`).
- `load_config` stops with an error naming the problem for unknown settings, unknown pair keys, a bad pair `mode` or wrongly typed values (`SETTINGS_YAML_TO_SHELL`); a setting left out keeps its built-in default.
- A change that adds, renames or removes a setting, or changes its default (`lib/settings.sh`: the defaults at the top, `SETTING_KEYS`, `SETTINGS_YAML_TO_SHELL`, `save_config`), updates `config/settings.example.yaml` in the same change; `test_example_settings_are_the_built_in_defaults` in `tests/test_cli.py` fails while they differ.
- After such a change, bring this machine's `config/settings.yaml` to the example's set of keys, keeping its existing values; never copy example values over existing settings or folder pairs.

## Sync Run Log

- Show recent sync runs with `proton-drive-sync --log`: the last 20 lines of `runs.log` (`RUN_LOG`) as time, status (`OK`, `CONFLICT`, `ERROR`, `STOPPED`), trigger (`CONTINUOUS` continuous sync, `SCHEDULED_HEADLESS` timer or cron, `MANUAL_HEADLESS` `--headless` run from a terminal, `MANUAL_MENU` menu sync), folder pair and result (`show_run_log`, `run_status`, `run_trigger`).
- `proton-drive-sync --log -f` follows new sync runs until stopped, so give it to the user instead of running it.

## Checks

- Run `python3 tests/run_tests.py --offline` after every change, and `python3 tests/run_tests.py` (about 7 minutes, uses the logged-in `proton-drive` CLI) after changes to syncing, scheduling or `lib/proton.sh`.
- Then check this machine with `proton-drive-sync --status` and `proton-drive-sync --log`.

## Upstream

- The `upstream` remote is fetch-only and keeps a single `proton-sync-tui.sh`; to port an upstream fix, run `git fetch upstream`, read `git diff 0869b4b upstream/main -- proton-sync-tui.sh`, and apply each change to the `lib/` module that holds that function.
