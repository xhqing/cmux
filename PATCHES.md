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
| `Resources/Info.plist` | Sparkle：`SUEnableAutomaticChecks` → `false`、`SUFeedURL` → 本仓库地址（见 DEVELOPMENT.md 第四节） |

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

---

## P4 — Markdown 面板：预览态就地编辑（锁 / 笔滑钮，VS Code 式）

**状态**：已实现（自建版 `0.65.2.2-xhqing.5` 起）

### 要解决的问题

cmux 的 Markdown 面板只有两种形态：只读渲染（`preview`）和整篇源码的 NSTextView（`text`）。想在渲染结果里改一句话，得整体切到源码模式，再在几千行里找那一段。想要的体验是 Typora / VS Code 新版 Markdown Editor 那样：**看着渲染结果直接改内容**。

### 为什么不是「搬 VS Code 的实现」

VS Code 的 Markdown Editor 由一个 npm 包 `@vscode/markdown-editor`（MIT，0.0.2-175）驱动。本机实测（离屏 WKWebView 加载真实包）：

- 包本身能在 WebKit 里解析、CSS 正常，但 `EditorView` 构造时无条件执行 `new EditContext({...})`，而 `EditContext` 是 Chromium 专有 API（配合 `element.editContext` 做文本输入）。WebKit 至今没有实现，于是启动即 `ReferenceError: Can't find variable: EditContext`。
- 它的面板适配层还依赖 VS Code 的 webview RPC（`@vscode/hubrpc`）、页面宿主和语言特性服务，搬进 cmux 等于顺带搬半个产品。

另外两条也不走：上游 PR #12479 是「整篇 contenteditable + 自己写 DOM→Markdown 序列化」，它自己的 Limits 里写着保存会归一化整个文档（表格分隔行、行内代码、手工换行都会被改写），而且该 PR 至今 OPEN + CONFLICTING；Milkdown（上游 NEXT 分支用的引擎）能在 WebKit 里跑，但 `getMarkdown()` 的往返同样会改写未编辑的块——实测把 `| --- | --- |` 写成 `| -- | -- |`、把 `$$ 块公式 $$` 变成行内 `$…$`。

### 改法（按本仓库结构实现）

**核心：每个块记录它在源文件里的字节区间，编辑只回写这一段。**

| 文件 | 改动 |
| --- | --- |
| `Resources/markdown-viewer/markdown-editor.js` | 新增。渲染后把 `marked` 的顶层 token 与渲染出的 DOM 子节点并行走一遍，给每个块打上 `data-cmux-block-start/end`；点块时用这段区间取出原文放进浮层 textarea，提交时把 textarea 的字节替换回该区间。锁/笔滑钮、闪光泽提示也在这里。 |
| `Resources/markdown-viewer/shell.html` | 渲染函数末尾加一行 `CmuxMarkdownEditor.markRendered(md)` 钩子；新增 `{{markdownEditorJS}}` 占位与滑钮 / 浮层的样式。只读渲染路径本身没动。 |
| `Sources/Panels/MarkdownPanel.swift` | `MarkdownPanelDisplayMode` 增加 `.editor`；`editorDidCommitText` 复用现有的 `textContent` / `isDirty` 通道；`commitEditorAndSave` 先 `flush()` 页面里未提交的块再保存；锁状态用 `markdown.editor.locked` 记住（和 VS Code 一样，下一个文档沿用）。 |
| `Sources/Panels/MarkdownWebRenderer.swift` | 新增 `cmuxMarkdownEditor` 消息桥（`change` / `readonly`），安装 / 卸载页面编辑层，`didFinish` 后重装（崩溃恢复重载也能编辑）。 |
| `Sources/Panels/MarkdownWebSupport.swift` | `MarkdownWebView.performKeyEquivalent` 现在也能把 `saveFilePreview` 快捷键交给面板（就地编辑模式没有 NSTextView 拥有它）。 |
| `Sources/Panels/MarkdownPanelView.swift` | 第三模式的分支与头部按钮（铅笔进入、眼睛回只读、`doc.plaintext` 回整篇源码）。 |
| `Sources/Panels/MarkdownViewerAssets.swift` | 注入 `markdown-editor.js`（和 viewer-navigation / sanitizer 一样的加载路径，构建期自动 deflate）。 |

**滑钮配色对齐 VS Code（后续修订）**：滑钮挂在 `document.body` 下、不在 `#content` 子树里，而 `applyTheme` 只把主题变量注入 `#content`，于是它一个变量都取不到、全部落回浅色主题的兜底——深色文档上就是个白底胶囊。现在 `applyTheme` 把同一批变量同时写入 `document.documentElement`（`--bgColor-default` 除外：它的值是 `transparent`，注入根节点会让浮动的块编辑浮层变透明），滑钮因此改吃 `--bgColor-muted`（填充，与文档背景对比度 1.09）与 `--borderColor-default`（1px 描边，1.92）；激活态垫底写死 `#0078d4`、图标纯白，未激活图标 `#8a8a8a`（浅色主题 `#616161`），图标槽改成 22×22 的 5px 圆角方形；`markdown-editor.js` 不再用 `hidden` 隐藏非激活图标，锁在左、笔在右两个常驻可见（与截图上量出的 VS Code 参考值逐项对齐）。

**就地编辑浮层改用文档底色（后续修订）**：浮层同样在 `#content` 外面，原来 `background: var(--bgColor-default, #ffffff)` 与 `border: var(--borderColor-accent, …)` 全部落在浅色兜底，深色文档上就是个白底、浅蓝描边的输入框。`MarkdownWebTheme` 新增 `surface`（面板不透明底色）并以 `--cmux-panel-surface` 注入根节点（`--bgColor-default` 是 `transparent`，遮不住正文），浮层背景改用它、描边改用与滑钮同一套 `--borderColor-default`；正文 / 提示颜色由新增的 `inheritContentPalette()` 从 `#content` 抄 `--fgColor-default` / `--fgColor-muted`，不再落到浅色兜底。

### 保留的行为（没被削弱）

- **只读渲染路径完全没动**：`preview` 仍然走原来的整篇 `marked.parse` + sanitizer，Mermaid / Vega / KaTeX 照旧；就地编辑层只在 `.editor` 模式安装，切回去就卸载。
- **不归一化未编辑的内容**：提交只替换被编辑块的那段字节，其它块（包含 frontmatter、表格、代码块、手工换行）逐字节不动。
- **脏 / 保存语义沿用面板**：脏标记、Cmd+S、Revert、外部文件变更合并、会话恢复都还是 `MarkdownPanel` 说了算，编辑层只上报文本。
- **安全边界不变**：编辑面只是 textarea 覆盖层，渲染仍走原有 allowlist sanitizer；本地图片仍走 `cmux-local-image://` 而不能读 `file://`。

### 已知边界

- 一次只能编辑一个块；提交后整篇重渲染（滚动位置由现有逻辑保持）。块内的**结构**要手写 Markdown（表格仍是表格语法），不是 Typora 那种表格网格。
- 编辑浮层按打开时的位置定位，编辑期间滚动窗口不会跟随（v1 取舍）。
- 就地编辑模式下没有查找条（Cmd+F 仍只在 `preview` 里工作），需要查找时切回预览或整篇源码模式。
- 大文件（如 431 KB 的 `CHANGELOG.md`）打开就地编辑会偏慢：每次渲染都要算一遍块区间；预览模式不受影响。

### 验证

- 离屏 WKWebView 冒烟（本机 `swiftc` + WebKit，不抢焦点）：块区间覆盖校验——`README.md` 24 块 / 4804 字节、`CHANGELOG.md` 前 120 行 42 块 / 14362 字节，**非空白字节全部落在某个块的区间内、无重叠**；点击开块、textarea 取到该块原文、提交后消息里的文档结构完整；锁定时点击只触发滑钮光泽、不开编辑层。
- `swiftc -parse` 通过（6 个改动文件 + 2 个新增测试）；完整编译与运行时行为交由 CI / Release 构建验证（本机只有 CommandLineTools）。

---

## P5 — About 面板显示我们自己的发布版本号

**状态**：已实现

### 要解决的问题

About 窗口的「Version」一行显示 `0.65.2.2`，而 GitHub Release / tag 上的版本是 `0.65.2.2-xhqing.12`——两处对不上，看不出装的是哪一次自建发布。旁边的「Commit」链接还指向上游仓库（`https://github.com/manaflow-ai/cmux/commit/<hash>`），可 hash 是我们自己仓库的，点开是 404。

### 根因（读基线代码确认）

1. `Sources/App/About/AboutPanelView.swift` 的 `version` 直接读 `CFBundleShortVersionString`。
2. 这个键由 `MARKETING_VERSION` 注入，而 Apple 的规范要求它是 1~3 段纯数字，带 `-rN` 后缀会被工具链拒掉，所以 `build.yml` 只注入 `VERSION` 去掉后缀的前缀（见 DEVELOPMENT.md），修订后缀天然进不了 Info.plist。
3. `AboutPanelView` 里 `githubURL` 与 commit 链接都写死上游仓库地址。

### 改法（最小收敛点）

| 文件 | 改动 |
| --- | --- |
| `scripts/build-app-bundled-resources.sh` | 新增 `update_version()`：读仓库根 `VERSION`（去掉首尾空白）写进 Info.plist 的 `CMUXVersion` 键，在原来调用 `update_commit` 的两处（缓存命中早退分支 / 正常结束分支）一并调用。 |
| `Sources/App/About/AboutPanelView.swift` | `version` 优先读 `CMUXVersion`，其次环境变量 `CMUX_VERSION`（本地开发用），最后才回退旧的 `CFBundleShortVersionString`；仓库地址收敛成一个 `repository` 常量，GitHub 按钮与 commit 链接都指向本仓库。 |
| `.github/workflows/build.yml` | 校验 step 增加 `CMUXVersion` 与 `VERSION` 原值的比对，不一致直接红。 |
| `DEVELOPMENT.md` | 版本号注入一节补记 `CMUXVersion` 的来源与校验。 |

### 为什么不用「直接把后缀写进 `CFBundleShortVersionString`」

那条路更短，但会绕开 Apple 对 bundle version 的格式约束（1~3 段纯数字），`ValidateEmbeddedBinary`、公证、Launch Services 的版本比较都可能因此报警或行为异常；而 `CMUXVersion` 是纯展示用的自有键，加它不影响任何系统行为。

### 验证

- `swiftc -parse` 通过（改动的 Swift 文件）。
- 完整构建与 About 面板实际显示交由 CI Release 构建验证：校验 step 会打印 `release : <VERSION>` 与 About 面板的取值，两者不一致直接失败。

---

## P6 — Markdown 预览默认加载安全远程图片（`markdown.loadRemoteImages`，默认开启）

**状态**：已实现

### 要解决的问题

用 cmux 内置 markdown 查看器打开 README 这类文档时，shields.io 徽章等远程图片全部渲染成「Remote image blocked」占位块，必须一张张点「Load this image」才显示。上游的保守默认可以理解（预览一个陌生文件时不替读者访问外部服务器），但日常读自己项目 README 时这个体验和 GitHub / VS Code 差得太远，用户明确要求「徽章要能正常显示」。

### 改法（最小收敛点）

保留上游整套安全机制与人工确认流程，只把「要不要每张图手动点一次」变成一个设置项：

| 文件 | 改动 |
| --- | --- |
| `Resources/markdown-viewer/shell.html` | 新增 `remoteImagesAutoLoad` 标志与 `window.__cmuxSetRemoteImageAutoLoad(enabled)`；`ensureRemoteImagePlaceholder()` 末尾在 `canOfferLoad && remoteImagesAutoLoad` 时直接走 `loadApprovedRemoteImage(info.href)`（仍然经过 `remoteImageCanOfferLoad` 与宿主 approve，不绕过）；自动加载时先折叠占位块（`display:none`），失败时由 `setRemoteImageLoadingState(img, false)` 恢复显示；同一 URL 只向宿主请求一次；打开设置时补齐页面上已渲染的图片（覆盖「先开设置再渲染」与「渲染后再开设置」两种顺序）。 |
| `Sources/Panels/MarkdownRemoteImageSettings.swift`（新增） | 设置键 `markdown.loadRemoteImages`，`resolvedDefault` / `setDefault` / `resetDefault`，内置默认 `true`。 |
| `Sources/Panels/MarkdownWebRenderer.swift` | 新增 `loadRemoteImages` 参数；Coordinator 改用 `MarkdownRemoteImageAutoLoadSync`（见下方 r15 修复）记录该值，并在 `didFinish` 强制重新注入，shell 重载后页面状态不会丢。 |
| `Packages/Shared/CmuxAgentChat/.../MarkdownRemoteImageAutoLoadSync.swift`（新增） | 纯值类型：记录请求值 / shell 是否就绪 / 已推送值。shell 未就绪时 `pendingPush()` 不记账；`didFinish` 调 `shellLoadFinished()` 无条件拿到要推送的值。 |
| `Packages/Shared/CmuxAgentChat/Tests/.../MarkdownRemoteImageAutoLoadSyncTests.swift`（新增） | 覆盖 r15 抢跑时序、重载必须重推、加载后变更只推一次、加载前多次变更由 `didFinish` 送最后值；PR 门禁会实际跑该包的 `swift test`。 |
| `Sources/Panels/MarkdownPanel.swift` | 新增 `@Published loadRemoteImages`，init 读 `resolvedDefault()`；UserDefaults 观察回调里同步新值，设置或 `cmux.json` 变更立即生效。 |
| `Sources/Panels/MarkdownPanelView.swift` | 把值传给渲染器。 |
| `Packages/macOS/CmuxSettings/.../MarkdownCatalogSection.swift` | 新增目录键（boolean、默认 `true`、带 `userFacing` toggle 描述符）。 |
| `Packages/macOS/CmuxSettingsUI/.../Sections/AppSection.swift` | 设置页 App 区 Markdown 字体 / 宽度旁边新增开关行，含开 / 关两种副标题。 |
| `Packages/macOS/CmuxSettingsUI/.../Navigation/CuratedSettingEntry+Default.swift` | 收录进 curated 设置导航。 |
| `Sources/SettingsSearchIndex.swift` / `Sources/SettingsSearchAliases.swift` / `Sources/CommandPalette/CommandPaletteSettingsToggle.swift` | 设置搜索项、搜索别名、命令面板开关。 |
| `Sources/CmuxSettingsJSONPathSupport.swift` / `Sources/CmuxSettingsFileStore+SupportedPaths.swift` / `Sources/KeyboardShortcutSettingsFileStore+SectionParsers.swift` / `Sources/KeyboardShortcutSettingsFileStore+Template.swift` | `cmux.json` 的路径注册、markdown 节布尔解析与模板默认值。 |
| `schemas/config/cmux.schema.json` + `Packages/macOS/CmuxFoundation/.../CmuxConfigSchema.generated.swift` | schema 新增 `markdown.loadRemoteImages`（描述写清默认自动加载安全 HTTPS 远程图片、关掉恢复逐图确认），并用 `scripts/generate-cmux-config-schema.py` 重新生成。 |
| `cmuxTests/MarkdownPanelTests.swift` | 新增 `testMarkdownRenderAutoLoadsRemoteImagesWhenEnabled`（渲染前开 / 渲染后开两种顺序、失败回退、HTTP 图片仍拦）。 |
| `Packages/macOS/CmuxSettingsUI/Tests/.../SettingsRowAnchorResolutionTests.swift` | 行锚点契约清单登记 `markdown.loadRemoteImages`；同时补上 P1 漏登记的 `app.confirmCloseRunningProcess`（该包 `swift test` 一直因此报「搜索项没有可滚动的行」，直到本 PR 才第一次在 CI 里跑到这个包测试）。 |
| `Packages/Shared/CmuxAgentChat/.../MarkdownRemoteImageApprovals.swift` | 只改文档注释：批准记录现在也可能由页面在设置开启时代为发起（消息形式不变），不再只来自读者点击。安全逻辑没有任何改动。 |
| `cmux.xcodeproj/project.pbxproj` | 注册新源文件；顺带跑了一次 `scripts/normalize-pbxproj.py`（该文件在 main 上已处于未归一化状态，`check-pbxproj.sh` 本来就是红的，归一化把两条无关条目也排了序）。 |

### 为什么默认开启

- **用户诉求就是「预览要能正常显示徽章」**：VSCode 的 markdown 预览和 GitHub 的 README 页面都默认加载远程图片，读者的默认预期已经是「图片就在那里」。cmux 自建版面向的是本机日常使用（读自己项目的 README），不是打开陌生文件。
- **安全边界没有动**：仍只允许 HTTPS、不带凭据、端口只能是 443、拒绝 localhost / `.local` / 内网 IP；宿主仍然按 URL 逐个记录批准，`cmux-remote-image://` scheme handler 只 fetch 批准过的 URL；加载失败不静默——占位块连同三个回退按钮（重载 / 复制 URL / 外部打开）会显示回来。
- **关掉即恢复上游行为**：设置页开关（或 `cmux.json` 里 `markdown.loadRemoteImages: false`）一关，就是上游原样的逐图确认流程，连 shell 的默认值都保持手动。
- 担心的场景（预览不可信文档时不想让 cmux 替你发请求）由这个开关覆盖，而且与上游不冲突——上游日后若做同样的设置，rebase 时可对齐语义。

### r15 回归与修复（2026-11-09）

**现象**：装的是 r15（`CMUXVersion=0.65.2.2-r15`，bundle 内 `Resources/markdown-viewer/shell.html` 与 tag 的 sha256 一致，UserDefaults 里没有 `markdown.loadRemoteImages`，即默认开启），但内置查看器打开 README 时 shields.io 徽章仍全部显示「Remote image blocked」，必须逐张点「Load this image」。

**根因**：Coordinator 用 `appliedLoadRemoteImages` 记录「当前文档已经收到该值」，但这个记录在页面还没准备好时就被写入了：

1. `makeNSView` 先调 `setLoadRemoteImages(true)`——此时 WebView 还是 `about:blank`，`evaluateJavaScript` 无效，但 `applied` 已被置为 `true`；
2. `loadShell()` 把 `applied` 重置为 `nil` 并开始 `loadHTMLString`；
3. SwiftUI 紧接着调用 `updateNSView`，再次 `setLoadRemoteImages(true)`——shell 仍在加载、`window.__cmuxSetRemoteImageAutoLoad` 还不存在，JS 静默失败，但 `applied` 又被置为 `true`；
4. `didFinish` 调 `applyLoadRemoteImages()`，`applied == last` 直接 return，页面永远停在 shell 默认的 `remoteImagesAutoLoad = false`。

**修复**：

- 新增 `Packages/Shared/CmuxAgentChat/.../MarkdownViewer/MarkdownRemoteImageAutoLoadSync.swift`：把「请求值 / 当前文档是否已加载 / 已推送值」抽成纯值类型。`pendingPush()` 在 shell 未加载完成时一律返回 `nil` 且不写 `applied`；`shellLoadFinished()` 无条件返回要推送的值（并记为已推送），保证 `didFinish` 一定注入。
- `MarkdownWebRenderer.swift` 的 Coordinator 改用该类型：`setLoadRemoteImages` → `request` + `pendingPush`；`loadShell` / `close` → `shellLoadStarted()`；`didFinish` → `shellLoadFinished()` + 强制推送。行为不变——设置关闭仍推 `false` 恢复逐图确认，重载 / 崩溃恢复会重新注入，自动加载失败仍回退三个按钮，HTTP / 内网 URL 仍被拦（这些逻辑都在 `shell.html`，本次未改）。
- 测试：`Packages/Shared/CmuxAgentChat/Tests/.../MarkdownRemoteImageAutoLoadSyncTests.swift` 覆盖 r15 的抢跑时序、重载必须重推、加载后变更只推一次、加载前多次变更由 `didFinish` 送最后值。该包在 PR 门禁的 `check-swift-packages.py` 里会实际跑 `swift build` + `swift test`。

### 已知边界

- 设置关掉时，**已经**自动加载出来的图片不会撤回（宿主已记录批准、图片已显示）；关掉只影响之后渲染的图片。
- 自动加载失败后不会自动重试，需要读者点「Load this image」（和上游手动流程一致）。
- 本地图片（相对路径）走的 `cmux-local-image://` 路径本来就不需要确认，本补丁没有改动。
- 上游 rebase 冲突点：`shell.html` 的远程图片段、`MarkdownWebRenderer.swift`、`MarkdownPanel.swift`、`MarkdownCatalogSection.swift`、`AppSection.swift`。

### 验证

- 改动过的 Swift 文件逐个 `swiftc -parse -enable-bare-slash-regex` 通过；`swift build --package-path Packages/Shared/CmuxAgentChat` 通过。本机是 CommandLineTools（没有 `Testing` 模块），`swift test` 无法执行，如实记录；CI 的 `scripts/check-swift-packages.py` 会对该包实际跑 `swift test`。
- 另外用 `swiftc` 把同一份状态机源码与断言脚本编译成本地可执行文件，逐条跑过 r15 时序（抢跑不记账、`didFinish` 必推、重载重推、关闭推送、重复不推），全部通过。
- `cmuxTests` 不在 PR 门禁里跑、本机也没有完整 Xcode；P6 原有的 WebView 测试保留不动，本轮的时序修复由上面的 `CmuxAgentChat` 单测覆盖（CI 可执行）。
- 本次不涉及 schema / pbxproj 改动；`git diff --check` 与 `scripts/lint-pbxproj-test-wiring.sh` 照常跑过。

---

## P7 — Markdown 面板显示本地 SVG 图片（README 项目 LOGO 不再破图）

**状态**：已实现

### 要解决的问题

在 cmux 内置 markdown 查看器里打开一份带本地 LOGO 的 README（例如某个项目根目录的 README，顶部用 `<img src="assets/logo.svg">` 或 `![](assets/logo.svg)` 引用仓库里的 SVG）：LOGO 是破图——只剩 alt 文字加一个问号图标；同一页的 shields.io 徽章（远程 SVG）显示正常。用户为此改了十几轮 README 写法都没用，因为问题不在 README。

### 根因（读代码确认，不是推测）

1. `Resources/markdown-viewer/shell.html` 的 `rewriteLocalImageSources()` 对 `contentEl.querySelectorAll('img[src]')` 逐个处理，`cmuxLocalImageURL()` 只判断「是不是相对路径 + 解析后是不是 `file:`」、**不看扩展名**——所以 HTML 写 `<img>` 和 markdown 写 `![]()` 完全一样，都会被重写成 `cmux-local-image://image?url=<file URL>`。
2. `Sources/Panels/MarkdownWebRenderer.swift` 的 `localImageMimeType(for:)` 白名单原本只有 png / jpg / jpeg / gif / webp / avif，**没有 svg**。
3. 同文件 `localImageFileURL(from:)` 末尾的 guard 是 `standardizedURL.path.hasPrefix(markdownRoot) && Self.localImageMimeType(for: standardizedURL.pathExtension) != nil`，所以 `.svg` 直接 `return nil`；`imageLoadTask` 随即回退成 `ImageLoadResult(data: Data(), mimeType: "image/png")` → 空数据 → 破图。
4. 远程图片是另一条链路：`Packages/Shared/CmuxAgentChat/.../MarkdownRemoteImageLoader.swift` 的 MIME 归一化明确列了 `image/svg+xml`，所以徽章能显示。这正好解释「只有徽章渲染出来、本地 LOGO 破图」。

### 改法（最小收敛点）

| 文件 | 改动 |
| --- | --- |
| `Sources/Panels/MarkdownWebRenderer.swift` | `localImageMimeType(for:)` 增加 `case "svg": return "image/svg+xml"`（带注释说明 image 上下文的安全语义与 `.svgz` 为何不加）。这是整个修复唯一的逻辑改动。 |
| `cmuxTests/MarkdownPanelTests.swift` | 新增 `testMarkdownRenderHandlesLocalSVGImageSources` 与 `tinySVG` fixture（8×4、显式 width/height 的矩形 SVG）。 |

`.svgz` 没有加：它要求响应体是 gzip 压缩流、由 HTTP `Content-Encoding` 解压；`cmux-local-image://` 是本地文件读取、不经过 HTTP 内容编码协商，WebKit 拿到 gzip 字节只会当成坏图，加了反而给人「支持了」的错觉。

### 为什么放开 svg 不引入脚本执行面

SVG 能带 `<script>` / `onload` / 外部引用，看起来像「放开一个可执行格式」，但这里加载它是经过 `<img src=...>`，属于 **image 上下文**：

- 规范层面 SVG 在 image 上下文按 **secure static mode** 渲染：脚本不执行（`<script>` 与事件处理属性一律无效）、动画不启动、不加载外部资源（不会去 fetch `xlink:href` 指向的远程文件或 CSS `@import`）。
- 所以挡脚本的门是 **image 上下文**，不是 MIME 白名单——白名单只决定「这个文件的字节要不要交付给 WebKit」。同一份 SVG 换成 `<iframe>` / 直接导航打开才需要考虑脚本，而这条预览管线只把本地文件喂给 `<img>`，没有 iframe / 导航入口。
- 目视可控：图片能拿到的信息就是「markdown 文件同目录及其子目录里的文件」，与 png 同级——这个信任边界早在 P1 之前的上游行为里就存在，本次没有扩大。

如果将来有人把本地图片改成 `iframe` / `<object>` 渲染，这个结论立刻失效，那时必须重新评估（届时 MIME 白名单要再做一次收紧）。

### 保留的保护（没被削弱）

- `localImageFileURL(from:)` 的目录限制原样保留：scheme 必须是 `cmux-local-image:`、`url` 参数必须是 `file:` URL、markdown 目录 `standardizedFileURL.resolvingSymlinksInPath()`、`path != "/"` 拒绝、目标文件同样先 standardized + resolvingSymlinksInPath 再 `hasPrefix(markdownRoot)`——越界、软链逃逸、根目录场景全部照旧拒绝。
- shell 侧仍然只重写**相对路径**（`isRelativeLocalImagePath`）：绝对路径与绝对 `file:` URL 不会被塞进 `cmux-local-image://`。
- 远程图片链路（`cmux-remote-image://` + `MarkdownRemoteImageLoader`）本次未改。

### 已知边界

- `.svgz` 不支持（见上）。
- 本地图片仍然没有文件大小上限：一张几百 MB 的 SVG 会和同尺寸 PNG 一样吃内存。这是既有行为，本次不扩大也不修复。
- 同目录下的 SVG 在 image 上下文里无法执行脚本、无法外连，但它仍能把画面渲染成任意内容（例如伪造成 UI 截图）——这是「显示本地图片」的固有属性，与是否会话安全无关。
- 上游 rebase 冲突点：`MarkdownWebRenderer.swift` 的 `localImageMimeType(for:)`（一处 switch）。

### 验证

- `swiftc -parse` 对改动的两个 Swift 文件通过（`Sources/Panels/MarkdownWebRenderer.swift`、`cmuxTests/MarkdownPanelTests.swift`）。
- `cmuxTests` 不在 PR 门禁里跑，本机也没有完整 Xcode（项目规矩：本机不跑完整构建，两小时量级），因此新增的 WebView 用例在本机**未实际执行**，如实记录；由 CI 的 `build-macos` 编译兜底，行为验证交给发版后安装 + 用户实测。
- 新增用例覆盖三条断言：本地同目录 `logo.svg` 渲染成功（`complete == true`、`naturalWidth` / `naturalHeight > 0`、`currentSrc` 以 `cmux-local-image://` 开头）、目录外 SVG 被拒（`naturalWidth == 0`）、显式 `file:` URL 不进本地图片通道（`src` 为空）。原有 PNG 用例未改动，其中的「越界路径被拒」「绝对路径 / 绝对 file: 被拒」断言继续覆盖同样的保护面。

---

## P8 — 修好「Check for Updates…」：从 `xhqing/cmux` 的 Release 检测并安装最新版

**状态**：已实现

### 要解决的问题

菜单里的「Check for Updates…」一直报错 / 什么也检查不到。P1 时代关掉了 Sparkle 的**自动安装**、把 feed 指回本仓库（`Info.plist` 里还写了 `SUEnableAutomaticChecks=false`，但 `CmuxUpdater` 的 `UpdateSettings` 会注册上游默认的 `true`，实际把自动检查覆盖成开启——这一点也是本次顺手核实的），可本仓库从来没有发布过 appcast：菜单项实际去拉 `https://github.com/xhqing/cmux/releases/latest/download/appcast.xml`，拿回来的是 404。用户想要的是：**能从本仓库的 Release 里检测出最新版，并在应用内直接更新过去**。

### 根因（读代码 + 实测确认）

1. `Resources/Info.plist` 的 `SUFeedURL` 已经指向本仓库，但 `SUPublicEDKey` 仍是**上游**的公钥 `avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc=`（`project.pbxproj` 两处 `SPARKLE_PUBLIC_KEY` 的默认值）。上游私钥不在我们手里，所以即使有 appcast 也签不了名。
2. `.github/workflows/build.yml` 只产 zip，**从不生成 `appcast.xml`**；`attach-release-asset.yml` 也只挂 zip 与 sha256。因此 `releases/latest/download/appcast.xml` 实测为 404。
3. 就算把 appcast 补上，`generate_appcast` 默认把 `CFBundleShortVersionString`（纯数字 `0.65.2.2`）写进 `sparkle:shortVersionString`，更新提示会把 `-r18` 显示成「0.65.2.2」，用户看不出这是哪个修订。
4. 更新弹窗里的「View Release Notes」由 `UpdateState.ReleaseNotes` 从显示版本号反推 GitHub 地址，而反推目标写死为 `github.com/manaflow-ai/cmux`——在本分叉里点进去会跳到上游的发布页。

### 改法

| 文件 | 改动 |
| --- | --- |
| `cmux.xcodeproj/project.pbxproj` | 两处 `SPARKLE_PUBLIC_KEY` 换成我们自己的 EdDSA 公钥 `rfbvt6jmbne/wfXun8IedZrnp4hR/iRFi9oCPtKsN4Q=`（Info.plist 的 `SUPublicEDKey` 从这里注入）。 |
| `.github/workflows/build.yml` | 校验 step 增加「公钥必须是本仓库的、feed 必须精确指向本仓库」；新增 tag 构建的「生成并签名 appcast」step（secret `SPARKLE_PRIVATE_KEY` → `scripts/sparkle_generate_appcast.sh` → `scripts/ci/set-appcast-version.py`）；产物加上 `appcast.xml`。 |
| `.github/workflows/attach-release-asset.yml` | 把 `appcast.xml` 与 zip / sha256 一起挂到 Release；挂之前校验 appcast 的下载地址确实指向本 tag 的 zip，不一致拒绝发布。 |
| `scripts/ci/set-appcast-version.py` | 把 appcast 的 `<item><title>` 与 `sparkle:shortVersionString` 改成 `VERSION` 原值（`0.65.2.2-r18`）。Sparkle 版本比较用的是 `sparkle:version`（`CFBundleVersion`），显示字段不参与排序。 |
| `Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateState.swift` | `ReleaseNotes` 优先取 appcast 自己的 `sparkle:fullReleaseNotesLink` / `sparkle:releaseNotesLink`，没有时才回退到原来的「显示版本号反推」逻辑。 |
| `Packages/macOS/CmuxUpdater/Tests/CmuxUpdaterTests/ReleaseNotesTests.swift` | 新增两条单测：appcast 链接优先、无链接时保持旧行为。 |
| `scripts/sparkle_generate_appcast.sh` | 未改动（上游脚本原本就支持任意归档格式与自定义下载前缀，直接复用）。 |

私钥只进两个地方：GitHub Actions secret `SPARKLE_PRIVATE_KEY`（CI 签名用）与开发机 macOS 钥匙串（服务名 `cmux-sparkle-eddsa`）；不写进仓库任何文件。

### 为什么生成 appcast，而不是自己写更新器

Sparkle 已经完整地实现了「拉 feed → 比较版本 → 提示 → 下载 → EdDSA 校验 → 解压 → 替换 app → 重启」，本分叉也已经有整套自定义更新 UI（`CmuxUpdater` / `CmuxUpdaterUI`）在跑。缺的只是**喂给它一个本仓库的、签好名的 appcast**。自己再写一个「查 GitHub API + 替换 `/Applications` 下的 app」的更新器，要重新处理替换时文件锁、原子替换、回滚、重启、签名等边界，风险远大于补上 appcast。

### 一次性迁移（必须知道）

Sparkle 校验更新包时用的是**当前安装版本**的 `SUPublicEDKey`：r17 及更早装的是上游公钥，而我们没有上游私钥；ad-hoc 签名的 designated requirement 又是 cdhash，也让「Apple 签名一致」这条兜底不可能成立。所以 **r17 / 更早的安装无法自动更新到带本仓库公钥的版本**，必须手动用 `scripts/install-release.sh` 重装一次。装上新版之后，后续所有更新都能在应用内完成。

### 验证

- 用 Sparkle 2.8.1 的 `generate_appcast` 在本机对一份改过公钥的 app 试跑了整条链路：appcast 生成成功、`sparkle:edSignature` 存在、`set-appcast-version.py` 后 `<item><title>` 与 `shortVersionString` 为 `0.65.2.2-r18`、channel 标题 `cmux` 未被误改。
- 签名依赖的私钥公钥配对已实测：`scripts/derive_sparkle_public_key.swift` 从私钥导出的公钥与写进 `project.pbxproj` 的公钥一致。
- `.github/workflows/` 的两个 YAML 用 Ruby 的 YAML 解析器做了语法校验。
- `UpdateState.swift` 与整个 `CmuxUpdater` 包源码一起编成本地探针跑过真实行为：带 `sparkle:fullReleaseNotesLink` 的 item 得到本仓库的 release 地址，不带链接的 item 保持旧行为（反推到上游 `v0.65.2`）。本机是 CommandLineTools、没有 Swift Testing 的 `Testing` 模块，所以 `ReleaseNotesTests` 只能做 `swiftc -parse` 语法检查，真正执行交给 PR 门禁的 `scripts/check-swift-packages.py`（`macos-26` runner 有完整 Xcode）。
- 发布侧已验到「签名 appcast + zip 全部正确」；应用内的「检测到新版本 → 下载 → 安装 → 重启」要等下一次 tag（r19）发布后实测——本次没有比 r18 更新的版本可测。
- r18 的 tag 构建（run 42824769839）成功，artifact 里已包含 `appcast.xml`；首次资产挂载因 attach workflow 通知消息里的 `bad substitution` 中断，修复后（PR #74）用 `workflow_dispatch` 重跑同一个 run 的挂载，Release 资产补齐。
- 发布后的实测：`https://github.com/xhqing/cmux/releases/latest/download/appcast.xml` 返回 200；`sparkle:version` = `20261110024`、显示版本 `0.65.2.2-r18`、下载地址指向本 tag 的 zip。把 zip 下载回来复算：sha256 与 Release 里的 `.sha256` 一致，EdDSA 签名用 app 内公钥（CryptoKit `Curve25519.Signing.PublicKey`）验证通过；zip 内 app 的 `CFBundleIdentifier` / `CMUXVersion` / `SUPublicEDKey` / `SUFeedURL` / `CFBundleVersion` 全部与预期一致，`codesign --verify --deep --strict` 通过（ad-hoc，符合预期）。

---

## P9 — 构建产物不再把构建机的 home 烧进 `LSEnvironment`（#46）

**状态**：已实现

### 要解决的问题

CI 构建出来的 `cmux.app`，`Info.plist` 的 `LSEnvironment` 里写死了 CI runner 的 home：

```
CMUX_SOCKET_PATH = /Users/runner/Library/Application Support/cmux/cmux-xhqing.sock
CMUXD_UNIX_PATH  = /Users/runner/Library/Application Support/cmux/cmuxd-xhqing.sock
```

装到任何用户机器上，这两个路径都不存在（`/Users/runner` 根本不属于该用户），socket 只能落到 fallback 路径或直接失败。

### 根因

`scripts/reloads.sh` 在「改身份」那一段用 `$HOME/Library/Application Support/cmux` 算出 socket 路径，再用 `PlistBuddy` 写进 `LSEnvironment`。`LSEnvironment` 是**构建期**写进产物、**运行期**由 LaunchServices 注入的，值一旦写死就跟着产物走：本地构建时它恰好等于构建者自己的 home（所以本机看不出来），CI 上 `$HOME=/Users/runner`，于是每个用户都拿到一个别人机器上的路径。

顺带记一笔：这条路还绕回了 `~/Library/Application Support`——上游从 0.64.20 起特意把控制 socket 迁到 `~/.local/state/cmux`，就是为了避开「别的签名的二进制读写另一个 app 的 Application Support 会触发 TCC 弹窗」（上游 issue #5146）。我们的注入把它又推了回去。

### 改法

按 issue 里的方向①（构建期不注入绝对路径，app 启动时按自己的 home 算默认路径）实施，身份键照旧保留：

| 文件 | 改动 |
| --- | --- |
| `scripts/reloads.sh` | `LSEnvironment` 只注入 `CMUX_BUNDLE_ID` 与 `CMUX_ALLOW_SOCKET_OVERRIDE`；`CMUX_SOCKET_PATH` / `CMUXD_UNIX_PATH` 不再写进产物（还会显式 `Delete` 掉旧值，防止复用的 DerivedData 里增量构建没重写 plist 保留上一版烤进去的路径）。身份专属路径改由已有的启动环境传递（`env … CMUX_SOCKET_PATH=… open -g`），`--tag` 并行构建照样各用各的 socket。 |
| `scripts/check-bundle-home-paths.sh`（新增） | 检查产物 `Info.plist` 里有没有任何 `/Users/` 绝对路径：有就打印命中行并退出 1。`reloads.sh` 改完 plist 立刻调它，构建期就把规则守住。 |
| `.github/workflows/build.yml` | 构建完、打包前再加一步对最终产物跑同一个检查（CI 日志里同时打印 `LSEnvironment` 的键值，作为发布证据）。 |
| `scripts/install-release.sh` | 不参与改写（见下），只加一条提示：装到本机的包如果 `Info.plist` 里带 `/Users/...`，说明是 #46 修复之前的旧 Release，打印警告提醒（不阻断安装）。 |
| `DEVELOPMENT.md` / `README.md` / `README_cn.md` / `PATCHES.md` | 同步「socket 位置不在构建期写死、改用 app 默认路径」的口径与代价。 |

### 为什么选方向①，不选「CI 不注入」或「安装脚本改写」

- **方向②（只让 CI 不注入）**同样可行，但两条构建路径会分叉：本机构建的产物仍然带着构建者的 home，一旦这个产物被装到别的机器（或另一个账号）上，同一个 bug 照样复现。#46 的病灶是「构建期把机器相关的值烤进产物」，不是「CI 特有问题」，所以按病灶本身修——所有入口统一不注入。
- **方向③（安装脚本改写 plist）**不可靠：`Info.plist` 在 ad-hoc 签名的封签范围内，改写就得重新签名；而且走 Sparkle 的应用内更新**不经过**安装脚本，用户装到的又是未改写的产物——同一个 app 会因升级路径不同而有两种 socket 行为。`install-release.sh` 还支持「只下载这一个脚本、不 clone 仓库」的用法，不适合再给它加改写职责。
- **不改 Swift**：默认路径逻辑（`SocketControlSettings` / `SocketPathMarkerFiles` / `CmuxStateDirectory`）本来就是对的——它按 `FileManager.homeDirectoryForCurrentUser` 解析、根本不受 `$HOME` 影响。需要改的只是「我们把一个构建期常量塞给它」这件事，所以一行 Swift 都不用动，也就不会碰到 #43 正在改的 socket 启动流程与访问策略。

### 默认路径在所有身份下都可靠（issue 列的待确认项）

读代码确认（`Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/`）：

1. `SocketPathMarkerFiles.variant()` 只把上游那几个身份（`com.cmuxterm.app` / `.nightly` / `.rc` / `.staging` / `.debug`）映射到各自通道；`com.xhqing.cmux` 与 `com.xhqing.cmux.<tag>` 都落进 `.stable`。
2. `.stable` 的默认路径是 `resolvedStableDefaultSocketPath()` → `CmuxStateDirectory`（`<home>/.local/state/cmux/cmux.sock`），home 由 `FileManager.homeDirectoryForCurrentUser`（getpwuid）给出，**不读 `$HOME`**；主路径被别人占用 / 不可访问时回退到同目录的 `cmux-<uid>.sock`，所以多账号机器也不会互相踩。
3. CLI 侧（`CLI/CLISocketPathResolver.swift`）第一顺位候选就是同一个 `~/.local/state/cmux/cmux.sock`，其次才是 marker 文件与 `/tmp` 别名——app 用默认路径时，CLI 不需要任何额外配置就能找到它。
4. 这条路在 TCC 上也是安全的：`CmuxStateDirectory` 的注释解释了为什么必须离开 `Application Support`。

### 代价（诚实记录）

分叉版与官方版因此共用同一个默认 socket 路径。本机只装本分叉，日常没有影响；万一两者并存，只有一个能占住它——需要并存时用 `CMUX_SOCKET_PATH` 给其中一个换路径（`CMUX_ALLOW_SOCKET_OVERRIDE=1` 仍在产物里，override 依然生效）。想换成「分叉专属且可移植」的固定路径（如 `/tmp/cmux-xhqing.sock`）是另一条路，但会牺牲多账号安全与 app 自己的路径策略，本次不取。

### 验证

- 用假 `xcodebuild`（只负责把产物放到 `-derivedDataPath` 下）实跑了 `scripts/reloads.sh` 的三条路径：
  - 默认身份：产物 `LSEnvironment` 只剩 `CMUX_BUNDLE_ID = com.xhqing.cmux` 与 `CMUX_ALLOW_SOCKET_OVERRIDE = 1`，脚本内置的检查通过；假 app 记录的启动环境仍是 `CMUX_SOCKET_PATH=/Users/<构建者>/Library/Application Support/cmux/cmux-xhqing.sock`（本机行为不变）。
  - `--tag feature-xyz`：产物 `LSEnvironment` 同样干净，启动环境为 `cmux-feature-xyz.sock`（并行构建仍互不干扰）。
  - 「增量构建没重写 plist」场景（预先把上一版烤进去的 `/Users/runner/...` 放回产物，用 `SHIM_KEEP_PLIST=1` 模拟）：检查脚本先报错（退出 1），`reloads.sh` 跑完后两个键被删掉、检查通过（退出 0）。
- 手工对照：同一份旧式 plist（`/Users/runner/...`）直接喂给检查脚本 → 退出 1 并打印命中行；干净 plist（XML 与 binary 两种格式都试）→ 退出 0。
- `bash -n` 过了 `reloads.sh` / `install-release.sh` / 新脚本；`build.yml` 用 Ruby YAML 解析器校验通过。
- CI 侧的实际断言在 `build-macos` 里（`校验产物不含构建机 home 路径` 步骤）；PR 门禁 `checks` 没有改动（job 名与步骤都不变）。真正的 Release 产物验证要等下一次 tag 构建——本机是 Intel macOS 12 + CommandLineTools，跑不了完整构建。

---

## P10 — 后台忙碌时的按键尖峰：检查点导出不再在主线程格式化整段 scrollback

**状态**：已实现

### 要解决的问题

Issue #45：`.12` 版本采到 584 个按键，其中 4 例 ≥ 50 ms、2 例 ≥ 100 ms。开头的 66.30 / 115.71 ms 是冷启动首键（Issue #44），中间稳定期 p50 6~8 ms，**结尾后台忙碌时另有 53.70 ms / 101.41 ms 两例**。预期是后台工作（Git 探测、自动保存、标题刷新、大量 shell 输出）不该让按键处理延迟超过 ~30 ms。

### 根因（读代码确认）

滚动回写检查点（`Sources/SessionScrollbackCheckpoint.swift`）会把有输出的终端回写成 crash-safe 文件，其中「主线程那一半」是 `TerminalScrollbackCheckpointExport.begin` —— 它调用 Ghostty 的 `write_screen_file:copy,vt`，**格式化该终端的整段历史**；4000 行 / 40 万字符的上限是在导出之后、由非主线程读临时文件时才截断的，主线程已经付掉了整段格式化的时间。三点让它专打输入路径：

1. 只有 `hasPendingOutput` 的终端才排 capture，所以它天然只在用户跑构建、日志在流的时候触发；
2. `typingQuietPeriod = 5` 是「导出开始前」的一次性检查，挡不住「导出跑到一半用户重新开始敲键」；
3. `mainThreadCaptureBudget = 50 ms` + 超预算退避 `slowCaptureBackoff = 600 s`，正好解释「整场只有两例、且相隔很久」。

对照：quit / 快照路径的 `readTerminalTextFromVTExportForSnapshot`（`Sources/TerminalController.swift`）早就改用 Ghostty 的有界格式化，注释写明「不要格式化了整段再丢掉」。只有检查点这条路径没跟上。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Sources/AppDelegate+SessionScrollbackCheckpoint.swift` | `TerminalScrollbackCheckpointExport.begin` 先走 `readBoundedScreenTailVT(maxRows: lineLimit, maxBytes: 400_000 * 4)`；运行时不支持时才回退原来的 `write_screen_file:copy,vt` 临时文件路径 |
| `Sources/GhosttyTitleUpdateIngress.swift` | `KeyLatencyProbe` 新增 `recordActivity(_:startedAt:detail:)`（同一个日志写 span 行）与 `KeyLatencyMainTurnMonitor`（探针开启时才安装的 runloop 观察者，主线程单回合 ≥ 20 ms 记一行 `mainTurn`） |
| `Sources/SessionScrollbackCheckpoint.swift` | 每次导出记一行 `scrollbackExport`（超 50 ms 预算时带 `overBudget=1`） |
| `Sources/SessionAutosaveCoordinator.swift` | 每个 autosave tick 记一行 `sessionAutosave` |
| `Sources/AppDelegate.swift` | `didFinishLaunching` 安装主线程回合监视器（探针未开启时立即返回） |
| `scripts/analyze-key-latency.py` | 新增：把尖峰与重叠 span 对起来，并对没有 span 覆盖的尖峰给出「去抓 sample / spindump」的提示 |
| `scripts/check-latency-guardrails.py` | 新增一组守卫：检查点导出必须走有界格式化 |

### 保留的行为（没被削弱）

- 每次检查点仍最多 3 个导出、一次 main-queue turn 只做一个、超预算退避 600 s、要求 5 s 打字静默；
- 导出内容仍是「最新 ~4000 行 VT 文本」，与 quit 快照同口径（行数语义由 Ghostty 的 bounded formatter 保证）；
- 运行时不支持 bounded 请求时行为与改动前完全一致（走原来的临时文件路径）；
- 探针关闭时全部新增代码只剩一次静态 bool 判断。

### 已知取舍

- `maxRows` 是「物理行」上限，与原先「导出后按逻辑行截断」在折行文本上可能差几行；与 quit 快照路径的差异一致，属于既有口径。
- 本机（Intel macOS 12 + 仅 CommandLineTools）跑不了 GUI 与完整编译，性能结论要等用户装新版后用探针实测；代码正确性由 PR 门禁与 `build-macos` 兜底。
- 检查点导出的主线程成本现在有界，但「导出撞上刚按下的键」这个窗口本身还在（5 s 静默期是开始前的检查）；要等实机日志证明 20 ms 以内就不再构成尖峰。

### 验证

- `swiftc -parse` 跑过改动的 4 个 Swift 文件与 `AppDelegate.swift`（后者需把 3 处 `nonisolated(unsafe)` 临时降级才能被 Swift 5.7 解析，属本机工具链限制，不是改动引入）；
- `python3 scripts/check-latency-guardrails.py` 15 组全 PASS（含新增的一组）；
- `python3 scripts/analyze-key-latency.py --self-test` 通过；用合成日志跑过「有 span 覆盖 / 无 span 覆盖」两条分支的输出；
- 实机验收口径（指标 + 阈值）见 LATENCY.md 的「Issue #45」一节。

---

## P11 — 首个按键不再为键盘布局 / 输入源的冷加载付费（Issue #44）

**状态**：已实现（功能分支 `fix/first-keystroke-latency`）

### 要解决的问题

`KeyLatencyProbe` 在 `.12` 上实测（584 键 / 235.8 秒）：终端刚拿到焦点后的第 1 个可打印键 66.30 ms、第 2 个 115.71 ms、第 3 个起 11.42 ms，稳定态 p50 6~8 ms——第一个键比稳定态慢一个数量级，而这正是用户最容易注意到的时刻。

### 根因（读代码 + 冷启动实测，不是推测）

1. **探针口径**：`KeyLatencyProbe.record(event:phase:"keyDown")` 只在 `keyDown` 入口打点，`delayMs` 是「系统事件时间戳 → 进入 `keyDown`」。所以一个键的处理器慢，表现出来是**下一个键**的 `delayMs` 变大（主线程被占着）。
2. **按键路径上的进程级一次性开销**：`Sources/KeyboardLayout.swift` 的 `id` / `character(forKeyCode:)` / `isDeadKey` 每次都先 `TISCopyCurrentKeyboardInputSource()`，再用 `UCKeyTranslate(..., UInt32(LMGetKbdType()), ...)`。这两步在进程内第一次调用时贵：macmini（Intel / macOS 12.4）冷启动实测 `TISCopyCurrentKeyboardInputSource()` 30 ~ 45 ms、`LMGetKbdType()` 19.3 ms，之后都是 0.00 ms；AppKit 自己的 `NSEvent.characters(byApplyingModifiers:)` 与它们共用同一份缓存（冷 30.9 ms，先预热 TIS 之后 0.00 ms）。
3. **默认安装不会在启动时碰到它们**：`systemWideHotkey.enabled` 默认 `false`，`KeyboardShortcutSettings.refreshRegistration()` 在热键未启用时直接 `unregisterHotKey()` 返回；菜单快捷键用存下来的字符串（`StoredShortcut.menuItemKeyEquivalent`），不查布局。所以这份「冷」一直留到第一个按键——`keyDown` 里紧接着探针点的 `KeyboardLayout.id` 就是第一个付费点。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Sources/KeyboardLayout.swift` | 新增 `warmCaches()`：把 `TISCopyCurrentKeyboardInputSource()` / `TISCopyCurrentASCIICapableKeyboardInputSource()` / `LMGetKbdType()` / 几个 `UCKeyTranslate` 路径各跑一次；新增 `scheduleCacheWarmup(delay:)`：每进程最多调度一次，延后执行。 |
| `Sources/GhosttyTerminalView.swift` | `runtimeSurfaceDidBecomeReady()` 里调用 `KeyboardLayout.scheduleCacheWarmup()`（surface 就绪 = 面板马上能接键盘，但用户还要几百毫秒才会敲）；`keyDown` 增加 release 侧分段计时（`layoutIdMs` / `interpretMs` / 总时长），默认关闭。 |
| `Sources/GhosttyTitleUpdateIngress.swift` | `KeyLatencyProbe` 增加 `recordPhases` / `recordCost` 与共享的 `enqueue`，日志格式保持 `<unixTime> <phase> <delayMs> <keyCode> <isRepeat> [k=v...]`。 |
| `Sources/AppDelegate.swift` | `cmux_performKeyEquivalent(with:)` 入口记一条 `keyEquivalent` 阶段，用来区分「进入我们的代码之前就排队了」与「key-equivalent 路由慢」。 |
| `scripts/analyze-key-latency.py` | 认识新加的三种探针行：`keyEquivalent` / `keyDown.end` / `warmKeyboardLayout` 列成 `routing:` / `handler:` / `warm-up:` 三段，不计入 `keys:` 统计、也不再被误当成后台 span；`--self-test` 覆盖这三种行。 |

### 保留的行为（没被削弱）

- **预热是纯读的**：只调 `TIS*` / `LMGetKbdType` / `UCKeyTranslate`，**不构造、不解释任何 `NSEvent`**。刻意不预热文本输入上下文 / 输入法：那只能靠合成事件走 `interpretKeyEvents`，而它会走 `insertText`——在终端里等于真的把字符打进 shell，还可能让输入法进入组合状态。
- 预热只跑一次（`didScheduleCacheWarmup` 守卫），已热时再跑也是 0.00 ms；延后 0.25 s 是为了不叠在 surface 创建与第一帧上。
- 输入延迟守卫（打字静默期、Git 探测限流、标题合并、预测回显等）原样保留，`scripts/check-latency-guardrails.py` 照旧全绿。

### 已知取舍 / 边界

- **不承诺「首键 < 20 ms」**：这次只搬走「TIS + LMGetKbdType」这一块（实测 30 ~ 50 ms）。剩余部分由新加的探针口径归因：`interpretMs` 大 = 首次 `interpretKeyEvents` 激活输入法（CJK 输入法可能远高于本机测到的 7~10 ms）；`total` 小但 `delayMs` 仍大 = 启动期主线程忙碌（属 #45 / 启动耗时，不在按键路径上）。
- 本机数字来自 macmini（Intel / macOS 12.4），用户机器是 Apple Silicon / 新系统，绝对值会不同；「第一次贵、之后接近 0」来自系统缓存设计，不随机器变化。

### 验证

- `swiftc -parse -enable-bare-slash-regex Sources/KeyboardLayout.swift Sources/GhosttyTitleUpdateIngress.swift` 通过；`keyDown` 里新加的分段计时用等价结构的临时文件做过 `swiftc -typecheck`（本机 Swift 5.7 无法整文件解析 `nonisolated(unsafe)` 的既有语法）；完整编译由 `build-macos` 兜底。
- `python3 scripts/check-latency-guardrails.py`、`python3 scripts/generate-cmux-config-schema.py --check`、`./scripts/lint-pbxproj-test-wiring.sh` 三项门禁本机全绿。
- **行为验证由用户在本机装新版后跑探针完成**：`defaults write com.xhqing.cmux cmuxKeyLatencyProbe -bool true` → 冷启动 → 连敲 10 个以上可打印键 → 看 `~/.local/state/cmux/key-latency.log`。验收看「第 1、2 键合计」（应从约 182 ms 降到 130 ~ 150 ms 量级）、`keyDown.end` 的 `layoutIdMs` 应变成亚毫秒、`warmKeyboardLayout` 应只有一行。详见 [LATENCY.md](LATENCY.md) 的 Issue #44 一节。


---

## P12 — 控制 socket 启动链路在 Release 下可诊断（Issue #43 的后半段）

**状态**：已实现

### 要解决的问题

Issue #43 的现象是「装在 `/Applications` 的 `com.xhqing.cmux` 永远不会创建控制 socket」。根因（发布包的 `Info.plist` 里烤进了构建机的 home）已经由 **P9 / #46** 修掉，但这次排查的代价说明另一半问题同样要修：

- `SocketControlServer.start()` 的失败路径只有两处：`print(...)` 到 stderr（LaunchServices 启动的 app 没人看得到）和经 `SocketControlServerEvents.failure` 发往 Sentry 的 breadcrumb；本自建版没有 DSN，`SentrySDK.isEnabled == false` 时 `sentryBreadcrumb` / `sentryCaptureError` 全是空操作。
- 文件启动日志 `StartupBreadcrumbLog` 只对 nightly / rc / debug 身份开启，`com.xhqing.cmux` 与 `com.cmuxterm.app` 都关着。
- 结果：监听器在 bind 之前就失败（stage `create_lock_directory`、errno `EACCES`），用户机器上**一点痕迹都不留**；当时只能把发布 zip 的 `Info.plist` 抠出来才看到真实原因。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Sources/App/StartupBreadcrumbLog.swift` | ① `isEnabled` 抽成可测纯函数 `isEnabled(bundleIdentifier:environment:)`，`com.xhqing.cmux`（含带 tag 变体）也开启文件日志（`~/Library/Logs/cmux/startup-com.xhqing.cmux.log`），`CMUX_DISABLE_STARTUP_BREADCRUMBS=1` / `CMUX_STARTUP_BREADCRUMBS=1` 覆盖规则不变；② 新增 `SocketStartupLog`：把监听器生命周期写进启动日志，失败另走 `os.Logger`（subsystem `com.cmuxterm.app`、category `ControlSocket`）打 error，附 stage / errno 文本 / hint；③ `socketDirectoryStatus(path:)` 给出 socket 目录状态（`missing` / `writable` / `read_only` / `not_a_directory` / `not_absolute`），目录不存在时 hint 直接点明「`CMUX_SOCKET_PATH` 可能在别的机器上烘焙过」。 |
| `Sources/TerminalController+SocketServerEvents.swift` | `breadcrumb`（只转 `socket.listener.*`，避免每个连接的客户端级 breadcrumb 淹没启动日志）、`failure`、`listenerDidStart` 三个 seam 同时写 `SocketStartupLog`；Sentry 行为完全不变（有 DSN 时照旧上报）。 |
| `Sources/AppDelegate+SocketConfiguration.swift` | 两条启动路径（`startSocketListenerIfEnabled` / `ensureSocketListenerIfEnabled`）各记一条 start attempt（mode / path / source / socket 目录状态；不健康时带 `health.failureSignals`）；访问模式为 `off` 时记 `socket.listener.disabled`（带用户配置的模式值）。 |
| `cmuxTests/SocketConfigurationLifecycleTests.swift` | 新增四个用例：本仓库身份开启启动日志、上游 stable 保持关闭、显式环境开关生效、socket 目录状态识别（`writable` / `missing` / `not_absolute`）。 |
| `DEVELOPMENT.md` / `CHANGELOG.md` | 写清「socket 起不来时怎么查」：启动日志里找 `socket.listener.didStart` / `startAttempt` / `failed`，统一日志用 `log show --predicate 'subsystem == "com.cmuxterm.app" AND category == "ControlSocket"'`。 |

### 边界（刻意不做的部分）

- **不改监听器的路径/回退策略**：P9 已经把「构建期写死路径」这个病灶从源头去掉；再给「路径不可用」加一层静默 fallback，会把「配置错了」伪装成「看起来能用」，并且自定义路径失去身份隔离后会和官方 app 抢同一个 socket。诊断信息足够让人一眼看出问题即可。
- **不给客户端级 breadcrumb 加文件写入**：那类事件按连接重复，写盘会和真实流量成正比；只留 `socket.listener.*`。
- **不动 Sentry 接线**：`sentryBreadcrumb` / `sentryCaptureError` 的调用与去重闸门（`SocketListenerFailureCaptureGate`）原样保留，新链路只是并列的本地出口。

### 验证

- `swiftc -parse` 通过（`Sources/App/StartupBreadcrumbLog.swift`、`Sources/AppDelegate+SocketConfiguration.swift`、`Sources/TerminalController+SocketServerEvents.swift`；`cmuxTests` 那个文件含 Swift Testing 宏，本机 Swift 5.7 解析不了既有内容，未作为判据）。
- `./scripts/lint-pbxproj-test-wiring.sh`、`python3 scripts/generate-cmux-config-schema.py --check`、`python3 scripts/check-latency-guardrails.py` 本机全绿；完整编译与测试执行由 PR 门禁 `checks`（macos-26）与 `build-macos` 兜底。
- 真机验收（装下一版后）：`~/Library/Logs/cmux/startup-com.xhqing.cmux.log` 里应出现 `socket.listener.startAttempt` 与 `socket.listener.didStart`（路径 `~/.local/state/cmux/cmux.sock`）；若监听器再失败，同一条日志链路会留下 `socket.listener.failed` 的 stage / errno / hint，不用再靠拆发布包取证。

---

## P13 — 内置 GitHub Dark Default 默认外观 + 打包完整主题库（Issue #71）

**状态**：已实现

### 要解决的问题

- #70 把 cmux 配置与 Ghostty 彻底解耦后，默认外观仍靠 `cmuxDefaultFallbackConfigContents()` 里硬编码的「Apple System Colors」风格调色板（亮 / 暗各一套），而 bundle 里没有主题库——`theme = <name>` 能否解析完全取决于机器上有没有装 Ghostty。换设备 / 干净环境下 cmux 开箱没有确定的外观，也不带任何主题。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Config/GhosttyConfig.swift` | ① `cmuxDefaultLightThemeName` / `cmuxDefaultDarkThemeName` 都改为 `"GitHub Dark Default"`，让「bundle 里有主题文件」与「无主题文件」两条路径得到同一结果；② `cmuxDefaultFallbackConfigContents()` 不再分亮 / 暗，固定返回 GitHub Dark Default 全套配色（palette 0–15、background `#0d1117`、foreground `#e6edf3`、cursor `#2f81f7` / `#6fc1ff`、selection `#e6edf3` / `#0d1117`，与 bundle 里的 `GitHub Dark Default` 主题文件逐字一致）；③ `shouldApplyManagedDefaultAppearance` 不再受 `adaptiveDefaultTheme` 开关门控——默认外观在用户没有写 theme / 终端颜色时**始终**应用，`adaptiveDefaultThemeEnabled` 参数保留但只作源码兼容、不再参与决策；④ `themeSearchPaths` 的搜索顺序改成「用户目录 `~/.config/cmux/themes/<name>` → bundle 内主题库 → 硬编码兜底」，同名主题以用户文件为准。 |
| `Sources/GhosttyTerminalView.swift` | `loadRealUserGhosttyConfig` 与 `GhosttyApp.shouldApplyManagedDefaultAppearance` 同步解耦：注入 managed 默认外观只取决于「用户配置里有没有 theme / 终端颜色」，不再读 `TerminalAdaptiveDefaultThemeSettings.isEnabled`。 |
| `Sources/TerminalAdaptiveDefaultThemeSettings.swift` | 「Adapt Default Theme to Appearance」设置项保留（UI 与通知原样），但 `loadForCmux` 不再把它传给 `GhosttyConfig.load`；注释写明该设置自 #71 起不再影响行为。 |
| `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/TerminalCatalogSection.swift` | `terminal.adaptiveDefaultTheme` 默认值 `true` → `false`，注释注明「默认主题不再区分亮 / 暗、该设置已无效果」。 |
| `schemas/config/cmux.schema.json` + `CmuxConfigSchema.generated.swift` | 同步 `default: false` 与描述（「Kept for compatibility…no longer differs between light and dark appearance」）。 |
| `Resources/Localizable.xcstrings` / `ThemesSection.swift` / `CuratedSettingEntry+Default.swift` | 设置行副标题（9 种语言）改为「默认主题在浅色与深色外观下相同，此设置不再生效」。 |
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/TerminalThemes/GhosttyThemeDirectories.swift` | `urls` 顺序改为用户目录在前、bundle 主题库在后（与 `themeSearchPaths` 同一套顺序）；`GhosttyThemeCatalog` 的「先出现者胜」去重因此让用户同名主题覆盖内置。 |
| `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Config/GhosttyConfig.swift`（续） | 新增 `isConditionalThemeValue(_:)` 与 `userThemeFileURL(forThemeName:environment:)`：后者在用户主题目录里按 `themeNameCandidates` 找可读文件，供引擎侧解析桥接用。 |
| `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/ConfigDiscovery/GhosttyConfigDiscovery.swift` | **引擎侧主题解析桥接**（验收第 5 条的关键）：vendored ghostty 引擎只搜 `~/.config/ghostty/themes` + `GHOSTTY_RESOURCES_DIR` 下的主题库，**不认识** `~/.config/cmux/themes`。`conditionalThemeOverrideConfigContents` 现在对「最后的 theme 指令」解析出的主题名（普通名与 light:/dark: 语法都覆盖）：用户主题目录命中 → 注入 `theme = <绝对路径>`（引擎直接读文件，用户文件覆盖内置同名主题）；绝对路径原值 → 不注入；未命中 → 条件语法照旧注入名字（#3459 修复），普通名不注入（引擎经 `GHOSTTY_RESOURCES_DIR` 能直接找到 bundle 库）。新增 `environment` 参数供测试固定 home。 |
| `Sources/GhosttyTerminalView.swift`（续） | `GhosttyApp.conditionalThemeOverrideConfigContents` 转发新加的 `environment` 参数；引擎加载链不变（注入发生在 `ghostty_config_load_recursive_files` 之后、`loadCmuxDefaultAppearanceConfig` 的兜底断言之前）。 |
| `cmux.xcodeproj/project.pbxproj` | 加 **folder reference** `ghostty-themes`（蓝色文件夹，`path = ghostty/themes`）挂进 Resources 组与主 app 的 Copy Bundle Resources——一次引用整个目录，不在工程里逐个列 463 个文件；Xcode 每次构建自动把 `Resources/ghostty/themes` 原样拷进 `cmux.app/Contents/Resources/ghostty/themes`。 |
| `.github/workflows/build.yml` | 打包前新增校验 step「校验 bundle 主题库完整」：bundle 内主题文件数量必须等于仓库 `Resources/ghostty/themes`，且逐文件 diff 一致；防止上游同步或工程改动让 bundle 主题库悄悄漂移。 |
| `Resources/ghostty/README.md` | 主题库来源说明（上游 cmux tag + 463 个文件 + 重新导入策略），放在 `ghostty/` 下而不是 `themes/` 内——`themes/` 里的任何普通文件都会被 `cmux themes` 当成主题列出来。 |
| `THIRD_PARTY_LICENSES.md` | 补一条「Ghostty Theme Library」：来源为上游 cmux v0.65.2.2 的 `Resources/ghostty/themes`（上游 PR #1314 引入），Ghostty 主题包为 MIT，与 GPL-3.0-or-later 兼容。 |

### 主题库来源（实测记录）

- 主题文件**不是这次新拉的**：基线 `ef4b8cf`（上游 release tag `v0.65.2.2`，commit `12023d89`）自带 `Resources/ghostty/themes` 共 **463 个文件**，由上游 commit `01a4797a`（「Bundle Ghostty themes in cmux」，PR #1314，2026-03-13）引入；本次已抽样 diff 验证与上游 v0.65.2.2 逐字节一致。缺的只是「打包进 bundle」这一步（上游工程里有，本仓库的工程引用随基线裁剪丢失，由本次 folder reference 补回）。
- 任务单里「ghostty 子模块 cb1ef70 的 themes 目录」这个出处不成立：实测该 commit 的树里没有 `themes/` 目录（ghostty-org/ghostty 的 main / v1.0.0 / v1.2.0 / v1.3.0 树也都没有）。主题包的源头是 ghostty 官方主题集（MIT，其数据源自 MIT 的 `mbadolato/iTerm2-Color-Schemes`）。文档按实测写成「上游 cmux v0.65.2.2」。

### 边界（刻意不做的部分）

- **CLI diff viewer 的默认外观不动**（`CLI/cmux_open.swift` 的 `diffViewerDefaultThemeConfigContents` 仍是亮 / 暗两套硬编码）：Issue #71 的验收范围是终端配色，diff 面板不在其中。
- **`terminal.adaptiveDefaultTheme` 的设置项与 UI 保留**，只是不再影响行为；这是 issue 的明确要求（「保留代码与设置项，默认值改为 false」），不是半途而废。
- **PR 门禁 `checks` 不改**：folder reference 的打包正确性由 `build-macos` 的新校验 step 兜底，不让轻量门禁去跑 bundle 打包。

### 验证

- `./scripts/lint-pbxproj-test-wiring.sh`、`python3 scripts/generate-cmux-config-schema.py --check`、`python3 scripts/check-latency-guardrails.py` 本机全绿。
- 本机（Intel macOS 12 / Swift 5.7）`swiftc -parse` 对本次改动的全部源码文件通过；`GhosttyConfig.swift` 与 `GhosttyTerminalView.swift` 因**既存**的 Swift 6 `nonisolated(unsafe)` 语法被 Swift 5.7 误报（改动前后都存在），Swift 6 语法正确性由 PR 门禁 `checks`（macos-26）与 `build-macos` 兜底。
- 测试更新：`GhosttyConfigManagedDefaultAppearanceTests`（开关不再门控注入、两外观同色、新增 fallback == bundle 主题文件逐字对比与 fallback 即 GitHub Dark Default 两个防漂移用例）、`GhosttyConfigAdaptiveAppearanceRegressionTests`（亮 / 暗同色断言）、`GhosttyConfigThemeParityTests`（noConfig / nonAppearanceSetting fixture 改为 GitHub Dark Default 单套快照、changesWithAppearance 改 false）、`GhosttyConfigDiscoveryThemeOverrideTests`（新增用户目录命中注入绝对路径两个用例）、`GhosttyThemeColorsTests.ordersDirectories`（用户目录在前）、`SettingCatalogTests`（adaptiveDefaultTheme 默认值断言翻转为 false）、`cmuxTests/GhosttyConfigTests`（无效 UTF-8 候选跳过、用户目录覆盖注入绝对路径、fresh-install 预览断言改为 `#0D1117`；conditional override 系列固定 home 防 flake）。
- 真机验收（装下一版后，见 `DEVELOPMENT.md` 第三节与 Issue #71 的 7 条清单）。
