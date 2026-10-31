import shutil
import subprocess

import harness


class TwoWaySyncTests(harness.SyncTestCase):
    def test_first_sync_copies_each_side_to_the_other_including_subfolders(self) -> None:
        self.configure()
        self.write_local("local-only.txt", "local")
        self.write_local("notes/deep/local-nested.txt", "nested")
        harness.remote_create_folder(parent=self.remote, name="remote-folder")
        self.put_remote(relative="remote-only.txt", content="remote")
        self.put_remote(relative="remote-folder/remote-nested.txt", content="remote nested")
        self.sync()
        self.assertIn("local-only.txt", self.remote_names())
        self.assertIn("local-nested.txt", self.remote_names("notes/deep"))
        self.assertEqual((self.local / "remote-only.txt").read_text(), "remote")
        self.assertEqual((self.local / "remote-folder" / "remote-nested.txt").read_text(), "remote nested")
        row = self.last_run()
        self.assertEqual(row.status, "OK")
        self.assertEqual(row.trigger, "SCHEDULED_HEADLESS")
        self.assertEqual(row.pair, str(self.local) + " <> " + self.remote)
        self.assertEqual(row.result, "2 up, 2 down, no errors")

    def test_second_sync_without_changes_changes_nothing(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.sync()
        self.sync()
        self.assertEqual(self.last_run().result, "no changes, no errors")

    def test_edits_flow_both_ways(self) -> None:
        self.configure()
        self.write_local("a.txt", "v1")
        self.put_remote(relative="b.txt", content="v1")
        self.sync()
        self.write_local("a.txt", "version two, local")
        self.put_remote(relative="b.txt", content="version two, from Proton", replace=True)
        self.sync()
        self.assertEqual(self.remote_names()["a.txt"].size, len("version two, local"))
        self.assertEqual((self.local / "b.txt").read_text(), "version two, from Proton")
        self.assertEqual(self.last_run().result, "1 up, 1 down, no errors")

    def test_deletions_flow_both_ways_and_local_ones_are_recoverable(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.write_local("b.txt", "b")
        self.write_local("c.txt", "c")
        self.sync()
        (self.local / "a.txt").unlink()
        harness.remote_trash(self.remote + "/b.txt")
        self.sync()
        self.assertEqual(set(self.remote_names()), {"c.txt"})
        self.assertFalse((self.local / "b.txt").exists())
        self.assertIn("b.txt", self.local_trash_names())
        self.assertEqual(self.last_run().result, "2 deleted, no errors")

    def test_local_rename_moves_the_remote_file(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.write_local("keep.txt", "keep")
        self.sync()
        (self.local / "a.txt").rename(self.local / "renamed.txt")
        self.sync()
        self.assertEqual(set(self.remote_names()), {"renamed.txt", "keep.txt"})
        self.assertEqual(self.last_run().result, "1 moved, no errors")

    def test_remote_rename_moves_the_local_file(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.write_local("keep.txt", "keep")
        self.sync()
        harness.remote_rename(path=self.remote + "/a.txt", new_name="renamed.txt")
        self.sync()
        self.assertEqual(sorted(path.name for path in self.local.iterdir()), ["keep.txt", "renamed.txt"])
        self.assertEqual(self.last_run().result, "1 moved, no errors")


class ConflictTests(harness.SyncTestCase):
    local_edit = "local edit"
    remote_edit = "remote edit, longer"

    def make_conflict(self, *, strategy: str) -> None:
        self.configure(settings=harness.Settings(conflict_strategy=strategy))
        self.write_local("doc.txt", "base")
        self.sync()
        self.write_local("doc.txt", self.local_edit)
        self.put_remote(relative="doc.txt", content=self.remote_edit, replace=True)

    def test_keep_both_saves_the_proton_version_beside_the_local_one(self) -> None:
        self.make_conflict(strategy="both")
        self.sync()
        self.assertEqual((self.local / "doc.txt").read_text(), self.local_edit)
        self.assertEqual((self.local / "doc.remote.txt").read_text(), self.remote_edit)
        self.assertEqual(self.last_run().status, "CONFLICT")
        self.sync()
        remote = self.remote_names()
        self.assertEqual(remote["doc.txt"].size, len(self.local_edit))
        self.assertEqual(remote["doc.remote.txt"].size, len(self.remote_edit))

    def test_keep_local_overwrites_the_proton_version(self) -> None:
        self.make_conflict(strategy="local")
        self.sync()
        self.assertEqual((self.local / "doc.txt").read_text(), self.local_edit)
        self.assertEqual(self.remote_names()["doc.txt"].size, len(self.local_edit))
        self.assertEqual(self.last_run().status, "CONFLICT")

    def test_keep_proton_overwrites_the_local_version(self) -> None:
        self.make_conflict(strategy="remote")
        self.sync()
        self.assertEqual((self.local / "doc.txt").read_text(), self.remote_edit)
        self.assertEqual(self.last_run().status, "CONFLICT")

    def test_skip_and_ask_leave_both_versions_untouched_in_background_syncs(self) -> None:
        for strategy in ("skip", "ask"):
            with self.subTest(strategy=strategy):
                self.remote = harness.remote_create_folder(parent=harness.remote_test_root(), name=self.id().rsplit(".", 1)[-1] + "-" + strategy)
                self.make_conflict(strategy=strategy)
                self.sync(expected_exit=0)
                self.assertEqual((self.local / "doc.txt").read_text(), self.local_edit)
                self.assertEqual(self.remote_names()["doc.txt"].size, len(self.remote_edit))
                self.assertEqual(self.last_run().status, "CONFLICT")
                shutil.rmtree(self.sandbox.state_root / "pairs")


class SelectiveSyncTests(harness.SyncTestCase):
    def test_excluded_names_skipped_folders_and_large_files_stay_local(self) -> None:
        self.configure(skip=("private",), settings=harness.Settings(max_file_size_mb=1))
        self.write_local("keep.txt", "keep")
        self.write_local("scratch.tmp", "temp")
        self.write_local(".git/config", "git")
        self.write_local("private/secret.txt", "secret")
        (self.local / "big.bin").write_bytes(b"x" * (2 * 1024 * 1024))
        self.sync()
        self.assertEqual(set(self.remote_names()), {"keep.txt"})

    def test_backup_mode_uploads_but_never_downloads(self) -> None:
        self.configure(mode=harness.SyncMode.UPLOAD)
        self.write_local("a.txt", "a")
        self.put_remote(relative="b.txt", content="b")
        self.sync()
        self.assertIn("a.txt", self.remote_names())
        self.assertFalse((self.local / "b.txt").exists())

    def test_download_mode_downloads_but_never_uploads(self) -> None:
        self.configure(mode=harness.SyncMode.DOWNLOAD)
        self.write_local("a.txt", "a")
        self.put_remote(relative="b.txt", content="b")
        self.sync()
        self.assertNotIn("a.txt", self.remote_names())
        self.assertEqual((self.local / "b.txt").read_text(), "b")


class SafetyTests(harness.SyncTestCase):
    def test_large_deletion_stops_until_allowed(self) -> None:
        self.configure(settings=harness.Settings(delete_confirm_count=2, delete_confirm_percent=0))
        for name in ("a.txt", "b.txt", "c.txt", "d.txt"):
            self.write_local(name, name)
        self.sync()
        for name in ("a.txt", "b.txt", "c.txt"):
            (self.local / name).unlink()
        self.sync(expected_exit=1)
        self.assertEqual(len(self.remote_names()), 4)
        row = self.last_run()
        self.assertEqual(row.status, "STOPPED")
        self.assertEqual(row.result, "Stopped: 3 deletions need confirmation")
        self.sync("--allow-deletes")
        self.assertEqual(set(self.remote_names()), {"d.txt"})

    def test_emptied_or_missing_local_folder_stops_without_deleting(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.write_local("b.txt", "b")
        self.sync()
        for name in ("a.txt", "b.txt"):
            (self.local / name).unlink()
        self.sync(expected_exit=1)
        self.assertEqual(self.last_run().result, "Stopped: local folder is empty")
        self.local.rmdir()
        self.sync(expected_exit=1)
        self.assertEqual(self.last_run().result, "Stopped: local folder is missing")
        self.assertEqual(set(self.remote_names()), {"a.txt", "b.txt"})

    def test_dry_run_changes_nothing_and_is_not_logged(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        completed = self.sync("--dry-run")
        self.assertIn("DRY RUN", completed.stdout)
        self.assertEqual(self.remote_names(), {})
        self.assertEqual(self.sandbox.run_log_rows(), [])

    def test_start_fresh_restores_files_instead_of_deleting_them(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        self.sync()
        (self.local / "a.txt").unlink()
        self.write_local("b.txt", "b")
        self.sync("--start-fresh")
        self.assertEqual((self.local / "a.txt").read_text(), "a")
        self.assertEqual(set(self.remote_names()), {"a.txt", "b.txt"})

    def test_running_sync_lock_blocks_a_second_sync_until_its_owner_exits(self) -> None:
        self.configure()
        self.write_local("a.txt", "a")
        holder = subprocess.Popen(["bash", "-c", "sleep 120; true", "proton-lock-holder"])
        try:
            lock = self.sandbox.state_root / "sync.lock"
            lock.mkdir(parents=True)
            (lock / "pid").write_text(str(holder.pid))
            completed = self.sync(expected_exit=1)
            self.assertIn("Another sync is already running", completed.stderr)
            self.assertEqual(self.remote_names(), {})
        finally:
            holder.kill()
            holder.wait()
        self.sync()
        self.assertIn("a.txt", self.remote_names())


class RunLogTests(harness.SyncTestCase):
    def test_run_log_records_trigger_and_rotates_when_large(self) -> None:
        self.configure()
        self.sandbox.run_log.parent.mkdir(parents=True)
        self.sandbox.run_log.write_text("x" * (1024 * 1024 + 1) + "\n")
        self.write_local("a.txt", "a")
        self.sync()
        self.assertTrue(self.sandbox.run_log.with_name("runs.log.1").exists())
        self.sync(tty=True)
        rows = self.sandbox.run_log_rows()
        self.assertEqual([row.trigger for row in rows], ["SCHEDULED_HEADLESS", "MANUAL_HEADLESS"])
        self.assertEqual([row.result for row in rows], ["1 up, no errors", "no changes, no errors"])

    def test_unwritable_run_log_does_not_stop_the_sync(self) -> None:
        self.configure()
        self.sandbox.run_log.parent.write_text("a file where the logs folder should be")
        self.write_local("a.txt", "a")
        self.sync()
        self.assertIn("a.txt", self.remote_names())
        detailed_logs = sorted((self.sandbox.pair_state_dir() / "logs").glob("sync-*.log"))
        self.assertIn("[ERROR] Couldn't write the run log", detailed_logs[-1].read_text())


class ContinuousSyncTests(harness.SyncTestCase):
    def test_continuous_sync_uploads_local_changes_and_picks_up_proton_changes(self) -> None:
        self.configure(settings=harness.Settings(watch_poll_minutes=1, watch_delay_seconds=1))
        process = self.sandbox.start("--watch")
        output = ""
        try:
            self.assertTrue(harness.wait_until(condition=lambda: len(self.sandbox.run_log_rows()) >= 1, timeout_seconds=60))
            self.write_local("from-local.txt", "local")
            self.assertTrue(
                harness.wait_until(condition=lambda: "from-local.txt" in self.remote_names(), timeout_seconds=90, interval_seconds=3)
            )
            self.put_remote(relative="from-proton.txt", content="proton")
            self.assertTrue(
                harness.wait_until(condition=lambda: (self.local / "from-proton.txt").exists(), timeout_seconds=150, interval_seconds=3)
            )
            self.assertEqual({row.trigger for row in self.sandbox.run_log_rows()}, {"CONTINUOUS"})
            self.assertIsNone(process.poll())
        finally:
            output = harness.stop_process_group(process)
        self.assertIn("Continuous sync started", output)
        self.assertIn("syncing (local changes)", output)
        self.assertIn("syncing (checking Proton Drive)", output)
