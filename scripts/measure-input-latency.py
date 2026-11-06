#!/usr/bin/env python3
"""Measure end-to-end input latency through the cmux CLI.

This is a *relative* probe, not a keyboard-to-photon instrument. It sends a
unique token with `cmux send` and polls `cmux read-screen --lines 1` until the
token appears, so the number includes the CLI process, the control socket, the
PTY echo and the screen read. A baseline of read-only `read-screen` calls is
subtracted to remove most of that fixed overhead.

Use it for A/B comparisons: before/after a patch, this build against the
official build, a quiet machine against a busy one. Do not compare its absolute
numbers with a 240 fps screen recording of a physical keypress.

Requirements:
  - A running cmux app with the `cmux` CLI on PATH (or pass --cmux).
  - A plain shell surface (not an agent TUI in the alternate screen).
  - --surface <id|ref|index>, or the CMUX_SURFACE_ID environment variable.

Usage:
    python3 scripts/measure-input-latency.py --surface surface:1 --samples 40
    python3 scripts/measure-input-latency.py --surface surface:1 --samples 40 --force

Nothing here runs automatically and it never activates a window or steals
focus: the user keeps typing normally in whatever surface is targeted.
"""

from __future__ import annotations

import argparse
import os
import secrets
import shutil
import statistics
import subprocess
import sys
import time

POLL_INTERVAL_SECONDS = 0.004


def cli(cli_path: str, args: list[str], timeout: float) -> tuple[bool, str, float]:
    started = time.perf_counter()
    try:
        result = subprocess.run(
            [cli_path, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        return False, str(error), time.perf_counter() - started
    elapsed = time.perf_counter() - started
    output = result.stdout if result.returncode == 0 else (result.stderr or result.stdout)
    return result.returncode == 0, output, elapsed


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return ordered[index]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmux", default=os.environ.get("CMUX_CLI", "cmux"))
    parser.add_argument("--surface", default=os.environ.get("CMUX_SURFACE_ID"))
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--baseline-samples", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=3.0, help="Per-sample timeout in seconds.")
    parser.add_argument("--force", action="store_true", help="Pass --force to `cmux send`.")
    parser.add_argument("--output", type=argparse.FileType("w"), default=sys.stdout)
    args = parser.parse_args(argv)

    if not args.surface:
        print("error: --surface is required (or set CMUX_SURFACE_ID)", file=sys.stderr)
        return 2
    if not shutil.which(args.cmux) and not os.path.isfile(args.cmux):
        print(f"error: cmux CLI not found: {args.cmux}", file=sys.stderr)
        return 2
    if args.samples < 1 or args.baseline_samples < 1:
        print("error: sample counts must be positive", file=sys.stderr)
        return 2

    surface_args = ["--surface", args.surface]

    ok, screen, _ = cli(args.cmux, ["read-screen", *surface_args, "--lines", "1"], args.timeout)
    if not ok or not screen.strip():
        print(
            "error: cannot read the target surface. Check that cmux is running, "
            "the surface id is right, and the surface is a plain shell.",
            file=sys.stderr,
        )
        print(screen.strip()[:400], file=sys.stderr)
        return 2

    baseline: list[float] = []
    for _ in range(args.baseline_samples):
        ok, _, elapsed = cli(args.cmux, ["read-screen", *surface_args, "--lines", "1"], args.timeout)
        if ok:
            baseline.append(elapsed * 1000.0)
    baseline_ms = statistics.median(baseline) if baseline else 0.0

    latencies: list[float] = []
    failures = 0
    for sample in range(args.samples):
        token = "LATENCY" + secrets.token_hex(3).upper() + str(sample)
        send_args = ["send", *surface_args]
        if args.force:
            send_args.append("--force")
        send_args.append(token)
        ok, _, _ = cli(args.cmux, send_args, args.timeout)
        if not ok:
            failures += 1
            continue

        sent_at = time.perf_counter()
        deadline = sent_at + args.timeout
        seen = False
        while time.perf_counter() < deadline:
            ok, screen, _ = cli(args.cmux, ["read-screen", *surface_args, "--lines", "1"], args.timeout)
            if ok and token in screen:
                latencies.append((time.perf_counter() - sent_at) * 1000.0)
                seen = True
                break
            time.sleep(POLL_INTERVAL_SECONDS)
        if not seen:
            failures += 1

        # Drop the un-submitted token so the next sample starts from a fresh
        # prompt line. Ctrl+C is safe in a plain shell and never submits input.
        cli(args.cmux, ["send-key", *surface_args, "ctrl+c"], args.timeout)
        time.sleep(0.02)

    print(f"surface: {args.surface}", file=args.output)
    print(f"samples: {len(latencies)} ok / {failures} failed", file=args.output)
    print(f"read-screen baseline (median): {baseline_ms:.2f} ms", file=args.output)
    if not latencies:
        print("no successful samples; nothing to report", file=sys.stderr)
        return 1
    p50 = percentile(latencies, 0.50)
    p90 = percentile(latencies, 0.90)
    p99 = percentile(latencies, 0.99)
    print(f"send -> visible:  p50 {p50:.2f} ms   p90 {p90:.2f} ms   p99 {p99:.2f} ms", file=args.output)
    print(
        "minus baseline:   "
        f"p50 {max(0.0, p50 - baseline_ms):.2f} ms   "
        f"p99 {max(0.0, p99 - baseline_ms):.2f} ms  (estimate only)",
        file=args.output,
    )
    print(
        "note: includes CLI + socket + PTY echo + screen read. "
        "Compare runs against each other, not against a physical-keypress recording.",
        file=args.output,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
