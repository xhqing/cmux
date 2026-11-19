#!/usr/bin/env bash
# Resolve the code-signing identity shared by the two build entry points:
# scripts/reload.sh (dev / Debug build) and scripts/reloads.sh (Release build,
# also used by CI's build.yml).
#
# 为什么要有这个脚本（Issue #121）：
#   ad-hoc 签名（`codesign --sign -`）没有证书，TCC 记下的 designated
#   requirement 是本次构建的 cdhash；每重新构建一次 cdhash 就变一次，系统于是
#   把屏幕录制等授权当成「另一个 App」而作废。换成固定证书后 requirement 变成
#   `identifier "com.xhqing.cmux" and certificate leaf = H"<证书哈希>"`，证书不
#   变 → 重建后授权继续有效。
#
# 约定（`CMUX_DEV_SIGN_IDENTITY`）：
#   * 未设置 / 空 / 全空白 → 输出 `-`（ad-hoc），保持所有既有环境与 CI 的行为不变；
#   * 显式设为 `-` → 输出 `-`，明确要求 ad-hoc 时照办；
#   * 其他值 → 必须能在本机钥匙串里找到同名（或以该 SHA-1 为前缀的）代码签名
#     身份，找到就输出该身份名；**找不到一律非零退出、stdout 为空**。
#
# 为什么不允许静默回退 ad-hoc：静默回退等于把 #121 的 bug 悄悄带回来——构建照
# 样成功、签名照样「有效」，只是用户要等到下一次系统提示「屏幕录制权限又失效
# 了」才发现。身份配错是配置问题，应当在构建开始前就大声失败。
set -euo pipefail

env_var="CMUX_DEV_SIGN_IDENTITY"
requested="${!env_var:-}"

# 去掉首尾空白（含制表符 / 全空白输入）：`CMUX_DEV_SIGN_IDENTITY="  "` 按未设置处理。
requested="${requested#"${requested%%[![:space:]]*}"}"
requested="${requested%"${requested##*[![:space:]]}"}"

note_adhoc() {
  printf "note: 本次构建使用 ad-hoc 签名（没有证书）：TCC 授权（屏幕录制、辅助功能等）认的是本次构建的 cdhash，每次重新构建都会失效。把 %s 设成一个固定的代码签名身份即可保持授权；步骤见 DEVELOPMENT.md「十、代码签名身份与 TCC 授权」。\n" \
    "$env_var" >&2
}

if [[ -z "$requested" || "$requested" == "-" ]]; then
  note_adhoc
  printf '%s\n' "-"
  exit 0
fi

# 非 ad-hoc：必须在钥匙串里真的存在，否则失败。
identities=""
if command -v security >/dev/null 2>&1; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
fi

# `security find-identity -v` 的行格式：`  1) <40 位 SHA-1> "身份名"`。
# 身份名里可能有空格、括号、冒号，所以按「引号前是 40 位十六进制」定位。
identities_tsv="$(
  printf '%s\n' "$identities" \
    | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"$/\1\t\2/p'
)"

requested_hash=""
if [[ "$requested" =~ ^[0-9A-Fa-f]{8,40}$ ]]; then
  requested_hash="$(printf '%s' "$requested" | tr '[:lower:]' '[:upper:]')"
fi

resolved=""
while IFS=$'\t' read -r hash name; do
  [[ -n "$hash" ]] || continue
  if [[ "$name" == "$requested" ]]; then
    resolved="$name"
    break
  fi
  # 也接受 SHA-1 前缀（`security find-identity -v` 里 40 位十六进制那一列）。
  # 不用 `${hash^^}`：macOS 自带的 /bin/bash 是 3.2，没有大小写转换的展开语法。
  if [[ -n "$requested_hash" && "$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')" == "$requested_hash"* ]]; then
    resolved="$name"
    break
  fi
done <<< "$identities_tsv"

if [[ -z "$resolved" ]]; then
  {
    printf 'error: 找不到代码签名身份 "%s"（环境变量 %s 指定的）。\n' "$requested" "$env_var"
    printf '本机可用的代码签名身份（security find-identity -v -p codesigning）：\n'
    if [[ -n "$identities_tsv" ]]; then
      printf '%s\n' "$identities_tsv" | while IFS=$'\t' read -r hash name; do
        printf '  - %s\n' "$name"
      done
    else
      printf '  （一个都没有；先按 DEVELOPMENT.md 第十节生成并信任证书）\n'
    fi
    printf '这里不会静默回退 ad-hoc：ad-hoc 签名会让 TCC 授权在每次重新构建后失效（Issue #121）。\n'
  } >&2
  exit 1
fi

# 单行输出，供 `codesign --sign "$(...)"` 直接使用。
printf '%s\n' "$(printf '%s' "$resolved" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
