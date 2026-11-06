# TODO

本仓库的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T9** 删掉残留的旧 fork `xhqing/cmux-upstream-fork-archive`（就是原来那个 1.1 GiB 的 fork，2026-11-02 让位改名后留下的）：当前 gh token 没有 `delete_repo` 权限，需要 `gh auth refresh -h github.com -s delete_repo` 之后 `gh repo delete xhqing/cmux-upstream-fork-archive --yes`，或者直接在网页 Settings → Danger Zone 删除（记录：2026-11-03 07:20）
- [ ] **T10** 把 `cmuxTests` / `cmuxCLITests` 接入 CI（记录：2026-11-03 22:10）
  **背景**：PR 门禁 `checks` 目前做 `swiftc -parse` 语法、SwiftPM 包级 `swift build` / `swift test`（`check-swift-packages.py`，2026-11-06 接入）、配置 schema、输入延迟防护守卫（`check-latency-guardrails.py`）、pbxproj 测试接线、gitleaks 六项；但 **app target 的 `cmuxTests` / `cmuxCLITests` 仍然没有地方执行**——测试文件存在、门禁绿，但没人跑（如 Issue #2 的 `cmuxTests/EmptyWindowStateTests.swift`）。本机与 macmini 都没装完整 Xcode（开发机是 CommandLineTools，`swift test` 缺 `Testing` 模块）；包级单测由带 Xcode 的 CI runner 跑，app target 单测仍需 `xcodebuild test`。这是回归防护网的实质缺口，不只是不便。
  **要做什么**：按 `DEVELOPMENT.md` 第 9.4 节的建议，在 `pr-checks.yml` 增一个 job（或独立 workflow）跑 `xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests`；先实测冷构建 + 测试耗时（Release 构建约 1.5 小时，测试 job 需评估 runner 6 小时时限与是否拆 job），再决定是否设为 required check（新增 required check 要同步改分支保护的 checks 列表，`checks` 这个名字不能动）。
  **边界**：本机 5 Mbps 出口不适合装 Xcode 走本地路线，必须在 CI 跑；首次接入时先只跑 `cmuxTests`（不含 `cmuxCLITests`），确认稳定后再扩。

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
- [ ] **T12** 按实测数字改本地每键路径（记录：2026-11-06 18:46）
  **背景**：P3 只削掉了后台 Git 探测的 CPU 争用；本地「按键 → 字符出现」的每键路径开销还没有数字。上一轮靠读代码猜的 `isAlternateScreenActive()` 视口序列化热点已被证伪（快捷键路径有按事件缓存、文本编辑手势有按按键缓存），不能再凭静态阅读动刀。
  **要做什么**：装自建版跑 `python3 scripts/measure-input-latency.py --surface <id> --samples 40`，拿到 p50 / p99 与读屏基线；再按数字定位每键热点（快捷键判定、`NSWindow.sendEvent` swizzle、焦点修复、通知清除、IME 解释、Ghostty 渲染），只改实测热点。#13 先拉 `ghostty/` 子模块源码定位 URL 检测是否落在每键路径；#11 改两个 shell 集成的加载 / hook 时序并补回归用例。
  **边界**：测量脚本是相对 A/B 工具（改前 / 改后、空闲 / 忙碌、自建版 / 官方版），数字含 CLI / socket / 读屏开销，不能与物理按键录屏的绝对数字直接比较。每步改动走 worktree + 功能分支 + PR，包级单测与 CI 门禁全绿后合并；详见 `LATENCY.md`。
