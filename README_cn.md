<h1 align="center">
  <img src="./Assets.xcassets/AppIcon.appiconset/512.png" alt="cmux" width="120" />
  <br />
  cmux <sub>（xhqing 自建版）</sub>
</h1>

<p align="center">基于 <a href="https://github.com/manaflow-ai/cmux">cmux</a> 的个人自建版，只保留 macOS 部分——Ghostty 内核、竖排标签页的终端。</p>

<p align="center">
  <a href="https://github.com/xhqing/cmux/releases/latest"><img src="https://img.shields.io/github/v/release/xhqing/cmux?label=%E6%9C%80%E6%96%B0%E7%89%88" alt="最新版" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF-GPL--3.0--or--later-4c71f2" alt="许可证" /></a>
  <img src="https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-macOS%2014%2B-000000?logo=apple" alt="平台" />
  <a href="https://github.com/xhqing/cmux/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/xhqing/cmux/build.yml?label=%E6%9E%84%E5%BB%BA" alt="构建" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

---

## 这个仓库是什么

这是我自己编译使用的 cmux，基线是上游 release tag **v0.65.2.2**，上面叠加了少量补丁。它**不是 GitHub 上的分叉（fork）**，而是一个独立仓库，git 历史也做过刻意的压平处理（原因见 [DEVELOPMENT.md](DEVELOPMENT.md)）。

和官方版本的行为差别：

- **关掉工作区 / 标签页 / 窗口时，不再因为「里面有进程在跑」就弹确认框**（设置键 `app.confirmCloseRunningProcess`，默认关闭）。未保存内容、pinned 工作区、进行中的 agent 会话的保护照旧生效。
- **更新永远不会自动安装，而且只从本仓库获取**：应用内「Check for Updates…」读取随本仓库 Release 发布的签名 appcast。应用也可能按上游默认在后台检查更新、并在侧边栏显示更新提示；但你不点安装就不会有任何东西被替换。更新源永远不会指向官方 cmux 仓库。
- 用的是 ad-hoc 签名，并采用本项目自己的正式身份：bundle id `com.xhqing.cmux`、独立 socket、独立偏好设置域，不再与官方版共用任何状态。

每个补丁要解决什么问题、根因是什么，都写在 [PATCHES.md](PATCHES.md) 里。

## 仓库结构

只保留 macOS app 需要的东西：

| 路径 | 作用 |
| --- | --- |
| `Sources/` | app 源码（AppKit / SwiftUI 各 target） |
| `Packages/macOS/`、`Packages/Shared/` | app 链接的本地 Swift 包 |
| `Packages/iOS/CmuxMobile*` | Xcode 工程真正依赖的那 6 个 iPhone 包 |
| `Resources/` | 随包资源（webview、本地化、terminfo 等） |
| `CLI/` | `cmux` 命令行 target |
| `TunnelExtension/`、`Native/`、`vendor/` | 系统扩展、Rust FFI 辅助、第三方依赖 |
| `cmuxTests/`、`cmuxCLITests/`、`cmuxUITests/`、`cmuxCLITestSupport/` | 测试 target |
| `scripts/`、`config/`、`schemas/`、`skills/` | 构建脚本、配置骨架、随包 agent 技能 |
| `ghostty/` | git 子模块：终端内核 |

刻意删掉的：`web/`（官网）、`docs/`、`ios/`（iOS app）、`cmux-tui/`、`webviews/`、`daemon/`、`coderouter/`、`agent-chat/`、`services/`、`workers/`（只留一个辅助程序）、24 个语种的翻译 README，以及上游继承来的 145 个 workflow。剩下的部分全部是 GPL-3.0-or-later —— 采用 BUSL 许可的服务端代码已经随 `web/` 等目录一起删掉了。

## 安装

推荐用安装脚本，一条命令完成「下载 → 校验 → 安装 → 去隔离 → 启动」（不需要 clone 本仓库）：

```bash
curl -fsSL https://raw.githubusercontent.com/xhqing/cmux/main/scripts/install-release.sh -o /tmp/cmux-install.sh
bash /tmp/cmux-install.sh
```

脚本默认装最新版到 `/Applications`，覆盖旧版本前会先问你；常用参数：`--tag v0.65.2.2-r15` 指定版本、`--dest <目录>` 换安装目录、`--no-launch` 装完不启动、`--yes` 跳过确认（非交互环境必须加）、`--skip-checksum` 应急跳过校验。

### 手工安装（兜底）

从 [最新 Release](https://github.com/xhqing/cmux/releases/latest) 下载 zip：

```bash
unzip cmux-<版本>-macos-arm64.zip -d /tmp/cmux-xhqing
xattr -dr com.apple.quarantine "/tmp/cmux-xhqing/cmux.app"
cp -R "/tmp/cmux-xhqing/cmux.app" /Applications/
```

这份构建是 ad-hoc 签名、没有公证。**用浏览器下载的 zip 及其解压副本会带 `com.apple.quarantine` 隔离属性**，双击时会被 Gatekeeper 拦下（弹窗「Apple could not verify "cmux" ...」），所以手工安装**必须**先 `xattr -dr com.apple.quarantine` 去掉它，否则系统会报「已损坏」或「无法验证开发者」。上面的脚本用 `curl` 下载（curl 不写这个属性），安装后还会再补一次 `xattr -dr`，所以不会有这个坑。

## 构建

优先走 CI：跑 `build-macos` workflow（`workflow_dispatch`，`arch` 默认 `arm64`），或推送形如 `v*-r[0-9]*` 的 tag。本机构建需要 Xcode 26 + Zig 0.16.0 + Rust，出口带宽小的时候光下载就要几小时，详见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 构建、安装、版本、开发流程、PR 门禁 |
| [PATCHES.md](PATCHES.md) | 相对上游的每一个补丁，含根因分析 |
| [LATENCY.md](LATENCY.md) | 上游未解决的输入延迟问题在本仓库基线的逐条核实与处置（附源码证据） |
| [SYNC.md](SYNC.md) | 怎么跟上上游的新 release tag |
| [CHANGELOG.md](CHANGELOG.md) | 变更记录 |
| [TODO.md](TODO.md) | 待办 |

## 致谢与许可

cmux 由 [Manaflow](https://github.com/manaflow-ai/cmux) 开发，终端内核是 [Ghostty](https://github.com/ghostty-org/ghostty) 的分叉。上游版权归其作者所有；本仓库只承载 [PATCHES.md](PATCHES.md) 里列出的补丁和一条压平的历史。许可条款见 [LICENSE](LICENSE) 与 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)（GPL-3.0-or-later，另含第三方声明）。

