# TODO

本仓库的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T9** 删掉残留的旧 fork `xhqing/cmux-upstream-fork-archive`（就是原来那个 1.1 GiB 的 fork，2026-11-02 让位改名后留下的）：当前 gh token 没有 `delete_repo` 权限，需要 `gh auth refresh -h github.com -s delete_repo` 之后 `gh repo delete xhqing/cmux-upstream-fork-archive --yes`，或者直接在网页 Settings → Danger Zone 删除（记录：2026-11-03 07:20）
- [ ] **T10** 把 `cmuxTests` / `cmuxCLITests` 接入 CI（记录：2026-11-03 22:10）
  **背景**：PR 门禁 `checks` 目前只做 `swiftc -parse` 语法、配置 schema、pbxproj 测试接线、gitleaks 四项，不跑单测；本机与 macmini 都没装 Xcode（开发机是 CommandLineTools），所以新写的回归测试（如 Issue #2 的 `cmuxTests/EmptyWindowStateTests.swift`）实际上没有任何地方执行——测试文件存在、门禁绿，但没人跑。这是回归防护网的实质缺口，不只是不便。
  **要做什么**：按 `DEVELOPMENT.md` 第 9.4 节的建议，在 `pr-checks.yml` 增一个 job（或独立 workflow）跑 `xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests`；先实测冷构建 + 测试耗时（Release 构建约 1.5 小时，测试 job 需评估 runner 6 小时时限与是否拆 job），再决定是否设为 required check（新增 required check 要同步改分支保护的 checks 列表，`checks` 这个名字不能动）。
  **边界**：本机 5 Mbps 出口不适合装 Xcode 走本地路线，必须在 CI 跑；首次接入时先只跑 `cmuxTests`（不含 `cmuxCLITests`），确认稳定后再扩。

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
