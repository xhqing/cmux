# Ghostty Theme Library (bundled)

This directory (`themes/`) holds the Ghostty theme library that cmux bundles
into the app at `Contents/Resources/ghostty/themes` via the `ghostty-themes`
folder reference in `cmux.xcodeproj` (Issue #71). The build pipeline asserts
the bundled copy matches this directory file for file
(`.github/workflows/build.yml` → "校验 bundle 主题库完整").

## Provenance

- The theme files were imported from upstream cmux release tag
  **`v0.65.2.2`** (commit `12023d89`, 2026-10-27), whose
  `Resources/ghostty/themes` contains exactly the same 463 files.
- Upstream cmux added this directory in commit `01a4797a`
  ("Bundle Ghostty themes in cmux", PR #1314, 2026-03-13), calling it the
  "upstream Ghostty theme pack". The pack originates from Ghostty's public
  theme set (Ghostty is MIT-licensed; see `THIRD_PARTY_LICENSES.md`), which in
  turn draws from the community `mbadolato/iTerm2-Color-Schemes` collection
  (MIT).

Do not drift these files from upstream `main`; when a newer upstream cmux tag
is adopted (see `SYNC.md`), re-import `Resources/ghostty/themes` from that tag
and update this note.

## File count

463 theme files, one per theme, named exactly as `theme = <name>` refers to
them (e.g. `GitHub Dark Default`, `Solarized Dark`). Any regular file in
`themes/` is listed as a theme by `cmux themes`, so keep documentation out of
this directory.
