# 开发与构建说明（xhqing 自建版）

本仓库是 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 的个人自建版：基线固定在上游 **release tag**（当前 `v0.65.2.2`），只在其上叠加少量自有补丁。补丁清单见 [PATCHES.md](PATCHES.md)，同步上游的方法见 [SYNC.md](SYNC.md)。

**它已经不是 GitHub 上的 fork**（2026-11-02 主动脱离 fork network），而是一个独立仓库；仓库里只保留 macOS app 需要的内容，git 历史也压平成了「一条基线 + 我们的补丁」（原因与取舍见上面表格与第八节）。

## 零、本仓库的形态（2026-11-02 起）

| 项 | 现状 | 为什么 |
| --- | --- | --- |
| 仓库 | `xhqing/cmux`（独立仓库，`isFork=false`，2026-11-03 接管该名字；旧 fork 已改名为 `xhqing/cmux-upstream-fork-archive` 待删，见 TODO T9） |
| 与上游的关系 | 独立仓库，不在 fork network 里 | 分叉会带着上游 20,328 个提交、1.1 GiB 体积，且继承上游 145 个 workflow；GitHub 的「Leave fork network」要求仓库小于 1 GiB，所以走的是「重建 + 压平历史」的路子 |
| git 历史 | 1 个基线提交（上游 `v0.65.2.2` 剥离后的树）+ 我们自己的补丁提交 | 历史体积从 1.1 GiB 降到约 137 MiB；上游历史需要时仍可查上游仓库或本地 shallow fetch |
| 仓库内容 | 只留 macOS app 的构建闭包 | 官网（`web/`）、文档、iOS app、`cmux-tui`、`webviews/`、服务端目录等都不参与 macOS 构建 |
| 子模块 | `ghostty`（终端内核）、`vendor/bonsplit` | `homebrew-cmux` 是上游的 Homebrew tap，与本 app 构建无关，已移除 |
| workflow | 只有 `.github/workflows/build.yml`（构建）与 `pr-checks.yml`（PR 门禁） | 上游那 145 个是给他们自己的私有 runner / secrets 准备的 |
| 许可 | GPL-3.0-or-later（另含 `THIRD_PARTY_LICENSES.md`） | 采用 BUSL 的服务端目录（`web/`、`workers/iroh-v2` 等）已随剥离删掉 |

### 想恢复某个被删的目录

删掉的都还在上游仓库里，按需取回即可（不要重新变回 fork）：

```bash
git fetch --depth 1 upstream tag v0.65.2.2
git checkout v0.65.2.2 -- web/            # 举例：只想看看官网代码
git switch -c tmp-inspect && git rm -r --cached web/ && git read-tree --reset -u HEAD
```

## 一、构建方式：CI 优先，本机作退路

选 CI 优先的实测原因是本机出口只有约 5 Mbps（约 670 KB/s），装 Xcode 26（约 4~6 GB）光下载就要两小时；而 GitHub 公开 runner 自带 Xcode 26，不用我们下载。

### 1. CI 构建（首选）

workflow 文件：`.github/workflows/build.yml`（我们自己的，不依赖上游的 Blacksmith 私有 runner）。

- 触发方式：手动 `workflow_dispatch`，或推送形如 `v*-r[0-9]*` 的 tag 时自动跑。
- **架构输入 `arch`（默认 `arm64`）**：用户本机是 Apple Silicon，而工程默认编通用二进制（arm64 + x86_64 = 整个 app 编两遍，实测一轮 3.5 小时还没编完）。日常发版只编 `arm64`；要装到 Intel 机器（如 macmini）时手动选 `x86_64`，确实两个都要才选 `universal`。产物名里的架构是从二进制里用 `lipo -archs` 读出来的真实值，不是输入参数。
- **版本号注入**：工程里 `MARKETING_VERSION` 写死上游的 `0.65.2`（12 处），CI 以仓库根 `VERSION` 为准注入：`CFBundleShortVersionString` = VERSION 去掉 `-rN` 后缀（Apple 要求纯数字段），修订后缀只出现在 `VERSION` / `CHANGELOG` / tag / Release 名 / 产物文件名里。`CFBundleVersion`（build number）用「UTC 日期 + run 号」，单调递增，避免同一个 staging app 反复覆盖安装时系统拿旧的 Launch Services / 图标缓存。构建末尾的校验 step 会拿实际写进 Info.plist 的值与预期比对，不一致直接红。
- **About 面板显示完整发布版本**：About 的「Version」一行读 Info.plist 的 `CMUXVersion` 键（构建阶段 `scripts/build-app-bundled-resources.sh` 从仓库根 `VERSION` 原样写入，带 `-rN` 后缀，跟 GitHub Release / tag 一致）；该键缺失时（旧构建）才退回 `CFBundleShortVersionString` 的纯数字值。校验 step 同时比对 `CMUXVersion` 与 `VERSION`，不一致直接红。
- **仓库只有一条分叉线：默认分支 `main`（受保护）**，上游 `main` 只留一个 `upstream-main` 快照 ref 作参照（分支布局与理由见 SYNC.md）。`gh` 在本仓库有两个 remote，可能解析错（把 `upstream` 当成目标仓库、报 `workflow not found`），**触发时仍建议一律带上 `-R xhqing/cmux`**：

  ```bash
  gh workflow run build-macos -R xhqing/cmux --ref main -f tag=xhqing
  gh run list -R xhqing/cmux --limit 5
  gh run view <run-id> -R xhqing/cmux --log
  ```
- runner：`macos-26`（自带 Xcode 26.x，实测镜像里 26.0.1 ~ 26.6 都有，默认 26.6）。
- 关键步骤：
  1. `actions/checkout` 带 `submodules: recursive`（`ghostty`、`vendor/bonsplit` 两个子模块必须拉到）；
  2. 选 Xcode 26，`xcodebuild -downloadComponent MetalToolchain` 装 Metal 工具链（上游要求单独下载）；
  3. 装 Zig **0.16.0**（`ghostty/build.zig.zon` 里写的是 `minimum_zig_version = "0.16.0"`，`scripts/setup.sh` 的版本检查要求主次版本完全一致，所以**不能用 `brew install zig` 的 latest**——现在是 0.17.x，会直接报不兼容；workflow 里改成下载 ziglang.org 上固定的 0.16.0 tarball）；
  4. Rust 用 runner 自带的 rustup / cargo（`scripts/setup.sh` 会装固定版本工具链）；Go 用来编译 Cloud 隧道扩展里的 WireGuard 引擎，**Release 构建必须有**（runner 镜像一般自带，没有则 `brew install go`）；
  5. `./scripts/setup.sh`（初始化子模块、拉 checksum 固定的预编译 `GhosttyKit.xcframework`）；
  6. `./scripts/reloads.sh --derived-data /tmp/cmux-build`（Release 配置 + 本项目正式身份构建；脚本末尾自己会跑一次 `scripts/check-bundle-home-paths.sh`，产物里一旦出现构建机的 `/Users/...` 绝对路径就直接失败）；
  7. 对构建产物再断言一次「不含构建机 home 路径」（同一个检查脚本），然后打包 `.app` 为 zip 上传为 artifact。
- 产物：`cmux-<版本>-macos-arm64.zip`，解压得到 `cmux.app`，bundle id `com.xhqing.cmux` —— 这是本项目自己的正式身份，与官方 cmux（`com.cmuxterm.app`）不共用偏好设置域或更新通道。
  - **socket 位置不在构建期写死**（#46）：产物的 `Info.plist` 里，`LSEnvironment` 只带身份键（`CMUX_BUNDLE_ID`、`CMUX_ALLOW_SOCKET_OVERRIDE`），`CMUX_SOCKET_PATH` / `CMUXD_UNIX_PATH` 一律不注入 —— 构建机（CI runner）的 home 一旦被烤进产物，装到任何别的机器上都不存在。socket 由 app 启动时按真实账号 home 解析，落到 `~/.local/state/cmux/cmux.sock`（`CmuxStateDirectory`，不读 `$HOME`；CLI 找的也是这一条），换用户、换机器都成立。构建期守门是 `scripts/check-bundle-home-paths.sh`：产物 `Info.plist` 里出现任何 `/Users/` 绝对路径就让构建失败。
  - 代价要说清楚：分叉版与官方版因此**共用同一个默认 socket 路径**。两者同时装、同时跑时只能有一个占住它（本机只装本分叉，日常不受影响；真要并存，用 `CMUX_SOCKET_PATH` 手动给其中一个换路径）。本地 `reloads.sh` 构建的身份专属路径不靠产物、而靠启动环境传入（见第二节），不受这条影响。

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

`reloads.sh` 不再把 socket 路径写进产物的 `Info.plist`（#46）：身份专属路径（`~/Library/Application Support/cmux/cmux-<身份>.sock`、tag 构建是 `cmux-<tag>.sock`）改由启动时的环境变量传给 app，`--tag` 并行构建之间照样互不干扰。从 Finder 直接双击打开这类本地产物时，app 会退回自己的默认路径 `~/.local/state/cmux/cmux.sock`。

## 二、安装与验证（重要）

### 1. 安装脚本（推荐）

`scripts/install-release.sh` 把「下载 → sha256 校验 → 安装 → 去隔离 → 启动」固化成一条命令：

```bash
# 安装最新版到 /Applications（覆盖旧版本前会先确认）
./scripts/install-release.sh

# 指定版本、装到临时目录、装完不启动
./scripts/install-release.sh --tag v0.65.2.2-r15 --dest /tmp/cmux-install-test --yes --no-launch
```

不 clone 仓库也能直接用（脚本会自己从 GitHub Release 取资产）：

```bash
curl -fsSL https://raw.githubusercontent.com/xhqing/cmux/main/scripts/install-release.sh -o /tmp/cmux-install.sh
bash /tmp/cmux-install.sh
```

- 版本：默认取最新 Release，`--tag` 可指定（不带前导 `v` 也行）。
- 校验：会下载同名 `.sha256` 资产并用 `shasum -a 256` 比对，校验失败直接中止；只有 `--skip-checksum` 能跳过（仅限应急）。
- 安装：zip 缓存在 `~/Library/Caches/cmux/releases/`，校验一致时复用；先 `ditto` 到 `<dest>/.cmux.app.new` 再原子替换，失败会回滚，成功后不留下备用副本。
- 保护：如果目标位置（如 `/Applications/cmux.app`）里已有 cmux 在运行，脚本会拒绝安装并提示先退出——绝不强行替换运行中的实例，没有强制开关。
- 提示：如果下载到的包 `Info.plist` 里带 `/Users/...`（#46 修复之前的旧 Release），脚本会打印一条警告，说明这个包的 socket 路径在本机不存在、建议换成含修复的新版本；只提醒、不阻断安装。
- 只有装到 `/Applications` 才会跑 `lsregister -f` 注册 LaunchServices；装到测试目录不会污染系统数据库。

### 2. 手工安装（兜底）

```bash
# 从 Release 下载 zip 后
unzip cmux-<版本>-macos-arm64.zip -d /tmp/cmux-xhqing
xattr -dr com.apple.quarantine "/tmp/cmux-xhqing/cmux.app"
cp -R "/tmp/cmux-xhqing/cmux.app" /Applications/
open "/Applications/cmux.app"
```

- 自建版**默认是 ad-hoc 签名**（没有 Developer ID），也没做公证，所以**必须先去掉隔离属性**（`xattr -dr com.apple.quarantine`），否则系统会报「已损坏」或「无法验证开发者」。想要重建不打断屏幕录制等 TCC 授权，可以按第十节用固定证书签名（`CMUX_DEV_SIGN_IDENTITY`）；无论哪种签名，去隔离这一步都照旧。
- **浏览器下载的 zip 及其解压副本会带 `com.apple.quarantine`**（Chrome / Safari 会给下载文件打上这个标记），所以手工安装必须 `xattr -dr`；`curl` 下载不会带这个属性，上面的安装脚本就是用 `curl` 下载的。
- 本项目用独立 bundle id（`com.xhqing.cmux`）与独立 Preferences 域，和官方版互不干扰；socket 用 app 自己的默认路径 `~/.local/state/cmux/cmux.sock`（见第一节「socket 位置不在构建期写死」）；从旧的 `com.cmuxterm.app.staging.xhqing` 身份切换过来时，偏好设置域和会话快照需要一次性迁移。
- **socket 起不来时怎么查**：先看 `~/Library/Logs/cmux/startup-com.xhqing.cmux.log`（启动面包屑，2026-11-11 起 `com.xhqing.cmux` 身份默认开启）里有没有 `socket.listener.didStart`；没有的话按顺序看 `socket.listener.startAttempt`（记了 mode / path / source / socket 目录状态）与 `socket.listener.failed`（stage / errno / hint）。`socket.listener.failed` 的 `stage` 是 POSIX 阶段名（`create_lock_directory` 表示连 socket 目录都没建出来），`hint` 直接指出目录缺在哪。同样的失败还会以 error 级写进统一日志：`log show --predicate 'subsystem == "com.cmuxterm.app" AND category == "ControlSocket"' --last 10m`。

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
7. **更新通道**：菜单「Check for Updates…」只请求本仓库（`xhqing/cmux`）的 appcast，**不能**请求 `manaflow-ai/cmux`；当前已是最新版时应提示「已是最新」。下一次发版后才能完整验证「检测到新版本 → 下载 → 安装并重启」。

## 四、应用内更新（Sparkle）：更新源只认本仓库，自动安装关闭

- **更新源固定为本仓库**：`SUFeedURL` → `https://github.com/xhqing/cmux/releases/latest/download/appcast.xml`，无论自动还是手动检查，都永远不会拉官方版本。
- **不会静默安装**：`SUAutomaticallyUpdate` 与 `UpdateSettings` 都把它固定为 `false`，新版本必须由用户点「Install and Relaunch」。
- **自动检查沿用上游默认（开着）**：`Resources/Info.plist` 里的 `SUEnableAutomaticChecks` 虽然写 `false`，但 `CmuxUpdater` 的 `UpdateSettings.apply(to:)` 会注册上游默认（自动检查 = `true`）并对旧安装做一次迁移，所以实际行为是「自动检查 + 后台探测，发现新版本时侧边栏出现更新提示」。这是上游的设计（`DevStagingUpdateGatingTests` 明确断言 public release train 保持自动检查开启），本分叉保留它；所有检查结果都只来自本仓库的 appcast。

### 更新链路怎么跑

1. 构建（tag 触发的 `build.yml`）产出 zip 后，用 GitHub secret `SPARKLE_PRIVATE_KEY` 调 `scripts/sparkle_generate_appcast.sh` 生成并签名 `appcast.xml`，再用 `scripts/ci/set-appcast-version.py` 把显示版本改成 `VERSION` 原值（带 `-rN`）。
2. `attach-release-asset` workflow 把 `cmux-*.zip`、`.sha256`、`appcast.xml` 一起挂到 Release；挂之前会校验 appcast 里的下载地址确实指向**本 tag** 的 zip，不一致就拒绝发布。
3. app 里点「Check for Updates…」→ Sparkle 拉 `releases/latest/download/appcast.xml` → 用 `sparkle:version`（`CFBundleVersion`，单调递增）比较 → 有新版本就提示「Install and Relaunch」→ 下载 zip、校验 EdDSA 签名、替换 app、重启。

### 密钥

- **公钥** `SUPublicEDKey` 写死在 `cmux.xcodeproj/project.pbxproj` 的 `SPARKLE_PUBLIC_KEY`（Debug / Release 两处），当前值：`rfbvt6jmbne/wfXun8IedZrnp4hR/iRFi9oCPtKsN4Q=`。
- **私钥**只在 GitHub secret `SPARKLE_PRIVATE_KEY` 里；开发机备份在 macOS 钥匙串（服务名 `cmux-sparkle-eddsa`、账号 `private-key`）。
- **改公钥必须与 secret 成对更换**：appcast 用新私钥签名、app 却带旧公钥时，Sparkle 会拒绝安装。轮换步骤：生成新密钥对（Sparkle 的 `generate_keys`）→ 改 `project.pbxproj` 两处公钥 → 更新 GitHub secret → 发一个新版本（旧版装不了跨密钥的更新）。

### 一次性迁移（r17 及更早的安装）

r17 及更早的 app 里装的是**上游的** `SUPublicEDKey`，我们手里没有对应私钥；而 ad-hoc 签名的 designated requirement 是 cdhash，Sparkle 的「Apple 签名一致」兜底也不可能匹配。所以从 r17 或更早的版本升级到带本仓库公钥的版本，**必须手动用 `scripts/install-release.sh` 重装一次**；从这之后的手动更新都走 Sparkle 的「Install and Relaunch」。

### 为什么不用上游的通道

上游的 appcast 与签名密钥都属于 `manaflow-ai/cmux`：feed 指回上游会被官方版本覆盖，而用上游公钥去签我们的包又签不了（私钥在对方手里）。所以本分叉必须有自己的一套 appcast + 密钥。

## 五、提交纪律与 gitleaks hook

本机全局装了 gitleaks pre-commit hook（对暂存区做密钥扫描）。上游代码库里有大量**假 token 测试夹具**和 SVG 路径数字（会被 `public-ipv4-literal` 规则误伤成公网 IP），一次导入类提交能刷出 150 条误报。

- **导入上游代码的提交**（比如把某个上游 tag 的文件一次性带进来）：允许 `git commit --no-verify`，并在提交信息里写清楚这是导入。
- **我们自己的补丁提交**：照常过 hook，不许用 `--no-verify` 绕过——这条不能变成习惯。
- **版本号会被误判成公网 IP**：`public-ipv4-literal` 规则匹配「四段数字」，所以版本文档里的 `0.65.2.2` 这类字符串会被误报。已在全局 `~/.gitleaks.toml` 给该规则补上 `^0\.` 白名单（`0.0.0.0/8` 是 IANA 保留段、不可能是公网地址），两边都不需要再拿 `--no-verify` 硬绕。

## 六、版本与发版

- 版本号权威来源：仓库根 `VERSION`，格式是「上游基线版本 + `-r<N>` 修订号」——不带个人 handle；N 是本仓库自己的修订号，换上游 tag 后从 1 重新开始。当前版本号一律看 `VERSION` 文件本身，本文档不写死具体值（写死了每发一次版就漂移一次）。
- 每次发版：更新 `VERSION` → 在 `CHANGELOG.md` 顶部写条目 → 打 tag（把 `VERSION` 的值前面加个 `v`，形如 `v<上游基线>-r<N>`）→ 推 tag（CI 自动构建）→ 用 CI 产物建 GitHub Release。
- tag 构建会自动产出并签名 `appcast.xml`，`attach-release-asset` 把它和 zip / sha256 一起挂到 Release——app 内更新依赖它，发版时不要手工替换或漏挂。
- 发版判断：只有本分叉自上一个 tag 以来有 `fix` / `feat` 类改动才发版；纯文档、杂事不发版。

## 七、上游同步

见 [SYNC.md](SYNC.md)。核心原则：**基线永远用上游 release tag，不用上游 main**（main 每天在动），我们的补丁保持一两个小提交，这样跟着新 tag rebase 成本很低。

### 内置主题库怎么同步（Issue #71）

`Resources/ghostty/themes` 的 463 个主题文件随上游 release tag 导入（当前 `v0.65.2.2`，见 `Resources/ghostty/README.md` 的来源记录），经 `cmux.xcodeproj` 里的 folder reference（`ghostty-themes`）整目录打包进 `cmux.app/Contents/Resources/ghostty/themes`。

- **不要从上游 main 拉主题**：主题库固定在上游 tag 上，跟着 tag 走。换新 tag 时按 `SYNC.md` 重新导入上游该 tag 的 `Resources/ghostty/themes`，然后更新 `Resources/ghostty/README.md` 里的 tag 记录。
- **不要在 `themes/` 里放非主题文件**：目录里的任何普通文件都会被 `cmux themes` 当主题列出（说明文档放在 `Resources/ghostty/README.md`，不在 `themes/` 内）。
- **打包正确性由 `build-macos` 校验**：构建流水线里有一步逐文件比对 bundle 主题库与仓库源目录，数量或内容不一致会直接失败；不要删掉那个 step。

## 八、上游继承来的 workflow（历史遗留问题，已随脱离 fork 一并解决）

**过去的麻烦**：GitHub 的 fork 会把上游 `.github/workflows/` 下的全部 workflow 一起继承过来（本仓当时 146 个），而且 `schedule`（定时）触发在 fork 里照样生效。上游那套是给他们的私有 runner 和 secrets 准备的：`Nightly macOS build` 每次是几小时的全量构建，`iOS TestFlight` 上传和公证续做在我们这里没有对应凭据，只会失败刷屏；这些 run 还会抢走我们 `build-macos` 的 macOS runner 队列。2026-11-01 的处理是「除 `build-macos` 外 145 个全部 `disabled_manually`」。

**现在的状态（2026-11-02 起）**：仓库脱离 fork network 并重建，`.github/workflows/` 里只剩我们自己的三个文件——`build.yml`（构建）、`attach-release-asset.yml`（把构建产物挂到 Release）与 `pr-checks.yml`（PR 门禁）。继承来的 145 个 workflow 已不在仓库里，不需要再批量关；也没有上游 cron 偷偷触发。

**边界**：以后要借上游某个 workflow（比如静态检查），把那个文件单独拷过来、按我们的 runner 改一遍再用，不要整体同步上游的 `.github/`。

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

`.github/workflows/pr-checks.yml`，job 名固定 `checks`（分支保护的必过检查认这个名字），`pull_request → main` 与 `push → main` 都触发，另外支持手动 `workflow_dispatch`。五个检查项：

1. **Swift 语法**（`swiftc -parse`）：只解析、不做类型检查，秒级到分钟级。抓语法错、文件截断、非法字符。
2. **配置 schema 一致**：`web/data/*.schema.json` 必须是合法 JSON，且 `scripts/generate-cmux-config-schema.py --check` 通过（schema 改了却没重新生成对应的 Swift 常量会直接红）。
3. **测试接线**：`scripts/lint-pbxproj-test-wiring.sh`——`cmuxTests/` 下的 Swift 文件必须在 `project.pbxproj` 里注册过，防止「测试文件加了但永远不会跑，PR 一路绿」。
4. **密钥扫描**（`gitleaks`）：只扫**这次 PR 改到的文件**（不扫全仓库历史），规则用 `.github/gitleaks-ci.toml`（在官方默认规则之上只补 SVG 类的误报白名单）。
5. **签名身份解析**（Issue #121）：`python3 scripts/tests/test_resolve_sign_identity.py -v`——纯 Python + 文本扫描，实测 <2 秒。它锁的是 `scripts/resolve-sign-identity.sh` 的对外行为（未设置输出 `-`、显式 `-` 照办、空白当未设置、身份不存在必须非零退出且 stdout 为空）与「两个构建入口不许再写死 `--sign -`」，防的是「为了修 TCC 授权加的证书支持被后续改动悄悄退回 ad-hoc」。

### 3. 为什么 PR 门禁是轻量的（本条偏离要写明理由）

**没有把完整构建放进 PR 门禁，是刻意的取舍，不是偷懒。**

- 本仓库两万多个文件、一万三千多个 Swift 文件，还带 `ghostty` 子模块（Zig 编译）与 Metal 工具链，`build-macos` 跑一次完整 Release 构建实测是 **2~4 小时**。
- 把「几小时」当 PR 门禁的实际后果只有两种：要么每个 PR 都卡半天、流程直接废掉；要么大家被迫关掉保护绕过去——那比没有门禁更糟。
- 所以门禁守的是「**几分钟内能跑完、且真会因为问题变红**」这一类检查；**完整的编译 / 类型 / 链接正确性由 `build-macos`（tag 或手动 dispatch 触发）兜底**。也就是说：PR 门禁绿 ≠ 一定能编译过，发版前的 `build-macos` 才是那一层。
- **大改动的抽样**：Swift 语法检查对超过 `MAX_SWIFT_PARSE`（当前 1500）的清单做等距抽样（覆盖整份清单，不是只看开头），日志里会打一条 `::notice::` 说明。上游同步这类一次改上千文件的 PR 因此不会把门禁拖成十几分钟；这类 PR 的编译正确性同样交给 `build-macos`。

### 4. 测试套件接在哪儿（2026-11-13 落定，2026-11-16 拆为独立 workflow）

- 仓库自带两个测试 target：`cmuxTests`（scheme `cmux-unit`）与 `cmuxCLITests`（scheme `cmux-cli-tests`）。
- **`cmuxTests` 跑在独立的 `unit-tests.yml`，不进 PR 门禁、也不留在 `build-macos` 里**（Issue #93，2026-11-16 定稿）：它用 `@testable import cmux` 依赖整个 app target，跑一次等于再走一遍完整构建（Debug 配置，约 90 分钟）。实测全量：XCTest 4112 条约 20 分钟、Swift Testing 那套 87 分钟以上仍未跑完，整条 step 200 分钟量级。
- **为什么必须独立成一个 workflow（而不只是同一 workflow 里的一个 step）**：`attach-release-asset` 由 `workflow_run: completed` 触发。只要测试还留在 build-macos 里，workflow 就要等测试跑完（或超时）才 `completed`，资产也就挂得晚。r24 的实测数据就是证据：构建 82 分钟、打包 + appcast + 上传 54 秒（共 85 分钟产物就绪），但资产要等测试结束才挂上。拆开后 build-macos 约 86 分钟结束、资产立即挂上；测试与它并行跑，失败只标红自己。
- **挂资产只看「上传产物」step**：`attach-release-asset` 的判据是 build job 的「上传产物」step 结论，不是整个 run 的结论——构建或打包失败时该 step 不存在或 skipped，会明确拒绝；测试红不影响资产（测试不在这个 workflow 里）。
- **`unit-tests.yml` 的 setup 与 `build.yml` 同源**（Xcode 26 / Metal / Zig 0.16 / Go / `scripts/setup.sh`）：改动任一处时对照另一处，避免两条流水线跑在不同工具链上。
- `cmuxCLITests`（只测 CLI target，不依赖 app）目前仍未接入；如果要接，它才是有可能进 PR 门禁的候选——同样必须先实测耗时。

### 4a. CI 上哪些测试可信（2026-11-18 定稿，Issue #98）

`unit-tests` 全量实测（`44085353974`，182 分钟）：XCTest 4112 条里 **137 失败**，Swift Testing 10029 个 test case 里 **211 issues**。失败几乎全部集中在一类：**需要真实窗口服务器 / 键盘事件 / 登录账号与 Cloud、模拟器环境**的用例。headless runner 上没有这些环境，它们红了不代表代码坏了。

所以分两层：

| 层 | 在哪跑 | 范围 |
| --- | --- | --- |
| **可信层（CI）** | `unit-tests` | 其余全部：纯逻辑、状态机、包层测试、Markdown 渲染、文件监视等 |
| **本机层** | `./scripts/test-all-local.sh` | 全量，含 CI 跳过的 17 个分组 |

CI 跳过的分组用 `-skip-testing:` 写在 `unit-tests.yml` 的 `SKIP` 数组里（不改测试代码、不动 `project.pbxproj`），当前 **56 条**（XCTest 分组 + Swift Testing suite / 单条用例，三轮实测后补全）：

- 快捷键路由：`AppDelegateShortcutRoutingTests`
- 窗口 / 标签页关闭确认：`MainWindowCloseConfirmationTests`、`TabManagerCloseCurrentPanelTests`、`TabManagerCloseDontAskAgainTests`、`TabManagerWarnBeforeClosingWorkspaceTests`、`TabManagerCloseCurrentTabSpamTests`、`MainWindowCloseTerminationRoutingTests`、`QuitConfirmationAlertPresenterTests`、`EmptyWindowStateTests`
- 浏览器 / 模拟器集成：`BrowserDeveloperToolsVisibilityPersistenceTests`、`SimulatorPanelIntegrationTests`
- Cloud 与多机：`SurfacePaneFactoryFocusTests`
- 其余涉及真实进程 / 外部命令：`WorkspaceManualUnreadTests`、`TerminalNotificationDirectInteractionTests`、`CLINotifyProcessIntegrationRegressionTests`、`CMUXOpenCommandTests`、`WorkspacePullRequestSidebarTests`

**维护规则**：新增一个用例时先判断它需不需要上面这些环境；需要的就进本机层，不要往 CI 里塞。要从跳过清单里移除某组，先在 CI 上跑一轮确认它稳定通过（每轮约 3 小时）。


- **接入条件**：这两个 target 能在一台 `macos-26` runner 上、门禁的 `timeout-minutes` 之内跑完；且 PR 阶段改 app target 的 PR 应在合并前手动 `gh workflow run build.yml --ref <分支>` 跑一次，把类型错误与测试编译错误提前暴露（PR 门禁的 `swiftc -parse` 不做类型检查）。
- **接入时在 `checks` 里加一个 step**（前提是上面「先实测」已完成）：

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

`enforce_admins` 是开着的，所以管理员也不能绕过 checks 直推。万一门禁本身坏了（比如 workflow 文件语法错、`checks` 永远不出结果），按这个顺序救：

```bash
# 1. 先看是不是 workflow 自身的问题（Actions 页面会有 workflow 级别的红叉，而不是 job 失败）
gh run list -R xhqing/cmux --limit 5

# 2. 临时把 required checks 摘掉 + 允许管理员绕过（其它保护项照着当前值写全，别少字段）
gh api -X PUT repos/xhqing/cmux/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0, "dismiss_stale_reviews": false},
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
JSON

# 3. 推修复、合并，确认 checks 恢复正常后，用完整设置恢复（把 required_status_checks 加回来）
gh api -X PUT repos/xhqing/cmux/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": ["checks"]},
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0, "dismiss_stale_reviews": false},
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
JSON
```

**别偷懒只传一个字段**：这个 PUT 是「整体替换」语义，只传 `enforce_admins=false` 会被直接拒（HTTP 422：`required_pull_request_reviews` / `required_status_checks` / `restrictions` weren't supplied）——实测如此，所以要么照上面写全、要么用 `required_status_checks: null` 显式摘掉。改完一律 `gh api repos/xhqing/cmux/branches/main/protection` 复查一遍。

> 另一个更常见的「checks 永远不出结果」原因不是 workflow 本身，而是**仓库的 Actions 被禁用**（`gh workflow run` 会报 `HTTP 422: Actions has been disabled for this repository`）。这时去仓库 Settings → Actions 确认是否开启，或用 `gh api -X PUT repos/xhqing/cmux/actions/permissions -F enabled=true` 打开；API 显示已开启但 dispatch / push / pull_request 都不出 run，说明是平台侧禁用，只能到网页 Actions 页按提示重新启用。

### 6. `required_status_checks` 什么时候补齐（2026-11-02）

**历史情况**：旧仓库（fork）的 Actions 曾被平台禁用——`gh workflow run` 报 `HTTP 422: Actions has been disabled for this repository`，而 `gh api .../actions/permissions` 却返回 `enabled: true`（`PUT enabled=true` 成功但不生效）。在没有 check 能上报的情况下把 `checks` 设成必过，会让 `main` 完全无法合并，所以那时刻意留空。

**现在**：仓库已重建为独立仓库，Actions 状态随之清零（TODO.md T7）。首次验证顺序如下，别反着做：

1. 确认 Actions 可用：`gh workflow list -R xhqing/cmux` 能看到 `build-macos` 与 `PR checks（门禁：checks）`；看不到就先去网页 Actions 页启用；
2. 开一个真实 PR，确认 `checks` 真的产生并且能跑绿（`gh pr checks <N>` 有结果）；
3. 这时才把 required check 加上去：`required_status_checks` 设为 `{"strict": true, "contexts": ["checks"]}`（其余字段按 9.1 / 9.5 的完整 payload 写全，`PUT` 是整体替换语义）；
4. 用一个 PR 复验「PR → checks 绿 → auto-merge → squash 合并 → 合并后 main push 也跑一遍」整条链路，并再试一次直推 `main` 确认仍被拒。

## 十、代码签名身份与 TCC 授权（Issue #121）

### 1. 症状与根因

**症状**：每次重新构建 / 重新安装 cmux，屏幕录制（以及辅助功能、输入监控等）授权都要重给一次；「系统设置 → 隐私与安全性 → 屏幕录制」里会出现同一个 App 的多条旧记录。

**根因**：构建脚本用 `codesign --sign -`（ad-hoc 签名）。ad-hoc 没有证书，macOS 记下的 **designated requirement** 只能退化成这一份二进制产物的哈希：

| 签名方式 | designated requirement | 重建后 |
| --- | --- | --- |
| ad-hoc（`codesign --sign -`） | `cdhash H"a360b28b…"` | 每次重建 cdhash 都变 → 系统认为是**另一个 App** → TCC 授权作废 |
| 证书签名（固定证书） | `identifier "com.xhqing.cmux" and certificate leaf = H"9f2c…"` | 证书与 bundle id 不变 → 授权继续有效 |

### 2. 两个构建入口怎么用

`scripts/reload.sh`（Debug / 开发版）与 `scripts/reloads.sh`（Release，CI 的 `build.yml` 也走它）都通过 `scripts/resolve-sign-identity.sh` 解析身份，认同一个环境变量 `CMUX_DEV_SIGN_IDENTITY`：

```bash
export CMUX_DEV_SIGN_IDENTITY="cmux Local Code Signing"   # 写进 ~/.zshrc 长期生效
./scripts/reload.sh                                        # 开发版
./scripts/reloads.sh --derived-data /tmp/cmux-build        # Release
```

- **未设置 / 空 / 全空白** → 输出 `-`，行为与以前完全一致（ad-hoc）。这种构建会在 stderr 上提示 TCC 授权会随重建失效。
- **显式设为 `-`** → 明确要求 ad-hoc，照办。
- **设为身份名（或它 SHA-1 指纹的前缀）** → 必须在 `security find-identity -v -p codesigning` 里找得到；**找不到直接让构建失败**，stdout 不输出任何身份。

最后一条是刻意的：静默回退 ad-hoc 等于把 #121 的 bug 悄悄带回来——构建照样成功，用户要等到下一次系统提示「屏幕录制权限又失效了」才发现。

### 3. 创建证书（开发机自用）

**推荐：跑脚本**

```bash
./scripts/create-dev-signing-cert.sh
```

它会：生成 RSA 2048 / 3650 天、`basicConstraints=critical,CA:FALSE` + `keyUsage=critical,digitalSignature` + `extendedKeyUsage=critical,codeSigning` 的自签名证书（CN 默认 `cmux Local Code Signing`）→ 导入登录钥匙串（`-T /usr/bin/codesign -T /usr/bin/security`）→ 把可换机恢复的 `.p12` 与 PEM 备份到 `~/.dev/private/cmux/signing/`（p12 密码**不写盘**，请存进 KeePass 等密码库）。同名证书已存在时**拒绝覆盖**（重新生成会让证书哈希变化、TCC 授权再失效一次）。

其他参数：`--name "<CN>"` 改名字、`--out <p12 路径>` 改备份位置、`--import <p12>` 换机恢复。

**或者：钥匙串访问 GUI**

「钥匙串访问 → 证书助理 → 创建证书…」→ 名称填 `cmux Local Code Signing`、「证书类型」选**代码签名**、「证书颁发机构」选「让我自定」、有效期 3650 天。

### 4. 始终信任（必须手动做一次）

自签名证书默认不被系统信任，`codesign` 不会用它：

1. 「钥匙串访问」→ 左侧「登录」→「证书」→ 找到 `cmux Local Code Signing`；
2. 双击 → 展开「信任」→「使用此证书时」选**始终信任** → 关闭窗口并输入系统密码。

或命令行（效果相同，会要求管理员密码）：

```bash
sudo security add-trusted-cert -d -r trustAsRoot -p codeSign \
  -k /Library/Keychains/System.keychain ~/.dev/private/cmux/signing/cmux-dev-signing.cert.pem
```

验证：

```bash
security find-identity -v -p codesigning
# 输出里应出现 "cmux Local Code Signing"，且不再是 "0 valid identities found"
```

### 5. 第一次切到证书签名：重新授权一次

旧记录认的是 ad-hoc 的 cdhash，换了签名身份之后系统会把它们当成历史垃圾。先清掉旧记录、再重新授权一次：

```bash
tccutil reset ScreenCapture com.xhqing.cmux      # Release 版
tccutil reset ScreenCapture com.cmuxterm.app.debug   # 开发版（reload.sh 默认 bundle id）
```

然后打开 app、按系统提示重新授予屏幕录制等权限。**这只需要做一次**——之后证书不变，重建不再打断授权。

### 6. 备份与换机

- **备份**：`~/.dev/private/cmux/signing/` 下的 `.p12` + `.cert.pem`（本机私有目录，随 Syncthing 同步、不进仓库）；p12 的密码单独存进 KeePass 等密码库，**不要**和备份放在一起。
- **换机恢复**：`./scripts/create-dev-signing-cert.sh --import <备份.p12>`，再按第 4 节重做「始终信任」。
- **「始终信任」是本机设置**：它写在本机的信任设置里，不会随 p12 走；换机必须重设，否则 `security find-identity -v` 仍然看不到这张证书。
- **证书重新生成会让 TCC 再失效一次**：新证书 = 新哈希 = 新的 designated requirement，所以不要为了「重来一遍」随手删掉证书。

### 7. Sparkle 升级注意（一次性）

r26 / r27 的安装包是 ad-hoc 签名。从它们升到**证书签名**的版本时，签名身份变了，Sparkle 会拒绝安装（它校验签名一致性）。需要一次性手动重装：

```bash
./scripts/install-release.sh --tag <第一个证书签名的版本>
```

之后版本之间签名身份一致，应用内更新恢复正常。

### 8. CI 的证书配置（可选）

`build.yml` 支持用两个（三个）secret 给产物挂固定身份；**都不配时行为与以前完全一致**（ad-hoc，日志里会打一条 warning 说明代价）：

| Secret | 内容 | 必填 |
| --- | --- | --- |
| `CMUX_DEV_SIGNING_CERT_P12_BASE64` | 证书 + 私钥的 `.p12`，`base64 -i cmux-dev-signing.p12 \| pbcopy` 的结果 | 配了才启用 |
| `CMUX_DEV_SIGNING_CERT_PASSWORD` | 该 `.p12` 的密码 | 同上 |
| `CMUX_DEV_SIGNING_IDENTITY` | 证书 CN，默认 `cmux Local Code Signing` | 可选 |

配置方法：`gh secret set CMUX_DEV_SIGNING_CERT_P12_BASE64 -R xhqing/cmux < <(base64 -i ~/.dev/private/cmux/signing/cmux-dev-signing.p12)`，密码用 `gh secret set CMUX_DEV_SIGNING_CERT_PASSWORD -R xhqing/cmux`（交互输入）。

流水线行为：

1. 「导入签名证书（可选）」只在 `CMUX_DEV_SIGNING_CERT_P12_BASE64` 非空时执行：临时钥匙串 + `security import -T /usr/bin/codesign` + `set-key-partition-list` + `add-trusted-cert -r trustAsRoot -p codeSign`，然后把 `CMUX_DEV_SIGN_IDENTITY` 写进 `$GITHUB_ENV`。**导入失败 / 身份找不到 = 构建直接红**，不静默退回 ad-hoc。
2. 构建后「校验产物的签名身份」读 `codesign -d --requirements -`：配了身份时 requirement 里必须出现 `certificate leaf`（出现 `cdhash` 就失败）；没配时只打 warning。

注意：`scripts/build-sign-upload.sh` 里那张 `SIGN_HASH` 是**上游**（manaflow-ai/cmux）的 Developer ID 证书指纹，本仓库没有这张证书、也没有 workflow 调用它——它不在本仓库的发版链路上，缺证书时现在会在 pre-flight 明确报错。

### 9. 边界

自签名证书只解决**开发机自用**（本机重建不打断自己的 TCC 授权）。对外分发仍然需要 Apple Developer Program 的 Developer ID Application 证书 + 公证（notarization），这一条没有变。
