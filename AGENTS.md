# AGENTS.md

- Personal copy of `proton-sync-tui.sh`, a Bash tool that syncs local folders with Proton Drive through the `proton-drive` CLI, imported from `justinsloan/proton-drive-sync` at `0869b4b`.

## Layout

- `proton-sync-tui.sh`: the whole tool, menu (`main_menu`) and sync engine (`sync_engine`); `--help` lists the CLI options.
- `scripts/setup.sh`: machine setup: apt packages, run-log link, continuous sync, then `--install`.
- `logs/runs.log`: one line per sync run, gitignored; `scripts/setup.sh` (`link_run_logs_into_repo`) links the script's `run-logs` folder here.
- `LICENSE`: upstream MIT notice; keep it with the script.

## Runtime

- Background sync runs the installed copy `~/.local/bin/proton-drive-sync` (`INSTALL_PATH`), not the repo file; run `./proton-sync-tui.sh --install` after editing to update it and restart automatic sync.
- Settings and folder pairs live in `~/.config/proton-sync/config` (`CONFIG_FILE`, written by `save_config`), outside the repo.
- Sync state and detailed per-run logs live in `~/.local/share/proton-sync` (`STATE_ROOT`).
- `scripts/setup.sh` turns on continuous sync (`--schedule watch`), a systemd user service written by `write_systemd_units`.

## Sync Run Log

- Show recent sync runs with `proton-drive-sync --log`: the last 20 lines of `logs/runs.log` as time, status (`OK`, `CONFLICT`, `ERROR`, `STOPPED`), trigger (`CONTINUOUS` continuous sync, `SCHEDULED_HEADLESS` timer or cron, `MANUAL_HEADLESS` `--headless` run from a terminal, `MANUAL_MENU` menu sync), folder pair and result (`show_run_log`, `run_status`, `run_trigger`).
- `proton-drive-sync --log -f` follows new sync runs until stopped, so give it to the user instead of running it.

## Checks

- No test suite; run `bash -n proton-sync-tui.sh scripts/setup.sh`, then `proton-drive-sync --status` and `proton-drive-sync --log`.

## Upstream

- The `upstream` remote is fetch-only; compare with `git fetch upstream` and `git diff upstream/main:proton-sync-tui.sh HEAD:proton-sync-tui.sh`.
