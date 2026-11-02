# 开发与构建说明（xhqing 自建分叉）

本仓库是 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 的个人自建分叉，基线固定在**上游 release tag**（当前 `v0.65.2.2`），只在其上叠加少量自有补丁。补丁清单见 [PATCHES.md](PATCHES.md)，同步上游的方法见 [SYNC.md](SYNC.md)。

> 上游自己的 `AGENTS.md`（内容是指给上游 agent 的工作守则）与 `CLAUDE.md` 已迁到 [docs/upstream-agent-notes.md](docs/upstream-agent-notes.md) 保存，本文件取代它们在本地的作用。

## 一、构建方式：CI 优先，本机作退路

选 CI 优先的实测原因是本机出口只有约 5 Mbps（约 670 KB/s），装 Xcode 26（约 4~6 GB）光下载就要两小时；而 GitHub 公开 runner 自带 Xcode 26，不用我们下载。

### 1. CI 构建（首选）

workflow 文件：`.github/workflows/build.yml`（我们自己的，不依赖上游的 Blacksmith 私有 runner）。

- 触发方式：手动 `workflow_dispatch`，或推送形如 `v*-xhqing.*` 的 tag 时自动跑。
- **架构输入 `arch`（默认 `arm64`）**：用户本机是 Apple Silicon，而工程默认编通用二进制（arm64 + x86_64 = 整个 app 编两遍，实测一轮 3.5 小时还没编完）。日常发版只编 `arm64`；要装到 Intel 机器（如 macmini）时手动选 `x86_64`，确实两个都要才选 `universal`。产物名里的架构是从二进制里用 `lipo -archs` 读出来的真实值，不是输入参数。
- **版本号注入**：工程里 `MARKETING_VERSION` 写死上游的 `0.65.2`（12 处），CI 以仓库根 `VERSION` 为准注入：`CFBundleShortVersionString` = VERSION 去掉 `-xhqing.N` 后缀（Apple 要求纯数字段），迭代后缀只出现在 `VERSION` / `CHANGELOG` / tag / Release 名 / 产物文件名里。`CFBundleVersion`（build number）用「UTC 日期 + run 号」，单调递增，避免同一个 staging app 反复覆盖安装时系统拿旧的 Launch Services / 图标缓存。构建末尾的校验 step 会拿实际写进 Info.plist 的值与预期比对，不一致直接红。
- **仓库只有一条分叉线：默认分支 `main`（受保护）**，上游 `main` 只留一个 `upstream-main` 快照 ref 作参照（分支布局与理由见 SYNC.md）。`gh` 在本仓库有两个 remote，可能解析错（把 `upstream` 当成目标仓库、报 `workflow not found`），**触发时仍建议一律带上 `-R xhqing/cmux`**：

  ```bash
  gh workflow run build-macos -R xhqing/cmux --ref main -f tag=xhqing
  gh run list -R xhqing/cmux --limit 5
  gh run view <run-id> -R xhqing/cmux --log
  ```
- runner：`macos-26`（自带 Xcode 26.x，实测镜像里 26.0.1 ~ 26.6 都有，默认 26.6）。
- 关键步骤：
  1. `actions/checkout` 带 `submodules: recursive`（`ghostty`、`homebrew-cmux`、`vendor/bonsplit` 三个子模块必须拉到）；
  2. 选 Xcode 26，`xcodebuild -downloadComponent MetalToolchain` 装 Metal 工具链（上游要求单独下载）；
  3. 装 Zig **0.16.0**（`ghostty/build.zig.zon` 里写的是 `minimum_zig_version = "0.16.0"`，`scripts/setup.sh` 的版本检查要求主次版本完全一致，所以**不能用 `brew install zig` 的 latest**——现在是 0.17.x，会直接报不兼容；workflow 里改成下载 ziglang.org 上固定的 0.16.0 tarball）；
  4. Rust 用 runner 自带的 rustup / cargo（`scripts/setup.sh` 会装固定版本工具链）；Go 用来编译 Cloud 隧道扩展里的 WireGuard 引擎，**Release 构建必须有**（runner 镜像一般自带，没有则 `brew install go`）；
  5. `./scripts/setup.sh`（初始化子模块、拉 checksum 固定的预编译 `GhosttyKit.xcframework`）；
  6. `./scripts/reloads.sh --tag xhqing`（Release 配置 + 隔离 bundle id 构建）；
  7. 打包 `.app` 为 zip 上传为 artifact。
- 产物：`cmux-<版本>-macos-arm64.zip`，解压得到 `cmux STAGING xhqing.app`，bundle id `com.cmuxterm.app.staging.xhqing` —— 和系统里装着的官方 cmux（`com.cmuxterm.app`）**完全隔离**，可以并行安装、并行运行。

### 2. 本机构建（退路）

只有 CI 走不通时才在本机装环境（约 20 GB 磁盘 + 两小时下载）：

```bash
# 前置：Xcode 26（含 Metal 工具链）、Zig、Rust
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -downloadComponent MetalToolchain
brew install zig
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

cd ~/Developer/cmux
./scripts/setup.sh
CMUX_DEV_BACKEND_MODE=local ./scripts/reloads.sh --tag xhqing
```

`setup.sh` 会初始化子模块、装固定版本 Rust 工具链、拉 checksum 固定的预编译 `GhosttyKit.xcframework`（拉取失败才回退到用 Zig 从源码构建，可用 `CMUX_GHOSTTYKIT_NO_PREBUILT=1` 强制源码构建）。

## 二、安装与验证（重要）

```bash
# 从 Release 下载 zip 后
unzip cmux-<版本>-macos-arm64.zip -d /tmp/cmux-xhqing
xattr -dr com.apple.quarantine "/tmp/cmux-xhqing/cmux STAGING xhqing.app"
cp -R "/tmp/cmux-xhqing/cmux STAGING xhqing.app" /Applications/
open "/Applications/cmux STAGING xhqing.app"
```

- 自建版是 **ad-hoc 签名**，没有 Developer ID 也没有公证，所以**必须先去掉隔离属性**（`xattr -dr com.apple.quarantine`），否则系统会报「已损坏」或「无法验证开发者」。
- 自建版与官方版**可以同时开**（bundle id 不同、socket 路径不同）。

### 绝对不要做的事

用户日常就在用 `/Applications/cmux.app`，里面跑着多个 pi 会话——**在它运行时绝不 quit / kill / 重启 / 替换它**，也不要设 `CMUX_ALLOW_REPLACING_RUNNING_CMUX`（只有用户本人可以决定）。要验证新版，一律用上面的隔离 bundle id 并行安装。替换 `/Applications/cmux.app` 那一步必须用户单独点头。

## 三、自建版验证清单（P1 专项）

装好自建版、在新窗口里操作一遍：

1. **默认不弹**：开一个工作区，里面跑点东西（比如一个 `sleep 300` 或一个 pi 会话），关掉这个工作区 → **应该直接关，不弹任何对话框**；
2. 同样跑着进程，按 Cmd+W 关标签页 / 按 Cmd+Ctrl+W 关窗口 → 同样不该弹；
3. **设置项能开回保护**：设置 → App → 找到「Confirm Before Closing Running Processes」打开，重做第 1 步 → 这次**应该弹**「Close workspace?」；
4. **勾选真生效**：在第 3 步弹出的对话框里勾上 "Don't ask again" 再点关闭，然后重做一次 → **不应该再弹**；
5. **未保存内容仍然保护**：在一个浏览器面板里输入点东西但不提交（页面变 dirty），关工作区 → **应该照样弹**（不受新开关影响）；
6. **pinned 工作区**：把工作区 pin 住再关 → 仍应弹「Close pinned workspace?」；
7. **Sparkle 已关**：菜单里「Check for Updates」不应去请求 `manaflow-ai/cmux`（如果它报错/无更新都正常，就是不能装到官方版本）。

## 四、自动更新（Sparkle）已被关掉

上游的 app 内建 Sparkle 自动更新，指向 `https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml`。**如果不关，官方一旦发新版就会把我们自建的 app 覆盖掉。** 本分叉已在 `Resources/Info.plist` 里做了两处改动：

- `SUEnableAutomaticChecks` → `false`（不再自动检查更新）；
- `SUFeedURL` → `https://github.com/xhqing/cmux/releases/latest/download/appcast.xml`（即使手动点「检查更新」也只会问我们自己的仓库，永远不会去拉官方版本）。

另外 `SUPublicEDKey` 是上游的签名公钥，我们手里没有对应私钥，所以我们也无法给自己的分叉签更新包——这个通道对我们来说本来就是死的，关掉只是把它彻底焊死。

## 五、提交纪律与 gitleaks hook

本机全局装了 gitleaks pre-commit hook（对暂存区做密钥扫描）。上游代码库里有大量**假 token 测试夹具**和 SVG 路径数字（会被 `public-ipv4-literal` 规则误伤成公网 IP），一次导入类提交能刷出 150 条误报。

- **导入上游代码的提交**（比如把某个上游 tag 的文件一次性带进来）：允许 `git commit --no-verify`，并在提交信息里写清楚这是导入。
- **我们自己的补丁提交**：照常过 hook，不许用 `--no-verify` 绕过——这条不能变成习惯。
- **版本号会被误判成公网 IP**：`public-ipv4-literal` 规则匹配「四段数字」，所以版本文档里的 `0.65.2.2` 这类字符串会被误报。已在全局 `~/.gitleaks.toml` 给该规则补上 `^0\.` 白名单（`0.0.0.0/8` 是 IANA 保留段、不可能是公网地址），两边都不需要再拿 `--no-verify` 硬绕。

## 六、版本与发版

- 版本号权威来源：仓库根 `VERSION`（当前 `0.65.2.2-xhqing.1`），格式是「上游基线版本 + `-xhqing.N` 后缀」，N 是本分叉自己的迭代号。
- 每次发版：更新 `VERSION` → 在 `CHANGELOG.md` 顶部写条目 → 打 tag（`v0.65.2.2-xhqing.1`）→ 推 tag（CI 自动构建）→ 用 CI 产物建 GitHub Release。
- 发版判断：只有本分叉自上一个 tag 以来有 `fix` / `feat` 类改动才发版；纯文档、杂事不发版。

## 七、上游同步

见 [SYNC.md](SYNC.md)。核心原则：**基线永远用上游 release tag，不用上游 main**（main 每天在动），我们的补丁保持一两个小提交，这样跟着新 tag rebase 成本很低。

## 八、仓库 housekeeping：继承来的 workflow 要批量关掉

**问题**：GitHub 的 fork 会把上游 `.github/workflows/` 下的全部 workflow 一起继承过来（本仓 146 个），而且 **`schedule`（定时）触发在 fork 里照样生效**。上游那套是给他们的私有 runner 和 secrets 准备的：`Nightly macOS build` 每次是几小时的全量构建，`iOS TestFlight` 上传和公证续做在我们这里没有对应凭据，只会失败刷屏；这些 run 还会跟我们自己的 `build-macos` 抢 macOS runner 队列。

**现状（2026-11-01 处理）**：除 `build-macos` 外，145 个 workflow 已全部 `disabled_manually`，排队中的残留 run 也已取消。

**恢复某个 workflow**（比如想临时跑一次上游的静态检查）：

```bash
gh workflow list -R xhqing/cmux                      # 看状态
gh workflow enable <workflow 名或 id> -R xhqing/cmux  # 开回来
gh workflow disable <workflow 名或 id> -R xhqing/cmux # 再关掉
```

**批量复查 / 再关一遍**（上游会持续新增 workflow，跟着默认分支进到 fork）：

```bash
for id in $(gh api repos/xhqing/cmux/actions/workflows --paginate --jq '.workflows[].id'); do
  name=$(gh api repos/xhqing/cmux/actions/workflows/$id --jq '.name')
  [ "$name" = "build-macos" ] && continue
  gh api -X PUT repos/xhqing/cmux/actions/workflows/$id/disable
done
```

**代价（必须知道的）**：关掉之后，**开 PR 时不会再有上游那套 CI 检查**。我们的验证靠 `build-macos` 构建成功 + 用户实测，不靠 PR 门禁。所以本仓库的改动要自己保证质量，不要以为「PR 绿了就是对的」。

**别忘了清理队列里已经排进去的 run**：disable 只阻止**新的**触发，已经进队的 run 还会等着分配 runner（2026-11-01 实测：关完 145 个 workflow 之后队列里还积着 12 条 schedule 进去的 run，其中一条 `Nightly macOS build` 是几小时的全量构建）。清法：

```bash
# 看一眼还有多少排队/在跑的
gh api "repos/xhqing/cmux/actions/runs?status=queued&per_page=20" --jq '.workflow_runs[] | "\(.id) \(.name)"'

# 逐条取消（把 <id> 换成上面列出来的）
gh run cancel <id> -R xhqing/cmux
```

清完用这四条复查，应该全是 0：

```bash
for st in in_progress queued waiting pending; do
  echo "$st: $(gh api "repos/xhqing/cmux/actions/runs?status=$st&per_page=100" --jq '.total_count')"
done
```

上游的 cron 随时可能改，所以**每次跟上游同步前后都顺手看一眼队列**。

**边界**：只关继承来的、对我们无意义的 workflow；`build-macos` 永远保持 active。新增自己的 workflow 时，先在 fork 里手动触发验证一次，再决定要不要长期开着。

## 九、代码改动流程（dev-workflow）与 PR 门禁 `checks`

### 1. 一切改动走 dev-workflow

本仓库是 Atlas 的子项目，按团队标准算**复杂开发项目**：`main` 锁定、一切改动经 PR、CI 绿才合并。

- **Issue 先行**：需求 / 缺陷先开 GitHub Issue（Issues 已开启），写清复现步骤或预期行为。复数小改动可以合并成一个 Issue。
- **分支**：`feat/<功能>` / `fix/<缺陷>` / `chore/<事项>`，小写短横线，从最新 `main` 开出，一个分支只做一件事。
- **PR 目标 `main`**，`gh pr merge --squash --auto --delete-branch`——CI 绿自动合并，不等人工点。
- **只允许 squash 合并**（仓库已关掉 merge commit 与 rebase merge）。
- **发版**仍走 `bump → release` 链，不从功能分支直接发正式版。
- **行为改动先有测试**：测试由 Hopper（测试工程 agent）按 Issue 出题，写完先自跑见红，实现到绿。测试文件必须 wire 进 `project.pbxproj`，否则 Xcode 静默忽略、测试永远不跑——这条已在门禁里硬拦。

`main` 的保护配置（对齐团队口径）：必过状态检查 `checks` + `strict`（合并前分支须最新）、禁止直推（含管理员）、禁止 force push、禁止删除、线性历史。

### 2. 门禁 `checks` 做什么

`.github/workflows/pr-checks.yml`，job 名固定 `checks`（分支保护的必过检查认这个名字），`pull_request → main` 与 `push → main` 都触发，另外支持手动 `workflow_dispatch`。四个检查项：

1. **Swift 语法**（`swiftc -parse`）：只解析、不做类型检查，秒级到分钟级。抓语法错、文件截断、非法字符。
2. **配置 schema 一致**：`web/data/*.schema.json` 必须是合法 JSON，且 `scripts/generate-cmux-config-schema.py --check` 通过（schema 改了却没重新生成对应的 Swift 常量会直接红）。
3. **测试接线**：`scripts/lint-pbxproj-test-wiring.sh`——`cmuxTests/` 下的 Swift 文件必须在 `project.pbxproj` 里注册过，防止「测试文件加了但永远不会跑，PR 一路绿」。
4. **密钥扫描**（`gitleaks`）：只扫**这次 PR 改到的文件**（不扫全仓库历史），规则用 `.github/gitleaks-ci.toml`（在官方默认规则之上只补 SVG 类的误报白名单）。

### 3. 为什么 PR 门禁是轻量的（本条偏离要写明理由）

**没有把完整构建放进 PR 门禁，是刻意的取舍，不是偷懒。**

- 本仓库两万多个文件、一万三千多个 Swift 文件，还带 `ghostty` 子模块（Zig 编译）与 Metal 工具链，`build-macos` 跑一次完整 Release 构建实测是 **2~4 小时**。
- 把「几小时」当 PR 门禁的实际后果只有两种：要么每个 PR 都卡半天、流程直接废掉；要么大家被迫关掉保护绕过去——那比没有门禁更糟。
- 所以门禁守的是「**几分钟内能跑完、且真会因为问题变红**」这一类检查；**完整的编译 / 类型 / 链接正确性由 `build-macos`（tag 或手动 dispatch 触发）兜底**。也就是说：PR 门禁绿 ≠ 一定能编译过，发版前的 `build-macos` 才是那一层。
- **大改动的抽样**：Swift 语法检查对超过 `MAX_SWIFT_PARSE`（当前 1500）的清单做等距抽样（覆盖整份清单，不是只看开头），日志里会打一条 `::notice::` 说明。上游同步这类一次改上千文件的 PR 因此不会把门禁拖成十几分钟；这类 PR 的编译正确性同样交给 `build-macos`。

### 4. 以后怎么扩（把测试套件接进门禁）

- 仓库自带两个测试 target：`cmuxTests`（scheme `cmux-unit`）与 `cmuxCLITests`（scheme `cmux-cli-tests`）。
- **接入条件**：这两个 target 能在一台 `macos-26` runner 上、门禁的 `timeout-minutes` 之内跑完。**接入时在 `checks` 里加一个 step**：

  ```yaml
  - name: Unit tests (cmuxTests)
    run: |
      set -euo pipefail
      xcodebuild test \
        -project cmux.xcodeproj \
        -scheme cmux-unit \
        -destination 'platform=macOS,arch=arm64' \
        -only-testing:cmuxTests
  ```

- **注意三件事**：① 加完 step 不要改 job 名——分支保护的必过检查认的是 `checks` 这个名字；② 单次耗时超过 runner 时限时，要么拆成两个 job（那就得同步改分支保护的 required checks 列表），要么按测试标签拆 `-only-testing:` 分批；③ 测试依赖完整构建产物，真实耗时**先实测再定**，不要凭印象写超时时间。
- 这份「先实测、再进门禁」的顺序同样适用于以后想加的 `swift build`（只编某个 SwiftPM 包）、`actionlint`（workflow 语法）之类的检查。

### 5. 门禁自己坏了的逃生办法（少见，但要会）

`enforce_admins` 是开着的，所以管理员不能绕过 checks 直推。万一门禁本身坏了（比如 workflow 文件语法错、导致 `checks` 永远不出结果），按这个顺序救：

```bash
# 1. 先看是不是 workflow 自身的问题（Actions 页面会有 workflow 级别的红叉，而不是 job 失败）
gh run list -R xhqing/cmux --limit 5

# 2. 临时允许管理员绕过（修好立刻改回 true）
gh api -X PUT repos/xhqing/cmux/branches/main/protection \
  -F enforce_admins=false

# 3. 推修复、合并，确认 checks 恢复正常后，立刻恢复
gh api -X PUT repos/xhqing/cmux/branches/main/protection \
  -F enforce_admins=true
```

`-F` 只能改单个布尔字段，不会把其它保护项（required checks、linear、force push 禁项）冲掉；但为稳妥，改完用 `gh api repos/xhqing/cmux/branches/main/protection` 复查一遍。
