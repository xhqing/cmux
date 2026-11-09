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
