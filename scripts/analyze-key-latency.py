#!/usr/bin/env python3
"""Attribute keystroke spikes to the background work that overlapped them.

The app writes `~/.local/state/cmux/key-latency.log` while the key-latency probe
is enabled (`defaults write com.xhqing.cmux cmuxKeyLatencyProbe -bool true`, or
`CMUX_KEY_LATENCY_PROBE=1`). The log mixes two kinds of line:

    <unixTime> <phase> <delayMs> <keyCode> <isRepeat>   one per key event
    <unixTime> <activity> <durationMs> [detail]         one per background span

Key lines answer "how long did this key wait before the terminal handled it".
Activity spans answer "what was running then", and a span covers
`[unixTime - durationMs, unixTime]`:

    mainTurn            a main-thread runloop turn that ran at least 20 ms
    scrollbackExport    one scrollback checkpoint's Ghostty format on main
    sessionAutosave     one session autosave tick (8 s schedule)

A spike is the event instant `unixTime - delayMs / 1000` landing inside a span.
If a spike has no overlapping span, the main thread was not busy with cmux work
of its own when the event arrived: look outside the app (another process holding
the CPU, or the window server) with `sample` / `spindump` instead of hunting for
Swift code. See LATENCY.md for the collection procedure and acceptance limits.

Usage:
    python3 scripts/analyze-key-latency.py [log path] [options]
    python3 scripts/analyze-key-latency.py --self-test

Options:
    --threshold-ms N   spikes are key events at or above this delay (default 30)
    --slack-ms N       tolerance when matching a span to a spike instant (default 50)
    --no-spikes        only print the summary tables
"""

from __future__ import annotations

import argparse
import datetime as _dt
import statistics
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

DEFAULT_LOG = Path("~/.local/state/cmux/key-latency.log").expanduser()

#: Phases written by `KeyLatencyProbe.record(event:phase:)`.
KEY_PHASES = {"keyDown"}


@dataclass(frozen=True)
class KeyEvent:
    timestamp: float
    delay_ms: float
    key_code: int
    is_repeat: bool

    @property
    def event_instant(self) -> float:
        """Unix time at which the system created the event."""
        return self.timestamp - self.delay_ms / 1000.0


@dataclass(frozen=True)
class Span:
    start: float
    end: float
    phase: str
    duration_ms: float
    detail: str

    def covers(self, instant: float, slack: float) -> bool:
        return self.start - slack <= instant <= self.end + slack


def parse_log(text: str) -> tuple[list[KeyEvent], list[Span], int]:
    keys: list[KeyEvent] = []
    spans: list[Span] = []
    skipped = 0
    for raw in text.splitlines():
        fields = raw.split()
        if len(fields) < 3:
            skipped += 1
            continue
        try:
            timestamp = float(fields[0])
            duration = float(fields[2])
        except ValueError:
            skipped += 1
            continue
        phase = fields[1]
        is_key_line = (
            phase in KEY_PHASES
            or (len(fields) == 5 and fields[3].lstrip("-").isdigit())
        )
        if is_key_line:
            try:
                keys.append(
                    KeyEvent(
                        timestamp=timestamp,
                        delay_ms=duration,
                        key_code=int(fields[3]) if len(fields) > 3 else -1,
                        is_repeat=len(fields) > 4 and fields[4] == "1",
                    )
                )
            except ValueError:
                skipped += 1
            continue
        spans.append(
            Span(
                start=timestamp - duration / 1000.0,
                end=timestamp,
                phase=phase,
                duration_ms=duration,
                detail=" ".join(fields[3:]),
            )
        )
    return keys, spans, skipped


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def clock(unix_time: float) -> str:
    return _dt.datetime.fromtimestamp(unix_time).strftime("%H:%M:%S.%f")[:-3]


def summarize(values: list[float]) -> str:
    if not values:
        return "n=0"
    return (
        f"n={len(values)} p50={statistics.median(values):.2f} "
        f"p90={percentile(values, 0.90):.2f} p99={percentile(values, 0.99):.2f} "
        f"max={max(values):.2f}"
    )


def report(
    keys: list[KeyEvent],
    spans: list[Span],
    threshold_ms: float,
    slack_ms: float,
    show_spikes: bool,
    stream=sys.stdout,
) -> int:
    def out(line: str = "") -> None:
        print(line, file=stream)

    delays = [key.delay_ms for key in keys]
    out(f"keys:   {summarize(delays)}")
    out(
        "        "
        + f">=20ms: {sum(1 for d in delays if d >= 20)}  "
        + f">=30ms: {sum(1 for d in delays if d >= 30)}  "
        + f">=50ms: {sum(1 for d in delays if d >= 50)}  "
        + f">=100ms: {sum(1 for d in delays if d >= 100)}"
    )

    phases: dict[str, list[float]] = {}
    for span in spans:
        phases.setdefault(span.phase, []).append(span.duration_ms)
    if phases:
        out("")
        out("background spans (main-thread cost per phase):")
        for phase in sorted(phases, key=lambda name: -max(phases[name])):
            out(f"  {phase:<18} {summarize(phases[phase])}")
    else:
        out("")
        out("background spans: none in this log (probe written by an older build?)")

    spikes = [key for key in keys if key.delay_ms >= threshold_ms]
    if not show_spikes:
        return 0
    out("")
    if not spikes:
        out(f"spikes: none at or above {threshold_ms:.0f} ms")
        return 0
    out(f"spikes at or above {threshold_ms:.0f} ms ({len(spikes)}):")
    slack = slack_ms / 1000.0
    attributed = 0
    for key in spikes:
        overlaps = [span for span in spans if span.covers(key.event_instant, slack)]
        if overlaps:
            attributed += 1
        out(f"  {clock(key.timestamp)} {key.delay_ms:8.2f} ms  keyCode={key.key_code}"
            + ("  (repeat)" if key.is_repeat else ""))
        if not overlaps:
            out("      no cmux background span overlapped this event instant")
            continue
        for span in sorted(overlaps, key=lambda item: item.start):
            detail = f" {span.detail}" if span.detail else ""
            out(
                f"      {span.phase:<18} {span.duration_ms:8.2f} ms"
                f"  {clock(span.start)} -> {clock(span.end)}{detail}"
            )
    out("")
    out(
        f"attributed: {attributed}/{len(spikes)} spikes overlapped a cmux background span"
    )
    if attributed < len(spikes):
        out(
            "unattributed spikes are not cmux main-thread work: capture "
            "`sample cmux` / `spindump` while they happen before changing app code"
        )
    return 0


def self_test() -> int:
    """Run the parser and the matcher against a synthetic log."""
    log = "\n".join(
        [
            # A spike whose event instant falls inside a 96 ms scrollback export.
            "1000.000 scrollbackExport 96.00 overBudget=1",
            "1000.010 keyDown 101.41 12 0",
            # A spike with no span around it.
            "2000.000 keyDown 53.70 12 0",
            # A fast key inside a long main-thread turn.
            "3000.100 mainTurn 40.00",
            "3000.050 keyDown 33.00 0 0",
            "3001.000 keyDown 6.00 0 0",
        ]
    ) + "\n"
    from io import StringIO

    keys, spans, skipped = parse_log(log)
    assert skipped == 0, skipped
    assert len(keys) == 4, keys
    assert len(spans) == 2, spans
    buffer = StringIO()
    report(keys, spans, threshold_ms=30, slack_ms=50, show_spikes=True, stream=buffer)
    output = buffer.getvalue()
    assert "attributed: 2/3 spikes" in output, output
    assert "scrollbackExport" in output and "mainTurn" in output, output
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "key-latency.log"
        path.write_text(log, encoding="utf-8")
        assert parse_log(path.read_text(encoding="utf-8"))[0] == keys
    print("self-test ok")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Attribute keystroke spikes to overlapping cmux background spans."
    )
    parser.add_argument("log", nargs="?", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--threshold-ms", type=float, default=30.0)
    parser.add_argument("--slack-ms", type=float, default=50.0)
    parser.add_argument("--no-spikes", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    if not args.log.is_file():
        print(f"error: no log at {args.log}", file=sys.stderr)
        print(
            "enable the probe first: defaults write com.xhqing.cmux "
            "cmuxKeyLatencyProbe -bool true  (restart cmux, then use it normally)",
            file=sys.stderr,
        )
        return 2

    keys, spans, skipped = parse_log(args.log.read_text(encoding="utf-8", errors="replace"))
    print(f"log: {args.log}  (unparsed lines: {skipped})")
    if not keys:
        print("no key events yet: is the probe enabled for this build?", file=sys.stderr)
        return 1
    return report(
        keys,
        spans,
        threshold_ms=args.threshold_ms,
        slack_ms=args.slack_ms,
        show_spikes=not args.no_spikes,
    )


if __name__ == "__main__":
    sys.exit(main())
