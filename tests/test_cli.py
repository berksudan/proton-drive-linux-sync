import pathlib
import re

import yaml

import harness

_OFFLINE_REMOTE = "/my-files/proton-sync-offline-test"
_LOG_ROWS = (
    "2026-10-31 01:00:00\tOK\tCONTINUOUS\t/tmp/a <> /my-files/a\t1 up, no errors\n"
    "2026-10-31 01:05:00\tERROR\tMANUAL_MENU\t/tmp/a <> /my-files/a\t1 up, 2 errors\n"
)


class _OfflineTestCase(harness.SandboxTestCase):
    local: pathlib.Path

    def setUp(self) -> None:
        super().setUp()
        self.local = self.sandbox.root / "local"
        self.local.mkdir()
        self.sandbox.write_config(
            pairs=(harness.Pair(local=self.local, remote=_OFFLINE_REMOTE, mode=harness.SyncMode.TWO_WAY, skip=()),),
            settings=harness.Settings(),
        )

    def write_run_log(self, content: str) -> None:
        self.sandbox.run_log.parent.mkdir(parents=True, exist_ok=True)
        self.sandbox.run_log.write_text(content)


class CommandLineTests(_OfflineTestCase):
    def test_help_lists_every_option(self) -> None:
        completed = self.sandbox.run("--help")
        self.assertEqual(completed.returncode, 0)
        for option in (
            "--headless",
            "--pair N",
            "--dry-run",
            "--allow-deletes",
            "--start-fresh",
            "--watch",
            "--status",
            "--log [-f]",
            "--schedule KIND",
            "--install",
            "--uninstall",
            "--help",
        ):
            self.assertIn(option, completed.stdout)

    def test_invalid_arguments_exit_with_usage_error(self) -> None:
        for args, message in (
            (("--bogus",), "Unknown option: --bogus"),
            (("--schedule", "bogus"), "--schedule needs one of"),
            (("--status", "-f"), "-f only works with --log"),
            (("--headless", "--pair", "0"), "--pair needs a folder pair number"),
            (("--headless", "--pair", "2"), "There is no folder pair 2"),
        ):
            with self.subTest(args=args):
                completed = self.sandbox.run(*args)
                self.assertEqual(completed.returncode, 2)
                self.assertIn(message, completed.stderr + completed.stdout)

    def test_status_lists_pairs_and_automatic_sync(self) -> None:
        completed = self.sandbox.run("--status")
        self.assertEqual(completed.returncode, 0)
        self.assertIn("Automatic sync:  off", completed.stdout)
        self.assertIn("1. " + str(self.local) + " <> " + _OFFLINE_REMOTE, completed.stdout)
        self.assertIn("Mode:       two-way", completed.stdout)
        self.assertIn("Last sync:  never", completed.stdout)

    def test_settings_are_read_from_settings_yaml_next_to_the_script(self) -> None:
        completed = self.sandbox.run("--status")
        self.assertIn("Settings:        " + str(self.sandbox.config_file), completed.stdout)
        self.assertFalse((self.sandbox.config_home / "proton-sync").exists())

    def test_no_folder_pairs_means_nothing_is_synced(self) -> None:
        self.sandbox.write_config_text('notify: "off"\n')
        status = self.sandbox.run("--status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("No folder pairs set up", status.stdout)
        self.assertNotIn("Proton Drive/root", status.stdout)
        headless = self.sandbox.run("--headless")
        self.assertEqual(headless.returncode, 0, headless.stderr)
        self.assertIn("nothing to sync", headless.stdout)
        self.assertFalse((self.sandbox.state_root / "pairs").exists())
        self.assertFalse(self.sandbox.run_log.exists())


class RunLogViewTests(_OfflineTestCase):
    def test_log_without_runs_says_so(self) -> None:
        completed = self.sandbox.run("--log")
        self.assertEqual(completed.returncode, 0)
        self.assertIn("No runs logged yet", completed.stdout)

    def test_log_prints_aligned_plain_columns_when_piped(self) -> None:
        self.write_run_log(_LOG_ROWS)
        completed = self.sandbox.run("--log")
        self.assertEqual(completed.returncode, 0)
        lines = completed.stdout.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertNotIn("\x1b", completed.stdout)
        self.assertEqual(lines[0].index("/tmp/a"), lines[1].index("/tmp/a"))
        self.assertTrue(lines[1].startswith("2026-10-31 01:05:00  ERROR"))
        self.assertTrue(lines[1].endswith("1 up, 2 errors"))

    def test_log_shows_only_the_last_twenty_runs(self) -> None:
        rows = "".join(
            "2026-10-31 01:" + str(minute).zfill(2) + ":00\tOK\tCONTINUOUS\tp\tno changes, no errors\n" for minute in range(30)
        )
        self.write_run_log(rows)
        lines = self.sandbox.run("--log").stdout.splitlines()
        self.assertEqual(len(lines), 20)
        self.assertTrue(lines[0].startswith("2026-10-31 01:10:00"))

    def test_log_colours_status_and_trigger_in_a_terminal(self) -> None:
        self.write_run_log(_LOG_ROWS)
        output = self.sandbox.run("--log", tty=True).stdout
        for coloured in ("\x1b[32mOK", "\x1b[1;31mERROR", "\x1b[36mCONTINUOUS", "\x1b[35mMANUAL_MENU", "\x1b[2m2026-10-31"):
            self.assertIn(coloured, output)

    def test_no_color_turns_colours_off_in_a_terminal(self) -> None:
        self.write_run_log(_LOG_ROWS)
        output = self.sandbox.run("--log", tty=True, env_overrides={"NO_COLOR": "1"}).stdout
        self.assertNotIn("\x1b[", output)
        self.assertIn("ERROR", output)

    def test_log_follow_prints_new_runs(self) -> None:
        self.write_run_log(_LOG_ROWS)
        process = self.sandbox.start("--log", "-f")
        try:
            initial = harness.read_output_until(process=process, text="MANUAL_MENU", timeout_seconds=10)
            self.assertIn("MANUAL_MENU", initial)
            with self.sandbox.run_log.open("a") as run_log:
                run_log.write("2026-10-31 01:10:00\tCONFLICT\tCONTINUOUS\tp\t1 conflicts, no errors\n")
            followed = harness.read_output_until(process=process, text="CONFLICT", timeout_seconds=10)
            self.assertIn("CONFLICT", followed)
            self.assertIsNone(process.poll())
        finally:
            harness.stop_process_group(process)


class AutomaticSyncScheduleTests(_OfflineTestCase):
    def unit_text(self, name: str) -> str:
        return (self.sandbox.unit_dir / name).read_text()

    def test_timer_schedules_write_timer_and_service_units(self) -> None:
        for kind, calendar_pattern, status_text in (
            ("hourly", r"^OnCalendar=\*-\*-\* \*:\d\d:00$", "every hour (systemd)"),
            ("six", r"^OnCalendar=\*-\*-\* 00/6:\d\d:00$", "every 6 hours (systemd)"),
            ("daily", r"^OnCalendar=\*-\*-\* 03:\d\d:00$", "daily (systemd)"),
        ):
            with self.subTest(kind=kind):
                completed = self.sandbox.run("--schedule", kind)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertRegex(self.unit_text("proton-drive-linux-sync.timer"), re.compile(calendar_pattern, re.MULTILINE))
                service = self.unit_text("proton-drive-linux-sync.service")
                self.assertIn(str(self.sandbox.script), service)
                self.assertRegex(service, re.compile(r"^ExecStart=.* --headless$", re.MULTILINE))
                self.assertFalse((self.sandbox.unit_dir / "proton-drive-linux-sync-watch.service").exists())
                self.assertIn("Automatic sync:  " + status_text, self.sandbox.run("--status").stdout)
                self.assertIn("--user enable --now proton-drive-linux-sync.timer", self.sandbox.stub_calls("systemctl"))

    def test_continuous_schedule_writes_only_the_watch_service(self) -> None:
        self.sandbox.run("--schedule", "hourly")
        completed = self.sandbox.run("--schedule", "watch")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Automatic sync: continuous (using systemd)", completed.stdout)
        watch_unit = self.unit_text("proton-drive-linux-sync-watch.service")
        self.assertRegex(watch_unit, re.compile(r"^ExecStart=.* --watch$", re.MULTILINE))
        self.assertIn('Environment="XDG_STATE_HOME=' + str(self.sandbox.state_home) + '"', watch_unit)
        self.assertNotIn("XDG_CONFIG_HOME", watch_unit)
        self.assertFalse((self.sandbox.unit_dir / "proton-drive-linux-sync.timer").exists())
        self.assertFalse((self.sandbox.unit_dir / "proton-drive-linux-sync.service").exists())
        self.assertIn("--user enable --now proton-drive-linux-sync-watch.service", self.sandbox.stub_calls("systemctl"))
        self.assertIn("Automatic sync:  continuous (systemd)", self.sandbox.run("--status").stdout)

    def test_off_removes_every_unit(self) -> None:
        self.sandbox.run("--schedule", "watch")
        completed = self.sandbox.run("--schedule", "off")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(sorted(path.name for path in self.sandbox.unit_dir.iterdir()), [])
        self.assertIn("Automatic sync:  off", self.sandbox.run("--status").stdout)


class InstallTests(_OfflineTestCase):
    def test_install_links_the_command_to_the_repo_script(self) -> None:
        completed = self.sandbox.run("--install")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Installed: " + str(self.sandbox.installed_command) + " -> " + str(self.sandbox.script), completed.stdout)
        self.assertTrue(self.sandbox.installed_command.is_symlink())
        self.assertEqual(self.sandbox.installed_command.resolve(), self.sandbox.script.resolve())
        for args in (("--help",), ("--status",), ("--log",)):
            with self.subTest(args=args):
                rerun = self.sandbox.run(*args, script=self.sandbox.installed_command)
                self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertIn("Settings:        " + str(self.sandbox.config_file), self.sandbox.run("--status", script=self.sandbox.installed_command).stdout)
        self.assertIn('Exec="' + str(self.sandbox.installed_command) + '"', self.sandbox.desktop_file.read_text())

    def test_install_points_automatic_sync_at_the_installed_command(self) -> None:
        self.sandbox.run("--schedule", "watch")
        completed = self.sandbox.run("--install")
        self.assertIn("Automatic sync (continuous) now runs " + str(self.sandbox.installed_command) + ".", completed.stdout)
        watch_unit = (self.sandbox.unit_dir / "proton-drive-linux-sync-watch.service").read_text()
        self.assertIn('"' + str(self.sandbox.installed_command) + '" --watch', watch_unit)

    def test_uninstall_removes_command_launcher_and_automatic_sync_that_uses_it(self) -> None:
        self.sandbox.run("--schedule", "watch")
        self.sandbox.run("--install")
        completed = self.sandbox.run("--uninstall")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Turned off automatic sync (it used " + str(self.sandbox.installed_command) + ").", completed.stdout)
        self.assertFalse(self.sandbox.installed_command.is_symlink())
        self.assertFalse(self.sandbox.desktop_file.exists())
        self.assertFalse((self.sandbox.unit_dir / "proton-drive-linux-sync-watch.service").exists())
        self.assertTrue(self.sandbox.config_file.exists())
        self.assertTrue(self.sandbox.script.exists())


class SetupScriptTests(_OfflineTestCase):
    def test_setup_installs_packages_turns_on_continuous_sync_and_installs_the_command(self) -> None:
        completed = self.sandbox.run(script=self.sandbox.repo / "scripts" / "setup.sh")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        for step in ("[1/4]", "[2/4]", "[3/4]", "[4/4]", "Setup done.", "Keeping " + str(self.sandbox.config_file)):
            self.assertIn(step, completed.stdout)
        self.assertIn("sudo needed for: apt-get install -y -qq dialog inotify-tools jq libnotify-bin yq", completed.stdout)
        self.assertTrue(
            any("apt-get install -y -qq dialog inotify-tools jq libnotify-bin yq" in call for call in self.sandbox.stub_calls("sudo"))
        )
        watch_unit = (self.sandbox.unit_dir / "proton-drive-linux-sync-watch.service").read_text()
        self.assertIn('"' + str(self.sandbox.installed_command) + '" --watch', watch_unit)
        self.assertEqual(self.sandbox.installed_command.resolve(), self.sandbox.script.resolve())
        rerun = self.sandbox.run(script=self.sandbox.repo / "scripts" / "setup.sh")
        self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
        self.assertIn("1. " + str(self.local) + " <> " + _OFFLINE_REMOTE, self.sandbox.run("--status").stdout)

    def test_setup_creates_settings_from_the_example_with_no_folder_pairs(self) -> None:
        self.sandbox.config_file.unlink()
        completed = self.sandbox.run(script=self.sandbox.repo / "scripts" / "setup.sh")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Created " + str(self.sandbox.config_file), completed.stdout)
        self.assertEqual(self.sandbox.config_file.read_text(), self.sandbox.example_config_file.read_text())
        self.assertIn("No folder pairs set up", self.sandbox.run("--status").stdout)


class SettingsFileTests(_OfflineTestCase):
    def test_example_settings_are_the_built_in_defaults(self) -> None:
        example = yaml.safe_load(self.sandbox.example_config_file.read_text())
        self.assertEqual(self.sandbox.save_settings_through_script(source=self.sandbox.example_config_file), example)
        self.assertEqual(self.sandbox.save_settings_through_script(source=self.sandbox.root / "missing.yaml"), example)

    def test_saving_keeps_every_setting_and_pair(self) -> None:
        written = {
            "conflict_strategy": "both",
            "sync_jobs": 2,
            "trash_retention_days": 7,
            "log_retention_days": 0,
            "delete_confirm_count": 10,
            "delete_confirm_percent": 0,
            "max_file_size_mb": 100,
            "notify": "problems",
            "watch_poll_minutes": 5,
            "watch_delay_seconds": 3,
            "debug": True,
            "exclude_patterns": ["*.tmp", "name with spaces"],
            "pairs": [
                {"local": "/data/Notes", "remote": "/my-files/Notes", "mode": "upload", "skip": ["drafts/old", "a b"]},
                {"local": "/data/Photos", "remote": "/my-files/Photos", "mode": "download", "skip": []},
            ],
        }
        self.sandbox.write_config_text(yaml.safe_dump(written, sort_keys=False))
        self.assertEqual(self.sandbox.save_settings_through_script(source=self.sandbox.config_file), written)

    def test_home_shorthand_in_a_local_folder_is_expanded(self) -> None:
        self.sandbox.write_config_text("pairs:\n  - local: ~/Notes\n    remote: /my-files/Notes\n")
        status = self.sandbox.run("--status").stdout
        self.assertIn("1. ~/Notes <> /my-files/Notes", status)
        self.assertIn("Mode:       two-way", status)

    def test_invalid_settings_stop_with_the_exact_problem(self) -> None:
        for text, problem in (
            ("bogus_setting: 1\n", "unknown setting(s): bogus_setting"),
            ("pairs:\n  - local: /a\n    remote: /my-files/a\n    colour: red\n", "pair 1: unknown key(s): colour"),
            ("pairs:\n  - local: /a\n", "pair 1 needs a local and a remote folder"),
            ("pairs:\n  - local: /a\n    remote: /my-files/a\n    mode: sideways\n", "pair 1: mode must be two-way, upload or download"),
            ("pairs: /a\n", "pairs must be a list"),
            ("exclude_patterns: '*.tmp'\n", "exclude_patterns must be a list of names"),
            ("sync_jobs: [1, 2]\n", "setting sync_jobs must be a single value"),
            ("- just\n- a list\n", "the file must map setting names to values"),
        ):
            with self.subTest(problem=problem):
                self.sandbox.write_config_text(text)
                for args in (("--status",), ("--headless",)):
                    completed = self.sandbox.run(*args)
                    self.assertEqual(completed.returncode, 1, completed.stdout)
                    self.assertIn(problem, completed.stderr)
                    self.assertIn("couldn't read the settings in " + str(self.sandbox.config_file), completed.stderr)
        self.assertFalse((self.sandbox.state_root / "pairs").exists())
