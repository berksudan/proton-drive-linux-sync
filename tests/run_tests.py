import argparse
import datetime
import os
import pathlib
import sys
import unittest

import harness

_SUITE_DIR = pathlib.Path(__file__).resolve().parent


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the proton-drive-sync test suite against the repo script.")
    parser.add_argument("--offline", action="store_true", help="run only tests that don't touch Proton Drive")
    parser.add_argument("-k", dest="patterns", action="append", default=[], help="only run tests matching this substring")
    return parser.parse_args()


def _load_tests(*, offline: bool, patterns: list[str]) -> unittest.TestSuite:
    loader = unittest.TestLoader()
    if patterns:
        loader.testNamePatterns = ["*" + pattern + "*" for pattern in patterns]
    file_pattern = "test_cli.py" if offline else "test_*.py"
    return loader.discover(str(_SUITE_DIR), pattern=file_pattern, top_level_dir=str(_SUITE_DIR))


def run_suite_with_proton_test_folder() -> int:
    arguments = _parse_arguments()
    print("Repo under test (each test runs its own copy): " + str(harness.REPO_DIR))
    remote_root = None
    if not arguments.offline:
        folder_name = "proton-sync-tests-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        remote_root = harness.remote_create_folder(parent="/my-files", name=folder_name)
        os.environ[harness.REMOTE_ROOT_ENV] = remote_root
        print("Proton test folder: " + remote_root)
    try:
        result = unittest.TextTestRunner(verbosity=2).run(_load_tests(offline=arguments.offline, patterns=arguments.patterns))
    finally:
        if remote_root is not None:
            cleanup = harness.remote_delete_tree_permanently(remote_root)
            print("Permanently deleted " + str(cleanup.deleted_count) + " test item(s) from Proton's trash.")
            if cleanup.left_in_trash:
                print("Left in Proton's trash (name also used by your own trashed items): " + ", ".join(cleanup.left_in_trash))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_suite_with_proton_test_folder())
