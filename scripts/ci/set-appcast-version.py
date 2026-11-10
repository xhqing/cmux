#!/usr/bin/env python3
"""Set the human-facing version in a Sparkle appcast to this repository's release version.

Why this exists: `generate_appcast` copies `CFBundleShortVersionString` into the appcast's
`<title>` and `<sparkle:shortVersionString>`. This repository's `CFBundleShortVersionString`
has to stay numeric-only for Apple tooling (`0.65.2.2`), while the release version carries a
`-rN` revision suffix (`0.65.2.2-r18`). Without this rewrite, the in-app update prompt would
say "0.65.2.2 is available" even when the installed build is `0.65.2.2-r16`.

Sparkle compares versions with `<sparkle:version>` (the monotonic `CFBundleVersion`); the
short version string is display-only, so replacing it does not affect update ordering.

Usage:
    set-appcast-version.py <appcast.xml> <display-version>
"""

import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: set-appcast-version.py <appcast.xml> <display-version>", file=sys.stderr)
        return 2

    path, version = sys.argv[1], sys.argv[2]
    if not version:
        print("error: display version must not be empty", file=sys.stderr)
        return 2

    with open(path, encoding="utf-8") as handle:
        xml = handle.read()

    # Only the <item> title carries the update version; the channel-level <title> is the app
    # name and must stay untouched.
    xml, title_count = re.subn(
        r"(<item>\s*)<title>.*?</title>",
        lambda match: f"{match.group(1)}<title>{version}</title>",
        xml,
        count=1,
    )
    xml, short_count = re.subn(
        r"<sparkle:shortVersionString>.*?</sparkle:shortVersionString>",
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>",
        xml,
        count=1,
    )
    if title_count != 1 or short_count != 1:
        print(
            "error: expected exactly one <title> and one <sparkle:shortVersionString> "
            f"in {path} (found {title_count} and {short_count})",
            file=sys.stderr,
        )
        return 1

    with open(path, "w", encoding="utf-8") as handle:
        handle.write(xml)

    print(f"appcast display version set to {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())