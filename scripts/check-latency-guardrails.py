#!/usr/bin/env python3
"""Regression guard for the input-latency guardrails in the v0.65.2.2 baseline.

Upstream manaflow-ai/cmux still has several OPEN typing-latency issues and
unmerged PRs (#1519, #4705, PR #4707, PR #5665, #25089, ...). The release this
repository is built from already contains equivalent fixes under different PR
numbers, so the real risk is not "wait for upstream" but "silently lose one of
these guards while rebasing onto a newer upstream tag".

These guards are invisible when they work and only get noticed when typing
starts feeling slow again. This script checks that the mechanisms are still in
the source tree; it runs as a step of the `checks` PR gate. See LATENCY.md for
the per-issue analysis, the evidence list, and the limits of a static check.

What it does NOT do: it does not measure latency, and it does not prove the
guards actually fire at runtime. Behavioural coverage belongs to unit tests
(TODO T10) and an on-device A/B recording, not to a source-pattern lint.

Usage:
    python3 scripts/check-latency-guardrails.py [--repo-root <path>]

Exit codes:
    0  every guard present
    1  at least one guard missing (or a forbidden pattern reintroduced)
    2  invocation error
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

PROBE = (
    "Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/"
    "Service/SidebarGitMetadataService+Probe.swift"
)
LIMITER = (
    "Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/"
    "Scheduling/WorkspaceGitMetadataProbeLimiter.swift"
)
INDEX = "Packages/macOS/CmuxGit/Sources/CmuxGit/Parsing/GitMetadataService+Index.swift"
PREDICTION_ENGINE = (
    "Packages/Shared/CmuxTerminalPrediction/Sources/CmuxTerminalPrediction/"
    "TerminalPredictionEngine.swift"
)
PREDICTION_CENTER = (
    "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Prediction/"
    "TerminalPredictionCenter.swift"
)
TERMINAL_CATALOG = (
    "Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/"
    "TerminalCatalogSection.swift"
)


@dataclass(frozen=True)
class Guard:
    title: str
    path: str
    required: tuple[str, ...] = ()
    at_least: tuple[tuple[str, int], ...] = ()
    forbidden: tuple[str, ...] = ()
    language: str = "swift"
    note: str = ""


GUARDS: tuple[Guard, ...] = (
    Guard(
        title="Git probes defer during the typing quiet window",
        path=PROBE,
        required=(
            "nonisolated static let terminalTypingQuietInterval: TimeInterval",
            '"terminalTypingDeferred"',
            "probeLimiter.acquire()",
        ),
        at_least=(("host?.terminalTypingIsActive(within: Self.terminalTypingQuietInterval)", 2),),
        note=(
            "Both checks matter: one before a probe starts, one before a "
            "snapshot read before typing publishes sidebar state."
        ),
    ),
    Guard(
        title="Process-wide Git probe concurrency cap",
        path=LIMITER,
        required=(
            "public actor WorkspaceGitMetadataProbeLimiter",
            "public func acquire() async -> Bool",
            "public func release()",
        ),
    ),
    Guard(
        title="Concurrency cap is actually injected into every window",
        path="Sources/TabManager.swift",
        required=("sharedWorkspaceGitProbeLimiter = WorkspaceGitMetadataProbeLimiter(limit: 2)",),
    ),
    Guard(
        title="Allocation-free hex encoding for Git index object IDs",
        path=INDEX,
        required=(
            "gitIndexHexAlphabet",
            "encoded.append(gitIndexHexAlphabet[Int(byte >> 4)])",
        ),
        forbidden=(
            'String(format: "%02x"',
            'String(format: "%02hhx"',
        ),
        note="Upstream issue #4705 called out a String(format:) loop in this path.",
    ),
    Guard(
        title="Terminal title churn is coalesced before sidebar refresh",
        path="Sources/DockSplitStore.swift",
        required=(
            "func enqueueTerminalTitleUpdate(",
            "terminalTitleUpdateCoalescer.signal(",
        ),
    ),
    Guard(
        title="Title coalescing delay is configurable and bounded",
        path="Sources/PanelTitleUpdateCoalescingSettings.swift",
        required=(
            "static func delay(settings:",
            "minimumDelayMilliseconds",
            "maximumDelayMilliseconds",
        ),
    ),
    Guard(
        title="Predictive local echo excludes local and alternate-screen surfaces",
        path=PREDICTION_ENGINE,
        required=(
            "guard isRemoteSurface else { return .localSurface }",
            "if isAlternateScreen { return .alternateScreen }",
            "public mutating func seedAlternateScreen(_ isActive: Bool)",
        ),
        note=(
            "This exclusion is intentional: an agent TUI in the alternate "
            "screen must not have guessed glyphs drawn into it."
        ),
    ),
    Guard(
        title="Prediction center seeds the alternate-screen state from the terminal",
        path=PREDICTION_CENTER,
        required=(
            "func seedIfNeeded(surfaceID: UUID)",
            "engines[surfaceID]?.seedAlternateScreen(isActive)",
        ),
    ),
    Guard(
        title="TextBox and predictive-echo settings exist in the catalog",
        path=TERMINAL_CATALOG,
        required=(
            "public let predictiveLocalEcho = DefaultsKey<Bool>(",
            "public let showTextBoxOnNewTerminals = DefaultsKey<Bool>(",
            "public let focusTextBoxOnNewTerminals = DefaultsKey<Bool>(",
        ),
    ),
    Guard(
        title="New terminal panels honour the TextBox settings",
        path="Sources/Workspace.swift",
        required=(
            "TerminalTextBoxInputSettings.focusOnNewTerminals()",
            "TerminalTextBoxInputSettings.showOnNewTerminals()",
            "preferTextBoxInputWhenActivated()",
            "showTextBoxInputWhenAvailable()",
        ),
    ),
    Guard(
        title="TextBox show / focus APIs are still on TerminalPanel",
        path="Sources/Panels/TerminalPanel.swift",
        required=(
            "func preferTextBoxInputWhenActivated()",
            "func showTextBoxInputWhenAvailable()",
        ),
    ),
    Guard(
        title="Typing timestamp feeds the quiet-window checks",
        path="Sources/SessionAutosaveCoordinator.swift",
        required=("lastTypingActivityAt = ProcessInfo.processInfo.systemUptime",),
    ),
    Guard(
        title="Sidebar Git host exposes the typing quiet window",
        path="Sources/TabManager+SidebarGitHosting.swift",
        required=(
            "func terminalTypingIsActive(within interval: TimeInterval) -> Bool",
            "func terminalTypingQuietDelay(for interval: TimeInterval) -> TimeInterval",
            "lastTypingActivityAt",
        ),
    ),
    Guard(
        title="Scrollback checkpoint exports format a bounded tail",
        path="Sources/AppDelegate+SessionScrollbackCheckpoint.swift",
        required=(
            "readBoundedScreenTailVT(",
            "maxRows: lineLimit",
        ),
        note=(
            "Checkpoints capture the panes that produced background output, so "
            "they run exactly when the user is most likely to type again. "
            "Formatting the whole scrollback on the main thread made that export "
            "the only background task able to charge 50-100 ms to a keystroke; "
            "the quit-path snapshot already used the bounded formatter."
        ),
    ),
    Guard(
        title="zsh integration keeps the double-integration hook guards",
        path="Resources/shell-integration/cmux-zsh-integration.zsh",
        language="shell",
        required=(
            "_cmux_zsh_job_table_saturated",
            "_cmux_patch_ghostty_job_table_guard()",
            "zselect -t",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION",
        ),
        note=(
            "Guards on Ghostty's precmd / preexec / ZLE hooks, a fork-free "
            "sleep, and bounded ordered socket writes keep the two shell "
            "integrations from contending with input (#2195)."
        ),
    ),
)


def strip_comments(text: str, language: str) -> str:
    """Drop comments so a stale comment cannot make a deleted guard look alive."""
    if language == "shell":
        text = re.sub(r"(?m)^\s*#.*$", "", text)
        return re.sub(r"(?m)\s+#.*$", "", text)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def check_guard(root: Path, guard: Guard) -> tuple[bool, list[str]]:
    path = root / guard.path
    if not path.is_file():
        return False, [f"file missing: {guard.path}"]
    source = strip_comments(path.read_text(encoding="utf-8", errors="replace"), guard.language)
    problems: list[str] = []
    for pattern in guard.required:
        if pattern not in source:
            problems.append(f"missing: {pattern!r}")
    for pattern, minimum in guard.at_least:
        found = source.count(pattern)
        if found < minimum:
            problems.append(f"expected at least {minimum} of {pattern!r}, found {found}")
    for pattern in guard.forbidden:
        if pattern in source:
            problems.append(f"forbidden pattern reintroduced: {pattern!r}")
    return not problems, problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root (defaults to the script's parent directory).",
    )
    args = parser.parse_args(argv)
    root = args.repo_root.resolve()
    if not root.is_dir():
        print(f"error: repo root is not a directory: {root}", file=sys.stderr)
        return 2

    pattern_count = sum(
        len(g.required) + len(g.at_least) + len(g.forbidden) for g in GUARDS
    )
    print(f"input-latency guardrails: {len(GUARDS)} groups, {pattern_count} patterns")
    failures = 0
    for guard in GUARDS:
        ok, problems = check_guard(root, guard)
        if ok:
            print(f"  PASS  {guard.title}")
            continue
        failures += 1
        print(f"  FAIL  {guard.title}  [{guard.path}]")
        for problem in problems:
            print(f"          - {problem}")
        if guard.note:
            print(f"          why: {guard.note}")

    if failures:
        print(
            f"\n{failures} guard group(s) regressed. See LATENCY.md before "
            "changing these checks: if upstream replaced a guard with an "
            "equivalent implementation, update this script and document it, "
            "do not delete the check.",
            file=sys.stderr,
        )
        return 1
    print("\nall input-latency guardrails present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
