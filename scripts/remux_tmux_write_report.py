#!/usr/bin/env python3
"""Summarize Remux tmux write bundles from trace logs."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


TRACE_RE = re.compile(
    r"Remux (?:latency|perf|flow|tmuxViewport) "
    r"t=(?P<timestamp>\d+) "
    r"(?P<body>.*)$"
)
WRITE_RE = re.compile(
    r"transport\.send begin "
    r"bytes=(?P<bytes>\d+) "
    r"preview=(?P<preview>.*)$"
)
TARGET_RE = re.compile(r"(?:^| )-t (?P<target>[^ ;\\]+)")
PANE_ID_RE = re.compile(r"%\d+")

NANOS_PER_MILLISECOND = 1_000_000


@dataclass(frozen=True)
class LogLine:
    source: str
    line: int
    timestamp: int | None
    body: str


@dataclass(frozen=True)
class TmuxWriteCommand:
    kind: str
    target: str
    text: str


@dataclass(frozen=True)
class TmuxWriteBundle:
    source: str
    line: int
    timestamp: int | None
    byte_count: int
    preview: str
    commands: tuple[TmuxWriteCommand, ...]

    @property
    def primary_kind(self) -> str:
        for kind in (
            "pane_history",
            "pane_visible",
            "pane_pending_output",
            "pane_state",
            "pane_metadata",
            "window_list",
            "refresh_client",
            "select_window",
            "select_pane",
            "send_keys",
        ):
            if any(command.kind == kind for command in self.commands):
                return kind
        return self.commands[0].kind if self.commands else "empty"

    @property
    def is_state_read_bundle(self) -> bool:
        return any(command.kind in STATE_READ_COMMAND_KINDS for command in self.commands)

    @property
    def signature(self) -> tuple[tuple[str, str], ...]:
        return tuple((command.kind, command.target) for command in self.commands)

    @property
    def kind_signature(self) -> tuple[str, ...]:
        return tuple(command.kind for command in self.commands)


@dataclass(frozen=True)
class ParseResult:
    writes: tuple[TmuxWriteBundle, ...]


@dataclass(frozen=True)
class DuplicateWrite:
    previous: TmuxWriteBundle
    current: TmuxWriteBundle
    delta_ms: float


@dataclass(frozen=True)
class RefreshFollowup:
    refresh: TmuxWriteBundle
    state_read: TmuxWriteBundle
    delta_ms: float


STATE_READ_COMMAND_KINDS = {
    "pane_history",
    "pane_visible",
    "pane_pending_output",
    "pane_state",
    "pane_metadata",
    "tmux_version",
    "window_list",
}


def decode_preview(preview: str) -> str:
    return (
        preview
        .replace("\\134x0D", "\n")
        .replace("\\134x0A", "\n")
        .replace("\\x0D", "\n")
        .replace("\\x0A", "\n")
    )


def split_commands(preview: str) -> tuple[TmuxWriteCommand, ...]:
    commands: list[TmuxWriteCommand] = []
    for raw_line in decode_preview(preview).splitlines():
        for raw_command in raw_line.split(" ; "):
            command = raw_command.strip()
            if not command:
                continue
            commands.append(
                TmuxWriteCommand(
                    kind=command_kind(command),
                    target=command_target(command),
                    text=command,
                )
            )
    return tuple(commands)


def command_kind(command: str) -> str:
    first = command.split(maxsplit=1)[0] if command else "empty"
    if first == "display-message" and "#{version}" in command:
        return "tmux_version"
    if first == "display-message" and "#{history_size}" in command:
        return "pane_metadata"
    if first == "capture-pane":
        if " -P " in command:
            return "pane_pending_output"
        if " -S -" in command:
            return "pane_history"
        return "pane_visible"
    if first == "list-panes":
        return "pane_state"
    if first == "list-windows":
        return "window_list"
    if first == "refresh-client":
        return "refresh_client"
    if first == "select-window":
        return "select_window"
    if first == "select-pane":
        return "select_pane"
    if first == "send-keys":
        return "send_keys"
    if first in {"new-window", "split-window", "kill-pane", "kill-window"}:
        return first.replace("-", "_")
    if first.startswith("capt"):
        return "capture_truncated"
    if first.startswith("list-"):
        return "list_truncated"
    return first


def command_target(command: str) -> str:
    if match := TARGET_RE.search(command):
        return match.group("target")
    if match := PANE_ID_RE.search(command):
        return match.group(0)
    return "-"


def parse_log_line(source: str, line_number: int, line: str) -> LogLine:
    match = TRACE_RE.search(line)
    if match is None:
        return LogLine(
            source=source,
            line=line_number,
            timestamp=None,
            body=line,
        )

    return LogLine(
        source=source,
        line=line_number,
        timestamp=int(match.group("timestamp")),
        body=match.group("body"),
    )


def parse_write_lines(source: str, lines: Iterable[str]) -> list[TmuxWriteBundle]:
    writes: list[TmuxWriteBundle] = []
    for line_number, line in enumerate(lines, 1):
        log_line = parse_log_line(source, line_number, line)
        if match := WRITE_RE.search(log_line.body):
            preview = match.group("preview").strip()
            writes.append(
                TmuxWriteBundle(
                    source=source,
                    line=line_number,
                    timestamp=log_line.timestamp,
                    byte_count=int(match.group("bytes")),
                    preview=preview,
                    commands=split_commands(preview),
                )
            )
    return writes


def parse_paths(paths: Iterable[Path]) -> ParseResult:
    writes: list[TmuxWriteBundle] = []
    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            writes.extend(parse_write_lines(str(path), handle))
    return ParseResult(writes=tuple(writes))


def duplicate_writes(
    writes: list[TmuxWriteBundle],
    window_ms: float,
    same_preview: bool,
    state_read_only: bool = False,
) -> list[DuplicateWrite]:
    duplicates: list[DuplicateWrite] = []
    max_delta_ns = window_ms * NANOS_PER_MILLISECOND
    for previous, current in zip(writes, writes[1:]):
        if previous.source != current.source:
            continue
        if state_read_only and (
            not previous.is_state_read_bundle or not current.is_state_read_bundle
        ):
            continue
        if previous.timestamp is None or current.timestamp is None:
            continue
        delta = current.timestamp - previous.timestamp
        if delta < 0 or delta > max_delta_ns:
            continue
        if same_preview:
            if previous.preview != current.preview:
                continue
        elif previous.signature != current.signature:
            continue
        duplicates.append(
            DuplicateWrite(
                previous=previous,
                current=current,
                delta_ms=delta / NANOS_PER_MILLISECOND,
            )
        )
    return duplicates


def refresh_followups(
    writes: list[TmuxWriteBundle],
    window_ms: float,
) -> list[RefreshFollowup]:
    followups: list[RefreshFollowup] = []
    max_delta_ns = window_ms * NANOS_PER_MILLISECOND
    for index, refresh in enumerate(writes):
        if refresh.timestamp is None:
            continue
        if not any(command.kind == "refresh_client" for command in refresh.commands):
            continue
        for state_read in writes[index + 1:]:
            if state_read.source != refresh.source:
                break
            if state_read.timestamp is None:
                continue
            delta = state_read.timestamp - refresh.timestamp
            if delta < 0:
                continue
            if delta > max_delta_ns:
                break
            if state_read.is_state_read_bundle:
                followups.append(
                    RefreshFollowup(
                        refresh=refresh,
                        state_read=state_read,
                        delta_ms=delta / NANOS_PER_MILLISECOND,
                    )
                )
                break
    return followups


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0
    index = round((len(values) - 1) * fraction)
    return values[min(index, len(values) - 1)]


def summarize_values(values: list[float], suffix: str = "") -> str:
    if not values:
        return "count=0"
    ordered = sorted(values)
    return (
        f"count={len(ordered)} "
        f"avg{suffix}={statistics.fmean(ordered):.3f} "
        f"p50{suffix}={percentile(ordered, 0.50):.3f} "
        f"p95{suffix}={percentile(ordered, 0.95):.3f} "
        f"p99{suffix}={percentile(ordered, 0.99):.3f} "
        f"max{suffix}={ordered[-1]:.3f}"
    )


def bundle_label(kinds: tuple[str, ...]) -> str:
    return " + ".join(kinds) if kinds else "empty"


def target_label(write: TmuxWriteBundle) -> str:
    targets = [command.target for command in write.commands if command.target != "-"]
    if not targets:
        return "-"
    unique = []
    for target in targets:
        if target not in unique:
            unique.append(target)
    return ",".join(unique)


def print_write_report(
    result: ParseResult,
    duplicate_windows_ms: list[float],
    follow_windows_ms: list[float],
    top_count: int,
) -> None:
    writes = sorted(result.writes, key=lambda item: (item.source, item.timestamp or -1, item.line))

    print("tmux write summary")
    print(
        f"writes={len(writes)} "
        f"bytes={sum(write.byte_count for write in writes)} "
        f"commands={sum(len(write.commands) for write in writes)}"
    )

    kind_counts = Counter(command.kind for write in writes for command in write.commands)
    print()
    print("by command kind")
    for kind, count in kind_counts.most_common():
        bytes_for_kind = sum(
            write.byte_count
            for write in writes
            if any(command.kind == kind for command in write.commands)
        )
        print(f"{kind}: count={count} bundle_bytes={bytes_for_kind}")

    bundle_counts = Counter(write.kind_signature for write in writes)
    print()
    print(f"top {top_count} bundles")
    for kinds, count in bundle_counts.most_common(top_count):
        bytes_for_bundle = sum(write.byte_count for write in writes if write.kind_signature == kinds)
        print(f"{bundle_label(kinds)}: count={count} bytes={bytes_for_bundle}")

    print()
    print("adjacent duplicate same-preview writes")
    for window in duplicate_windows_ms:
        duplicates = duplicate_writes(writes, window_ms=window, same_preview=True)
        print(f"window_ms={window:g}: count={len(duplicates)}")

    print()
    print("adjacent duplicate state-read same-preview writes")
    for window in duplicate_windows_ms:
        duplicates = duplicate_writes(
            writes,
            window_ms=window,
            same_preview=True,
            state_read_only=True,
        )
        print(f"window_ms={window:g}: count={len(duplicates)}")

    print()
    print("adjacent duplicate same-signature writes")
    for window in duplicate_windows_ms:
        duplicates = duplicate_writes(writes, window_ms=window, same_preview=False)
        print(f"window_ms={window:g}: count={len(duplicates)}")

    print()
    print("adjacent duplicate state-read same-signature writes")
    for window in duplicate_windows_ms:
        duplicates = duplicate_writes(
            writes,
            window_ms=window,
            same_preview=False,
            state_read_only=True,
        )
        print(f"window_ms={window:g}: count={len(duplicates)}")

    print()
    print("refresh-client followed by state-read bundle")
    for window in follow_windows_ms:
        followups = refresh_followups(writes, window_ms=window)
        state_read_kinds = Counter(
            followup.state_read.primary_kind for followup in followups
        )
        detail = " ".join(
            f"{kind}={count}" for kind, count in sorted(state_read_kinds.items())
        )
        suffix = f" {detail}" if detail else ""
        print(f"window_ms={window:g}: count={len(followups)}{suffix}")

    print()
    print(f"top {top_count} duplicate state-read same-preview writes within max window")
    max_duplicate_window = max(duplicate_windows_ms) if duplicate_windows_ms else 0
    for duplicate in duplicate_writes(
        writes,
        window_ms=max_duplicate_window,
        same_preview=True,
        state_read_only=True,
    )[:top_count]:
        print(
            f"{duplicate.current.source}:{duplicate.previous.line}->{duplicate.current.line} "
            f"delta_ms={duplicate.delta_ms:.3f} "
            f"bytes={duplicate.current.byte_count} "
            f"bundle={bundle_label(duplicate.current.kind_signature)} "
            f"targets={target_label(duplicate.current)}"
        )

    print()
    print(f"top {top_count} refresh followups within max window")
    max_follow_window = max(follow_windows_ms) if follow_windows_ms else 0
    for followup in refresh_followups(writes, window_ms=max_follow_window)[:top_count]:
        print(
            f"{followup.state_read.source}:{followup.refresh.line}->{followup.state_read.line} "
            f"delta_ms={followup.delta_ms:.3f} "
            f"state_read={bundle_label(followup.state_read.kind_signature)} "
            f"targets={target_label(followup.state_read)}"
        )


def run_self_test() -> None:
    lines = [
        "Remux latency t=1000000 transport.send begin bytes=24 preview=refresh-client -C 45x37\\134x0A",
        "Remux latency t=2000000 transport.send begin bytes=120 preview=capture-pane -p -e -q -C -N -t %1 ; capture-pane -p -P -C -t %1\\134x0Alist-panes -s -F '#{pane_id}'\\134x0A",
        "Remux latency t=2500000 transport.send begin bytes=120 preview=capture-pane -p -e -q -C -N -t %1 ; capture-pane -p -P -C -t %1\\134x0Alist-panes -s -F '#{pane_id}'\\134x0A",
    ]
    writes = parse_write_lines("synthetic.log", lines)
    assert len(writes) == 3
    assert writes[1].kind_signature == ("pane_visible", "pane_pending_output", "pane_state")
    assert refresh_followups(writes, window_ms=2)[0].state_read == writes[1]
    assert len(duplicate_writes(writes, window_ms=1, same_preview=True, state_read_only=True)) == 1
    print("self-test passed")


def parse_float_list(value: str) -> list[float]:
    try:
        return [float(part) for part in value.split(",") if part]
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize Ghostty-generated tmux command bundles sent by Remux."
    )
    parser.add_argument("paths", nargs="*", type=Path, help="App log files to parse.")
    parser.add_argument("--top", type=int, default=12, help="Number of detail rows to print.")
    parser.add_argument(
        "--duplicate-windows-ms",
        type=parse_float_list,
        default=[1, 5, 25],
        help="Comma-separated adjacent duplicate windows in milliseconds.",
    )
    parser.add_argument(
        "--follow-windows-ms",
        type=parse_float_list,
        default=[25, 75, 150],
        help="Comma-separated refresh-client follow-up windows in milliseconds.",
    )
    parser.add_argument("--self-test", action="store_true", help="Run parser self-test.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    if not args.paths:
        print("error: provide at least one log path or --self-test", file=sys.stderr)
        return 2

    missing = [path for path in args.paths if not path.is_file()]
    if missing:
        for path in missing:
            print(f"error: missing log file: {path}", file=sys.stderr)
        return 2

    result = parse_paths(args.paths)
    print_write_report(
        result,
        duplicate_windows_ms=args.duplicate_windows_ms,
        follow_windows_ms=args.follow_windows_ms,
        top_count=args.top,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
