# TODO

本仓库的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T7** 在新仓库里把 Actions 与 required check 跑通：旧 fork 仓库曾出现「`gh workflow run` 报 `HTTP 422: Actions has been disabled for this repository`、push / pull_request 都不出 run，而 `gh api .../actions/permissions` 却显示 `enabled: true`」。2026-11-02 重建为独立仓库后该状态清零，需按 `DEVELOPMENT.md` 第九节第 6 小节：确认 `build-macos` / `PR checks` 可见 → 开真实 PR 验 `checks` 能绿 → 才把 required status check `checks`（strict）加进 main 保护 → 复验「PR → checks 绿 → auto-merge」整条链路（记录：2026-11-02 18:10）
- [ ] **T8** 新仓库首次 CI 构建复验：重建时剥离了 `web/`、`docs/`、`ios/`、`cmux-tui/`、`webviews/`、`daemon/` 等目录（只保留 macOS 构建闭包 + Xcode 工程依赖的 6 个 iPhone 包），需要实跑一次 `build-macos`（arm64）确认编译链没被剥离打断；顺带把 README 里 Release 徽章的首个产物补上（记录：2026-11-02 18:10）
- [ ] **T2** 自建版并行安装后验证 P1 的真实行为：关掉跑着 pi 的工作区不再弹窗、设置页开关打开后能恢复提示、"Don't ask again" 勾选真的生效（记录：2026-10-31 22:30）

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
