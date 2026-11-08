#!/usr/bin/env python3
"""Type-check (and, on CI, test) the SwiftPM packages touched by a change.

`pr-checks.yml` parses changed Swift files with `swiftc -parse`. That catches
syntax errors and truncated files, but a package-level change can still break
type checking and merge green. The app target is compiled by `build-macos`;
the standalone packages under `Packages/` can be built and tested on their own,
so this guard closes that gap.

Local note: the macOS CommandLineTools toolchain has no `Testing` module, so
`swift test` only works where a full Xcode is installed (the macos-26 CI
runner). Use `--build-only` on a local CommandLineTools machine.

Usage:
    python3 scripts/check-swift-packages.py [options]

Options:
    --changed-file PATH   File with one changed repo-relative path per line
                          (CI writes this in the "Collect changed files" step).
                          Defaults to `git diff --name-only HEAD^ HEAD`.
    --package PATH        Check this package explicitly (repeatable).
    --build-only          Only run `swift build`, skip `swift test`.
    --max-packages N      Cap how many packages one run checks (default 4).
                          A bulk upstream sync can touch dozens; the rest are
                          covered by build-macos.
    --timeout SECONDS     Per-command timeout (default 900).

Exit codes:
    0  all touched packages pass (or none touched)
    1  a build or test failed
    2  invocation error
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_PREFIXES = ("ghostty/", "vendor/")


def changed_paths(explicit_file: Path | None) -> list[str]:
    if explicit_file:
        if not explicit_file.is_file():
            raise ValueError(f"changed file does not exist: {explicit_file}")
        return explicit_file.read_text(encoding="utf-8", errors="replace").splitlines()
    result = subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--name-only", "HEAD^", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"git diff failed: {result.stderr.strip()}")
    return result.stdout.splitlines()


def package_for(path: str) -> Path | None:
    """Nearest ancestor directory containing Package.swift, if under Packages/."""
    if not path.endswith(".swift") or not path.startswith("Packages/"):
        return None
    if path.startswith(EXCLUDED_PREFIXES):
        return None
    candidate = (ROOT / path).parent
    while candidate != ROOT and candidate != candidate.parent:
        if (candidate / "Package.swift").is_file():
            return candidate
        if candidate == ROOT / "Packages":
            break
        candidate = candidate.parent
    return None


def has_tests(package: Path) -> bool:
    return any((package / "Tests").rglob("*.swift")) if (package / "Tests").is_dir() else False


def run(command: list[str], timeout: int) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        return False, (
            "STDOUT full:\n" + result.stdout
            + "\nSTDERR tail:\n" + "\n".join(result.stderr.splitlines()[-200:])
        )
    return True, "\n".join(output.splitlines()[-3:])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-file", type=Path)
    parser.add_argument("--package", type=Path, action="append", default=[])
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--max-packages", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args(argv)

    if args.max_packages < 1:
        print("error: --max-packages must be at least 1", file=sys.stderr)
        return 2

    try:
        paths = changed_paths(args.changed_file)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    packages: set[Path] = {package.resolve() for package in args.package}
    for path in paths:
        package = package_for(path.strip())
        if package:
            packages.add(package.resolve())

    ordered = sorted(packages)
    if not ordered:
        print("no SwiftPM packages touched; skipping package type check")
        return 0
    if len(ordered) > args.max_packages:
        print(
            f"{len(ordered)} packages touched; checking the first "
            f"{args.max_packages} (build-macos covers the rest)"
        )
        ordered = ordered[: args.max_packages]

    failures = 0
    for package in ordered:
        relative = package.relative_to(ROOT)
        print(f"== {relative} ==")
        ok, detail = run(["swift", "build", "--package-path", str(package)], args.timeout)
        print(f"  {'PASS' if ok else 'FAIL'}  swift build")
        if not ok:
            failures += 1
            print(detail)
            continue
        if args.build_only or not has_tests(package):
            if not has_tests(package):
                print("  SKIP  swift test (no test target)")
            continue
        ok, detail = run(["swift", "test", "--package-path", str(package)], args.timeout)
        print(f"  {'PASS' if ok else 'FAIL'}  swift test")
        if not ok:
            failures += 1
            print(detail)

    if failures:
        print(f"\n{failures} package(s) failed", file=sys.stderr)
        return 1
    print(f"\nall {len(ordered)} touched package(s) pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
