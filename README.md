# Proton Drive Linux Sync

Proton Drive Linux Sync keeps local folders in sync with Proton Drive.
It's a Bash tool built on Proton's `proton-drive` CLI, with a terminal menu for setting things up and background sync through systemd or cron.

Each folder pair runs in one of three modes: two-way, upload only (a backup to Proton) or download only.

Continuous sync uploads local changes within seconds and checks Proton for remote changes at a regular interval.
Timed sync runs hourly, every 6 hours or daily instead.

A sync stops before it deletes more files than the safety limit in Settings.
Files that a sync removes go to a local trash.
When a file changed on both sides, you can resolve the conflict from the menu.

## Requirements

- Debian or a Debian-based distribution like Ubuntu, since setup installs packages with `apt`.
- Proton's `proton-drive` CLI, logged in with `proton-drive auth login`.
- A systemd user session for continuous sync. Without one, timed sync uses cron.

## Setup

```bash
git clone https://github.com/berksudan/proton-drive-linux-sync.git
cd proton-drive-linux-sync
./scripts/setup.sh
```

The setup script installs `dialog`, `inotify-tools`, `jq`, `libnotify-bin` and `yq`.
It then creates `config/settings.yaml` from `config/settings.example.yaml`, turns on continuous sync and installs the `proton-drive-linux-sync` command.

The installed command runs straight from this repo, so leave the repo where it is.
If you move it, run `scripts/setup.sh` again.

## Usage

```bash
proton-drive-linux-sync           # open the menu to add folder pairs and change settings
proton-drive-linux-sync --status  # show folder pairs, last results and automatic sync
proton-drive-linux-sync --log     # show the last 20 sync runs
proton-drive-linux-sync --help    # list every option
```

Your settings are in `config/settings.yaml`.
Sync history, logs and the local trash are in `~/.local/state/proton-drive-linux-sync`.

## Credits

This project started as [justinsloan/proton-drive-sync](https://github.com/justinsloan/proton-drive-sync) and was split into modules.
It's licensed under MIT; see [LICENSE](LICENSE).
