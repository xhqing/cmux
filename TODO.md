# TODO

本分叉的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T2** 自建版并行安装后验证 P1 的真实行为：关掉跑着 pi 的工作区不再弹窗、设置页开关打开后能恢复提示、"Don't ask again" 勾选真的生效（记录：2026-10-31 22:30）

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T6** CI 注入 `MARKETING_VERSION=0.65.2.2`：当前 app 内 `CFBundleShortVersionString` 还是上游的 `0.65.2`（工程里 12 处硬编码），与 VERSION 的 `0.65.2.2-xhqing.1` 不一致；后缀不进 CFBundleShortVersionString（Apple 要求纯数字段），只保留在 VERSION / tag / Release / 产物名（记录：2026-11-01 02:40）
- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
