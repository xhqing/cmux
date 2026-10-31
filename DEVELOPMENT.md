# 开发与构建说明（xhqing 自建分叉）

本仓库是 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 的个人自建分叉，基线固定在**上游 release tag**（当前 `v0.65.2.2`），只在其上叠加少量自有补丁。补丁清单见 [PATCHES.md](PATCHES.md)，同步上游的方法见 [SYNC.md](SYNC.md)。

> 上游自己的 `AGENTS.md`（内容是指给上游 agent 的工作守则）与 `CLAUDE.md` 已迁到 [docs/upstream-agent-notes.md](docs/upstream-agent-notes.md) 保存，本文件取代它们在本地的作用。

## 一、构建方式：CI 优先，本机作退路

选 CI 优先的实测原因是本机出口只有约 5 Mbps（约 670 KB/s），装 Xcode 26（约 4~6 GB）光下载就要两小时；而 GitHub 公开 runner 自带 Xcode 26，不用我们下载。

### 1. CI 构建（首选）

workflow 文件：`.github/workflows/build.yml`（我们自己的，不依赖上游的 Blacksmith 私有 runner）。

- 触发方式：手动 `workflow_dispatch`，或推送形如 `v*-xhqing.*` 的 tag 时自动跑。
- runner：`macos-26`（自带 Xcode 26.x，实测镜像里 26.0.1 ~ 26.6 都有，默认 26.6）。
- 关键步骤：
  1. `actions/checkout` 带 `submodules: recursive`（`ghostty`、`homebrew-cmux`、`vendor/bonsplit` 三个子模块必须拉到）；
  2. 选 Xcode 26，`xcodebuild -downloadComponent MetalToolchain` 装 Metal 工具链（上游要求单独下载）；
  3. `brew install zig`（`cmuxd` 是 Zig 写的，构建脚本会 `zig build`）；
  4. Rust 用 runner 自带的 rustup / cargo（`scripts/setup.sh` 会装固定版本工具链）；
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

## 三、自动更新（Sparkle）已被关掉

上游的 app 内建 Sparkle 自动更新，指向 `https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml`。**如果不关，官方一旦发新版就会把我们自建的 app 覆盖掉。** 本分叉已在 `Resources/Info.plist` 里做了两处改动：

- `SUEnableAutomaticChecks` → `false`（不再自动检查更新）；
- `SUFeedURL` → `https://github.com/xhqing/cmux/releases/latest/download/appcast.xml`（即使手动点「检查更新」也只会问我们自己的仓库，永远不会去拉官方版本）。

另外 `SUPublicEDKey` 是上游的签名公钥，我们手里没有对应私钥，所以我们也无法给自己的分叉签更新包——这个通道对我们来说本来就是死的，关掉只是把它彻底焊死。

## 四、提交纪律与 gitleaks hook

本机全局装了 gitleaks pre-commit hook（对暂存区做密钥扫描）。上游代码库里有大量**假 token 测试夹具**和 SVG 路径数字（会被 `public-ipv4-literal` 规则误伤成公网 IP），一次导入类提交能刷出 150 条误报。

- **导入上游代码的提交**（比如把某个上游 tag 的文件一次性带进来）：允许 `git commit --no-verify`，并在提交信息里写清楚这是导入。
- **我们自己的补丁提交**：照常过 hook，不许用 `--no-verify` 绕过——这条不能变成习惯。

## 五、版本与发版

- 版本号权威来源：仓库根 `VERSION`（当前 `0.65.2.2-xhqing.1`），格式是「上游基线版本 + `-xhqing.N` 后缀」，N 是本分叉自己的迭代号。
- 每次发版：更新 `VERSION` → 在 `CHANGELOG.md` 顶部写条目 → 打 tag（`v0.65.2.2-xhqing.1`）→ 推 tag（CI 自动构建）→ 用 CI 产物建 GitHub Release。
- 发版判断：只有本分叉自上一个 tag 以来有 `fix` / `feat` 类改动才发版；纯文档、杂事不发版。

## 六、上游同步

见 [SYNC.md](SYNC.md)。核心原则：**基线永远用上游 release tag，不用上游 main**（main 每天在动），我们的补丁保持一两个小提交，这样跟着新 tag rebase 成本很低。
