import collections
import collections.abc
import dataclasses
import enum
import json
import os
import pathlib
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import types
import unittest

import yaml

REPO_DIR = pathlib.Path(__file__).resolve().parents[1]
REMOTE_ROOT_ENV = "PROTON_SYNC_TEST_REMOTE_ROOT"
SANDBOX_PARENT = REPO_DIR / "tests" / "sandboxes"
SYNC_TIMEOUT_SECONDS = 300
LOG_COLUMN_COUNT = 5

_TEST_SUITE_FOLDER = "tests/"

_STUB_SCRIPTS = {
    "systemctl": 'echo "$*" >> "$STUB_LOG_DIR/systemctl.calls"\n',
    "sudo": 'echo "$*" >> "$STUB_LOG_DIR/sudo.calls"\n',
    "notify-send": 'echo "$*" >> "$STUB_LOG_DIR/notify-send.calls"\n',
    "crontab": (
        'case "$1" in\n'
        '    -l) [ -f "$STUB_LOG_DIR/crontab" ] || exit 1; cat "$STUB_LOG_DIR/crontab" ;;\n'
        '    -) cat > "$STUB_LOG_DIR/crontab" ;;\n'
        "esac\n"
    ),
}


class SyncMode(enum.Enum):
    TWO_WAY = "two-way"
    UPLOAD = "upload"
    DOWNLOAD = "download"


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class Pair:
    local: pathlib.Path
    remote: str
    mode: SyncMode
    skip: tuple[str, ...]


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class Settings:
    conflict_strategy: str = "both"
    delete_confirm_count: int = 50
    delete_confirm_percent: int = 25
    max_file_size_mb: int = 0
    watch_poll_minutes: int = 15
    watch_delay_seconds: int = 1
    exclude_patterns: tuple[str, ...] = ("*.tmp", "*.swp", "*.partial", ".DS_Store", "Thumbs.db", ".git", ".proton-sync")


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class RunLogRow:
    time: str
    status: str
    trigger: str
    pair: str
    result: str


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class RemoteEntry:
    name: str
    kind: str
    size: int
    uid: str


def _field_value(raw: object) -> object:
    if isinstance(raw, dict) and "value" in raw:
        return raw["value"]
    return raw


def _repo_files_to_copy() -> list[str]:
    listed = subprocess.run(
        ["git", "-C", str(REPO_DIR), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [path for path in listed.stdout.split("\0") if path != "" and not path.startswith(_TEST_SUITE_FOLDER)]


def _copy_repo(*, destination: pathlib.Path) -> None:
    for relative in _repo_files_to_copy():
        source = REPO_DIR / relative
        if not source.is_file():
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def _run_proton(*args: str) -> str:
    completed = subprocess.run(["proton-drive", *args], capture_output=True, text=True, timeout=SYNC_TIMEOUT_SECONDS)
    if completed.returncode != 0:
        raise RuntimeError("proton-drive failed", args, completed.stdout, completed.stderr)
    return completed.stdout


def remote_list(path: str) -> dict[str, RemoteEntry]:
    entries = json.loads(_run_proton("filesystem", "list", path, "-j"))
    name_to_entry: dict[str, RemoteEntry] = {}
    for entry in entries:
        name = str(_field_value(entry["name"]))
        revision = entry.get("activeRevision")
        size = 0
        if isinstance(revision, dict):
            revision_fields = revision.get("value", revision)
            size = int(revision_fields.get("claimedSize", 0))
        name_to_entry[name] = RemoteEntry(name=name, kind=str(_field_value(entry["type"])), size=size, uid=str(entry["uid"]))
    return name_to_entry


def remote_uid(path: str) -> str:
    return str(json.loads(_run_proton("filesystem", "info", path, "-j"))["uid"])


def remote_create_folder(*, parent: str, name: str) -> str:
    _run_proton("filesystem", "create-folder", parent, name)
    return parent + "/" + name


def remote_upload(*, local_file: pathlib.Path, parent: str, replace: bool) -> None:
    strategy = ("-f", "replace") if replace else ()
    _run_proton("filesystem", "upload", *strategy, str(local_file), parent)


def remote_rename(*, path: str, new_name: str) -> None:
    _run_proton("filesystem", "rename", path, new_name)


def remote_trash(path: str) -> None:
    _run_proton("filesystem", "trash", path)


def _remote_folder_uids(path: str) -> set[str]:
    folder_uids = {remote_uid(path)}
    for entry in remote_list(path).values():
        if entry.kind == "folder":
            folder_uids |= _remote_folder_uids(path + "/" + entry.name)
    return folder_uids


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class TrashCleanup:
    deleted_count: int
    left_in_trash: tuple[str, ...]


def remote_delete_tree_permanently(path: str) -> TrashCleanup:
    folder_uids = _remote_folder_uids(path)
    root_uid = remote_uid(path)
    remote_trash(path)
    trashed = json.loads(_run_proton("filesystem", "list", "/trash", "-j"))
    trash_count_by_name: collections.Counter[str] = collections.Counter()
    test_count_by_name: collections.Counter[str] = collections.Counter()
    root_name = ""
    for entry in trashed:
        name = str(_field_value(entry["name"]))
        trash_count_by_name[name] += 1
        if entry["uid"] == root_uid:
            root_name = name
        elif entry.get("parentUid") in folder_uids:
            test_count_by_name[name] += 1
    if root_name == "":
        raise RuntimeError("trashed test folder not found in /trash", path)
    deleted_count = 0
    left_in_trash = []
    for name, count in sorted(test_count_by_name.items()) + [(root_name, 1)]:
        if trash_count_by_name[name] != count:
            left_in_trash.append(name)
            continue
        for _unused in range(count):
            _run_proton("filesystem", "delete", "/trash/" + name)
            deleted_count += 1
    return TrashCleanup(deleted_count=deleted_count, left_in_trash=tuple(left_in_trash))


def remote_test_root() -> str:
    root = os.environ.get(REMOTE_ROOT_ENV)
    if root is None:
        raise RuntimeError("Run the suite with run_tests.py; it creates the Proton test folder", REMOTE_ROOT_ENV)
    return root


def wait_until(*, condition: collections.abc.Callable[[], bool], timeout_seconds: float, interval_seconds: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(interval_seconds)
    return condition()


@dataclasses.dataclass(frozen=True, kw_only=True, slots=True)
class Sandbox:
    root: pathlib.Path

    @property
    def home(self) -> pathlib.Path:
        return self.root / "home"

    @property
    def config_home(self) -> pathlib.Path:
        return self.root / "config"

    @property
    def data_home(self) -> pathlib.Path:
        return self.root / "data"

    @property
    def state_home(self) -> pathlib.Path:
        return self.root / "state"

    @property
    def stub_dir(self) -> pathlib.Path:
        return self.root / "stubs"

    @property
    def stub_log_dir(self) -> pathlib.Path:
        return self.root / "stub-logs"

    @property
    def repo(self) -> pathlib.Path:
        return self.root / "repo"

    @property
    def script(self) -> pathlib.Path:
        return self.repo / "proton-sync-tui.sh"

    @property
    def config_file(self) -> pathlib.Path:
        return self.repo / "config" / "settings.yaml"

    @property
    def example_config_file(self) -> pathlib.Path:
        return self.repo / "config" / "settings.example.yaml"

    @property
    def state_root(self) -> pathlib.Path:
        return self.state_home / "proton-drive-sync"

    @property
    def run_log(self) -> pathlib.Path:
        return self.state_root / "runs.log"

    @property
    def unit_dir(self) -> pathlib.Path:
        return self.config_home / "systemd" / "user"

    @property
    def installed_command(self) -> pathlib.Path:
        return self.home / ".local" / "bin" / "proton-drive-sync"

    @property
    def desktop_file(self) -> pathlib.Path:
        return self.data_home / "applications" / "proton-drive-sync.desktop"

    def env(self) -> dict[str, str]:
        base = {key: value for key, value in os.environ.items() if key not in ("NO_COLOR", "PROTON_SYNC_DRY_RUN")}
        return base | {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.config_home),
            "XDG_DATA_HOME": str(self.data_home),
            "XDG_STATE_HOME": str(self.state_home),
            "STUB_LOG_DIR": str(self.stub_log_dir),
            "PATH": str(self.stub_dir) + ":" + os.environ["PATH"],
        }

    def write_config(self, *, pairs: tuple[Pair, ...], settings: Settings) -> None:
        document = {
            "conflict_strategy": settings.conflict_strategy,
            "delete_confirm_count": settings.delete_confirm_count,
            "delete_confirm_percent": settings.delete_confirm_percent,
            "max_file_size_mb": settings.max_file_size_mb,
            "notify": "off",
            "watch_poll_minutes": settings.watch_poll_minutes,
            "watch_delay_seconds": settings.watch_delay_seconds,
            "exclude_patterns": list(settings.exclude_patterns),
            "pairs": [
                {"local": str(pair.local), "remote": pair.remote, "mode": pair.mode.value, "skip": list(pair.skip)} for pair in pairs
            ],
        }
        self.write_config_text(yaml.safe_dump(document, sort_keys=False))

    def write_config_text(self, text: str) -> None:
        self.config_file.parent.mkdir(parents=True, exist_ok=True)
        self.config_file.write_text(text)

    def save_settings_through_script(self, *, source: pathlib.Path) -> object:
        saved = self.root / "saved-settings.yaml"
        script = (
            'set -uo pipefail; APP_DIR="$1"; source "$APP_DIR/lib/settings.sh"; CONFIG_FILE="$2"; load_config; '
            'validate_settings; remember_saved_settings; CONFIG_FILE="$3"; save_config'
        )
        completed = subprocess.run(
            ["bash", "-c", script, "save-settings", str(self.repo), str(source), str(saved)],
            env=self.env(),
            capture_output=True,
            text=True,
            timeout=SYNC_TIMEOUT_SECONDS,
        )
        if completed.returncode != 0:
            raise AssertionError("load and save through lib/settings.sh failed", completed.stdout, completed.stderr)
        return yaml.safe_load(saved.read_text())

    def run(
        self,
        *args: str,
        tty: bool = False,
        script: pathlib.Path | None = None,
        env_overrides: collections.abc.Mapping[str, str] = types.MappingProxyType({}),
    ) -> subprocess.CompletedProcess[str]:
        command = ["bash", str(self.script if script is None else script), *args]
        if tty:
            command = ["script", "-qec", shlex.join(command), "/dev/null"]
        return subprocess.run(
            command,
            env=self.env() | dict(env_overrides),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=SYNC_TIMEOUT_SECONDS,
        )

    def start(self, *args: str) -> subprocess.Popen[str]:
        return subprocess.Popen(
            ["bash", str(self.script), *args],
            env=self.env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )

    def run_log_rows(self) -> list[RunLogRow]:
        if not self.run_log.exists():
            return []
        rows = []
        for line in self.run_log.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != LOG_COLUMN_COUNT:
                raise AssertionError("run log line has wrong column count", line)
            rows.append(RunLogRow(time=fields[0], status=fields[1], trigger=fields[2], pair=fields[3], result=fields[4]))
        return rows

    def stub_calls(self, name: str) -> list[str]:
        calls_file = self.stub_log_dir / (name + ".calls")
        if not calls_file.exists():
            return []
        return calls_file.read_text().splitlines()

    def pair_state_dir(self) -> pathlib.Path:
        state_dirs = sorted((self.state_root / "pairs").iterdir())
        if len(state_dirs) != 1:
            raise AssertionError("expected one pair state folder", state_dirs)
        return state_dirs[0]


def read_output_until(*, process: subprocess.Popen[str], text: str, timeout_seconds: float) -> str:
    if process.stdout is None:
        raise RuntimeError("process was started without a stdout pipe")
    descriptor = process.stdout.fileno()
    seen = b""
    deadline = time.monotonic() + timeout_seconds
    while text.encode() not in seen and time.monotonic() < deadline:
        ready, _unused_write, _unused_error = select.select([descriptor], [], [], 0.5)
        if ready:
            chunk = os.read(descriptor, 65536)
            if chunk == b"":
                break
            seen += chunk
    return seen.decode()


def stop_process_group(process: subprocess.Popen[str]) -> str:
    os.killpg(process.pid, signal.SIGTERM)
    output, _unused = process.communicate(timeout=30)
    return output


def create_sandbox(*, name: str) -> Sandbox:
    SANDBOX_PARENT.mkdir(parents=True, exist_ok=True)
    sandbox = Sandbox(root=pathlib.Path(tempfile.mkdtemp(prefix=name + "-", dir=SANDBOX_PARENT)))
    _copy_repo(destination=sandbox.repo)
    for folder in (sandbox.home, sandbox.config_home, sandbox.data_home, sandbox.state_home, sandbox.stub_dir, sandbox.stub_log_dir):
        folder.mkdir(parents=True, exist_ok=True)
    for stub_name, body in _STUB_SCRIPTS.items():
        stub_file = sandbox.stub_dir / stub_name
        stub_file.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        stub_file.chmod(0o755)
    return sandbox


class SandboxTestCase(unittest.TestCase):
    sandbox: Sandbox

    def setUp(self) -> None:
        self.sandbox = create_sandbox(name=self.id().rsplit(".", 1)[-1])
        if os.environ.get("PROTON_SYNC_KEEP_SANDBOXES") is None:
            self.addCleanup(shutil.rmtree, self.sandbox.root, True)


class SyncTestCase(SandboxTestCase):
    local: pathlib.Path
    remote: str
    staging: pathlib.Path

    def setUp(self) -> None:
        super().setUp()
        self.local = self.sandbox.root / "local"
        self.local.mkdir()
        self.staging = self.sandbox.root / "staging"
        self.staging.mkdir()
        self.remote = remote_create_folder(parent=remote_test_root(), name=self.id().rsplit(".", 1)[-1])

    def configure(self, *, mode: SyncMode = SyncMode.TWO_WAY, skip: tuple[str, ...] = (), settings: Settings = Settings()) -> None:
        self.sandbox.write_config(pairs=(Pair(local=self.local, remote=self.remote, mode=mode, skip=skip),), settings=settings)

    def sync(self, *args: str, expected_exit: int = 0, tty: bool = False) -> subprocess.CompletedProcess[str]:
        completed = self.sandbox.run("--headless", *args, tty=tty)
        self.assertEqual(completed.returncode, expected_exit, completed.stdout + completed.stderr)
        return completed

    def write_local(self, relative: str, content: str) -> pathlib.Path:
        path = self.local / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def put_remote(self, *, relative: str, content: str, replace: bool = False) -> None:
        staged = self.staging / pathlib.PurePosixPath(relative).name
        staged.write_text(content)
        parent = self.remote
        relative_parent = str(pathlib.PurePosixPath(relative).parent)
        if relative_parent != ".":
            parent = self.remote + "/" + relative_parent
        remote_upload(local_file=staged, parent=parent, replace=replace)
        staged.unlink()

    def remote_names(self, relative_folder: str = "") -> dict[str, RemoteEntry]:
        path = self.remote if relative_folder == "" else self.remote + "/" + relative_folder
        return remote_list(path)

    def local_trash_names(self) -> set[str]:
        trash = self.sandbox.pair_state_dir() / "trash"
        return {path.name for path in trash.rglob("*") if path.is_file()}

    def last_run(self) -> RunLogRow:
        rows = self.sandbox.run_log_rows()
        self.assertTrue(rows, "run log is empty")
        return rows[-1]
