# 上游输入延迟问题在本仓库的处置

记录时间：2026-11-06

关联本仓库 Issue：#10 ~ #18（共 9 条，2026-11-04 建立）

---

## 一句话结论（2026-11-06 修订）

这 9 条 Issue 是「上游 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 仍 OPEN 的输入延迟问题 / 未合并 PR」的调研记录。逐条读基线 `v0.65.2.2` 源码后能确认的只有一件事：**基线里存在若干缓解机制**（打字静默期推迟 Git 探测、并发限流、无分配十六进制编码、标题合并、预测性本地回显等），它们不等于「输入延迟已解决」。用户实际只在本地使用 cmux，没有 Cloud 每键往返这一环，因此 #14 / #15 / #17 从主线移除；真正要解决的是本地路径：后台 Git 元数据探测与输入争 CPU、每键路径上的固定开销，以及 #13 的内核 URL 检测。

本文件现在是**修复工作台**：上游状态与基线证据留作历史参照，下面「本地延迟修复进展」一节记录已落地的代码改动、测量口径与下一步。之前「9 条 Issue 已收口」的说法已撤回——收口的是调研记录，不是延迟问题。

---

## 本地延迟修复进展（2026-11-06）

用户确认延迟体感全部来自**本地**使用，没有 Cloud / 远程终端，所以 #14（Cloud 用户报告）、#15（Cloud agent TUI 每键往返）、#17（Cloud 镜像 `ble.sh`）整条从主线移除；`showTextBoxForAgents`、`ghost.bash`、Cloud 服务端目录取回都不再做，TODO 里的 T11 相应归档。

### 已落地

- **P3 — 后台 Git 探测改走 cheap 读取**（对应 #12 / #16）：`Packages/macOS/CmuxGit` 新增 `GitMetadataReadOptions`，`.sidebar` 跳过 `.git/index` 解析与逐文件 `lstat`，只读分支 / HEAD；侧栏的常规探测（启动、新建工作区 / 标签页、打字静默期后的重试、周期刷新）走 cheap，文件系统事件、分支变化、目录变化仍走 `.full` 以保留精确 dirty 状态。取舍与文件清单见 [PATCHES.md](PATCHES.md) P3。包级单测 `GitMetadataReadOptionsTests` 断言 cheap 读取对 `fileStatusReader` 的调用次数为 0。
- **包级类型检查进 PR 门禁**：`scripts/check-swift-packages.py` + `pr-checks.yml` 新 step，对改动涉及的 SwiftPM 包跑 `swift build`，CI（带完整 Xcode）再跑 `swift test`。此前门禁只做 `swiftc -parse`，包里的类型错误能一路绿到 Release 构建才暴露。本机 CommandLineTools 没有 `Testing` 模块，本地用 `--build-only`。
- **端到端延迟探针**：`scripts/measure-input-latency.py` 用 `cmux send` + `cmux read-screen` 测「发键 → 字符可见」的 p50 / p99，扣掉只读屏幕的基线耗时。它是相对 A/B 工具（改前 / 改后、自建版 / 官方版、空闲 / 忙碌），数字包含 CLI 进程、socket、PTY 回显与读屏，**不能**与高帧率录屏量到的物理按键延迟直接比较。脚本不抢焦点，用户正常打字即可采集。

### 还没有做（按依赖顺序）

1. 装自建版跑一轮探针，拿到本地延迟的数字；在此之前不再凭读代码猜每键热点（上一轮把 `isAlternateScreenActive()` 的视口序列化当热点，核对后发现已有按事件 / 按键缓存，推断不成立）。
2. 按数字改 #10 的每键路径；#13 需先拉 `ghostty/` 子模块源码定位 URL 检测是否落在每键路径；#11 改两个 shell 集成的加载 / hook 时序并补回归用例。
3. 每步走 worktree + 功能分支 + PR，包级单测与 CI 门禁全绿后合并；最后跑完整 Release 构建、发正式版、装到本机实际使用验收。

---

## Issue #45：后台负载下的按键尖峰（50–115 ms，2026-11-11）

这一节记录本仓库 Issue #45 的定位、改法与验收口径。上一节（2026-11-06）的「还没有做」第 1 条是「装自建版跑一轮探针」，用户已经跑了，数据在下面。

### 实测数据

`.12` 版本的探针日志共 584 个按键（`~/.local/state/cmux/key-latency.log`）：

| 时段 | 样本 | 结论 |
| --- | --- | --- |
| 开头冷启动 | 66.30 ms / 115.71 ms 各一例 | 冷启动首键，归 **#44**，本节不碰 |
| 中间稳定期 | p50 6~8 ms，几乎无 > 20 ms | 正常 |
| 结尾后台忙碌时 | 53.70 ms / 101.41 ms 各一例 | 本节要解决的两例 |

关键形状不是「普遍变慢」，而是**整场只有两例、都在有后台输出的时段**。任何「后台任务一直在抢 CPU」的解释都跟这个形状不符——那会表现为尖峰数量多、幅度分散。

### 定位：逐项排除后剩下的唯一候选

先按数据形状排除，再落到代码：

| 候选 | 周期 / 触发 | 为什么不是它 |
| --- | --- | --- |
| 后台 Git 元数据探测 | 启动、新建、文件事件 | 已有 0.65 s 打字静默期（探测前 + 发布前两处）与进程级限流；读取走 `.utility` detached 任务，`.sidebar` 还是 cheap 读取（P3）。解释不了「只有 2 例」 |
| 会话自动保存 | 固定 8 s | tick 是 8 s 周期的，十几分钟会有上百次；如果它是主因，样本里应该有很多 10~50 ms 的尖峰，而不是 2 例 |
| 标题刷新 | 输出驱动 | `NotificationBurstCoalescer` + churn 过滤已合并，spinner 帧走便宜路径（`stableTitle` 不变） |
| **滚动回写检查点（scrollback checkpoint）的 Ghostty 导出** | **只在有输出的终端上、60 s 一次** | **特征全部对上，见下** |

滚动回写检查点（`Sources/SessionScrollbackCheckpoint.swift`）为什么对得上：

1. **只对「有后台输出」的终端触发**：`TerminalScrollbackCheckpointActivity.hasPendingOutput` 为真才排 capture。所以它天然只出现在用户跑构建 / 流式日志的时段，静默期一次都不排——与「只在结尾后台忙碌时出现」一致。
2. **主线程同步、成本随累计输出增长**：`TerminalScrollbackCheckpointExport.begin` 调的是 `write_screen_file:copy,vt`，Ghostty 会**格式化该终端整段历史**（持 surface 锁）。4000 行 / 40 万字符的上限是在导出**之后**、由非主线程读临时文件时截断的——主线程已经付掉了整段格式化的时间。一个已经跑了几分钟构建日志的 pane，导出几十毫秒到一百多毫秒完全合理。
3. **打字静默期挡不住碰撞**：`typingQuietPeriod = 5` 是「导出**开始前**」的一次性检查（`captureNext` 里每个 capture 前查一次）。无法阻止「导出跑到一半，用户重新开始敲键」——而这正是探针会记录成一例孤立尖峰的情形。
4. **预算与退避解释了「只有 2 例」**：`mainThreadCaptureBudget = 50 ms`，超预算的终端被 `slowCaptureBackoff = 600 s` 退避。一次 53.70 ms、一次 101.41 ms，各自触发一次退避、10 分钟内不再导出该 pane——正好是整场两例、且相隔很久。

还有一条旁证：**quit / 快照路径早就改用了有界格式化**。`Sources/TerminalController.swift` 的 `readTerminalTextFromVTExportForSnapshot` 注释原文是「Use Ghostty's bounded formatter so quit does not format an unbounded history and discard most of it afterward. Keep the export path as a compatibility fallback」。也就是说「整段格式化再丢掉」这件事在快照路径上已被认定为浪费，只是检查点这条路径当时没跟上。

**诚实边界**：以上是「读代码 + 数据形状」推出的最符合候选，不是实机 profile 出来的结论（本机没有完整 Xcode、也跑不了 GUI 实测）。所以这次同时把「怎么在用户机器上证明 / 证伪」做进了探针，见下一节与「怎么判断改动生效」。

### 改法

| 文件 | 改动 |
| --- | --- |
| `Sources/AppDelegate+SessionScrollbackCheckpoint.swift` | `TerminalScrollbackCheckpointExport.begin` 先走 `readBoundedScreenTailVT(maxRows: lineLimit, maxBytes: 400_000 * 4)`（Ghostty 只在持锁期间格式化最新 N 行），失败才回退原来的 `write_screen_file:copy,vt` 临时文件路径。行尾归一化与截断仍在非主线程做 |
| `Sources/GhosttyTitleUpdateIngress.swift` | `KeyLatencyProbe` 新增 `recordActivity(_:startedAt:detail:)`：同一个日志里写 `<unixTime> <activity> <durationMs> [detail]` 的 span 行；新增 `KeyLatencyMainTurnMonitor`（只在探针开启时安装的 runloop 观察者），主线程单回合 ≥ 20 ms 记一行 `mainTurn` |
| `Sources/SessionScrollbackCheckpoint.swift` | 每次导出记一行 `scrollbackExport`（超过 50 ms 预算时带 `overBudget=1`） |
| `Sources/SessionAutosaveCoordinator.swift` | 每个 autosave tick 记一行 `sessionAutosave`（带 `source=`） |
| `Sources/AppDelegate.swift` | `didFinishLaunching` 里安装主线程回合监视器（探针未开启时立即返回） |
| `scripts/analyze-key-latency.py` | 把尖峰与重叠的 span 对起来；没有 span 覆盖的尖峰判为「不是 cmux 主线程自己忙」，直接指向 `sample` / `spindump` |
| `scripts/check-latency-guardrails.py` | 新增一组守卫：检查点导出必须走有界格式化，防以后 rebase 掉 |

保留的行为：每次 checkpoint 仍然最多 `maxCapturesPerCheckpoint = 3` 个导出、仍然一次 main-queue turn 只做一个、仍然超预算就退避 600 s、仍然要求 5 s 打字静默；导出内容仍是「最新 ~4000 行 VT 文本」，与 quit 快照同口径。

### 用户在本机怎么采（Release 版同样生效）

```bash
# 1. 打开探针（重启 cmux 生效；注意是退出 app 再打开，不要 kill 进程）
defaults write com.xhqing.cmux cmuxKeyLatencyProbe -bool true

# 2. 正常用几小时（建议挑「会在别的 pane 跑构建 / 长任务」的时段，那正是要抓的场景）
#    日志：~/.local/state/cmux/key-latency.log
tail -f ~/.local/state/cmux/key-latency.log

# 3. 采集完关掉（这一步别忘：探针开着一键一行日志）
defaults delete com.xhqing.cmux cmuxKeyLatencyProbe
```

`CMUX_KEY_LATENCY_PROBE=1` 环境变量启动同样生效，适合只想采一次的场景。

日志现在有两种行（同一个文件、按第一列时间排序）：

```
<unixTime> keyDown  <delayMs> <keyCode> <isRepeat>   每个按键一行
<unixTime> <activity> <durationMs> [detail]          每个后台 span 一行
```

span 覆盖的时间窗是 `[unixTime - durationMs, unixTime]`。`activity` 目前有三种：`mainTurn`（主线程单回合 ≥ 20 ms）、`scrollbackExport`（一次检查点导出的主线程耗时）、`sessionAutosave`（一次自动保存 tick）。

### 怎么判断改动生效

```bash
python3 scripts/analyze-key-latency.py ~/.local/state/cmux/key-latency.log
```

判定标准（后台忙碌时段，即日志里存在 `scrollbackExport` / `sessionAutosave` 行的那段）：

| 指标 | 改前 | 改后通过线 |
| --- | --- | --- |
| `keyDown` ≥ 30 ms 的样本数 | 2（53.70 / 101.41） | **0**（冷启动首键属 #44，按第一分钟排除） |
| `keyDown` p99 | 101.41 ms | **< 20 ms** |
| `keyDown` p50 | 6~8 ms | 不回退（仍 6~8 ms） |
| `scrollbackExport` 单次耗时 | 可达 50~120 ms | **≤ 约 20 ms**，且不再出现 `overBudget=1` |
| 无 span 覆盖的 ≥ 30 ms 尖峰 | 2 | 0；若仍有，按下一节抓 `sample` |

判读规则：

- 尖峰的时间点落在某个 span 的窗口内 → 这次就是那个后台任务造成的，看 span 名就知道是哪类；
- 尖峰**没有**任何 span 覆盖，但同时间有一条 `mainTurn` → 主线程在跑没被插桩的代码（例如 SwiftUI 布局、Ghostty 渲染），下一步该去 profile 那段；
- 尖峰**连 `mainTurn` 都没有** → 主线程当时是空闲的，事件是在进 app 之前就被拖住了（别的进程占满 CPU、窗口服务器、键盘链路），改 cmux 代码没用。

最后一种情况怎么抓主线程现场（用户机器上，ad-hoc 版不需要调试权限）：

```bash
# 连续抓 5 秒堆栈；尖峰反复出现时连抓几次更有用
sample $(pgrep -f 'cmux.app/Contents/MacOS/cmux' | head -1) 5 -file /tmp/cmux-sample.txt
# 重量级但能抓到「谁在等谁」
spindump -o /tmp/cmux-spindump.txt $(pgrep -f 'cmux.app/Contents/MacOS/cmux' | head -1)
```

抓的时候记下墙上时间（`date +%T`），回来和日志第一列对齐即可。

### 与 Issue #44 的分工

冷启动首键（66.30 / 115.71 ms）不在这里处理：那是首次按键时 surface / 输入法 / 渲染首次初始化的一次性成本，另一个 Worker 在 `fix/keystroke-cold-first-key` 上做。两边都碰 `KeyLatencyProbe` 附近，但改的是不同函数（本节只**新增** `recordActivity` 与回合监视器，没动 `record(event:phase:)` 的行为）。

---

## 先说清楚这 9 条 Issue 是什么

它们不是本仓库的 bug 报告，而是 2026-11-04 对上游做的一次调研记录：用多组关键词扫上游 Issue 与 PR，筛出「coding-agent 的 TUI 输入框打字延迟」及其直接根因，逐条记下上游编号、状态、实测数据和「本地意义」。#18 是汇总，#10 ~ #17 是其中单独建条目的上游项（7 条 Issue + 2 条未合并 PR）。

这批记录里最关键的判断写在 #18 末尾：「上游没有已合入、能覆盖 coding-agent TUI 输入框打字延迟的完整修复，本 fork 若要自己解决，需要按 #25089 的方案 2 或方案 1 动手」。**这句话对上游成立，对本仓库基线不一定成立**——因为调研比的是「上游 Issue / PR 的合并状态」，而本仓库用的是一个具体的 release tag，那里面已经含了许多并未回填到这些老 Issue 的修复。这次核实就是把两者分开。

## 核实方法与边界

- **本仓库状态以源码为准**：逐条读相关 Swift / shell 文件，确认代码真的在、并且行为符合描述；文件与标识符在下文逐条列出。[CHANGELOG.md](CHANGELOG.md) 里的已合并 PR 号作旁证（例如 `#8084`、`#13967`、`#20238`）。
- **上游状态以 Issue 正文为准**：调研记录的时间点是 2026-11-04，本文不重新断言上游今天的状态。
- **等价实现不等于 PR 已合并**：下文说「已解决」时，指的是「这个根因在本仓库基线里已经被处理」，不是「上游那条 PR 被合了」。两者的差别很重要，将来同步上游 tag 时要按代码比对，不能按 Issue 状态推断。
- **本仓库验证不了的事，不硬下结论**：
  - 「按键 → 屏幕出现字符」的毫秒数只能在装好的 app 上量，静态读代码量不出来；
  - Cloud VM 的镜像、`ble.sh`、`ghost.bash`、devbox 验证脚本属于服务端，本仓库已剥离；
  - Ghostty 内核在本仓库是预编译的 `GhosttyKit.xcframework`（`ghostty/` 子模块不参与 app 构建），URL / 链接匹配这类内核行为无法从这里读源码定位。
- 结论只针对当前基线 `v0.65.2.2`。按 [SYNC.md](SYNC.md) 升级基线后，要重跑守卫脚本并复核本文。

---

## 逐条处置

### #10 —［上游 #1519］输入延迟总账（125 ms vs 80 ms）

- **上游记录**：0.6.2 版本用慢动作录屏量到 Ghostty 约 80 ms、cmux 约 125 ms；维护者 2026-09-25 说输入延迟工作由 #7399 跟踪且「已经收尾」，但 #1519 仍 OPEN，没人贴重测数字。
- **本仓库证据**：基线 `0.65.2.2` 比 0.6.2 晚得多，主线程输入路径上的修复已经进了 CHANGELOG 的已合并 PR 条目——`#8084` / `#8155`（title-churn 打字延迟）、`#20238`（标签栏每次渲染的挂起）、`#12521`（工作区与 portal 变动时的 SwiftUI 重排主线程挂起）、`#5857`（离屏 renderer GPU 内存回收）。代码侧还有输入时间戳 `SessionAutosaveCoordinator.lastTypingActivityAt`（`Sources/SessionAutosaveCoordinator.swift:194`），后台工作靠它判断「现在是不是在打字」。
- **结论**：本仓库不存在「等 #7399 合入」这件事；125 ms 是上游 0.6.2 的旧数据，不能拿来判定 0.65.2.2 的现状。这条 Issue 的剩余动作是**实机复测**（方法见「剩余缺口」一节），不是改代码。
- **边界**：没有复测数字，就不能说「本仓库的输入延迟已经和 Ghostty 一样快」；只能说已知的主线程根因已修、没有证据表明还缺某个具体修复。

### #11 —［上游 #2195］cmux 与 ghostty 两个 shell 集成同时开启时间歇卡顿

- **上游记录**：`CMUX_SHELL_INTEGRATION` 与 `CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION` 双开时，`ls` / `cd` 偶发 100 ms 以上延迟；报告者说最新 nightly 不复现，稳定版仍可复现，属于「修复存在但未随稳定版发布」。
- **本仓库证据**：`Resources/shell-integration/cmux-zsh-integration.zsh` 里已经有一整套针对双开时序的收敛：
  - `_cmux_patch_ghostty_job_table_guard()`（约 903 行）给 Ghostty 的 `_ghostty_precmd` / `_ghostty_preexec` / 三个 ZLE hook 前置了 `_cmux_zsh_job_table_saturated` 守卫，job 表饱和时直接返回，避免 hook 高峰期抢输入；
  - 同文件开头用 `zmodload zsh/zselect` 做**不 fork 进程**的等待（`_cmux_sleep_cs`），注释写明「vs ~1 fork+exec of /bin/sleep per second per pane」；
  - `_cmux_send` 用 `/usr/bin/nc -U -w` 保序且有超时上限（约 80 行起），并说明为什么不能用 Homebrew 的 nc；
  - `CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION` 在 tmux 环境同步白名单里（约 668 行）。
- **结论**：上游描述的「两个集成的 concurrent `precmd` / `preexec` 抢输入」这条因果链，在基线里已经通过「守卫 + 免 fork + 保序」处理过；本仓库没有待移植的稳定版缺口。
- **边界**：这是**静态读代码的结论**，不是实测「双开后 `ls` 不再卡」。若要在本机确认，按 Issue #11 的隔离方法（分别单开 / 双开、重复敲基础命令）跑一遍即可，不需要改代码。

### #12 —［上游 #4705］工作区 Git 元数据探测抢 CPU 造成打字延迟

- **上游记录**：采样显示 cmux 138% CPU、1.23 GB RSS，热点是 `beginWorkspaceGitMetadataProbeAttempt` → `initialWorkspaceGitMetadataSnapshot` → `gitIndexSnapshot`；建议四条修复方向（打字期间禁止 / 防抖 Git 刷新、换掉 `String(format:)` 十六进制循环、限制并发探测、休眠隐藏 renderer）；直接修复 PR `#4707` 已关闭未合并。
- **本仓库证据**（四条建议逐条对上）：
  1. **打字静默期让路**：`Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+Probe.swift` 定义 `terminalTypingQuietInterval = 0.65`，`beginWorkspaceGitMetadataProbeAttempt`（107 行）与 `applyWorkspaceGitMetadataSnapshotBatch`（232 行）两处都检查 `host?.terminalTypingIsActive(within:)`：正在打字就把探测推迟（reason `terminalTypingDeferred`），连「打字前已放行、打字中才读完」的快照也压住不发布侧栏状态；`Sources/TabManager+SidebarGitHosting.swift:196` 从 `AppDelegate.lastTypingActivityAt` 算剩余静默时间。这正是 `#4707` 的核心机制。
  2. **无分配十六进制编码**：`Packages/macOS/CmuxGit/Sources/CmuxGit/Parsing/GitMetadataService+Index.swift:19` 的 `gitIndexHexAlphabet` 在 308 ~ 318 行直接按字节查表写缓冲区，没有 `String(format:)` 循环。
  3. **并发探测限流**：`.../Scheduling/WorkspaceGitMetadataProbeLimiter.swift` 是进程级 `actor` 许可池，`Sources/TabManager.swift:561` 以 `limit: 2` 注入每个窗口的服务，探测任务先 `probeLimiter.acquire()` 才读快照。
  4. **隐藏 renderer / 标题抖动**：CHANGELOG 里 `#5857`（离屏 renderer GPU 内存回收）、`#8998`（隐藏 Ghostty renderer 内存回收）、`#7496` / `#7050`（内存压力时协同回收隐藏 renderer）几条已合并 PR 的条目；`Sources/DockSplitStore.swift` 的 `enqueueTerminalTitleUpdate` 走 `NotificationBurstCoalescer`（`Sources/PanelTitleUpdateCoalescingSettings.swift` 控制延迟），高频标题变化不会每次都唤醒侧栏刷新。
- **结论**：**已解决**。上游那条被关闭的 PR 不必移植——同一套机制已在基线里，再叠一遍会变成两套互相打架的调度。
- **边界**：这些是上游 PR `#4707` / `#5665` 要达成的**效果**，不是它们的 diff；将来 rebase 到新上游 tag 时，要看代码有没有被上游的别的实现替换，而不是看 PR 状态。守卫脚本 `check-latency-guardrails.py` 就是为这个加的。

### #13 —［上游 #17136］输入 `python3 -m http.` 时类 URL 前缀引发停顿

- **上游记录**：逐字敲 `python3 -m http.` 在句点附近明显停顿，随机标点文本不卡，Freestyle VM 终端里流畅；怀疑是 URL / 链接检测被激活，建议 profile 本地终端路径并加回归测试。
- **本仓库证据**：本仓库里能读到的链接相关代码都不是每键路径——`Sources/GhosttyNSView+LinkContextMenu.swift` 的链接菜单只在「按住链接修饰键的右键 / 悬停」时构造，注释明确说「There is no fallback to the word under the pointer」；`Sources/TerminalLinkOpenRequest.swift` 处理 OSC 8 链接的打开请求。真正的「屏幕文本里哪些字符算 URL」由 Ghostty 内核决定，而内核在本仓库是预编译 xcframework，没有源码可读。
- **结论**：**本仓库范围内无法定位这条的根因**，因此不做猜测性改动。Issue 正文里「建议加针对性回归测试」的前提是先 profile 出热点；在没定位之前写测试，只会把「当前行为」固化成断言，反而挡住以后的修复。
- **边界**：不能据此断言本仓库没有这个现象。要推进这条，需要在装好的 app 上按复现步骤录一次 profile（见「剩余缺口」），确认停顿落在内核的 URL 匹配、shell 补全还是 cmux 的输入转发，再决定动哪一层。

### #14 —［上游 #20778］Cloud terminal 打字卡（用户报告）

- **上游记录**：一条 Discord 用户反馈「testing cloud terminal its laggy when typing in it」，没有版本号、环境、复现数据，上游当作待补信息的报告留着。
- **本仓库边界**：本仓库保留的是 macOS app 侧的 Cloud 客户端代码（`Sources/Cloud/`、`CLI/CMUXCLI+CloudDomains.swift` 等），Cloud VM 的镜像、shell 初始化脚本、服务端终端链路都在 2026-11-02 剥离非 macOS 内容时删掉了（见 [DEVELOPMENT.md](DEVELOPMENT.md)「零、本仓库的形态」）。没有服务端代码，就没有可改的对象。
- **结论**：**本仓库范围内不适用**。但用户侧有立即可用的缓解：预测性本地回显（`terminal.predictiveLocalEcho`，默认开）覆盖远程 shell，TextBox 系列设置覆盖「把整段提示词在本地敲完再提交」，见下节。
- **边界**：这不是说 Cloud 打字已经不卡了，而是说这条报告缺数据、且它的服务端部分不在本仓库；要判断现状得用户提供本仓库自建版 + Cloud 环境的实测。

### #15 —［上游 #25089］Cloud 上 agent TUI 每键等一次完整往返

- **上游记录**：Cloud 机器空闲时，往 Claude Code / Codex 输入框敲字，每个字符要等约 200 ms 往返；预测性本地回显（`#13914` / `#13967`）按设计对 raw mode 与 alternate screen 关闭，而 agent TUI 恰好属于这类；提出的三个方案是「agent 输入框内做预测」「agent 空闲时自动显示并聚焦 TextBox」「原生 agent pane 跑在 Cloud 上」。
- **本仓库证据**：
  - 预测性本地回显**确实在基线里**（CHANGELOG 里 `#13967` / `#14860` / `#15217` 的条目，默认开、可用 `terminal.predictiveLocalEcho` 关闭；设置键定义在 `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/TerminalCatalogSection.swift:125`）；`Packages/Shared/CmuxTerminalPrediction/Sources/CmuxTerminalPrediction/TerminalPredictionEngine.swift` 的 `status(at:)` 顺序是「只对远程 surface 生效 → `if isAlternateScreen { return .alternateScreen }`」，与上游描述的限制完全一致。
  - **方案 2 的粗粒度版本已经可用**：`TerminalCatalogSection.swift:220` / `:226` 有 `terminal.showTextBoxOnNewTerminals` 与 `terminal.focusTextBoxOnNewTerminals`，`Sources/Workspace.swift:5093` 的 `configureNewTerminalPanel` 会据此调用 `TerminalPanel.preferTextBoxInputWhenActivated()` / `showTextBoxInputWhenAvailable()`（`Sources/Panels/TerminalPanel.swift:277`、`:286`）。打开后新建终端自动显示并聚焦 TextBox，提示词在本地输入框里敲完再提交，**打字过程不按字符等往返**；快捷键 Cmd+Shift+A 也能随时手动开关。
  - 上游嫌这个粗粒度版本「连本地终端一起打开」，所以方案 2 想要的是「只对远程 / Cloud 的 agent 终端、且 agent 空闲时」才自动显示——这个**精确版本本仓库还没有**（`rg showTextBoxForAgents` 无结果）。
- **结论**：**部分解决，且给出了零延迟的可用路径**。精确版登记为 [TODO.md](TODO.md) 的 T11，不属于本次的代码改动，理由见「为什么没有新增 Swift 逻辑」。
- **边界**：TextBox 提交提示词时仍要走一次往返，省掉的是逐字符等待；此外预测性回显不会、也不应该在 alternate screen 的 agent TUI 里乱画字符。

### #16 —［上游 PR #5665］大仓库里降低 CPU 占用与打字延迟（未合并）

- **上游记录**：33 个文件、`+1812 / -1002`，核心是给 Git 元数据读取加 `GitMetadataReadOptions` 的 cheap 模式，让侧栏只读便宜的分支 / HEAD / ref，顺带减少自动保存、窗口标题、spinner 标题通知等空闲抖动；仍 OPEN，`review: needs-attention`。
- **本仓库证据**：`rg GitMetadataReadOptions|cheapMode` 无结果——**cheap 模式这套抽象确实没有**。但这条 PR 针对的因果链（后台 Git 刷新与打字争 CPU）已经由 #12 里那套「打字静默期推迟 + 进程级限流 + 无分配索引解析」覆盖；它顺带想减的标题抖动，基线有 `PanelTitleUpdateCoalescingSettings` 与 `NotificationBurstCoalescer`（`Sources/DockSplitStore.swift:1307` 起）做合并与抑制。
- **结论**：**核心诉求已解决，不移植**。为一个已经解决的问题引入 33 文件的第二套元数据读取路径，会让「侧栏显示的 dirty 状态」出现两种口径，得不偿失。
- **边界**：cheap 模式还带一个「刻意牺牲 dirty / index 精度换响应速度」的取舍，本仓库没有做这个取舍，也就不存在精度下降；将来若在大仓库实测侧栏刷新仍慢，再单独评估，别顺手把整套 PR 搬进来。

### #17 —［上游 PR #20529］用 readline ghost text 替换 Cloud shell 的 `ble.sh`（未合并）

- **上游记录**：24 个文件、`+2947 / -352`，把 Cloud VM 每个 shell 加载的 `ble.sh` 换成 `cmux-ghost.bash`，改 Dockerfile、Freestyle bake、`verify-devbox-image.ts` 的 PTY 验证；实测 5 万条历史时 p50 从 21.6 ms 降到 2.2 ms。作者与评论者都确认它**不覆盖 agent TUI 输入框**。
- **本仓库边界**：`find` / `rg` 确认本仓库没有 `ble.sh`、`ghost.bash`、Dockerfile 或 devbox 镜像验证脚本；`ble.sh` 字样只出现在上游 CHANGELOG 与随包 skills 文档里，是历史叙述而非可运行代码。这些文件都在已剥离的服务端目录里。
- **结论**：**本仓库范围内不适用**。没有 Cloud 镜像可以改，也没有需要替换的 shell 行编辑器。
- **边界**：这条 PR 的价值（Cloud shell 侧延迟）与 #15（Cloud agent TUI 侧延迟）是两件事；作者本人也说了它不解决 agent 输入框。不要因为「上游 PR 没合并」就把它算成本仓库的缺口。

### #18 —［汇总］上游输入延迟问题与未合并 PR 清单

- **记录内容**：筛选口径、已单独建条目的 8 条、根因类 7 条、其它未合并 PR 5 条、已确认解决的 9 条，以及末尾结论。
- **需要修正的地方**：末尾结论「上游没有已合入、能覆盖 coding-agent TUI 输入框打字延迟的完整修复；本 fork 要自己动手」这句，**对上游仓库是对的，对本仓库基线是不完整的**——它比的是上游 Issue / PR 状态，没读基线代码。本文件（以及守卫脚本）补上了这一层：「上游未合并」与「本仓库未修复」是两件事；本仓库实际状态以源码为准，见 #12 / #16 / #15 三段。
- **结论**：**调研目的已达成并落档**。汇总本身继续留作上游状态的历史快照（2026-11-04），不再作为「本仓库待办清单」使用；需要动作的事项已经分流到 [TODO.md](TODO.md) 与本文「剩余缺口」一节，避免同一件事在 Issue 和 TODO 两处挂着。

---

## 本仓库已落地的输入延迟防护（证据清单）

> 下面的源码行号以 2026-11-06 的基线为准，只用来快速定位；按 [SYNC.md](SYNC.md) 升级基线后，请按标识符（函数名 / 设置键 / PR 号）复核，不要按行号。

| 防护 | 代码位置 | 对应上游条目 |
| --- | --- | --- |
| 打字静默期推迟工作区 Git 探测（两处：探测开始前、快照发布前） | `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+Probe.swift:10, 107, 232` | #4705 / PR #4707 |
| 进程级 Git 探测并发限流（`limit: 2`） | `.../Scheduling/WorkspaceGitMetadataProbeLimiter.swift`、`Sources/TabManager.swift:561` | #4705 建议 3 |
| Git 索引对象 ID 的查表式十六进制编码 | `Packages/macOS/CmuxGit/Sources/CmuxGit/Parsing/GitMetadataService+Index.swift:19, 308` | #4705 建议 2 |
| 输入时间戳（后台工作判断「正在打字」） | `Sources/SessionAutosaveCoordinator.swift:194`、`Sources/TabManager+SidebarGitHosting.swift:196` | #4705 / 打字静默期机制 |
| 终端标题高频变化合并、spinner 通知抑制 | `Sources/DockSplitStore.swift:1307`、`Sources/PanelTitleUpdateCoalescingSettings.swift` | #6599 / #8084 / PR #5665 顺带项 |
| 远程终端预测性本地回显（默认开，排除本地 / alternate screen） | `Packages/Shared/CmuxTerminalPrediction/Sources/CmuxTerminalPrediction/TerminalPredictionEngine.swift` 的 `status(at:)`、`TerminalCatalogSection.swift:125` | #13914 / #13967 / #15217、#25089 |
| TextBox 自动显示 / 聚焦（新建终端）与 Cmd+Shift+A 手动开关 | `TerminalCatalogSection.swift:220, 226`、`Sources/Workspace.swift:5093`、`Sources/Panels/TerminalPanel.swift:277, 286` | #25089 方案 2 的粗粒度版本 |
| shell 集成双开时的 hook 饱和守卫、免 fork 等待、socket 保序 | `Resources/shell-integration/cmux-zsh-integration.zsh:19, 76, 903` | #2195 |
| 滚动回写检查点导出改走有界格式化（不再在主线程格式化整段历史） | `Sources/AppDelegate+SessionScrollbackCheckpoint.swift` 的 `TerminalScrollbackCheckpointExport.begin`、`Packages/macOS/CmuxTerminal/.../TerminalSurface+TextCapture.swift` 的 `readBoundedScreenTailVT` | 本仓库 Issue #45 |
| 探针日志带后台 span（`mainTurn` / `scrollbackExport` / `sessionAutosave`） | `Sources/GhosttyTitleUpdateIngress.swift` 的 `KeyLatencyProbe.recordActivity`、`scripts/analyze-key-latency.py` | 本仓库 Issue #45 |
| 隐藏 renderer 内存回收、主线程视图与标签栏路径修复 | CHANGELOG 中 `#20238` / `#12521` / `#8998` / `#7496` / `#5857` 的已合并 PR 条目 | #1519 / #4705 建议 4 |

---

## 立即可用的配置（远程 / Cloud 打字）

这几项都是基线自带的能力，不需要改代码；设置页、`cmux.json` 或 `defaults` 均可设置。

1. **`terminal.predictiveLocalEcho`（默认开）**：远程 shell 上敲的字符立刻在本地显示、加下划线，远端确认后取消下划线；只对远程 surface 生效，本地终端、密码提示、全屏应用（含 agent TUI）自动排除。它解决的是「远程 shell 每键等往返」，不是 agent 输入框。
2. **`terminal.showTextBoxOnNewTerminals` + `terminal.focusTextBoxOnNewTerminals`**：打开后新建终端自动显示并聚焦 TextBox。Cloud 上把提示词写在本地输入框里，整段提交，**打字过程不逐字符等往返**；代价是本地新建的终端也会自动打开 TextBox（这正是 #25089 方案 2 想做「只对远程 agent 生效」的原因）。
3. **Cmd+Shift+A**：任意终端随时手动开关 TextBox，适合只在 Cloud 工作区用、不想全局改设置的情况。

> 严谨地说：TextBox 省掉的是**逐字符**的往返，提交整段提示词时仍有一次往返；predictiveLocalEcho 同理，它预测的是 cooked-mode shell 的回显，不会在 alternate screen 的 agent TUI 里替远端画字符。

---

## 剩余缺口与边界

1. **精确版「agent 空闲时自动显示 TextBox」未实现**（#15 / #18 方案 2）：需要新增一个「只对远程 agent 终端、且 agent hook 报告 idle / needsInput 时自动显示并聚焦 TextBox」的设置。已登记为 [TODO.md](TODO.md) 的 T11，含挂点与验收要点。
2. **#10 的实机复测没做**：静态读代码量不出毫秒数。方法：装好本仓库自建版（隔离 bundle id，可与官方版并行），用 Is It Snappy 之类高帧率录屏，同一键盘、同一时间窗口分别量「按键 → 字符出现」的本仓库版与原生 Ghostty，记录版本号、键盘连接方式（蓝牙键盘本身约 30 ms）、是否开了大量工作区。数字出来之前，不要写「延迟已经追平」这类结论。
3. **#13 需要先 profile 再谈修复**：复现 `python3 -m http.`，用 Instruments 分别看 Ghostty 内核的 URL 匹配、shell 补全、cmux 输入转发三段的耗时，定位后再决定动哪一层；本仓库目前没有内核源码可改。
4. **Cloud 服务端不在本仓库**（#14 / #17）：镜像里的 `ble.sh`、guest prompt 推送、Cloud 终端链路都属于上游服务端代码，本仓库已剥离，改不了也不该在这里改。
5. **基线升级时复核**：按 [SYNC.md](SYNC.md) 跟新上游 tag 后，先跑 `python3 scripts/check-latency-guardrails.py`，再按本文的证据清单比对新代码——上游可能用别的实现替换掉这些守卫，那时要么更新守卫脚本检查的模式，要么确认新实现等价，不能只看 PR 合并状态。

---

## 为什么没有直接移植上游 PR / 新增 Swift 逻辑

- **会叠两套语义**：#12 / #16 要解决的问题，基线已经用「打字静默期 + 限流 + 查表编码」解决了；把上游 PR 再搬进来等于同一条路径跑两套调度，风险比收益大。
- **编译验证条件不具备**：本机与 macmini 都只装了 CommandLineTools，没有完整 Xcode（见 [TODO.md](TODO.md) T10）；PR 门禁 `checks` 只做 Swift 语法解析、配置 schema、输入延迟防护守卫、pbxproj 接线与密钥扫描，不做类型检查，完整编译只在 `build-macos` 的 Release 构建里跑（约 1.5 小时）。在这种条件下往 app 里塞新的 Swift 逻辑，语法过了但类型没过，会把坏代码合进 main 并留到下一次正式发版才暴露。T11 的实现应该等 T10（把单测接进 CI）落地、或至少有一次干净的完整构建可用之后再动手。
- **Cloud 场景的服务端代码已剥离**，没有可移植的目标。
- 因此本次改动只碰**文档 + 可被本机直接跑通的回归守卫脚本**，属于不触碰 app 运行行为的杂事；关闭 9 条 Issue 的依据是「逐条核实并给出处置」，不是「输入延迟都修好了」。

---

## 回归防护：守卫脚本

`scripts/check-latency-guardrails.py` 在 PR 门禁 `checks` 里作为一步运行：静态检查上面「证据清单」里的关键守卫是否还在（打字静默期两处判断、Git 探测限流、查表编码、标题合并、预测回显的 alternate-screen 排除、TextBox 设置、shell 集成守卫、输入时间戳、滚动回写导出走有界格式化）。检查前会去掉注释，避免「注释里还写着、代码已经删了」造成假绿。

**它防的是什么**：按 [SYNC.md](SYNC.md) 同步上游新 tag 时，上游可能重构这些路径、把守卫悄悄换掉或删掉；这些防护本身不产生可见功能，回归了不会有人立刻发现，只会在「打字又变卡」时才被察觉。脚本让 PR 直接变红，把回归拦在合并前。

**它不防什么**：它检查的是「代码中有没有这些机制」，不验证机制实际生效，也不测毫秒数。行为验证靠单测（待 T10 接入 CI）与实机复测（见「剩余缺口」）。它是下限防线，不是性能基准。
