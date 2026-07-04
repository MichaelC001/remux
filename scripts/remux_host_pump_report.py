#!/usr/bin/env python3
"""Summarize current Remux tmux pump perf logs."""

from __future__ import annotations

import argparse
import re
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


TMUX_PUMP_RE = re.compile(
    r"Remux perf "
    r"t=(?P<timestamp>\d+) "
    r"thread=(?P<thread>[^ ]+) "
    r"tmuxPump "
    r"bytes=(?P<bytes>\d+) "
    r"wait_ms=(?P<wait>[0-9.]+) "
    r"apply_ms=(?P<apply>[0-9.]+)"
)


@dataclass(frozen=True)
class PumpSample:
    source: str
    line: int
    timestamp: int
    thread: str
    byte_count: int
    wait_ms: float
    apply_ms: float

    @property
    def total_ms(self) -> float:
        return self.wait_ms + self.apply_ms


def percentile(values: list[float], percentile_value: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("percentile requires at least one value")

    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def parse_lines(source: str, lines: Iterable[str]) -> list[PumpSample]:
    samples: list[PumpSample] = []
    for line_number, line in enumerate(lines, start=1):
        match = TMUX_PUMP_RE.search(line)
        if match is None:
            continue

        samples.append(
            PumpSample(
                source=source,
                line=line_number,
                timestamp=int(match.group("timestamp")),
                thread=match.group("thread"),
                byte_count=int(match.group("bytes")),
                wait_ms=float(match.group("wait")),
                apply_ms=float(match.group("apply")),
            )
        )
    return samples


def parse_paths(paths: Iterable[Path]) -> list[PumpSample]:
    samples: list[PumpSample] = []
    for path in paths:
        samples.extend(parse_lines(str(path), path.read_text(errors="replace").splitlines()))
    return samples


def summarize_values(label: str, values: list[float]) -> str:
    if not values:
        return f"{label}: n=0"

    return (
        f"{label}: "
        f"n={len(values)} "
        f"p50_ms={statistics.median(values):.3f} "
        f"p95_ms={percentile(values, 0.95):.3f} "
        f"max_ms={max(values):.3f}"
    )


def summarize_bucket(samples: list[PumpSample]) -> list[str]:
    total_bytes = sum(sample.byte_count for sample in samples)
    return [
        f"samples={len(samples)} total_bytes={total_bytes}",
        summarize_values("wait", [sample.wait_ms for sample in samples]),
        summarize_values("apply", [sample.apply_ms for sample in samples]),
        summarize_values("total", [sample.total_ms for sample in samples]),
    ]


def shorten(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 3)] + "..."


def report(samples: list[PumpSample], top_count: int) -> str:
    if not samples:
        return "tmux_pump_samples=0"

    lines = [f"tmux_pump_samples={len(samples)}"]
    lines.extend(summarize_bucket(samples))

    lines.append("")
    lines.append("by thread")
    for thread in sorted({sample.thread for sample in samples}):
        bucket = [sample for sample in samples if sample.thread == thread]
        lines.append(f"[{thread}]")
        lines.extend(summarize_bucket(bucket))

    lines.append("")
    lines.append(f"top {top_count} slowest")
    for sample in sorted(samples, key=lambda item: item.total_ms, reverse=True)[:top_count]:
        lines.append(
            f"{sample.total_ms:.3f}ms "
            f"wait_ms={sample.wait_ms:.3f} "
            f"apply_ms={sample.apply_ms:.3f} "
            f"bytes={sample.byte_count} "
            f"thread={sample.thread} "
            f"source={shorten(sample.source, 80)}:{sample.line}"
        )

    return "\n".join(lines)


def run_self_test() -> None:
    synthetic = [
        "noise",
        "Remux perf t=100 thread=bg tmuxPump bytes=4096 wait_ms=1.000 apply_ms=80.000",
        "Remux perf t=200 thread=bg tmuxPump bytes=119 wait_ms=0.250 apply_ms=2.500",
        "Remux perf t=300 thread=main tmuxPump bytes=55 wait_ms=0.000 apply_ms=0.100",
    ]
    samples = parse_lines("synthetic.log", synthetic)
    output = report(samples, top_count=2)

    assert len(samples) == 3
    assert sum(sample.byte_count for sample in samples) == 4270
    assert "tmux_pump_samples=3" in output
    assert "samples=3 total_bytes=4270" in output
    assert "wait: n=3 p50_ms=0.250" in output
    assert "apply: n=3 p50_ms=2.500" in output
    assert "[bg]" in output
    assert "81.000ms wait_ms=1.000 apply_ms=80.000" in output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize current Remux tmuxPump perf logs."
    )
    parser.add_argument("paths", nargs="*", type=Path, help="App log files to parse.")
    parser.add_argument("--top", type=int, default=12, help="Number of slow samples to print.")
    parser.add_argument("--self-test", action="store_true", help="Run parser self-test.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.self_test:
        run_self_test()
        print("self-test passed")
        return

    samples = parse_paths(args.paths)
    print(report(samples, top_count=args.top))


if __name__ == "__main__":
    main()
