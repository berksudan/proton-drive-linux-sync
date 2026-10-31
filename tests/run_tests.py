import argparse
import concurrent.futures
import dataclasses
import datetime
import os
import pathlib
import subprocess
import sys
import time
import unittest

import harness

_SUITE_DIR = pathlib.Path(__file__).resolve().parent
_DEFAULT_JOBS = 6
_SLOWEST_SHOWN = 10
_STARTS_FIRST = "test_continuous_sync"


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class _ProtonTestResult:
    test_id: str
    passed: bool
    seconds: float
    output: str


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the proton-drive-linux-sync test suite against the repo script.")
    parser.add_argument("--offline", action="store_true", help="run only tests that don't touch Proton Drive")
    parser.add_argument("-k", dest="patterns", action="append", default=[], help="only run tests matching this substring")
    parser.add_argument("--jobs", type=int, default=_DEFAULT_JOBS, help="Proton tests run at the same time (default: 6)")
    return parser.parse_args()


def _load_tests(*, file_pattern: str, patterns: list[str]) -> unittest.TestSuite:
    loader = unittest.TestLoader()
    if patterns:
        loader.testNamePatterns = ["*" + pattern + "*" for pattern in patterns]
    return loader.discover(str(_SUITE_DIR), pattern=file_pattern, top_level_dir=str(_SUITE_DIR))


def _test_ids(suite: unittest.TestSuite) -> list[str]:
    test_ids = []
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            test_ids.extend(_test_ids(item))
        else:
            test_ids.append(item.id())
    return test_ids


def _run_offline_tests(*, patterns: list[str]) -> bool:
    runner = unittest.TextTestRunner(verbosity=2, durations=_SLOWEST_SHOWN)
    return runner.run(_load_tests(file_pattern="test_cli.py", patterns=patterns)).wasSuccessful()


def _run_one_proton_test(test_id: str) -> _ProtonTestResult:
    started = time.monotonic()
    completed = subprocess.run([sys.executable, "-m", "unittest", test_id], cwd=_SUITE_DIR, capture_output=True, text=True)
    return _ProtonTestResult(
        test_id=test_id,
        passed=completed.returncode == 0,
        seconds=time.monotonic() - started,
        output=completed.stdout + completed.stderr,
    )


def _run_proton_tests(*, patterns: list[str], jobs: int) -> bool:
    test_ids = sorted(_test_ids(_load_tests(file_pattern="test_sync.py", patterns=patterns)), key=lambda test_id: _STARTS_FIRST not in test_id)
    print("\nRunning " + str(len(test_ids)) + " Proton tests, " + str(jobs) + " at a time:", flush=True)
    results: list[_ProtonTestResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for future in concurrent.futures.as_completed([pool.submit(_run_one_proton_test, test_id) for test_id in test_ids]):
            result = future.result()
            results.append(result)
            print(("ok    " if result.passed else "FAIL  ") + f"{result.seconds:6.1f}s  " + result.test_id, flush=True)
    for result in results:
        if not result.passed:
            print("\n==== " + result.test_id + "\n" + result.output)
    print("\nSlowest Proton tests:")
    for result in sorted(results, key=lambda result: result.seconds, reverse=True)[:_SLOWEST_SHOWN]:
        print(f"{result.seconds:6.1f}s  " + result.test_id)
    passed_count = sum(result.passed for result in results)
    print("\nProton tests: " + str(passed_count) + " of " + str(len(results)) + " passed")
    return passed_count == len(results)


def run_suite_with_proton_test_folder() -> int:
    arguments = _parse_arguments()
    started = time.monotonic()
    print("Repo under test (each test runs its own copy): " + str(harness.REPO_DIR))
    passed = _run_offline_tests(patterns=arguments.patterns)
    if not arguments.offline:
        folder_name = "proton-sync-tests-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        remote_root = harness.remote_create_folder(parent="/my-files", name=folder_name)
        os.environ[harness.REMOTE_ROOT_ENV] = remote_root
        print("Proton test folder: " + remote_root)
        try:
            passed = _run_proton_tests(patterns=arguments.patterns, jobs=arguments.jobs) and passed
        finally:
            cleanup_started = time.monotonic()
            cleanup = harness.remote_delete_tree_permanently(remote_root)
            print(
                "Permanently deleted "
                + str(cleanup.deleted_count)
                + " test item(s) from Proton's trash in "
                + f"{time.monotonic() - cleanup_started:.1f}s."
            )
            if cleanup.left_in_trash:
                print("Left in Proton's trash (name also used by your own trashed items): " + ", ".join(cleanup.left_in_trash))
    print(f"\nTotal: {time.monotonic() - started:.1f}s, " + ("all passed" if passed else "FAILED"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(run_suite_with_proton_test_folder())
