#!/usr/bin/env python3
"""Run repeated Remux debug latency probes on a connected physical iOS device."""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

DEFAULT_DONE_PATTERNS = {
    "input": r"debugLatencyProbe\.status debug latency input probe sent",
    "key-echo": r"debugLatencyProbe\.status debug latency key echo probe sent",
    "new-window": r"flow=tmux\.newWindow event=runtime\.wakeup\.appTick\.end",
    "split-right": r"flow=tmux\.splitPane event=runtime\.wakeup\.appTick\.end",
    "split-down": r"flow=tmux\.splitPane event=runtime\.wakeup\.appTick\.end",
    "show-windows": r"flow=tmux\.showWindows event=ui\.sheet\.presented",
    "show-panes": r"flow=tmux\.showPanes event=ui\.sheet\.presented",
    "show-windows-dismiss": r"flow=tmux\.dismissSelectionSheet event=ui\.sheet\.dismissed",
    "show-panes-dismiss": r"flow=tmux\.dismissSelectionSheet event=ui\.sheet\.dismissed",
    "select-window": r"flow=tmux\.selectWindow event=tmux\.signal\.transport\.emit\.session-window-changed",
    "select-pane": r"flow=tmux\.selectPane event=tmux\.signal\.transport\.emit\.window-pane-changed",
    "close-window": r"flow=tmux\.closeWindow event=tmux\.signal\.transport\.emit\.(window-close|session-window-changed)",
    "close-pane": r"flow=tmux\.closePane event=tmux\.signal\.transport\.emit\.(pane-exited|window-pane-changed|layout-change)",
}

DEFAULT_ENV = {
    "REMUX_TRACE_LATENCY": "1",
    "REMUX_TRACE_PERF": "1",
    "REMUX_TRACE_FLOWS": "1",
    "REMUX_TRACE_TMUX_VIEWPORT": "1",
}


@dataclass(frozen=True)
class SampleResult:
    probe: str
    index: int
    session: str
    log_path: Path
    completed: bool
    elapsed_seconds: float
    matched_line: str | None
    return_code: int | None


@dataclass(frozen=True)
class SSHConfig:
    host: str
    port: str
    username: str
    password: str | None
    private_key: str | None
    private_key_passphrase: str | None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run repeated physical-device Remux debug latency probes."
    )
    parser.add_argument("--device", required=True, help="physical device UDID")
    parser.add_argument("--bundle-id", default="dev.remux.app")
    parser.add_argument("--session", default="base", help="Remux saved workspace/session to auto-open")
    parser.add_argument(
        "--session-template",
        help=(
            "format string for per-sample session names; supports {stamp}, "
            "{probe}, and {index}"
        ),
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(".local/profiling/physical-probe-batch"),
    )
    parser.add_argument(
        "--probe",
        action="append",
        required=True,
        help="probe action; repeat to run several probe kinds",
    )
    parser.add_argument("--samples", type=int, default=3, help="samples per probe")
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds per sample")
    parser.add_argument("--tail-seconds", type=float, default=0.75)
    parser.add_argument(
        "--done-pattern",
        action="append",
        default=[],
        metavar="PROBE=REGEX",
        help="override completion regex for a probe",
    )
    parser.add_argument(
        "--report-script",
        type=Path,
        default=Path("scripts/remux_flow_segment_report.py"),
    )
    parser.add_argument(
        "--seed-config",
        type=Path,
        help=(
            "local JSON SSH config used to debug-seed an ephemeral Remux "
            "connection; supports displayName, host, port, username, password, "
            "privateKeyPEM, and privateKeyPassphrase"
        ),
    )
    parser.add_argument(
        "--ephemeral-storage",
        action="store_true",
        help="use Remux in-memory debug storage for the launched app process",
    )
    parser.add_argument(
        "--fixture",
        choices=("none", "two-windows", "two-panes"),
        default="none",
        help=(
            "prepare each disposable tmux session before launching the app; "
            "requires --seed-config and --session-template"
        ),
    )
    parser.add_argument(
        "--keep-fixture-sessions",
        action="store_true",
        help="do not kill disposable fixture tmux sessions after each sample",
    )
    parser.add_argument(
        "--local-fixture",
        action="store_true",
        help="prepare fixture tmux sessions with the local tmux command instead of SSH",
    )
    return parser.parse_args(argv)


def done_patterns(overrides: list[str]) -> dict[str, str]:
    patterns = dict(DEFAULT_DONE_PATTERNS)
    for override in overrides:
        if "=" not in override:
            raise ValueError(f"invalid --done-pattern value: {override}")
        probe, pattern = override.split("=", 1)
        if not probe or not pattern:
            raise ValueError(f"invalid --done-pattern value: {override}")
        patterns[probe] = pattern
    return patterns


def seed_environment(config_path: Path, session: str) -> dict[str, str]:
    raw = json.loads(config_path.read_text())
    environment = {
        "REMUX_DEBUG_SEED_CONNECTION": "1",
        "REMUX_DEBUG_SERVER_NAME": str(raw.get("displayName") or "Remux latency profiling"),
        "REMUX_DEBUG_SERVER_HOST": str(raw.get("host") or ""),
        "REMUX_DEBUG_SERVER_PORT": str(raw.get("port") or "22"),
        "REMUX_DEBUG_SERVER_USERNAME": str(raw.get("username") or ""),
        "REMUX_DEBUG_TMUX_SESSION": session,
    }

    password = raw.get("password")
    private_key = raw.get("privateKeyPEM") or raw.get("privateKey")
    private_key_passphrase = raw.get("privateKeyPassphrase")
    if private_key:
        environment["REMUX_DEBUG_PRIVATE_KEY"] = str(private_key)
        if private_key_passphrase is not None:
            environment["REMUX_DEBUG_PRIVATE_KEY_PASSPHRASE"] = str(private_key_passphrase)
    elif password is not None:
        environment["REMUX_DEBUG_SERVER_PASSWORD"] = str(password)

    missing = [
        key
        for key in ("REMUX_DEBUG_SERVER_HOST", "REMUX_DEBUG_SERVER_USERNAME")
        if not environment[key]
    ]
    if missing:
        names = ", ".join(missing)
        raise ValueError(f"{config_path} is missing required seed fields: {names}")
    if "REMUX_DEBUG_SERVER_PASSWORD" not in environment and "REMUX_DEBUG_PRIVATE_KEY" not in environment:
        raise ValueError(f"{config_path} must include password or privateKeyPEM")

    return environment


def load_ssh_config(config_path: Path) -> SSHConfig:
    raw = json.loads(config_path.read_text())
    config = SSHConfig(
        host=str(raw.get("host") or ""),
        port=str(raw.get("port") or "22"),
        username=str(raw.get("username") or ""),
        password=str(raw.get("password")) if raw.get("password") is not None else None,
        private_key=(
            str(raw.get("privateKeyPEM") or raw.get("privateKey"))
            if raw.get("privateKeyPEM") or raw.get("privateKey")
            else None
        ),
        private_key_passphrase=(
            str(raw.get("privateKeyPassphrase"))
            if raw.get("privateKeyPassphrase") is not None
            else None
        ),
    )
    missing = [name for name in ("host", "username") if not getattr(config, name)]
    if missing:
        names = ", ".join(missing)
        raise ValueError(f"{config_path} is missing required SSH fields: {names}")
    if config.password is None and config.private_key is None:
        raise ValueError(f"{config_path} must include password or privateKeyPEM")
    return config


def run_remote_tmux_script(config_path: Path, script: str) -> None:
    config = load_ssh_config(config_path)
    with tempfile.TemporaryDirectory(prefix="remux-probe-ssh-") as temporary:
        temporary_path = Path(temporary)
        ssh_command = [
            "ssh",
            "-T",
            "-o",
            "BatchMode=no",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "NumberOfPasswordPrompts=1",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-p",
            config.port,
        ]
        environment = os.environ.copy()

        if config.private_key is not None:
            key_path = temporary_path / "identity"
            key_path.write_text(config.private_key)
            key_path.chmod(0o600)
            ssh_command.extend(["-i", str(key_path)])
            if config.private_key_passphrase is not None:
                askpass_path = temporary_path / "askpass.sh"
                askpass_path.write_text("#!/bin/sh\nprintf '%s\\n' \"$REMUX_PROFILING_SSH_SECRET\"\n")
                askpass_path.chmod(0o700)
                environment["SSH_ASKPASS"] = str(askpass_path)
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment.setdefault("DISPLAY", "localhost:0")
                environment["REMUX_PROFILING_SSH_SECRET"] = config.private_key_passphrase
        elif config.password is not None:
            askpass_path = temporary_path / "askpass.sh"
            askpass_path.write_text("#!/bin/sh\nprintf '%s\\n' \"$REMUX_PROFILING_SSH_SECRET\"\n")
            askpass_path.chmod(0o700)
            environment["SSH_ASKPASS"] = str(askpass_path)
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment.setdefault("DISPLAY", "localhost:0")
            environment["REMUX_PROFILING_SSH_SECRET"] = config.password

        ssh_command.append(f"{config.username}@{config.host}")
        completed = subprocess.run(
            ssh_command,
            check=False,
            input=script + "\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        if completed.returncode != 0:
            details = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"remote tmux setup failed: {details[:1000]}")


def run_local_tmux_script(script: str) -> None:
    completed = subprocess.run(
        ["/bin/sh"],
        check=False,
        input=script + "\n",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"local tmux setup failed: {details[:1000]}")


def fixture_script(fixture: str, session: str) -> str:
    target_session = shlex.quote(session)
    if fixture == "two-windows":
        first_window = shlex.quote(f"{session}:remux_one")
        session_windows = shlex.quote(f"{session}:")
        return "\n".join(
            [
                "set -eu",
                f"tmux kill-session -t {target_session} 2>/dev/null || true",
                f"tmux new-session -d -s {target_session} -n remux_one",
                f"tmux new-window -t {session_windows} -n remux_two",
                f"tmux select-window -t {first_window}",
                f"tmux display-message -p -t {target_session} '#S' >/dev/null",
            ]
        )
    if fixture == "two-panes":
        main_window = shlex.quote(f"{session}:remux_main")
        return "\n".join(
            [
                "set -eu",
                f"tmux kill-session -t {target_session} 2>/dev/null || true",
                f"tmux new-session -d -s {target_session} -n remux_main",
                f"tmux split-window -h -t {main_window}",
                f"tmux display-message -p -t {target_session} '#S' >/dev/null",
            ]
        )
    raise ValueError(f"unknown fixture: {fixture}")


def cleanup_script(session: str) -> str:
    target_session = shlex.quote(session)
    return f"tmux kill-session -t {target_session} 2>/dev/null || true"


def prepare_fixture(config_path: Path, fixture: str, session: str, local: bool) -> None:
    script = fixture_script(fixture, session)
    if local:
        run_local_tmux_script(script)
        return
    run_remote_tmux_script(config_path, script)


def cleanup_fixture(config_path: Path, session: str, local: bool) -> None:
    script = cleanup_script(session)
    if local:
        run_local_tmux_script(script)
        return
    run_remote_tmux_script(config_path, script)


def launch_environment(
    *,
    session: str,
    probe: str,
    seed_config: Path | None,
    ephemeral_storage: bool,
) -> str:
    environment = dict(DEFAULT_ENV)
    environment["REMUX_DEBUG_AUTO_OPEN_SESSION"] = session
    environment["REMUX_DEBUG_LATENCY_PROBE"] = probe
    if seed_config is not None:
        environment.update(seed_environment(seed_config, session))
    if ephemeral_storage:
        environment["REMUX_DEBUG_EPHEMERAL_STORAGE"] = "1"
    return json.dumps(environment, separators=(",", ":"))


def sample_session_name(
    *,
    base_session: str,
    template: str | None,
    stamp: str,
    probe: str,
    index: int,
) -> str:
    session = (
        template.format(stamp=stamp, probe=probe, index=f"{index:02d}")
        if template is not None
        else base_session
    )
    if not SESSION_NAME_RE.fullmatch(session):
        raise ValueError(f"invalid tmux session name: {session!r}")
    return session


def terminate_process(process: subprocess.Popen[str]) -> int | None:
    if process.poll() is not None:
        return process.returncode
    process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate()
    try:
        return process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=3)


def run_sample(
    *,
    device: str,
    bundle_id: str,
    session: str,
    probe: str,
    index: int,
    out_dir: Path,
    done_pattern: re.Pattern[str],
    timeout_seconds: float,
    tail_seconds: float,
    seed_config: Path | None,
    ephemeral_storage: bool,
) -> SampleResult:
    log_path = out_dir / f"{probe}-{index:02d}.log"
    command = [
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device,
        "--terminate-existing",
        "--console",
        "--environment-variables",
        launch_environment(
            session=session,
            probe=probe,
            seed_config=seed_config,
            ephemeral_storage=ephemeral_storage,
        ),
        bundle_id,
    ]

    started = time.monotonic()
    matched_line: str | None = None
    completed = False
    with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        try:
            while True:
                remaining = timeout_seconds - (time.monotonic() - started)
                if remaining <= 0:
                    break
                ready, _, _ = select.select(
                    [process.stdout],
                    [],
                    [],
                    min(0.1, remaining),
                )
                if ready:
                    line = process.stdout.readline()
                    log_file.write(line)
                    log_file.flush()
                    if done_pattern.search(line):
                        matched_line = line.rstrip("\n")
                        completed = True
                        break
                    continue
                if process.poll() is not None:
                    break
                time.sleep(0.05)

            if completed and tail_seconds > 0:
                deadline = time.monotonic() + tail_seconds
                while time.monotonic() < deadline:
                    ready, _, _ = select.select(
                        [process.stdout],
                        [],
                        [],
                        min(0.1, max(0.0, deadline - time.monotonic())),
                    )
                    if ready:
                        line = process.stdout.readline()
                        log_file.write(line)
                        log_file.flush()
                        continue
                    if process.poll() is not None:
                        break
                    time.sleep(0.05)
        finally:
            return_code = terminate_process(process)

    return SampleResult(
        probe=probe,
        index=index,
        session=session,
        log_path=log_path,
        completed=completed,
        elapsed_seconds=time.monotonic() - started,
        matched_line=matched_line,
        return_code=return_code,
    )


def write_summary(results: list[SampleResult], summary_path: Path) -> None:
    lines = [
        "probe,index,session,completed,elapsed_seconds,return_code,log_path,matched_line",
    ]
    for result in results:
        matched = (result.matched_line or "").replace('"', '""')
        lines.append(
            f"{result.probe},{result.index},{result.session},{str(result.completed).lower()},"
            f"{result.elapsed_seconds:.3f},{result.return_code},"
            f"{result.log_path},\"{matched}\""
        )
    summary_path.write_text("\n".join(lines) + "\n")


def run_report(report_script: Path, logs: list[Path], report_path: Path) -> None:
    command = [sys.executable, str(report_script), *[str(log) for log in logs]]
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    report_path.write_text(completed.stdout)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.samples < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 2
    if args.ephemeral_storage and args.seed_config is None:
        print("--ephemeral-storage requires --seed-config", file=sys.stderr)
        return 2
    if args.fixture != "none":
        if args.seed_config is None:
            print("--fixture requires --seed-config", file=sys.stderr)
            return 2
        if args.session_template is None:
            print("--fixture requires --session-template", file=sys.stderr)
            return 2

    try:
        patterns = done_patterns(args.done_pattern)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    missing = [probe for probe in args.probe if probe not in patterns]
    if missing:
        print(f"missing completion pattern for probes: {', '.join(missing)}", file=sys.stderr)
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = args.out_dir / stamp
    out_dir.mkdir(parents=True, exist_ok=False)

    results: list[SampleResult] = []
    for probe in args.probe:
        compiled_pattern = re.compile(patterns[probe])
        for index in range(1, args.samples + 1):
            try:
                session = sample_session_name(
                    base_session=args.session,
                    template=args.session_template,
                    stamp=stamp,
                    probe=probe,
                    index=index,
                )
            except ValueError as error:
                print(str(error), file=sys.stderr)
                return 2

            print(
                f"running probe={probe} sample={index}/{args.samples} session={session}",
                flush=True,
            )
            if args.fixture != "none":
                assert args.seed_config is not None
                prepare_fixture(args.seed_config, args.fixture, session, args.local_fixture)
            try:
                result = run_sample(
                    device=args.device,
                    bundle_id=args.bundle_id,
                    session=session,
                    probe=probe,
                    index=index,
                    out_dir=out_dir,
                    done_pattern=compiled_pattern,
                    timeout_seconds=args.timeout,
                    tail_seconds=args.tail_seconds,
                    seed_config=args.seed_config,
                    ephemeral_storage=args.ephemeral_storage,
                )
            finally:
                if args.fixture != "none" and not args.keep_fixture_sessions:
                    assert args.seed_config is not None
                    cleanup_fixture(args.seed_config, session, args.local_fixture)
            results.append(result)
            status = "ok" if result.completed else "timeout"
            print(
                f"{status} probe={probe} sample={index} "
                f"session={session} elapsed={result.elapsed_seconds:.3f}s "
                f"log={result.log_path}",
                flush=True,
            )

    summary_path = out_dir / "samples.csv"
    write_summary(results, summary_path)
    logs = [result.log_path for result in results]
    report_path = out_dir / "aggregate-segments.txt"
    run_report(args.report_script, logs, report_path)
    print(f"summary={summary_path}")
    print(f"report={report_path}")

    timed_out = [result for result in results if not result.completed]
    return 1 if timed_out else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
