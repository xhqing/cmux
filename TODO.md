# TODO

本仓库的活跃待办。已处理的条目移入 [TODO-archive.md](TODO-archive.md)；超低频备忘放 [MEMO.md](MEMO.md)。

## 🟠 橙色（边界情况、防护缺口，可能演化为实际问题）

- [ ] **T13** `unit-tests` 全量在 CI 上的 flake / 挂死面收口（记录：2026-11-24 03:11）
  **现状**：codex 那条调度竞态用例（`coordinationContentionResolvesWithinOneWaitingRequest`）已修（PR #128，两度实测转绿）；两条 Cloud 用例的轮询预算已放宽到 30s（PR #129）。但同一时期的全量仍有第三条不同的用例红，每次还不是同一条：r26 / r29 rerun 是 `CloudPortRoutePlanTests.stopDuringStart`，修复后 main（run 44688219519）是 `CloudDesktopNavigationLifecycleTests.leaveAndReenter`（都是轮询预算到期）；2026-11-20 那次 dispatch（run 44703813508）更是在 `UpgradeAnalyticsTests.welcomeOtherOutcomes` 上挂死 4 小时、最后撞 360 分钟 job 上限被 cancelled（同一条用例在前两次跑里 1.8s 通过），整轮没有结论。
  **要做什么**：① 给「等外部信号」的用例路径（`analytics.drain()`、窗口 present / dismiss、`waitUntil`）加**有界**等待，避免无超时的挂死把整轮拖到 job 上限；② 评估给 workflow 加 per-step `timeout-minutes`（挂死能快速失败、不再烧 6 小时）；③ 定 flake 策略：继续按 SKIP 名单逐个排除（已有 4 轮先例）还是接受「全量红不阻塞发版」（现 `build-macos` 与 Release 资产不受影响）。
  **2026-11-21 更正（run 44755916546）**：30 秒预算落地后 `CloudPortRoutePlanTests.stopDuringStart` 仍然把 30 秒跑满才报错 —— 所以它**不是预算问题**，是同一进程里（XCTest + Swift Testing 混跑、1072 套件并行）主 actor 被别的测试长时间占着，本用例等的 `stop()` 任务与它同一个 actor。同样的推理适用于任何「等主 actor 上的异步任务」的用例；光调 timeout 只能让失败变慢。另外：同一次跑里 codex 那条用例是通过的（第三次）。
  **2026-11-24 03:11 验证（main `7195a2e`，run 45219812986，含 #141）**：`CloudPortRoutePlanTests.stopDuringStart` **转绿**（#141 的饥饿容错生效，这轮 30 秒预算没再跑满）。同一轮换成三条不同的用例红，每条都是「共享计数的时序断言」而不是「等主 actor 就绪」：`CloudLoopbackPortForwardTests.unixSocketHub`（`hub.connectTargets` 期望 1 实得 2）、`SidebarDerivedStateScaleTests.paneRegistryBookkeepingDoesNotInvalidateCachedSidebar(workspaceCount:)`（`workspaceSnapshotBuilds` 期望 0 实得 1）、`VMClientReadCoalescingTests.explicitTeamCoalescingKey`（URLProtocol 请求计数期望 2）。→ 「每轮换一条」的根因至少还有第二类：并行套件共享状态 / 计数竞争（#141 只覆盖了等待机制那一类）。**下一步**：按同族逐个把这几个计数断言改成不依赖跨套件时序（各自独立 fixture / 串行化该 suite / 断言范围而非精确计数），而不是继续加预算。

  **注意**：不要把 timeout 当成「改测试迁就实现」——上述用例挂的都是「等异步链路到位」，断言条件本身没错。
  **2026-11-24 失败用例二次调用已落地**：`scripts/ci/rerun_failed_unit_tests.py`（xcresult + 日志两源并集，漏选即红）+ `unit-tests.yml` 的「首轮红 → 只重跑失败清单 → 通过判噪声 / 仍红判回归」+ 门禁里的 fixture 断言（9 条）。端到端分支验证见同批 commit 的 canary 说明。**剩余观察**：① 长期靠重跑才绿的用例要统计（job summary 里有清单），不能一直当噪声；② `-test-iterations 2` 那组旗不要再加回来（实测每个用例都跑两遍）。

  **2026-11-23 retry 实测否定（run 45181479936）**：`-retry-tests-on-failure -test-iterations 2` 把每个用例都跑两遍（9465→18930 条、测试阶段 1985→4223 秒），没把时序噪声变绿 → 已撤销。这一轮的红换成 `RemoteTmuxMirrorPaneInputMappingTests`（断言 send-keys 到达顺序，上一轮绿、本轮两次都红）→ 与 RemoteTmuxMirror* 同族入 SKIP。**待办**：要「只重跑失败用例」需解析失败清单 + `-only-testing:` 二次调用（不是 xcodebuild 的这两面旗），另做一次验证。

  **2026-11-23 验证 + 两条收口（run 45157271886）**：`stopDuringStart` 改法验证通过（0.004 秒绿）；同一轮只剩 `SettingsWindowPresentationContractTests` 一条（`got .presented`，靠 Timer 在有界 run-loop 等待里关窗，headless 不可信）→ 已入 CI 的 SKIP 名单；同时（当时）给 `xcodebuild test` 加了 `-retry-tests-on-failure -test-iterations 2`，期望只重跑失败用例——下一轮实测证明它把每个用例都跑两遍，已撤销（见下方 retry 实测否定条）。**剩余观察**：下一次全量是否还有新的 headless 时序类用例红（若有，按同族并入 SKIP）。

  **2026-11-23 更正（run 45136803034 诊断行）**：`[MainActorWait] ... kind=actor-responsive maxActorStall=0.10s iterations=15000` 证明主 actor 与进程全程健康——`stopDuringStart` 不是饥饿，而是**断言了瞬时状态**：`CloudLinkFirstValue.result` 取消感知，`stop()` 一旦 cancel，forward 立即返回、`.stopping` 只存在几条同步语句，轮询基本看不见（预算从 10s 加到 30s 毫无改善也印证）。已改由测试持有的 continuation 把 forward 卡在飞行中，让 `.stopping` 稳定可观测，核心断言不变。**其余两个历史失败**（`CloudDesktopNavigationLifecycleTests` 的 8 秒 waitUntil、`UpgradeAnalyticsTests` 的 4 小时挂死）仍需分别验证：前者要继续看是否同类「瞬时状态 / 预算过窄」，后者已加 60 秒 deadline，若变成一条带诊断的红就说明是 pipeline 真的卡住。

  **2026-11-23 进展（r30 tag run 45034081189 补充证据 + 第一步落地）**：r30 的 tag 构建同样只挂 1 条（还是 `stopDuringStart`，30.0 秒跑满），日志里 72 处 ≥5 秒的全进程静默、最长 398 秒，证实「单进程 1072 suite 抢主 actor / runner 饥饿」这一判断。据此按「只改等待机制、不动断言」落地：新增 `cmuxTests/MainActorWaitSupport.swift`（`waitForMainActorState` 只把主 actor 跟得上的时间计入预算 + 硬上限 + 超时诊断行）、`AppKitTestEventPump.waitUntil` 与 `CloudPortRoutePlanTests.wait` 改用它、`UpgradeAnalyticsTests` 的 8 处 `analytics.drain()` 加 60 秒 deadline、`unit-tests.yml` 测试 step 加 `timeout-minutes: 180`。**剩余**：① 观察若干轮 tag 构建是否还出现「条件本身没变却红」；② 若诊断行显示 `process-starved` 居多，则再评估把 `cmuxTests` 分片到多进程（单进程并发度是吞吐与饥饿的共同来源）；③ 若显示 `actor-responsive`，说明是排队顺序问题，需要另找（主 actor 上的长同步块）。

- [ ] **T9** 删掉残留的旧 fork `xhqing/cmux-upstream-fork-archive`（就是原来那个 1.1 GiB 的 fork，2026-11-02 让位改名后留下的）：当前 gh token 没有 `delete_repo` 权限，需要 `gh auth refresh -h github.com -s delete_repo` 之后 `gh repo delete xhqing/cmux-upstream-fork-archive --yes`，或者直接在网页 Settings → Danger Zone 删除（记录：2026-11-03 07:20）
- [ ] **T10** 把 `cmuxTests` / `cmuxCLITests` 接入 CI（记录：2026-11-16 18:20）
  **进展（2026-11-16）**：`cmuxTests` 已拆到独立 `.github/workflows/unit-tests.yml`（与 `build-macos` 并行，不再占出包时间线，Issue #93）；r23 的测试编译错误（`RCChannelIdentityTests` 缺 `import CmuxFoundation`）已修；r24 实测 3 条 MarkdownPanel 新用例全绿。**剩余**：① `cmuxCLITests` 仍未接入；② 全量 `cmuxTests` 首次真正跑完就暴露 136 个既有失败（GUI / 快捷键 / 窗口行为类，其中 `AppDelegateShortcutRoutingTests` 44 个）与 Swift Testing 那套 90 分钟以上未跑完——已开独立 Issue 追踪，这是让这套测试真能当回归网的前提；③ Debug 整套重编约 90 分钟仍是最贵的环节。
  **背景**：PR 门禁 `checks` 目前做 `swiftc -parse` 语法、SwiftPM 包级 `swift build` / `swift test`（`check-swift-packages.py`，2026-11-06 接入）、配置 schema、输入延迟防护守卫（`check-latency-guardrails.py`）、pbxproj 测试接线、gitleaks 六项；但 **app target 的 `cmuxTests` / `cmuxCLITests` 仍然没有地方执行**——测试文件存在、门禁绿，但没人跑（如 Issue #2 的 `cmuxTests/EmptyWindowStateTests.swift`）。本机与 macmini 都没装完整 Xcode（开发机是 CommandLineTools，`swift test` 缺 `Testing` 模块）；包级单测由带 Xcode 的 CI runner 跑，app target 单测仍需 `xcodebuild test`。这是回归防护网的实质缺口，不只是不便。
  **要做什么**：按 `DEVELOPMENT.md` 第 9.4 节的建议，在 `pr-checks.yml` 增一个 job（或独立 workflow）跑 `xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests`；先实测冷构建 + 测试耗时（Release 构建约 1.5 小时，测试 job 需评估 runner 6 小时时限与是否拆 job），再决定是否设为 required check（新增 required check 要同步改分支保护的 checks 列表，`checks` 这个名字不能动）。
  **边界**：本机 5 Mbps 出口不适合装 Xcode 走本地路线，必须在 CI 跑；首次接入时先只跑 `cmuxTests`（不含 `cmuxCLITests`），确认稳定后再扩。

## 🟡 黄色（不影响正确性的优化、覆盖缺口）

- [ ] **T3** Dock（侧边 Dock 里的标签页）关闭确认还没接 `app.confirmCloseRunningProcess` 开关：`DockSplitStore.dockPanelNeedsConfirmClose(_:)` 仍是旧的「有进程就确认」（记录：2026-10-31 22:30）

## 🟢 绿色（计划类新功能）

- [ ] **T4** 参考上游 issue #9865 实现「空闲的 coding agent 不算 running process」：agent 停在等用户输入的提示符时，即使把 `app.confirmCloseRunningProcess` 打开也不应该算作有进程在跑（记录：2026-10-31 22:30）
- [ ] **T5** 建立上游同步节奏：至少每 1~2 个月 `gh release list -R manaflow-ai/cmux` 看一次新 tag，按 SYNC.md 的流程升级基线（记录：2026-10-31 22:30）
