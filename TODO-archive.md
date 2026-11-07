# TODO 归档

已处理的条目按完成时间倒序归档。编号不复用。


- ✅ **已转移** **T12** 按实测数字改本地每键路径（记录：2026-11-06 18:46）（转移：2026-11-07 15:05）
  **转移理由**：CLI 端到端与按键延迟数据都已采到（584 键 / 235.8 秒，p50 9.15 ms / p99 35.48 ms，稳定期 6~8 ms），剩余工作已按实测结果拆成 GitHub Issue：#44（首次按键 66~115 ms 冷启动）、#45（后台忙碌时 50~115 ms 尖峰）；另有两个新发现单独建条：#43（`com.xhqing.cmux` 身份下控制 socket 不监听）、#46（构建产物 `LSEnvironment` 写死 CI runner 的 home）。原条目正文保留如下。
  **背景（原条目）**：P3 只削掉了后台 Git 探测的 CPU 争用；本地「按键 → 字符出现」的每键路径开销还没有数字。上一轮靠读代码猜的 `isAlternateScreenActive()` 视口序列化热点已被证伪（快捷键路径有按事件缓存、文本编辑手势有按按键缓存），不能再凭静态阅读动刀。
  **要做什么（原条目）**：装自建版跑 `python3 scripts/measure-input-latency.py --surface <id> --samples 40`，拿到 p50 / p99 与读屏基线；再按数字定位每键热点（快捷键判定、 `NSWindow.sendEvent` swizzle、焦点修复、通知清除、IME 解释、Ghostty 渲染），只改实测热点。#13 先拉 `ghostty/` 子模块源码定位 URL 检测是否落在每键路径；#11 改两个 shell 集成的加载 / hook 时序并补回归用例。
  **边界（原条目）**：测量脚本是相对 A/B 工具（改前 / 改后、空闲 / 忙碌、自建版 / 官方版），数字含 CLI / socket / 读屏开销，不能与物理按键录屏的绝对数字直接比较。每步改动走 worktree + 功能分支 + PR，包级单测与 CI 门禁全绿后合并；详见 `LATENCY.md`。

## 已放弃

- ✅ **已放弃** **T11** 实现「agent 空闲时自动显示 / 聚焦 TextBox」的精确版（上游 #25089 方案 2，对应本仓库 Issue #15 / #18）：新增一个只在「远程 / Cloud 终端 + agent hook 报告 idle / needsInput」时生效的设置，避免现有 `terminal.showTextBoxOnNewTerminals` 连本地终端一起打开的副作用（记录：2026-11-06 16:32）（放弃：2026-11-06 18:46）
  **放弃理由**：用户确认延迟体感全部来自本地使用 cmux，没有用 Cloud 版，不存在「Cloud 上 agent TUI 每键等一次完整往返」这个场景；#14 / #15 / #17 已从主线移除，精确版 TextBox 自动化随之失去目标。原条目正文、已核实的代码挂点保留在这里，以备将来真的接 Cloud 时复用。另注：原「开工条件」里写的「PR 门禁只做语法解析、不做类型检查」已于 2026-11-06 由包级 `swift build` / `swift test` 门禁改变，该理由不再成立，但不影响本条的放弃结论。
  **背景（原条目）**：Cloud 上 agent TUI 每键等一次完整往返，预测性本地回显按设计不覆盖 alternate screen；本仓库基线已有粗粒度版本（两个 TextBox 设置 + Cmd+Shift+A），把整段提示词在本地 TextBox 敲完再提交即可绕开逐字符延迟。精确版要补的是「只对远程 agent、且只在空闲时」的自动化。
  **挂点（原条目，已核实）**：设置目录 `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/TerminalCatalogSection.swift`（照 `showTextBoxOnNewTerminals` 加 `DefaultsKey`）；运行时 `Sources/Workspace+AgentLifecycle.swift` 的 `setAgentLifecycle(key:panelId:lifecycle:)` 在状态变 `.idle` / `.needsInput` 时判断 `Workspace.isRemoteTerminalSurface(panelId)`，再调 `Sources/Panels/TerminalPanel.swift` 的 `preferTextBoxInputWhenActivated()`；设置页 `TextBoxSection.swift`、配置 schema / 搜索索引 / JSON 路径支持照现有键补齐。默认必须关闭，不能抢本地终端焦点。

## 已完成

- ✅ **已完成** **T2** 自建版并行安装后验证 P1 的真实行为（记录：2026-10-31 22:30）：用户实测第 1 条「关掉跑着 pi 的工作区不再弹窗」通过；其余两条（设置页开关打开后恢复提示、"Don't ask again" 勾选生效）用户明确表示不需要验收（第 2 条不在乎、第 3 条场景已不存在）。P1 随后续版本发布。（完成：2026-11-04 14:45）
- ✅ **已完成** **T8** 新仓库首次 CI 构建复验（记录：2026-11-02 18:10）：剥离后实跑 `build-macos`（arm64）全绿，run 41469693363 产出 107MB 产物，`校验 Sparkle / 打包 / 上传产物` 三步都 success —— 说明只留 macOS 构建闭包没有打断编译链。（完成：2026-11-03 07:10）
- ✅ **已完成** **T7** 新仓库的 Actions 与 required check（记录：2026-11-02 18:10）：重建后 Actions 直接可用（`build-macos` / `PR Checks` 均 active，旧 fork 那个「HTTP 422 Actions 被禁用」的状态随之消失），`PR Checks` 在 push 与 PR 上都能跑且已绿；`main` 保护已按旧仓库存档重设，并加上 required status check `checks`（strict）+ enforce admins。（完成：2026-11-03 07:15）
- ✅ **已完成** **T6** CI 注入 `MARKETING_VERSION`（原记录：2026-11-01 02:40）：根因不是注入写法，而是 `scripts/reloads.sh` 从没把 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 这类**环境变量翻成 xcodebuild 的构建设置**——xcodebuild 只认命令行参数，所以 Info.plist 里一直还是工程硬编码的 `0.65.2`。已在 `reloads.sh` 里统一转发 `ARCHS / ONLY_ACTIVE_ARCH / MARKETING_VERSION / CURRENT_PROJECT_VERSION / COMPILER_INDEX_STORE_ENABLE`（同一处 bug 还让「只编 arm64」静默失效，一并修掉）。（完成：2026-11-02 23:10）
- ✅ **已完成** **T1** CI 流水线首次跑通：`build-macos` workflow 在 `macos-26` runner 上完整构建出 Release app 并产出可用 zip（记录：2026-10-31 22:30）（完成：2026-11-01 02:31，run 41211029928 全绿，产物 211MB、ad-hoc 签名、sha256 校验通过）
