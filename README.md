<h1 align="center">
  <img src="./Assets.xcassets/AppIcon.appiconset/512.png" alt="cmux" width="120" />
  <br />
  cmux <sub>(xhqing build)</sub>
</h1>

<p align="center">A personal, macOS-only build of <a href="https://github.com/manaflow-ai/cmux">cmux</a> — a Ghostty-based terminal with vertical tabs.</p>

<p align="center">
  <a href="https://github.com/xhqing/cmux/releases/latest"><img src="https://img.shields.io/github/v/release/xhqing/cmux?label=release" alt="Latest release" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-4c71f2" alt="License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple" alt="Platform" />
  <a href="https://github.com/xhqing/cmux/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/xhqing/cmux/build.yml?label=build" alt="Build" /></a>
</p>

<p align="center">
  English | <a href="README_cn.md">简体中文</a>
</p>

---

## What this is

This is my own build of cmux, based on upstream release tag **v0.65.2.2** with a handful of
patches on top. It is **not a fork on GitHub's fork network** — it is a standalone repository,
and its git history was deliberately flattened (see [DEVELOPMENT.md](DEVELOPMENT.md)).

Behaviour differences from the official cmux build:

- **Closing a workspace / tab / window no longer asks for confirmation just because a process
  is running** — `app.confirmCloseRunningProcess` (default off). Unsaved content, pinned
  workspaces and in-progress agent sessions stay protected.
- **Sparkle auto-update is disabled**, and the feed points at this repository, so the official
  build can never silently replace this one.
- The app is ad-hoc signed and lives under its own bundle id
  (`com.cmuxterm.app.staging.xhqing`), so it installs **next to** the official app.

The patch list with the reasoning behind each change is in [PATCHES.md](PATCHES.md).

## Repository layout

Only what the macOS app needs is kept:

| Path | What it is |
| --- | --- |
| `Sources/` | App sources (AppKit / SwiftUI targets) |
| `Packages/macOS/`, `Packages/Shared/` | Local Swift packages the app links against |
| `Packages/iOS/CmuxMobile*` | The six iPhone packages the Xcode project actually depends on |
| `Resources/` | Bundled resources (webviews, localizations, terminfo, …) |
| `CLI/` | `cmux` command-line target |
| `TunnelExtension/`, `Native/`, `vendor/` | System extension, Rust FFI helpers, vendored libs |
| `cmuxTests/`, `cmuxCLITests/`, `cmuxUITests/`, `cmuxCLITestSupport/` | Test targets |
| `scripts/`, `config/`, `schemas/`, `skills/` | Build scripts, config scaffolding, bundled agent skills |
| `ghostty/` | Git submodule: the terminal engine |

Dropped on purpose: `web/` (marketing site), `docs/`, `ios/` (iOS app), `cmux-tui/`,
`webviews/`, `daemon/`, `coderouter/`, `agent-chat/`, `services/`, `workers/` (except one
helper), the 24 translated READMEs and upstream's 145 inherited workflows. Everything left is
GPL-3.0-or-later — the BUSL-licensed server pieces are gone with `web/` and friends.

## Install

Grab the zip from the [latest release](https://github.com/xhqing/cmux/releases/latest):

```bash
unzip cmux-<version>-macos-arm64.zip -d /tmp/cmux-xhqing
xattr -dr com.apple.quarantine "/tmp/cmux-xhqing/cmux STAGING xhqing.app"
cp -R "/tmp/cmux-xhqing/cmux STAGING xhqing.app" /Applications/
```

The build is ad-hoc signed (no notarization), so removing the quarantine attribute is
mandatory — otherwise macOS reports the app as damaged.

## Build

CI first: run the `build-macos` workflow (`workflow_dispatch`, `arch=arm64` by default), or
push a `v*-xhqing.*` tag. Building locally needs Xcode 26 + Zig 0.16.0 + Rust, and takes a
couple of hours of downloads on a slow link — see [DEVELOPMENT.md](DEVELOPMENT.md).

## Documentation

| File | Contents |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Build, install, versioning, workflow, PR gates |
| [PATCHES.md](PATCHES.md) | Every patch on top of upstream, with root-cause notes |
| [SYNC.md](SYNC.md) | How to move to a new upstream release tag |
| [CHANGELOG.md](CHANGELOG.md) | Changelog |
| [TODO.md](TODO.md) | Open work |

## Credits and license

cmux is created by [Manaflow](https://github.com/manaflow-ai/cmux); the terminal engine is a
fork of [Ghostty](https://github.com/ghostty-org/ghostty). All upstream copyright stays with
its authors. This repository only carries the patches listed in [PATCHES.md](PATCHES.md) and a
flattened history; see [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
for the terms (GPL-3.0-or-later, plus third-party notices).
