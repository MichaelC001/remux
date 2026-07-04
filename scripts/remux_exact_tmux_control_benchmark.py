#!/usr/bin/env python3
"""Measure raw bare-exec tmux -C topology response latency.

This is a standalone remote tmux benchmark, not the Remux app transport path.
It deliberately uses the same no-PTY control-mode shape as Remux: a bare
`tmux -C` exec stream. Remux itself still lets Ghostty own command generation,
parsing, and reconciliation.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import selectors
import shlex
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable


CONTEXT_PREFIX = "__REMUX_EXACT_CONTEXT__"
DEFAULT_CONFIG = Path(".local/remux-live-ssh.json")
SESSION_NAME_RE = re.compile(r"^remux-exact-ssh-bench-[A-Za-z0-9._-]+$")


@dataclass(frozen=True)
class SSHConfig:
    host: str
    username: str
    password: str
    port: int


@dataclass(frozen=True)
class ActionSpec:
    name: str
    report_name: str
    command_template: str
    topology_signals: tuple[str, ...]


@dataclass(frozen=True)
class TmuxContext:
    session_id: str
    pane_id: str


@dataclass(frozen=True)
class Sample:
    action: str
    elapsed_ms: float
    signal: str
    topology_line: str
    command: str


@dataclass(frozen=True)
class MatchedSignal:
    signal: str
    line: str


class BenchmarkError(RuntimeError):
    pass


ACTION_SPECS = (
    ActionSpec(
        name="new-window",
        report_name="new_window",
        command_template="new-window -t {session_id}",
        topology_signals=("%window-add", "%session-window-changed"),
    ),
    ActionSpec(
        name="split-pane",
        report_name="split_pane",
        command_template="split-window -h -t {pane_id}",
        topology_signals=("%window-pane-changed", "%layout-change"),
    ),
)


def load_config(path: Path, password_env: str | None) -> SSHConfig:
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise BenchmarkError(f"config not found: {path}") from error
    except json.JSONDecodeError as error:
        raise BenchmarkError(f"invalid JSON config {path}: {error}") from error

    password = ""
    if password_env:
        password = os.environ.get(password_env, "")
    if not password:
        password = str(raw.get("password", ""))

    host = str(raw.get("host", ""))
    username = str(raw.get("username", ""))
    port = int(raw.get("port", 22))
    missing = [
        key
        for key, value in [
            ("host", host),
            ("username", username),
            ("password", password),
        ]
        if not value
    ]
    if missing:
        raise BenchmarkError(f"missing required config fields: {', '.join(missing)}")

    return SSHConfig(host=host, username=username, password=password, port=port)


def percentile(values: list[float], percentile_value: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise BenchmarkError("cannot summarize an empty sample set")

    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def render_command(template: str, context: TmuxContext) -> str:
    try:
        command = template.format(
            session_id=context.session_id,
            pane_id=context.pane_id,
        )
    except KeyError as error:
        raise BenchmarkError(f"unknown command template field: {error}") from error

    command = command.strip()
    if not command:
        raise BenchmarkError("rendered tmux command is empty")
    return command


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def validate_session_name(session_name: str) -> str:
    if not SESSION_NAME_RE.fullmatch(session_name):
        raise BenchmarkError(
            "session name must match remux-exact-ssh-bench-[A-Za-z0-9._-]+"
        )
    return session_name


def control_payload(line: str) -> str:
    return line.strip()


def parse_context_line(line: str, token: str) -> TmuxContext | None:
    stripped = control_payload(line)
    if not stripped.startswith(f"{CONTEXT_PREFIX}{token} "):
        return None

    parts = stripped.split()
    if len(parts) < 3:
        raise BenchmarkError(f"malformed context response: {line!r}")
    return TmuxContext(session_id=parts[1], pane_id=parts[2])


def matching_signal(line: str, signals: Iterable[str]) -> MatchedSignal | None:
    stripped = control_payload(line)
    for signal in signals:
        if stripped == signal or stripped.startswith(f"{signal} "):
            return MatchedSignal(signal=signal, line=stripped)
    return None


def window_id_from_topology_line(line: str) -> str | None:
    match = re.search(r"@[0-9]+", line)
    if match is None:
        return None
    return match.group(0)


class AskPass:
    def __init__(self, password: str) -> None:
        self._password = password
        self._tmpdir: tempfile.TemporaryDirectory[str] | None = None
        self.path: Path | None = None

    def __enter__(self) -> "AskPass":
        self._tmpdir = tempfile.TemporaryDirectory(prefix="remux-exact-askpass.")
        self.path = Path(self._tmpdir.name) / "askpass.sh"
        self.path.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$REMUX_LIVE_SSH_PASSWORD\"\n"
        )
        self.path.chmod(0o700)
        return self

    def __exit__(self, *_: object) -> None:
        if self._tmpdir is not None:
            self._tmpdir.cleanup()

    def env(self) -> dict[str, str]:
        if self.path is None:
            raise BenchmarkError("askpass helper is not initialized")

        env = os.environ.copy()
        env["REMUX_LIVE_SSH_PASSWORD"] = self._password
        env["SSH_ASKPASS"] = str(self.path)
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env.get("DISPLAY", "remux")
        return env


class ControlModeSession:
    def __init__(
        self,
        config: SSHConfig,
        session_name: str,
        askpass: AskPass,
        tmux_command: str,
        connect_timeout: int,
    ) -> None:
        remote_command = (
            f"{shlex.quote(tmux_command)} -C new-session -A "
            f"-s {shlex.quote(session_name)}"
        )
        command = [
            "ssh",
            "-p",
            str(config.port),
            "-o",
            "BatchMode=no",
            "-o",
            "NumberOfPasswordPrompts=1",
            "-o",
            f"ConnectTimeout={connect_timeout}",
            f"{config.username}@{config.host}",
            remote_command,
        ]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=askpass.env(),
        )
        if self.process.stdout is None or self.process.stdin is None:
            raise BenchmarkError("failed to open ssh control pipes")

        self._selector = selectors.DefaultSelector()
        self._selector.register(self.process.stdout, selectors.EVENT_READ)
        self._buffer = b""

    def close(self) -> None:
        if self.process.poll() is not None:
            return

        try:
            self.send_command("detach-client")
        except Exception:
            pass

        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def send_command(self, command: str) -> int:
        if self.process.stdin is None:
            raise BenchmarkError("ssh stdin is closed")
        if self.process.poll() is not None:
            raise BenchmarkError(f"ssh exited early with code {self.process.returncode}")

        payload = f"{command.rstrip()}\n".encode()
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        return time.perf_counter_ns()

    def read_line(self, timeout_seconds: float) -> str | None:
        deadline = time.monotonic() + timeout_seconds
        while True:
            if b"\n" in self._buffer:
                raw, self._buffer = self._buffer.split(b"\n", 1)
                return raw.decode(errors="replace").rstrip("\r")

            if self.process.poll() is not None:
                if self._buffer:
                    raw = self._buffer
                    self._buffer = b""
                    return raw.decode(errors="replace").rstrip("\r")
                raise BenchmarkError(f"ssh exited with code {self.process.returncode}")

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None

            events = self._selector.select(remaining)
            if not events:
                return None

            chunk = self.process.stdout.read1(4096)
            if not chunk:
                continue
            self._buffer += chunk

    def wait_for(
        self,
        predicate: Callable[[str], object | None],
        timeout_seconds: float,
        description: str,
    ) -> object:
        deadline = time.monotonic() + timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchmarkError(f"timed out waiting for {description}")

            line = self.read_line(remaining)
            if line is None:
                raise BenchmarkError(f"timed out waiting for {description}")

            result = predicate(line)
            if result is not None:
                return result

    def drain_until_idle(self, idle_seconds: float, max_seconds: float) -> None:
        deadline = time.monotonic() + max_seconds
        while time.monotonic() < deadline:
            line = self.read_line(idle_seconds)
            if line is None:
                return

    def request_context(self, timeout_seconds: float) -> TmuxContext:
        token = uuid.uuid4().hex[:8]
        command = (
            f"display-message -p "
            f"{shlex.quote(CONTEXT_PREFIX + token + ' #{session_id} #{pane_id}')}"
        )
        self.send_command(command)
        return self.wait_for(
            lambda line: parse_context_line(line, token),
            timeout_seconds,
            "tmux context response",
        )

    def measure_action(
        self,
        spec: ActionSpec,
        command: str,
        timeout_seconds: float,
    ) -> Sample:
        start = self.send_command(command)
        signal = self.wait_for(
            lambda line: matching_signal(line, spec.topology_signals),
            timeout_seconds,
            f"{spec.name} topology signal",
        )
        elapsed_ms = (time.perf_counter_ns() - start) / 1_000_000
        if not isinstance(signal, MatchedSignal):
            raise BenchmarkError(f"unexpected topology signal result: {signal!r}")
        return Sample(
            action=spec.report_name,
            elapsed_ms=elapsed_ms,
            signal=signal.signal,
            topology_line=signal.line,
            command=command,
        )

    def close_window(self, window_id: str, timeout_seconds: float) -> None:
        if not re.fullmatch(r"@[0-9]+", window_id):
            raise BenchmarkError(f"refusing invalid tmux window id: {window_id}")

        self.send_command(f"kill-window -t {window_id}")
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            line = self.read_line(0.05)
            if line is None:
                break
            if control_payload(line).startswith(f"%window-close {window_id}"):
                return

        remaining_window_ids = self.list_window_ids(timeout_seconds)
        if window_id in remaining_window_ids:
            raise BenchmarkError(f"tmux window remained after close: {window_id}")

    def list_window_ids(self, timeout_seconds: float) -> set[str]:
        token = uuid.uuid4().hex[:8]
        prefix = f"__REMUX_EXACT_WINDOW__{token}"
        done = f"__REMUX_EXACT_DONE__{token}"
        self.send_command(
            f"list-windows -F {shlex.quote(prefix + ' #{window_id}')}"
        )
        self.send_command(f"display-message -p {shlex.quote(done)}")

        window_ids: set[str] = set()
        deadline = time.monotonic() + timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchmarkError("timed out waiting for tmux window list")

            line = self.read_line(remaining)
            if line is None:
                raise BenchmarkError("timed out waiting for tmux window list")

            payload = control_payload(line)
            if payload == done:
                return window_ids
            if payload.startswith(f"{prefix} "):
                parts = payload.split()
                if len(parts) >= 2:
                    window_ids.add(parts[1])


def run_remote_shell(
    config: SSHConfig,
    askpass: AskPass,
    remote_command: str,
    connect_timeout: int,
) -> subprocess.CompletedProcess[str]:
    command = [
        "ssh",
        "-p",
        str(config.port),
        "-o",
        "BatchMode=no",
        "-o",
        "NumberOfPasswordPrompts=1",
        "-o",
        f"ConnectTimeout={connect_timeout}",
        f"{config.username}@{config.host}",
        remote_command,
    ]
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=askpass.env(),
    )


def cleanup_remote_session(
    config: SSHConfig,
    askpass: AskPass,
    session_name: str,
    tmux_command: str,
    connect_timeout: int,
) -> str:
    quoted_tmux = shlex.quote(tmux_command)
    quoted_session = shlex.quote(session_name)
    remote = (
        "set -eu; "
        f"tmux_bin={quoted_tmux}; "
        "\"$tmux_bin\" kill-session -t "
        f"{quoted_session} 2>/dev/null || true; "
        "remaining=$(\"$tmux_bin\" list-sessions -F '#S' 2>/dev/null "
        f"| grep -Fx {quoted_session} || true); "
        "if [ -n \"$remaining\" ]; then "
        "echo cleanup_result=remaining; printf '%s\\n' \"$remaining\"; exit 1; "
        "fi; "
        "echo cleanup_result=clean"
    )
    result = run_remote_shell(config, askpass, remote, connect_timeout)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        raise BenchmarkError(output or f"cleanup failed with code {result.returncode}")
    return output or "cleanup_result=clean"


def combine_errors(primary: BenchmarkError, cleanup_error: BenchmarkError) -> BenchmarkError:
    return BenchmarkError(f"{primary}; cleanup also failed: {cleanup_error}")


def summarize(samples: list[Sample], report_name: str) -> str:
    values = [sample.elapsed_ms for sample in samples if sample.action == report_name]
    return (
        f"exact_ssh_control_{report_name}_topology,"
        f"n={len(values)},"
        f"p50_ms={statistics.median(values):.3f},"
        f"p95_ms={percentile(values, 0.95):.3f},"
        f"max_ms={max(values):.3f}"
    )


def sample_created_window_id(sample: Sample) -> str:
    window_id = window_id_from_topology_line(sample.topology_line)
    if window_id is None:
        raise BenchmarkError(
            f"could not determine created window from {sample.action} signal: "
            f"{sample.topology_line!r}"
        )
    return window_id


def prepare_split_window(
    session: ControlModeSession,
    context: TmuxContext,
    new_window_template: str,
    timeout_seconds: float,
) -> tuple[TmuxContext, str]:
    command = render_command(new_window_template, context)
    sample = session.measure_action(ACTION_SPECS[0], command, timeout_seconds)
    window_id = sample_created_window_id(sample)
    return session.request_context(timeout_seconds), window_id


def run_benchmark(args: argparse.Namespace) -> int:
    session_name = validate_session_name(
        args.session_name or f"remux-exact-ssh-bench-{uuid.uuid4().hex[:8]}"
    )
    config = load_config(Path(args.config), args.password_env)
    started_at = utc_timestamp()

    samples: list[Sample] = []
    cleanup_output = "cleanup_result=not_attempted"
    with AskPass(config.password) as askpass:
        control: ControlModeSession | None = None
        primary_error: BenchmarkError | None = None
        try:
            control = ControlModeSession(
                config=config,
                session_name=session_name,
                askpass=askpass,
                tmux_command=args.tmux_command,
                connect_timeout=args.connect_timeout,
            )
            context = control.request_context(args.timeout)
            control.drain_until_idle(idle_seconds=0.05, max_seconds=1.0)

            new_window_spec, split_pane_spec = ACTION_SPECS
            for index in range(args.samples):
                command = render_command(args.new_window_command, context)
                sample = control.measure_action(new_window_spec, command, args.timeout)
                samples.append(sample)
                control.close_window(sample_created_window_id(sample), args.timeout)
                context = control.request_context(args.timeout)
                control.drain_until_idle(idle_seconds=0.05, max_seconds=1.0)
                if args.verbose:
                    print(
                        "sample "
                        f"action={sample.action} index={index + 1} "
                        f"elapsed_ms={sample.elapsed_ms:.3f} signal={sample.signal} "
                        f"command={shlex.quote(sample.command)}"
                    )

            for index in range(args.samples):
                context, split_window_id = prepare_split_window(
                    control,
                    context,
                    args.new_window_command,
                    args.timeout,
                )
                control.drain_until_idle(idle_seconds=0.05, max_seconds=1.0)
                command = render_command(args.split_pane_command, context)
                sample = control.measure_action(split_pane_spec, command, args.timeout)
                samples.append(sample)
                control.close_window(split_window_id, args.timeout)
                context = control.request_context(args.timeout)
                control.drain_until_idle(idle_seconds=0.05, max_seconds=1.0)
                if args.verbose:
                    print(
                        "sample "
                        f"action={sample.action} index={index + 1} "
                        f"elapsed_ms={sample.elapsed_ms:.3f} signal={sample.signal} "
                        f"command={shlex.quote(sample.command)}"
                    )
        except BenchmarkError as error:
            primary_error = error
            raise
        finally:
            if control is not None:
                control.close()
            try:
                cleanup_output = cleanup_remote_session(
                    config=config,
                    askpass=askpass,
                    session_name=session_name,
                    tmux_command=args.tmux_command,
                    connect_timeout=args.connect_timeout,
                )
            except BenchmarkError as cleanup_error:
                if primary_error is not None:
                    raise combine_errors(primary_error, cleanup_error) from cleanup_error
                raise

    print(
        "exact_ssh_tmux_session "
        f"host={config.host} port={config.port} username={config.username} "
        f"session={session_name} samples={args.samples} "
        f"started_at={started_at} finished_at={utc_timestamp()}"
    )
    print(f"new_window_command_template={shlex.quote(args.new_window_command)}")
    print(f"split_pane_command_template={shlex.quote(args.split_pane_command)}")
    print(summarize(samples, "new_window"))
    print(summarize(samples, "split_pane"))
    print(cleanup_output)
    return 0


def self_test() -> int:
    context = parse_context_line(
        f"{CONTEXT_PREFIX}abc123 $54 %10",
        "abc123",
    )
    assert context == TmuxContext(session_id="$54", pane_id="%10")
    assert parse_context_line("unrelated", "abc123") is None
    assert matching_signal("%window-add @2", ("%window-add",)) == MatchedSignal(
        signal="%window-add",
        line="%window-add @2",
    )
    assert matching_signal("%layout-change @2 abc", ("%layout-change",)) == MatchedSignal(
        signal="%layout-change",
        line="%layout-change @2 abc",
    )
    assert matching_signal("%output %1 abc", ("%layout-change",)) is None
    assert window_id_from_topology_line("%session-window-changed $1 @2") == "@2"
    assert window_id_from_topology_line("%window-add @3") == "@3"
    assert render_command("new-window -t {session_id}", context) == "new-window -t $54"
    assert render_command("split-window -h -t {pane_id}", context) == "split-window -h -t %10"
    assert validate_session_name("remux-exact-ssh-bench-abc123") == (
        "remux-exact-ssh-bench-abc123"
    )
    try:
        validate_session_name("main")
    except BenchmarkError:
        pass
    else:
        raise AssertionError("expected arbitrary session name to be rejected")

    samples = [
        Sample(
            "new_window",
            10.0,
            "%window-add",
            "%window-add @2",
            "new-window -t $54",
        ),
        Sample(
            "new_window",
            30.0,
            "%session-window-changed",
            "%session-window-changed $54 @3",
            "new-window -t $54",
        ),
        Sample(
            "new_window",
            20.0,
            "%window-add",
            "%window-add @4",
            "new-window -t $54",
        ),
        Sample(
            "split_pane",
            5.0,
            "%layout-change",
            "%layout-change @5",
            "split-window -h -t %10",
        ),
        Sample(
            "split_pane",
            15.0,
            "%window-pane-changed",
            "%window-pane-changed @5 %11",
            "split-window -h -t %10",
        ),
    ]
    new_summary = summarize(samples, "new_window")
    split_summary = summarize(samples, "split_pane")
    assert "n=3" in new_summary
    assert "p50_ms=20.000" in new_summary
    assert "p95_ms=29.000" in new_summary
    assert "n=2" in split_summary
    assert "p50_ms=10.000" in split_summary

    print("self_test=ok")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Measure standalone SSH tmux -C topology response latency "
            "over a bare exec stream."
        )
    )
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--password-env", default=None)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--connect-timeout", type=int, default=10)
    parser.add_argument("--session-name", default=None)
    parser.add_argument("--tmux-command", default="tmux")
    parser.add_argument(
        "--new-window-command",
        default="new-window -t {session_id}",
        help="tmux command template; fields: {session_id}, {pane_id}",
    )
    parser.add_argument(
        "--split-pane-command",
        default="split-window -h -t {pane_id}",
        help="tmux command template; fields: {session_id}, {pane_id}",
    )
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.samples <= 0:
        parser.error("--samples must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()

    try:
        return run_benchmark(args)
    except BenchmarkError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
