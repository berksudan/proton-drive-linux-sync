# AGENTS.md

- Bash tool that syncs local folders with Proton Drive through the `proton-drive` CLI, split into modules from `justinsloan/proton-drive-sync`'s single `proton-sync-tui.sh` at `0869b4b`.

## Layout

- `proton-sync-tui.sh`: entry point; sources each `lib/` module listed in `MODULES`, in that order, then calls `run_cli` (`lib/cli.sh`); `--help` lists the CLI options.
- `lib/`: one module per concern: `settings`, `pairs`, `state`, `logging`, `run_log`, `lock`, `execution`, `local_files`, `proton` (all `proton-drive` CLI calls), `conflicts`, `transfers`, `plan`, `engine` (`sync_engine`), `text`, `schedule`, `headless`, `watch`, `install`, `cli`.
- `lib/tui/`: the interactive menu (dialog or whiptail): `widgets` and one file per screen group, ending with `main_menu`.
- A new module loads only once it is added to `MODULES` in `proton-sync-tui.sh`.
- `scripts/setup.sh`: machine setup: apt packages, run-log link, continuous sync, then `--install`.
- `logs/runs.log`: one line per sync run, gitignored; `scripts/setup.sh` (`link_run_logs_into_repo`) links the script's `run-logs` folder here.
- `LICENSE`: upstream MIT notice; keep it with the code.

## Runtime

- Background sync runs the installed copy, not the repo files: `--install` (`install_program_files`) copies `proton-sync-tui.sh` and `lib/` to `~/.local/share/proton-drive-sync` (`INSTALL_DIR`) and links `~/.local/bin/proton-drive-sync` (`INSTALL_PATH`) to it; run `./proton-sync-tui.sh --install` after editing to update it and restart automatic sync.
- Settings and folder pairs live in `~/.config/proton-sync/config` (`CONFIG_FILE`, written by `save_config`), outside the repo.
- Sync state and detailed per-run logs live in `~/.local/share/proton-sync` (`STATE_ROOT`).
- `scripts/setup.sh` turns on continuous sync (`--schedule watch`), a systemd user service written by `write_systemd_units`.

## Sync Run Log

- Show recent sync runs with `proton-drive-sync --log`: the last 20 lines of `logs/runs.log` as time, status (`OK`, `CONFLICT`, `ERROR`, `STOPPED`), trigger (`CONTINUOUS` continuous sync, `SCHEDULED_HEADLESS` timer or cron, `MANUAL_HEADLESS` `--headless` run from a terminal, `MANUAL_MENU` menu sync), folder pair and result (`show_run_log`, `run_status`, `run_trigger`).
- `proton-drive-sync --log -f` follows new sync runs until stopped, so give it to the user instead of running it.

## Checks

- No committed test suite; run `bash -n` on `proton-sync-tui.sh`, `lib/*.sh`, `lib/tui/*.sh` and `scripts/setup.sh`, then `proton-drive-sync --status` and `proton-drive-sync --log`.

## Upstream

- The `upstream` remote is fetch-only and keeps a single `proton-sync-tui.sh`; to port an upstream fix, run `git fetch upstream`, read `git diff 0869b4b upstream/main -- proton-sync-tui.sh`, and apply each change to the `lib/` module that holds that function.
