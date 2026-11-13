# cmux · 项目硬约束

身份与角色见本仓库根 `AGENTS.md`；团队通用规则见全局 `~/.pi/agent/AGENTS.md`，此处不重述。

## 本项目是什么

[manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 的个人自建版：基线固定在上游 **release tag**（当前 `v0.65.2.2`），只在其上叠加少量自有补丁（清单见 `PATCHES.md`，同步上游见 `SYNC.md`）。已脱离 fork network，是独立仓库；只保留 macOS app 的构建闭包。

## 🚨 绝对不要做的事（最重要）

用户**日常就在用 `/Applications/cmux.app`**，里面跑着多个 pi 会话。

- **绝不在它运行时 quit / kill / 重启 / 替换它**，也不要设置 `CMUX_ALLOW_REPLACING_RUNNING_CMUX`——只有用户本人可以决定。
- 要验证新版，一律用隔离 bundle id（`com.xhqing.cmux`）**并行安装**，不碰正在运行的那个。
- 替换 `/Applications/cmux.app` 那一步**必须用户单独点头**，Worker 不得自行执行。

## 构建

- **CI 优先**：`.github/workflows/build.yml`，手动 `workflow_dispatch` 或推 `v*-r[0-9]*` tag 触发；`gh` 命令一律带 `-R xhqing/cmux`（本仓库有两个 remote，可能解析错）。重活不要在本机跑。
- **本机构建只是退路**（约 20 GB 磁盘 + 两小时下载），CI 走不通时才用。
- **Zig 必须 0.16.0**：不能用 `brew install zig` 的 latest（现在是 0.17.x，`scripts/setup.sh` 会直接报不兼容）；需要时从 ziglang.org 下载固定版本。
- **架构只编 arm64**：`universal` 是整个 app 编两遍，实测一轮 3.5 小时还没完。
- 版本号注入：`VERSION` 去掉 `-rN` 后缀写进 `CFBundleShortVersionString`，完整版本写进 `CMUXVersion`（About 面板显示）；构建末尾有校验 step。
- 安装：ad-hoc 签名、无公证，**必须先 `xattr -dr com.apple.quarantine`**，否则系统报「已损坏」（手工路径；用 `scripts/install-release.sh` 安装则会自动下载、校验、去隔离）。
- **更新通道（Sparkle）**：自动**安装**关着（`SUAutomaticallyUpdate=false`），自动检查沿用上游默认；CI 用 GitHub secret `SPARKLE_PRIVATE_KEY` 生成并签名 `appcast.xml`，`attach-release-asset` 自动挂到 Release。改 `project.pbxproj` 的 `SPARKLE_PUBLIC_KEY`（两处）**必须**同步更新该 secret，否则签名对不上、app 内更新装不上；私钥本机备份在 macOS 钥匙串（服务名 `cmux-sparkle-eddsa`、账号 `private-key`）。详见 `DEVELOPMENT.md` 第四节。

## PR 门禁只能说轻量（刻意的取舍，别去"优化"）

`checks` job 只做四项：Swift 语法（`swiftc -parse`）、配置 schema 一致性、测试接线（`cmuxTests/` 文件必须注册进 `project.pbxproj`）、gitleaks 扫描改动文件。

- **不要提议把完整构建塞进 PR 门禁**：两万多个文件 + ghostty 子模块 + Metal 工具链，`build-macos` 实测 2~4 小时；当门禁的实际后果是流程废掉或被绕过。完整编译正确性由 `build-macos` 兜底。
- **改门禁时不要改 job 名**——分支保护的必过检查认的就是 `checks` 这个名字。
- 新增测试 step 前先实测耗时，别凭印象写超时。

## 版本与发版

- 版本号权威：仓库根 `VERSION`，格式「上游基线 + `-r<N>` 修订号」（不带个人 handle；N 是本仓库自己的修订号，换上游 tag 后从 1 重新开始）。
- 发版：更新 `VERSION` → CHANGELOG 顶部写条目 → 打 tag（把 `VERSION` 的值前面加个 `v`，形如 `v<上游基线>-r<N>`）→ 推 tag（CI 自动构建）→ CI 自动把 zip / sha256 / `appcast.xml` 挂到 Release（app 内更新靠 appcast，不要漏挂或手改）。
- **只有本分叉自上一个 tag 以来有 fix / feat 类改动才发版**；纯文档、杂事不发版。

## 提交纪律

- 本机全局 gitleaks pre-commit hook 会扫暂存区。
- **我们自己的补丁提交不许 `--no-verify`**。
- 导入上游代码的提交（一次性带进某 tag 的文件）允许 `--no-verify`，并在提交信息里写清楚这是导入。
- `0.65.2.2` 这类版本号会被 `public-ipv4-literal` 误判——已在全局 `~/.gitleaks.toml` 给 `^0\.` 加白名单，不需要 `--no-verify` 硬绕。

## 上游同步

**基线永远用上游 release tag，不用上游 main**（main 每天在动）。我们的补丁保持一两个小提交，跟着新 tag rebase 成本很低。详见 `SYNC.md`。

## 自建版验证清单（改行为后必须过）

装好新版、在新窗口里逐条走（完整版见 `DEVELOPMENT.md` 第三节）：① 跑着进程的工作区关闭时**默认不弹**；② Cmd+W / Cmd+Ctrl+W 同样不弹；③ 设置里打开「Confirm Before Closing Running Processes」后重试**应该弹**；④ 勾选 "Don't ask again" 后不再弹；⑤ 浏览器面板有未保存内容时**仍要弹**；⑥ pinned 工作区仍要弹；⑦ 更新通道只问本仓库（菜单「Check for Updates…」不应请求上游 `manaflow-ai/cmux`，装的是最新版时应提示已是最新）。

## 测试文件对 Worker 只读（2026-11-13 立）

测试由 **Leader（dev-agent / Atlas 的会话）在实现开工前**写好，以功能分支上的本地 commit 形式存在。你（Worker）对测试文件**只能读、只能运行**：

- **禁止新建 / 修改 / 删除 / 移动**任何测试文件与测试基础设施：本项目的测试位置是 `cmuxTests/`（Xcode 单元测试）、`scripts/ci/test_*.py`、`scripts/tests/`、`scripts/dev-profiles/*.test.mjs`；含 fixtures / helpers / conftest 等伴生文件（跑测试缺了也不自己补）。
- **碰到测试跑不通、断言与 Issue 预期不符 → 终止开发、上报 Leader（`Atlas`）或用户裁决**，绝不改测试迁就实现——这是 LLM 的典型失败模式（改不动代码就放宽断言）。
- **`# TEST_CASES_WRITE_OK` 标记的签发权在 Leader**，你不加；被 `test-cases-guard` 拦下时不要绕过。
- 例外：测试运行自产的缓存与构建产物（`__pycache__`、`.pytest_cache`、coverage 输出、`out/` 等）可清理，走授权标记通道。

## 详细说明

`DEVELOPMENT.md`（构建 / 安装 / 门禁 / 发版全流程）、`PATCHES.md`（补丁清单）、`SYNC.md`（上游同步方法）；通用工作规则见全局 `~/.pi/agent/AGENTS.md`。
