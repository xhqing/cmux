#!/usr/bin/env bash
#
# 从 GitHub Release 下载并安装 cmux（xhqing 自建版）。
#
# 为什么需要这个脚本：本项目的构建是 ad-hoc 签名，既没有 Developer ID 也没有
# 公证。用浏览器从 Release 页面下载 zip 时，macOS 会给文件打上
# com.apple.quarantine 隔离属性；解压出来的 cmux.app 双击时必然被 Gatekeeper
# 拦下，弹「Apple could not verify "cmux" ...」。本脚本用 curl 下载（curl 不写
# 隔离属性），安装后再补一次 xattr -dr，从源头上避开这个拦截。
#
# 用法见 --help。
set -euo pipefail

REPO="xhqing/cmux"
BUNDLE_ID="com.xhqing.cmux"
DEFAULT_DEST="/Applications"
CACHE_DIR="${HOME}/Library/Caches/cmux/releases"
REPO_API="https://api.github.com/repos/${REPO}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

TAG=""
DEST="$DEFAULT_DEST"
ASSUME_YES=0
LAUNCH=1
SKIP_CHECKSUM=0
TMP_DIR=""

info() { printf '==> %s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }
ok() { printf '✅ %s\n' "$*"; }
die() {
  printf '\n错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：scripts/install-release.sh [选项]

从 xhqing/cmux 的 GitHub Release 下载 cmux.app 并安装。默认安装最新版本，
安装后自动去掉隔离属性并启动。

选项：
  --tag <tag>       指定版本标签（如 v0.65.2.2-r15），不带 v 也可以；
                    默认取最新 Release
  --dest <目录>     安装目录，默认 /Applications
  --yes             跳过「覆盖已安装版本」的交互确认（非交互环境必须加）
  --no-launch       安装完成后不启动 cmux
  --skip-checksum   跳过 sha256 校验（仅限应急；发布资产缺失 .sha256 时用）
  -h, --help        显示本帮助

示例：
  # 安装最新版到 /Applications（会先问是否覆盖旧版本）
  ./scripts/install-release.sh

  # 安装指定版本到临时目录，用于验证，不启动
  ./scripts/install-release.sh --tag v0.65.2.2-r15 \
    --dest /tmp/cmux-install-test --yes --no-launch

说明：
  - 只支持 macOS + Apple Silicon（arm64）。
  - 如果目标位置（例如 /Applications/cmux.app）已经有 cmux 在运行，脚本会
    拒绝替换并提示先退出 cmux——绝不强行替换正在运行的实例。
  - 这份构建是 ad-hoc 签名、没有公证，spctl 评估为 rejected 属预期；脚本只
    校验 codesign 完整性，不把 spctl 的结论当失败条件。
  - 下载缓存放在 ~/Library/Caches/cmux/releases/，缓存里的 zip 校验通过后
    下次直接复用。
EOF
}

# ---------- 参数解析 ----------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || die "--tag 需要一个值（如 v0.65.2.2-r15）"
      TAG="$2"
      shift 2
      ;;
    --dest)
      [ "$#" -ge 2 ] || die "--dest 需要一个目录"
      DEST="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --skip-checksum)
      SKIP_CHECKSUM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（用 --help 查看用法）"
      ;;
  esac
done

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# ---------- 基础检查 ----------

require_commands() {
  local missing="" cmd
  for cmd in curl unzip shasum ditto codesign xattr mktemp pgrep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="${missing} ${cmd}"
    fi
  done
  if [ -n "$missing" ]; then
    die "缺少必需的命令：${missing# }"
  fi
  if [ ! -x /usr/libexec/PlistBuddy ]; then
    die "缺少 /usr/libexec/PlistBuddy（macOS 自带的 plist 工具）"
  fi
}

check_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  if [ "$os" != "Darwin" ]; then
    die "这个脚本只支持 macOS（当前系统：${os}）。"
  fi
  if [ "$arch" != "arm64" ]; then
    die "Release 里只有 Apple Silicon（arm64）构建，当前架构是 ${arch}。"
  fi
}

read_plist() {
  local key="$1" plist="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null
}

# 读已安装 app 的版本：优先 CMUXVersion（带 -rN 的完整发布版本），
# 旧构建没有这个键时退回 CFBundleShortVersionString。
installed_version_of() {
  local app="$1" plist version
  plist="${app}/Contents/Info.plist"
  [ -f "$plist" ] || return 1
  if version="$(read_plist CMUXVersion "$plist")"; then
    :
  elif version="$(read_plist CFBundleShortVersionString "$plist")"; then
    :
  else
    return 1
  fi
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# 找出从指定 app 的 bundle 里启动的进程。
pids_for_app() {
  local app="$1"
  pgrep -f "${app}/Contents/MacOS/cmux" 2>/dev/null || true
}

# ---------- 版本解析 ----------

resolve_latest_tag() {
  local api_tag response tag
  if command -v gh >/dev/null 2>&1; then
    if api_tag="$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null)" \
      && [ -n "$api_tag" ]; then
      printf '%s\n' "$api_tag"
      return 0
    fi
    warn "gh 没能取到最新版本（未安装或未登录），改用 GitHub API。"
  fi

  response="$(curl -fsSL --retry 3 --connect-timeout 15 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: cmux-install-release' \
    "${REPO_API}/releases/latest")" \
    || die "无法获取最新 Release，请检查网络；也可以直接用 --tag 指定版本。"

  tag="$(printf '%s' "$response" | tr -d '\n' \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$tag" ]; then
    die "GitHub API 没有返回 tag_name，可能触发了限流；请稍后重试，或用 --tag 指定版本。"
  fi
  printf '%s\n' "$tag"
}

# ---------- 下载 ----------

curl_download() {
  local url="$1" out="$2"
  shift 2
  if [ -t 2 ]; then
    curl -fL --retry 3 --connect-timeout 15 --progress-bar "$@" -o "$out" "$url"
  else
    curl -fsSL --retry 3 --connect-timeout 15 "$@" -o "$out" "$url"
  fi
}

# 绝大多数网络直接走 releases/download 即可。部分代理 / 网络会让这个地址返回
# 5xx，此时用 GitHub API 的 release asset 接口兜底（同样是 curl 下载）。
api_asset_url() {
  local asset="$1" asset_id
  command -v gh >/dev/null 2>&1 || return 1
  asset_id="$(gh api "repos/${REPO}/releases/tags/${TAG}" \
    --jq ".assets[] | select(.name == \"${asset}\") | .id" 2>/dev/null)" || return 1
  [ -n "$asset_id" ] || return 1
  printf 'https://api.github.com/repos/%s/releases/assets/%s\n' "$REPO" "$asset_id"
}

download_asset() {
  local asset="$1" out="$2" url api_url
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"

  info "下载 ${asset}"
  if curl_download "$url" "$out"; then
    return 0
  fi
  rm -f "$out"

  if api_url="$(api_asset_url "$asset")"; then
    warn "GitHub 的 Release 下载地址不可用，改用 API 资产接口重试。"
    if curl_download "$api_url" "$out" -H 'Accept: application/octet-stream'; then
      return 0
    fi
    rm -f "$out"
  fi
  return 1
}

# ---------- 主流程 ----------

require_commands
check_platform

# 1. 解析并规范化版本号
if [ -z "$TAG" ]; then
  TAG="$(resolve_latest_tag)"
  info "使用最新 Release：${TAG}"
fi
case "$TAG" in
  v[0-9]*) ;;
  [0-9]*) TAG="v${TAG}" ;;
  *) die "版本标签格式不对：${TAG}（应形如 v0.65.2.2-r15）" ;;
esac
case "$TAG" in
  *[[:space:]]*|*/*) die "版本标签不合法：${TAG}" ;;
esac

VERSION="${TAG#v}"
# CFBundleShortVersionString 只保留纯数字段（Apple 的要求），
# 例如 0.65.2.2-r15 对应 0.65.2.2。
BASE_VERSION="${VERSION%%-*}"
ASSET="cmux-${VERSION}-macos-arm64.zip"
CHECKSUM_ASSET="${ASSET}.sha256"

# 2. 规范化安装目录
case "$DEST" in
  /*) ;;
  *) die "--dest 必须是绝对路径（收到：${DEST}）" ;;
esac
DEST="${DEST%/}"
[ -n "$DEST" ] || die "--dest 不能是根目录 /"
TARGET="${DEST}/cmux.app"

# 3. 已是同版本就直接结束（幂等）
EXISTING_VERSION=""
if [ -e "$TARGET" ]; then
  EXISTING_VERSION="$(installed_version_of "$TARGET")" || EXISTING_VERSION=""
  if [ -n "$EXISTING_VERSION" ] && [ "$EXISTING_VERSION" = "$VERSION" ]; then
    ok "已安装的 cmux 就是 ${VERSION}（${TARGET}），已是最新，无需重装。"
    exit 0
  fi
fi

# 4. 运行实例保护：绝不替换正在运行的那一份
if [ -e "$TARGET" ]; then
  RUNNING_PIDS="$(pids_for_app "$TARGET")"
  if [ -n "$RUNNING_PIDS" ]; then
    die "检测到 ${TARGET} 里的 cmux 正在运行（PID：$(printf '%s' "$RUNNING_PIDS" | tr '\n' ' ')）。
请先退出 cmux（在应用里按 Cmd+Q）再安装。
本脚本不会强行替换运行中的实例——那会让正在使用的工作区直接崩溃。"
  fi
fi

# 5. 覆盖安装前确认
if [ -e "$TARGET" ]; then
  info "已安装版本：${EXISTING_VERSION:-未知}（${TARGET}）"
  info "待安装版本：${VERSION}"
  if [ "$ASSUME_YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
      die "目标位置已有其他版本的 cmux，且当前不是交互终端。确认覆盖请加 --yes。"
    fi
    printf '确认覆盖安装到 %s？[y/N] ' "$TARGET" >&2
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) ;;
      *) printf '已取消安装。\n' >&2; exit 1 ;;
    esac
  fi
else
  info "安装目标：${TARGET}（当前没有安装，新装 ${VERSION}）"
fi

# 6. 准备临时目录
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_DIR="$(mktemp -d "${TMP_BASE}/cmux-install.XXXXXX")"

# 7. 校验文件
EXPECTED_HASH=""
if [ "$SKIP_CHECKSUM" -eq 0 ]; then
  CHECKSUM_PATH="${TMP_DIR}/${CHECKSUM_ASSET}"
  download_asset "$CHECKSUM_ASSET" "$CHECKSUM_PATH" \
    || die "下载校验文件 ${CHECKSUM_ASSET} 失败。
这说明该 Release 缺少 .sha256 资产或网络不通。确认资产存在后重试；
应急情况下可以加 --skip-checksum，但不推荐。"

  CHECKSUM_LINE="$(tr -d '\r' < "$CHECKSUM_PATH" | sed -n '1p')"
  EXPECTED_HASH="$(printf '%s\n' "$CHECKSUM_LINE" | awk '{print $1}')"
  CHECKSUM_NAME="$(printf '%s\n' "$CHECKSUM_LINE" | awk '{print $2}')"
  case "$EXPECTED_HASH" in
    ''|*[!0-9a-fA-F]*) die "校验文件格式不对：${CHECKSUM_PATH}" ;;
  esac
  [ "${#EXPECTED_HASH}" -eq 64 ] \
    || die "校验文件里的 sha256 长度不对：${CHECKSUM_PATH}"
  EXPECTED_HASH="$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')"
  if [ -n "$CHECKSUM_NAME" ] && [ "$CHECKSUM_NAME" != "$ASSET" ]; then
    die "校验文件对应的是 ${CHECKSUM_NAME}，与要下载的 ${ASSET} 不一致。"
  fi
else
  warn "已按 --skip-checksum 跳过 sha256 校验（仅限应急）。"
fi

# 8. 下载 zip（缓存命中且校验一致就复用）
ZIP_PATH="${CACHE_DIR}/${ASSET}"
NEED_DOWNLOAD=1
if [ -f "$ZIP_PATH" ]; then
  if [ "$SKIP_CHECKSUM" -eq 1 ]; then
    info "缓存里已有 ${ASSET}（本次跳过校验），直接复用。"
    NEED_DOWNLOAD=0
  else
    CACHED_HASH="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
    if [ "$CACHED_HASH" = "$EXPECTED_HASH" ]; then
      info "缓存里的 ${ASSET} 校验通过，跳过下载。"
      NEED_DOWNLOAD=0
    else
      warn "缓存里的 zip 与 .sha256 不一致，重新下载。"
    fi
  fi
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
  mkdir -p "$CACHE_DIR"
  rm -f "${ZIP_PATH}.part"
  download_asset "$ASSET" "${ZIP_PATH}.part" \
    || die "下载 ${ASSET} 失败。
请检查网络后重试；如果一直失败，可以到
https://github.com/${REPO}/releases/tag/${TAG}
手动下载后用 README 里的手工步骤安装（记得 xattr -dr com.apple.quarantine）。"
  mv "${ZIP_PATH}.part" "$ZIP_PATH"
fi

if [ "$SKIP_CHECKSUM" -eq 0 ]; then
  ACTUAL_HASH="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
  if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
    die "sha256 校验失败：期望 ${EXPECTED_HASH}，实际 ${ACTUAL_HASH}。
zip 可能下载不完整或被篡改。可删掉 ${ZIP_PATH} 后重试。"
  fi
  ok "sha256 校验通过。"
fi

# 9. 解压并校验新 bundle
UNPACK_DIR="${TMP_DIR}/unpack"
mkdir -p "$UNPACK_DIR"
unzip -q "$ZIP_PATH" -d "$UNPACK_DIR" \
  || die "解压失败：${ZIP_PATH} 可能已损坏。删掉它后重试。"

NEW_APP="${UNPACK_DIR}/cmux.app"
[ -d "$NEW_APP" ] || die "压缩包里没有找到 cmux.app，资产结构可能不对：${ZIP_PATH}"
NEW_PLIST="${NEW_APP}/Contents/Info.plist"
[ -f "$NEW_PLIST" ] || die "安装包结构不对：缺少 ${NEW_PLIST}"

NEW_BUNDLE_ID="$(read_plist CFBundleIdentifier "$NEW_PLIST")" \
  || die "读不到 CFBundleIdentifier：${NEW_PLIST}"
[ "$NEW_BUNDLE_ID" = "$BUNDLE_ID" ] \
  || die "bundle id 不匹配：期望 ${BUNDLE_ID}，实际 ${NEW_BUNDLE_ID}。
这可能是官方 cmux 的安装包，不是本仓库的构建。"

NEW_SHORT_VERSION="$(read_plist CFBundleShortVersionString "$NEW_PLIST")" \
  || die "读不到 CFBundleShortVersionString：${NEW_PLIST}"
[ "$NEW_SHORT_VERSION" = "$BASE_VERSION" ] \
  || die "版本不匹配：期望 ${BASE_VERSION}，实际 ${NEW_SHORT_VERSION}。
下载到的资产可能不是 ${TAG} 对应的构建。"

if NEW_FULL_VERSION="$(read_plist CMUXVersion "$NEW_PLIST")"; then
  [ "$NEW_FULL_VERSION" = "$VERSION" ] \
    || die "完整版本号不匹配：期望 ${VERSION}，实际 ${NEW_FULL_VERSION}。"
fi

# 老构建（xhqing/cmux#46 修复之前）把构建机的 home 路径写进了 LSEnvironment，
# 装到本机后那些路径必然不存在，socket 只能落到 fallback 或直接失败。修复后的
# 产物不再注入这类路径，所以这里只提醒、不阻断——重装旧版本本身是合理需求。
if plutil -convert xml1 -o - "$NEW_PLIST" | grep -q --fixed-strings '/Users/'; then
  warn "这个安装包的 Info.plist 里固化了构建机的 home 路径（/Users/...），
是 xhqing/cmux#46 修复之前的构建：那些路径在你的机器上不存在，控制 socket
可能起不来或只能落到 fallback 路径（CLI 可用 --socket 手动指定）。
建议换成包含该修复的新版本。这里只提醒、不阻断安装。"
fi

if ! codesign --verify --deep --strict "$NEW_APP"; then
  die "代码签名校验失败：${NEW_APP}。
安装包可能不完整，请删掉 ${ZIP_PATH} 后重新下载。"
fi

if spctl --assess --type execute "$NEW_APP" >/dev/null 2>&1; then
  info "spctl 评估：accepted"
else
  info "spctl 评估：rejected（ad-hoc 签名、无公证，属预期，不影响安装）"
fi

# 10. 安装：先拷到同目录下的暂存路径，再原子替换
mkdir -p "$DEST"
[ -w "$DEST" ] || die "没有写入权限：${DEST}
请用管理员账号运行，或用 --dest 指定一个可写目录。"

STAGING="${DEST}/.cmux.app.new"
BACKUP="${DEST}/.cmux.app.old"

# 上次中断留下的暂存目录直接清掉；旧版本备份要么恢复、要么清掉。
rm -rf "$STAGING"
if [ -e "$BACKUP" ]; then
  if [ ! -e "$TARGET" ]; then
    warn "发现上次安装中断留下的旧版本，正在恢复。"
    mv "$BACKUP" "$TARGET"
  else
    rm -rf "$BACKUP"
  fi
fi

info "拷贝新版本到 ${STAGING}"
# --noqtn：连隔离属性都不拷，避免把 zip / 解压文件的隔离状态带进安装目录。
ditto --noqtn "$NEW_APP" "$STAGING" \
  || die "拷贝失败：${NEW_APP} -> ${STAGING}。磁盘空间可能不足。"

HAD_OLD=0
if [ -e "$TARGET" ]; then
  HAD_OLD=1
  mv "$TARGET" "$BACKUP" \
    || die "无法移动旧版本 ${TARGET}（是否有进程占用？）。未做任何改动。"
fi

if ! mv "$STAGING" "$TARGET"; then
  if [ "$HAD_OLD" -eq 1 ] && [ -e "$BACKUP" ] && [ ! -e "$TARGET" ]; then
    mv "$BACKUP" "$TARGET" || true
  fi
  die "安装失败：无法把新版本移动到 ${TARGET}（旧版本已尽力回滚）。"
fi

# 11. 安装后复核：去隔离、验签名；失败就回滚
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
if ! codesign --verify --deep --strict "$TARGET"; then
  warn "安装后的签名校验失败，正在回滚。"
  rm -rf "$TARGET"
  if [ "$HAD_OLD" -eq 1 ] && [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$TARGET" || true
  fi
  die "安装后的 codesign 校验没有通过，已回滚。请删掉 ${ZIP_PATH} 后重新下载。"
fi

# 成功后才删除旧版本备份——不在 /Applications 里长期留备用 app 副本
if [ "$HAD_OLD" -eq 1 ] && [ -e "$BACKUP" ]; then
  rm -rf "$BACKUP"
fi

INSTALLED_VERSION="$(installed_version_of "$TARGET")" || INSTALLED_VERSION="$VERSION"

# 只有装到 /Applications 才注册 LaunchServices，测试目录不污染系统数据库
if [ "$DEST" = "/Applications" ]; then
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 \
      || warn "注册 LaunchServices 失败（不影响使用）。"
  fi
fi

ok "安装完成：${TARGET}"
ok "已装版本：${INSTALLED_VERSION}"

if [ "$LAUNCH" -eq 1 ]; then
  OTHER_PIDS="$(pgrep -f 'cmux.app/Contents/MacOS/cmux' 2>/dev/null || true)"
  if [ -n "$OTHER_PIDS" ]; then
    warn "还有别的 cmux 实例在运行（PID：$(printf '%s' "$OTHER_PIDS" | tr '\n' ' ')）。
如果装到的不是默认位置，open 可能只是激活已在运行的那个实例。"
  fi
  info "启动 cmux"
  open "$TARGET" \
    || die "启动失败，请手动打开：${TARGET}"
fi

exit 0
