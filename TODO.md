# TODO

本分叉的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T1** CI 流水线首次跑通：`build-macos` workflow 在 `macos-26` runner 上完整构建出 Release app 并产出可用 zip（当前只是写好了 workflow，还没实际跑过；要盯的是 Metal 工具链、Zig 构建 cmuxd、以及 ad-hoc 签名这三处）（记录：2026-10-31 22:30）
- [ ] **T2** 自建版并行安装后验证 P1 的真实行为：关掉跑着 pi 的工作区不再弹窗、设置页开关打开后能恢复提示、"Don't ask again" 勾选真的生效（记录：2026-10-31 22:30）

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
