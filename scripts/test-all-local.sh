#!/usr/bin/env bash
#
# 本机全量测试：不做任何跳过。
#
# 为什么需要它：CI（.github/workflows/unit-tests.yml）在 headless runner 上跳过了一批
# 依赖窗口服务器 / 键盘事件 / 登录账号与 Cloud、模拟器环境的用例——它们在 runner 上
# 稳定失败，红了不代表代码坏了（见 DEVELOPMENT.md 第 9.4 节与 Issue #98）。那些分组
# 必须在本机（有真实 GUI 会话）照常跑，所以提供这个入口。
#
# 用法：./scripts/test-all-local.sh [额外 xcodebuild 参数...]
set -euo pipefail
cd "$(dirname "$0")/.."

echo "本机全量测试（不跳过任何分组）。CI 跳过的分组清单见 .github/workflows/unit-tests.yml"
xcodebuild test \
  -project cmux.xcodeproj \
  -scheme cmux-unit \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/cmux-build \
  -only-testing:cmuxTests \
  "$@"
