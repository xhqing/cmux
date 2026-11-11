#!/usr/bin/env bash
#
# 校验构建产物的 Info.plist 里没有固化构建机的 home 绝对路径。
#
# 为什么需要它：`scripts/reloads.sh` 曾经用 `$HOME/Library/Application Support/cmux`
# 算出 socket 路径、写进 `LSEnvironment`。这个值在构建期就被烤进产物，CI 上
# `$HOME` 是 `/Users/runner`，于是任何用户装到的 app 都带着一个本机根本不可能
# 存在的路径（xhqing/cmux#46：socket 只能落到 fallback 或直接失败）。
#
# 现在 socket 路径改由 app 在启动时按真实 home 解析，本脚本负责守住这条规则：
# 产物里再出现 `/Users/<某人>`，构建就直接失败，而不是等装到用户机器上才发现。
#
# 用法：
#   ./scripts/check-bundle-home-paths.sh <path/to/cmux.app>
#   ./scripts/check-bundle-home-paths.sh <path/to/Info.plist>
#
# 退出码：0 = 干净；1 = 发现固化路径；2 = 用法错误或文件不存在。
set -euo pipefail

usage() {
  cat <<'EOF'
用法：scripts/check-bundle-home-paths.sh <app 或 Info.plist>

检查 Info.plist 里有没有 `/Users/` 开头的绝对路径（构建机 home 被烤进产物）。
有则打印命中行并以 1 退出；构建脚本应据此判定构建失败。
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

target="$1"
if [[ -d "$target" ]]; then
  plist="${target}/Contents/Info.plist"
elif [[ -f "$target" ]]; then
  plist="$target"
else
  echo "error: 路径不存在：${target}" >&2
  exit 2
fi
if [[ ! -f "$plist" ]]; then
  echo "error: 找不到 Info.plist：${plist}" >&2
  exit 2
fi

# 先把 LSEnvironment 原样打出来：构建日志里能直接看到这次注入了哪些键值，
# 排查「到底是哪一项又把 home 写回去了」时不用再翻产物。
if lsenv="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$plist" 2>/dev/null)"; then
  echo "LSEnvironment（${plist}）："
  printf '%s\n' "$lsenv"
else
  echo "LSEnvironment（${plist}）：未设置"
fi

# 值是原样落在 XML 里的（只有 `<` `>` `&` 会被转义，`/Users/` 不会），
# 所以整份 plist 转成 XML 后按行找就够，不必解析语法树、也不漏任何 key。
xml="$(plutil -convert xml1 -o - "$plist")"
hits="$(printf '%s\n' "$xml" | grep -n --fixed-strings '/Users/' || true)"
if [[ -n "$hits" ]]; then
  echo "error: ${plist} 里固化了构建机的 home 绝对路径（装到别的机器上必然不存在）：" >&2
  printf '%s\n' "$hits" >&2
  echo "提示：socket 等机器相关的值要在运行期解析，不要写进 Info.plist 的 LSEnvironment（见 xhqing/cmux#46）。" >&2
  exit 1
fi

echo "✅ 产物里没有固化进 Info.plist 的 /Users/ 绝对路径"
