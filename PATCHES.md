# 补丁清单（xhqing 自建分叉）

本仓库的规则是：**基线 = 上游 release tag 的原始代码，我们的改动全部是叠加在基线之上的小补丁**，一个语义一个提交，便于跟着上游新 tag rebase。

当前基线 tag：`v0.65.2.2`（上游 commit `12023d89feb5425c766ba05e8d8e4cfc176e3991`）

> **本地历史形态（2026-11-02 起）**：本仓库为脱离 fork network 重建，`main` 的根提交是本地的**压平基线** `ef4b8cf4538a645164e6fed7d3e149c597215ba4`——它的树 = 上游 `v0.65.2.2` 的树**去掉 web / docs / ios（除 6 个依赖包）/ cmux-tui / webviews / daemon 等非 macOS 构建内容**后的结果。上游原本那 20,328 个提交的历史不在本地仓库里，需要时按 `SYNC.md` 浅拉上游 tag。补丁清单本身不受影响：下面每条补丁都仍然以「相对上游代码的改动」来描述。

---

## P1 — 关闭工作区/标签页/窗口时，不再因为「有进程在跑」弹确认

**状态**：已实现（自建版 `0.65.2.2-xhqing.1`）

### 要解决的问题

用户每次关掉一个跑着 pi 的工作区，都会弹 "Close workspace?"，勾了 "Don't ask again" 也照样弹。

### 根因（读 v0.65.2.2 代码确认，不是推测）

1. `Sources/TabManager.swift` 的 `closeWorkspaceIfRunningProcess()`：

   ```swift
   let showsCloseConfirmation = requiresConfirmation
       && (needsCloseConfirmation || shouldConfirmWorkspaceClose(...))
   ```

   只要 `needsCloseConfirmation`（有进程在跑）为真，就**无条件弹框**，用户设置被完全绕过。

2. `Packages/macOS/CmuxSettings/.../CloseTabWarningReading.swift` 里 `.safety` 这一档被定义为「An active foreground process requires a warning regardless of settings」（源码注释原文），并且：

   - `shouldConfirmCloseIncludingSafety()` 里 `(!isAgentSession && requiresConfirmation) || ...` —— 进程这一档不读任何设置键；
   - `TabManager.swift` 的 `CloseDontAskAgainCheckbox.apply()` 用 `kinds.subtracting(.safety)` 把 `.safety` 从可勾选集合里摘掉——**勾选框只能关掉 `warnBeforeClosingWorkspace`，关不掉 `.safety`**，所以勾了继续弹。

3. 旁证：用户机器上 `defaults read com.cmuxterm.app` 里 `warnBeforeClosingWorkspace` 早就是 `0`，但仍在弹。

上游的处理方向是「保留进程保护、只修勾选框骗人」（PR #20517 / #20520），不满足我们的诉求，所以自建分叉里改语义。

### 改法（最小收敛点）

新增设置键 `app.confirmCloseRunningProcess`（**默认 false**），把「有进程在跑」从不可抑制的硬保护改成**可配置、默认关闭**的一档。

| 文件 | 改动 |
| --- | --- |
| `Sources/Workspace.swift` | 新增 `confirmsRunningProcessOnClose` 计算属性（读新设置键）；`panelNeedsConfirmClose(panelId:fallbackNeedsConfirmClose:)` 开头 `guard confirmsRunningProcessOnClose else { return false }`；`panelNeedsConfirmClose(panelId:)` 的 remote-tmux mirror 分支也乘上这个开关。**非终端面板仍然返回 `panel.isDirty`（未保存内容照常保护，不受开关影响）** |
| `Packages/macOS/CmuxSettings/.../CloseTabWarningReading.swift` | 协议新增 `warnsBeforeClosingRunningProcess`，协议扩展里给默认实现 `true`（让测试替身保持旧行为，不破坏既有单测） |
| `Packages/macOS/CmuxSettings/.../CloseTabWarningStore.swift` | 用新键实现上面的属性；`disableWarnings(_:)` 里遇到 `.safety` 时把新键置 `false`（**让 "Don't ask again" 真正生效**） |
| `Packages/macOS/CmuxSettings/.../AppCatalogSection.swift` | 新增目录键 `confirmCloseRunningProcess`（`defaultValue: false`，带 `userFacing` 描述符，进设置页与命令面板） |
| `Packages/macOS/CmuxSettingsUI/.../Sections/AppSection.swift` | 设置页 App 区新增一行开关「Confirm Before Closing Running Processes」，含开/关两种副标题文案 |
| `Sources/SettingsSearchIndex.swift` | 注册搜索项（`confirmation` / `running process` 等关键词） |
| `Sources/CmuxSettingsJSONPathSupport.swift` | 注册 JSON 配置键映射 |
| `Sources/CmuxSettingsFileStore+SupportedPaths.swift` | 注册支持的配置路径 |
| `Resources/Info.plist` | Sparkle：`SUEnableAutomaticChecks` → `false`、`SUFeedURL` → 本仓库地址（见 DEVELOPMENT.md 第三节） |

### 为什么改在 `Workspace.panelNeedsConfirmClose` 这一处

`rg panelNeedsConfirmClose` 过了一遍调用点，四条关闭路径全部汇到这个函数：

- 工作区关闭：`TabManager.closeWorkspaceIfRunningProcess` → `workspaceNeedsConfirmClose` → `Workspace.needsConfirmClose()` → `panelNeedsConfirmClose(panelId:)`
- 标签页关闭（Cmd+W）：`TabManager.closePanelWithConfirmation` / `Workspace.closeCurrentPanelWithConfirmation`
- 运行时 surface 关闭（Ghostty 发起）：`TabManager.closeRuntimeSurfaceWithConfirmation` → `panelNeedsConfirmClose(panelId:fallbackNeedsConfirmClose:)`
- 批量关闭 / 窗口关闭：`WorkspaceCloseTabsBatching`、`TabManager.shouldConfirmWindowClose`

另有两个 CLI/控制面入口（`TerminalController+ControlSurfaceContext2/3`）同样走这个函数，`force: true` 的场景本来就不弹。

### 保留的保护（没被削弱）

- **未保存内容**：非终端面板走 `panel.isDirty`，无条件弹；
- **pinned 工作区**：`confirmPinnedWorkspaceClose` 独立路径，不受影响；
- **agent 会话进行中（mid-turn）**：`warnBeforeClosingAgentSession` 独立开关，默认仍为 `true`；
- **X 按钮警告**：`warnBeforeClosingTabXButton` 独立开关，不受影响；
- **批量关闭提示**：`warnBeforeClosingWorkspace` / `warnBeforeClosingWindow` 仍在工作；
- 想恢复上游那种「有进程就拦」的行为：设置页把「Confirm Before Closing Running Processes」打开，或 `defaults write com.cmuxterm.app confirmCloseRunningProcess -bool true`。

### 已知未覆盖 / 已知风险

- **Dock（侧边 Dock 里的标签）**：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 是另一条独立判断，本次没接开关（那块面板里几乎不跑长期进程，优先级低）。如果实际用起来还会弹，再补一个同样的门控。
- **「Don't ask again」的语义边界**：勾选会关掉 `confirmCloseRunningProcess` 与对应对话框的警告键。因为该键默认已经关闭，只有用户主动打开保护后这两个才可能同时存在。
- **上游 rebase 冲突点**：`Workspace.swift` 的 `panelNeedsConfirmClose` 系列、`CloseTabWarningReading/Store`、`AppCatalogSection`、`AppSection`。上游若合并 PR #20215（同样在动这块），rebase 时要人工过一眼，别把两套语义叠在一起。

---

## P2 — 关闭最后一个标签页 / 工作区后保留空窗口，而不是退出应用

**状态**：已实现（Issue #2）

### 要解决的问题

窗口里只剩一个 workspace、其中只有一个标签页时，点标签页的 X（或按 Cmd+W、中键关闭这个标签页），会弹确认；确认后整个 cmux 窗口关闭、应用退出。期望：关闭最后一个标签页后 workspace 一并移除，但窗口保留、进入空状态（没有任何 workspace、没有任何标签页）；启动时若没有可恢复的会话，同样是空窗口；只有窗口级动作（红点 / Close Window / Cmd+Q）才退出应用。

### 根因（读代码确认）

1. `TabManager.closeWorkspace` 开头 `guard tabs.count > 1 else { return }`——最后一个 workspace 不允许被移除。
2. 关闭最后一个 workspace 的三条路径都走「关窗口」：
   - `closeWorkspaceIfRunningProcess`：`tabs.count <= 1` → `closeWindowForLastWorkspace`；
   - `closeWorkspacesWithConfirmation`：批量关全部 → `closeWindowForLastWorkspace`；
   - `closePanelAfterChildExited`：最后一个 panel 子进程退出且 `tabs.count <= 1` → `AppDelegate.closeMainWindowContainingTabId`。
3. 窗口关闭后，`handleMainTerminalWindowShouldClose` 认定这是最后一个主窗口 → `requestApplicationTermination()`，于是应用退出。
4. `restoreSessionSnapshot` 在 `newTabs.isEmpty` 时无条件造一个 `Terminal 1` fallback——空快照无法恢复成空窗口。
5. `ContentView` 的启动恢复（#399）在 onAppear 0.5s 后调 `recoverEmptyWorkspaceAfterStartupIfNeeded()`，会把空窗口补满。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Sources/TabManager.swift` | `closeWorkspace` 允许关闭最后一个 workspace；关闭后若 `tabs` 为空置 `hasEmptiedAllWorkspaces`，并把 `selectedTabId` 置 nil（`selectionTargetAfterClose` 返回 nil）。 |
| 同上 | 删除 `closeWindowForLastWorkspace`；`closeWorkspaceIfRunningProcess` 对最后一个 workspace 改为直接 `closeWorkspace`（`acceptCmdD` 改 false，仍保留窗口 Dock 的进程确认）。 |
| 同上 | `closeWorkspacesWithConfirmation`：批量关全部不再走窗口关闭；文案统一为「Close workspaces?」，警告改用 workspace 策略（`dontAskAgain = .workspace`）。 |
| 同上 | `closePanelAfterChildExited`：最后一个 workspace 的最后一个 panel 退出 → `closeWorkspace`（不再调 `closeMainWindowContainingTabId`）。 |
| 同上 | 新增 `closeWorkspaceAfterLastTabClose(_:source:)`：供标签页 X / Cmd+W / 中键关闭最后一个标签页时调用——不弹 workspace 级（`warnBeforeClosingWorkspace`）确认，但完整跑一遍标签页级警告策略（未保存内容、agent mid-turn、X 按钮警告、`confirmCloseRunningProcess` 设置、workspace 与窗口 Dock 的进程保护），并保留 pinned 确认。 |
| 同上 | `recoverEmptyWorkspaceAfterStartupIfNeeded` 增加 `!hasEmptiedAllWorkspaces` 守卫：用户主动清空的窗口不会在启动恢复时被补满；`workspaceTabsWillChange` 在 tabs 非空时清除该标志。 |
| 同上 | `restoreSessionSnapshot`：`newTabs.isEmpty` 时只有「快照本来有 workspace 但全部恢复失败」才造 fallback；快照明确为空则保持空窗口。恢复时清除 `hasEmptiedAllWorkspaces`。 |
| `Sources/Workspace.swift` | `BonsplitDelegate` 的「关闭最后一个 surface → 关闭 workspace」分支改为调用 `closeWorkspaceAfterLastTabClose`（标签页 X / Cmd+W / 中键统一走它）。 |
| `Sources/AppDelegate.swift` | 创建主窗口时 `createInitialWorkspace` 只在「无会话快照**且**显式带了工作目录 / 终端输入 / 标题」时为 true：普通启动与 New Window 默认是空窗口（Issue #2），`cmux <目录>` 这类显式用法照常创建 workspace。 |

### 保留的保护（没被削弱）

- 侧栏 workspace 的 X / Close Workspace：仍走原有 workspace 关闭确认（`warnBeforeClosingWorkspace`），只是关闭后窗口不退出；
- 标签页 X / Cmd+W / 中键关最后一个标签页：保留完整的标签页级保护——未保存内容（`panel.isDirty`）、agent mid-turn（`warnBeforeClosingAgentSession`）、X 按钮警告（`warnBeforeClosingTabXButton`）、`confirmCloseRunningProcess` 开启时的进程确认、pinned 确认、workspace / 窗口 Dock 的进程确认；
- pinned workspace 关闭确认、agent mid-turn 确认、未保存内容确认、X 按钮警告：不变；
- 「Keep Workspace Open」开启（`closeWorkspaceOnLastSurfaceShortcut` = false）：关闭最后一个标签页时保留 workspace 并补一个替代终端，行为不变；
- 窗口 Dock 里跑着进程时关闭最后一个 workspace：仍弹进程确认；
- 窗口级关闭（红点 / Close Window / Cmd+Q）：仍按退出策略退出应用。

### 已知未覆盖 / 风险

- 空窗口里没有额外的空白提示 UI（侧栏 + 号、命令面板 `New Workspace`、Cmd+T 均可新建）——先按最小改动实现，实机验收后再决定是否需要空状态引导。
- 空窗口的会话快照保存依赖 `isEligibleForSessionPersistence` 对空 workspaces 返回 true（已核实）；以后上游若改这条判定，要回头检查。
- 上游若合并「关闭最后一个 workspace 就关窗口」相关改动，rebase 时注意 `closeWorkspace` / `closeWorkspaceIfRunningProcess` / `closeWorkspacesWithConfirmation` / `closePanelAfterChildExited` / `BonsplitDelegate` 的冲突。

---

## P3 — 本地后台 Git 探测改走 cheap 读取，不再和打字争 CPU

**状态**：已实现（功能分支 `feat/local-input-latency`）

### 要解决的问题

用户只在本地使用 cmux，打字时仍感觉延迟。上游 #4705 的现场采样把根因之一指向工作区 Git 元数据探测：cmux 约 138% CPU，`gitIndexSnapshot` 热点会读 `.git/index`、对每个被跟踪文件 `lstat`。基线 `v0.65.2.2` 已经有「打字静默期推迟探测」（`SidebarGitMetadataService+Probe.swift`）与进程级限流（`WorkspaceGitMetadataProbeLimiter`），但探测一旦被放行，本身仍然是全量扫描；多工作区 / 大仓库时，这批后台工作会和输入路径抢 CPU。上游 PR #5665 提出 cheap 模式，至今未合并。

### 改法（按本仓库结构重写，不是 cherry-pick）

上游 PR 的路径是 `Packages/CmuxGit/`，本仓库已重构成 `Packages/macOS/CmuxGit/`，且读取链已下沉到 `CmuxSidebarGit` 包，所以按现有结构实现同一语义：

| 文件 | 改动 |
| --- | --- |
| `Packages/macOS/CmuxGit/.../Model/GitMetadataReadOptions.swift` | 新增：`.full`（精确）/ `.sidebar`（只读分支与 HEAD）两种读取预算 |
| `.../GitMetadataService.swift` | `workspaceMetadata(for:trackedPathEventGeneration:options:)`：cheap 时跳过 `gitTrackedChangesSnapshot` 与 HEAD 二次校验，直接返回干净快照；旧 API 默认 `.full` 转发，行为不变 |
| `Packages/macOS/CmuxSidebarGit/.../Hosting/WorkspaceGitMetadataReading.swift` | 协议加带 `options` 的方法，默认实现转发到旧方法（测试替身无需改动） |
| `.../Model/InitialWorkspaceGitMetadataSnapshot.swift` | 探测时把 `readOptions` 传给 reader |
| `.../Model/WorkspaceGitSnapshotTaskContext.swift` | 快照任务按目录携带读取预算，预算不同的请求照旧触发 rerun |
| `.../Service/SidebarGitMetadataService+Probe.swift` | `readOptions(forProbeReason:)`：文件系统事件 / 分支变化 / 目录变化用 `.full`，其余常规探测（启动、新建、打字静默期重试、周期刷新）用 `.sidebar` |

### 保留的行为（没被削弱）

- 需要精确 dirty / index 签名的调用方全部保持 `.full`：文件一变、分支一变、目录一变，侧栏仍会拿到精确的脏状态；
- 默认参数 `.full` 让所有既有调用（含 `GitMetadataService.workspaceMetadata(for:)`）语义不变；
- 打字静默期推迟、进程级并发限流、无分配十六进制编码等基线守卫原样保留（由 `scripts/check-latency-guardrails.py` 盯着）。

### 已知取舍

- `.sidebar` 探测**刻意不报告 dirty**（`isDirty: false`、签名为 nil），这是上游 PR #5665 明写的取舍：常规探测优先响应速度，精确状态交给下一次 watcher 驱动的 `.full` 刷新。如果某个工作区从不产生文件系统事件，侧栏的脏指示会保持上一次的值，直到下一次 `.full` 刷新。
- 减少 watch 监听路径（`includeWorkTreeRootWatchPath` 等）是上游 PR 的另一半，本次未做：它会改变「什么时候刷新」，需要单独评估，别和读取预算混在一起。

### 验证

- 新增 `Packages/macOS/CmuxGit/Tests/CmuxGitTests/GitMetadataReadOptionsTests.swift`：用计数替身证明 `.full` 确实 stat 了被跟踪文件、而 `.sidebar` 对 `fileStatusReader` 调用次数为 0，同时断言分支 / HEAD 仍精确；
- `swift build --package-path Packages/macOS/CmuxGit` 与 `.../CmuxSidebarGit` 本机通过（类型检查）；`swift test` 由带完整 Xcode 的 CI runner 执行，本机 CommandLineTools 无 `Testing` 模块。

---

## 与上游 PR / issue 的对应关系

| 上游 | 状态 | 我们的处理 |
| --- | --- | --- |
| #20517（勾选框误导）、#20520（隐藏误导的勾选框） | open | P1 从根上解决：开关关掉时根本不弹，勾选也真的能关掉进程保护 |
| #20215（新增 `app.closeRunningTabsWithoutConfirmation`） | open、停滞 | 我们用自己的键名 `app.confirmCloseRunningProcess`，语义相反、默认不提示 |
| #9865（空闲 coding agent 不算 running process） | open | **暂未实现**，见 TODO.md：P1 默认关闭进程保护后这条不紧急 |
| #1519 / #2195 / #4705 / #17136 / #20778 / #25089、PR #5665 / #20529（上游输入延迟一组） | 上游仍 OPEN，或 PR 未合并 | 本仓库 Issue #10 ~ #18 的逐条核实与处置见 [LATENCY.md](LATENCY.md)：大部分根因已由基线 `v0.65.2.2` 以别的 PR 修复，Cloud 服务端代码已剥离，剩余精确实现登记 TODO T11 |
