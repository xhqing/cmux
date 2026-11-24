#!/usr/bin/env python3
"""List the `-only-testing:` identifiers of the tests that failed a unit-test run.

Why this exists (TODO T13): the headless `unit-tests` job runs every `cmuxTests`
suite in one process on a shared runner. A handful of suites flip red from
timing noise (window server, run-loop pumping, cross-suite counters) even though
the implementation is fine, and each full run is expensive. Instead of rerunning
everything, the workflow reruns **only** the tests that failed: if they pass,
the failure was noise; if they fail again, it is a regression. That distinction
is only possible if we can name the failed tests precisely — hence this parser.

Sources, in priority order (their union is used so nothing is dropped):

  1. `--xcresult-json`: the output of
     `xcrun xcresulttool get test-results tests --path <bundle> --format json`.
     Identifiers there are authoritative for `-only-testing:`.
  2. `--log`: the raw `xcodebuild test` log. Used as a fallback (and always
     unioned) because it also captures lines the xcresult may nest differently.

Safety rule: never under-select. When a log line names a suite but not the
function (display-named Swift Testing tests), the whole suite is rerun.

Usage:
    rerun_failed_unit_tests.py --log raw.log [--xcresult-json tests.json]
    ... --explain   prints which source produced which identifier (stderr)

Exit codes: 0 = at least one identifier printed; 3 = nothing found (the caller
must treat that as a real failure, never as "nothing to do").
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TARGET = "cmuxTests"

# Swift Testing: `✘ Test <name> recorded an issue at <path>.swift:<line>:...`
ST_RECORDED = re.compile(
    r"✘ Test (?P<name>.+) recorded an issue at (?P<file>[^\s:]+\.swift):\d+"
)
# NOTE: the `✘ Test <name> failed after …` summary line is deliberately not
# parsed: it carries no file, so a function name from it cannot be turned into a
# `Suite/function` identifier. Every failure also logs the `recorded an issue at
# <file>` line below, which is what this parser relies on; anything it cannot
# attribute is left to the xcresult source instead of guessed.
# XCTest: `Test Case '-[SuiteName testMethod]' failed (0.123 seconds).`
XCT_FAILED = re.compile(r"Test Case '-\[(?P<suite>\w+) (?P<method>[^\]]+)\]' failed")


def _function_from_swift_testing_name(name: str) -> str | None:
    """Extracts `testFunction(...)` from a Swift Testing name, or None."""
    name = name.strip()
    if name.startswith('"') or name.startswith("'"):
        # A display name ("A canceled forward ..."), not a function signature.
        return None
    match = re.match(r"([A-Za-z_][A-Za-z0-9_.]*)\(.*\)\s*$", name, re.DOTALL)
    if match is None:
        return None
    return match.group(1)


def _strip_test_parameters(identifier: str) -> str:
    """`Suite/test(argument:)` -> `Suite/test` (keeps identifiers selectable)."""
    return re.sub(r"\(.*\)$", "", identifier)


def identifiers_from_log(path: Path) -> list[str]:
    """Identifiers named by the failure lines of one raw test log."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    found: list[str] = []

    for match in XCT_FAILED.finditer(text):
        found.append(f"{TARGET}/{match.group('suite')}/{match.group('method')}")

    # The recorded-issue line carries both the failing file (-> suite) and,
    # for function-named tests, the function. Display-named tests ("A canceled
    # forward ...") have no function in the log, so the suite is the finest
    # safe granularity: never under-select.
    for match in ST_RECORDED.finditer(text):
        suite = Path(match.group("file")).stem
        function = _function_from_swift_testing_name(match.group("name"))
        if function is None:
            found.append(f"{TARGET}/{suite}")
        else:
            found.append(f"{TARGET}/{suite}/{function}")

    return found


def identifiers_from_xcresult_json(path: Path) -> list[str]:
    """Identifiers of failed leaves anywhere in an xcresult JSON tree.

    The `xcresulttool get test-results tests` shape is a tree of nodes with
    `nodeType`, `name`, `identifier` and a status (`result` or `testStatus`).
    Walking generically keeps this working if Xcode reshapes the payload: any
    object that carries an `identifier` and reports a failure counts.
    """
    try:
        payload = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return []

    failed_statuses = {"failed", "failure", "error", "unexpected"}

    def is_failed(node: dict) -> bool:
        for key in ("result", "testStatus", "status", "caseStatus"):
            value = node.get(key)
            if isinstance(value, str) and value.strip().lower() in failed_statuses:
                return True
        return False

    found: list[str] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            identifier = node.get("identifier")
            node_type = str(node.get("nodeType", node.get("type", ""))).lower()
            if (
                isinstance(identifier, str)
                and identifier
                and is_failed(node)
                # Skip plan / configuration nodes that can carry a failure
                # aggregate but are not selectable tests.
                and "plan" not in node_type
                and "configuration" not in node_type
            ):
                found.append(identifier)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(payload)
    return found


def merge_identifiers(candidates: list[str]) -> list[str]:
    """Normalizes, dedupes, and collapses method identifiers under a suite."""
    normalized: list[str] = []
    for candidate in candidates:
        identifier = candidate.strip()
        if not identifier:
            continue
        identifier = _strip_test_parameters(identifier)
        if not identifier.startswith(f"{TARGET}/"):
            # xcresult identifiers may omit the target; log-derived ones never
            # do. Prefixing keeps `-only-testing:` well formed either way.
            identifier = f"{TARGET}/{identifier}"
        normalized.append(identifier)

    unique = sorted(set(normalized))
    suites = {identifier for identifier in unique if identifier.count("/") == 1}
    # A whole-suite selection already covers every method inside it.
    return [
        identifier
        for identifier in unique
        if identifier in suites
        or not any(identifier.startswith(f"{suite}/") for suite in suites)
    ]


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=None, help="raw xcodebuild test log")
    parser.add_argument(
        "--xcresult-json",
        type=Path,
        default=None,
        help="JSON from `xcrun xcresulttool get test-results tests --format json`",
    )
    parser.add_argument("--explain", action="store_true", help="report sources on stderr")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if args.log is None and args.xcresult_json is None:
        print("error: pass at least one of --log / --xcresult-json", file=sys.stderr)
        return 2

    from_xcresult = (
        identifiers_from_xcresult_json(args.xcresult_json) if args.xcresult_json else []
    )
    from_log = identifiers_from_log(args.log) if args.log else []
    identifiers = merge_identifiers(from_xcresult + from_log)

    if args.explain:
        print(
            f"xcresult: {len(from_xcresult)} raw, log: {len(from_log)} raw",
            file=sys.stderr,
        )
        for identifier in identifiers:
            print(f"  {identifier}", file=sys.stderr)

    if not identifiers:
        print("no failing test identifiers found", file=sys.stderr)
        return 3

    for identifier in identifiers:
        print(identifier)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
