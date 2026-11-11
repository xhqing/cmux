#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cmux"
BUNDLE_ID="com.xhqing.cmux"
BASE_APP_NAME="cmux"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
# Matches CmuxStateDirectory (non-TCC ~/.local/state/cmux) where the app/CLI now
# read the last-socket-path markers (https://github.com/manaflow-ai/cmux/issues/5146).
# Resolve the real account home via getpwuid (the same syscall
# homeDirectoryForCurrentUser uses) rather than $HOME, which a shell can override.
# perl ships with macOS and returns the full home path even when it contains spaces;
# `dscl ... | awk` mis-parses such paths because dscl wraps a value with spaces onto
# a second line. `|| true` keeps the lookup from aborting the script under
# `set -euo pipefail`; an empty result falls back to $HOME.
_cmux_account_home="$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null || true)"
LAST_SOCKET_PATH_DIR="${_cmux_account_home:-$HOME}/.local/state/cmux"

write_last_socket_path() {
  local socket_path="$1"
  local marker_name="${BUNDLE_ID}-last-socket-path"
  local tmp_marker="/tmp/cmux-${IDENTITY_SLUG:-xhqing}-last-socket-path"
  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "${LAST_SOCKET_PATH_DIR}/${marker_name}" || true
  echo "$socket_path" > "$tmp_marker" || true
}

identity_slug_from_bundle_id() {
  local bundle_id="$1"
  local suffix=""
  if [[ "$bundle_id" == "com.xhqing.cmux."* ]]; then
    suffix="${bundle_id#com.xhqing.cmux.}"
  fi
  sanitize_path "$suffix"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reloads.sh [options]

Release build with this project's own "cmux" identity (bundle id
com.xhqing.cmux), isolated from the official cmux app.

Options:
  --tag <name>           Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  echo "$cleaned"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ -z "$TAG_SLUG" ]]; then
    echo "error: --tag must contain at least one alphanumeric character" >&2
    exit 1
  fi
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="cmux ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.xhqing.cmux.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="/tmp/cmux-build-${TAG_SLUG}"
  fi
fi

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
# Cap parallel compile jobs. The Release build of this project OOM-kills
# xcodebuild on the 7 GB macos-26 runner at full parallelism, and the kill
# leaves no compiler error in the log (2026-11-06: three Release builds died
# mid-build with no `error:`/`BUILD FAILED` line). Override with CMUX_BUILD_JOBS.
XCODEBUILD_ARGS+=(-jobs "${CMUX_BUILD_JOBS:-2}")
# 架构与版本：CI 通过环境变量传这些构建设置，必须显式翻成 xcodebuild 的构建设置——
# xcodebuild 不读环境变量，只认命令行里的 build settings（2026-11-02 实测两例）：
#   * ARCHS 只写环境变量时，工程仍按 ARCHS_STANDARD 编 arm64 + x86_64 两遍（一轮几小时）；
#   * MARKETING_VERSION 只写环境变量时，Info.plist 里还是工程硬编码的 0.65.2。
for _setting in ARCHS ONLY_ACTIVE_ARCH MARKETING_VERSION CURRENT_PROJECT_VERSION COMPILER_INDEX_STORE_ENABLE; do
  if [[ -n "${!_setting:-}" ]]; then
    XCODEBUILD_ARGS+=("${_setting}=${!_setting}")
  fi
done
unset _setting
# Identity is applied after the build: the product is copied and its Info.plist
# is rewritten below (CFBundleIdentifier, display name, LSEnvironment) and
# re-signed. Never pass PRODUCT_BUNDLE_IDENTIFIER to xcodebuild: it applies to
# every target, so the app, its extensions and the Dock tile plugin would all
# end up with the same bundle id and the embed/sign stage dies without a
# compiler error (2026-11-06: two Release builds failed ~20-27 min in).
XCODEBUILD_ARGS+=(build)

xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Release/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH:-}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
    fi
  fi
fi
if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

# Copy the built app and rewrite its identity: display name, bundle id and the
# identity keys that keep this build's Preferences domain separate from the
# official cmux app. Socket paths are deliberately NOT baked in — see below.
IDENTITY_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
# When APP_NAME already matches the product name (e.g. "cmux"), the identity path
# IS the build product. Copying onto itself would run `rm -rf` on the source of
# the following `cp`, which deleted the freshly built app and failed the step
# with `cp: ... No such file or directory` right after `** BUILD SUCCEEDED **`
# (2026-11-06: builds .5-.9 all failed this way). Rewrite the plist in place.
if [[ "$IDENTITY_APP_PATH" != "$APP_PATH" ]]; then
  rm -rf "$IDENTITY_APP_PATH"
  cp -R "$APP_PATH" "$IDENTITY_APP_PATH"
fi
INFO_PLIST="$IDENTITY_APP_PATH/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"

  # LSEnvironment carries identity only — never a machine-specific path.
  #
  # https://github.com/xhqing/cmux/issues/46: this block used to bake
  # "$HOME/Library/Application Support/cmux/cmux-<slug>.sock" into
  # CMUX_SOCKET_PATH / CMUXD_UNIX_PATH. That value is frozen at build time, and
  # it is the *build* machine's home: on CI $HOME=/Users/runner, so the shipped
  # app carried a path that cannot exist on any user's machine, and even a
  # locally built app could not survive being installed for another account.
  #
  # The app resolves its own default at launch instead — the real account home
  # via FileManager.homeDirectoryForCurrentUser, i.e.
  # ~/.local/state/cmux/cmux.sock (see CmuxStateDirectory) — and this script
  # passes the identity-scoped paths through the launch environment below,
  # where they describe the machine that actually runs the build.
  # Do not put $HOME-derived values back into Info.plist: the check below fails
  # the build when any /Users/ path is baked in.
  IDENTITY_SLUG="$(identity_slug_from_bundle_id "$BUNDLE_ID")"
  APP_SUPPORT_DIR="${_cmux_account_home:-$HOME}/Library/Application Support/cmux"
  SOCKET_SLUG="${IDENTITY_SLUG:-xhqing}"
  CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-${SOCKET_SLUG}.sock"
  CMUX_SOCKET_PATH_VALUE="${APP_SUPPORT_DIR}/cmux-${SOCKET_SLUG}.sock"
  write_last_socket_path "$CMUX_SOCKET_PATH_VALUE"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_BUNDLE_ID \"${BUNDLE_ID}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_BUNDLE_ID string \"${BUNDLE_ID}\"" "$INFO_PLIST"
  # CMUX_ALLOW_SOCKET_OVERRIDE lets this non-staging bundle id honor the
  # CMUX_SOCKET_PATH handed to it at launch (see the `open` call below).
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_ALLOW_SOCKET_OVERRIDE 1" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_ALLOW_SOCKET_OVERRIDE string 1" "$INFO_PLIST"
  # Drop the path keys instead of trusting the build to start from a clean
  # template: an incremental build into a reused derived-data directory does not
  # always regenerate Info.plist, so an older revision's baked paths can survive
  # in the product this script rewrites in place.
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:CMUXD_UNIX_PATH" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:CMUX_SOCKET_PATH" "$INFO_PLIST" 2>/dev/null || true
  # Fail the build if a home path ever gets baked back in (issue #46).
  "$(dirname "${BASH_SOURCE[0]}")/check-bundle-home-paths.sh" "$IDENTITY_APP_PATH"
  if [[ -S "$CMUXD_SOCKET" ]]; then
    for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
      kill "$PID" 2>/dev/null || true
    done
    rm -f "$CMUXD_SOCKET"
  fi
  if [[ -S "$CMUX_SOCKET_PATH_VALUE" ]]; then
    rm -f "$CMUX_SOCKET_PATH_VALUE"
  fi
  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$IDENTITY_APP_PATH" >/dev/null 2>&1 || true
fi
APP_PATH="$IDENTITY_APP_PATH"

# Ensure any running instance is fully terminated, regardless of DerivedData path.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
# Restart any instance launched from this build product. Never touch an
# installed /Applications copy the user may be running.
pkill -f "${IDENTITY_APP_PATH}/Contents/MacOS/${BASE_APP_NAME}" || true
sleep 0.3
CMUXD_SRC="$PWD/cmuxd/zig-out/bin/cmuxd"
if [[ -d "$PWD/cmuxd" ]]; then
  (cd "$PWD/cmuxd" && zig build -Doptimize=ReleaseFast)
fi
if [[ -x "$CMUXD_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$CMUXD_SRC" "$BIN_DIR/cmuxd"
  chmod +x "$BIN_DIR/cmuxd"
fi
# Avoid inheriting cmux/ghostty environment variables from the terminal that
# runs this script (often inside another cmux instance), which can cause
# socket and resource-path conflicts.
OPEN_CLEAN_ENV=(
  env
  -u CMUX_SOCKET_PATH
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_TAG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
)

# The socket paths belong to the machine that launches the app, so they travel
# in this launch environment instead of being baked into Info.plist (see the
# LSEnvironment block above, https://github.com/xhqing/cmux/issues/46). Without
# them the app falls back to its own default, ~/.local/state/cmux/cmux.sock.
"${OPEN_CLEAN_ENV[@]}" CMUX_BUNDLE_ID="$BUNDLE_ID" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH_VALUE" CMUXD_UNIX_PATH="$CMUXD_SOCKET" open -g "$APP_PATH"

# Safety: ensure only one instance is running.
sleep 0.2
PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
if [[ "${#PIDS[@]}" -gt 1 ]]; then
  NEWEST_PID=""
  NEWEST_AGE=999999
  for PID in "${PIDS[@]}"; do
    AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
    if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
      NEWEST_AGE="$AGE"
      NEWEST_PID="$PID"
    fi
  done
  for PID in "${PIDS[@]}"; do
    if [[ "$PID" != "$NEWEST_PID" ]]; then
      kill "$PID" 2>/dev/null || true
    fi
  done
fi
