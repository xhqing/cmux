# 补丁清单（xhqing 自建分叉）

本仓库的规则是：**基线 = 上游 release tag 的原始代码，我们的改动全部是叠加在基线之上的小补丁**，一个语义一个提交，便于跟着上游新 tag rebase。

当前基线 tag：`v0.65.2.2`（上游 commit `12023d89feb5425c766ba05e8d8e4cfc176e3991`）

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

## 与上游 PR / issue 的对应关系

| 上游 | 状态 | 我们的处理 |
| --- | --- | --- |
| #20517（勾选框误导）、#20520（隐藏误导的勾选框） | open | P1 从根上解决：开关关掉时根本不弹，勾选也真的能关掉进程保护 |
| #20215（新增 `app.closeRunningTabsWithoutConfirmation`） | open、停滞 | 我们用自己的键名 `app.confirmCloseRunningProcess`，语义相反、默认不提示 |
| #9865（空闲 coding agent 不算 running process） | open | **暂未实现**，见 TODO.md：P1 默认关闭进程保护后这条不紧急 |
