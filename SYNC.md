# 上游同步方法

## 原则

1. **基线只用上游 release tag，不用上游 `main`**。上游 main 每天在动（分叉时已落后 5000+ 个提交），跟 main 等于每天都在解冲突；跟 tag 等于每次发版跟一次。
2. **我们的改动尽量少、尽量小**：一个语义一个提交，改完就能跑 `git rebase` 搬到新 tag 上。
3. **永远不改上游的历史**：本分叉的 `main` 只由「上游基线 + 我们的补丁」组成。

## 远端配置

```bash
git remote -v
# origin    https://github.com/xhqing/cmux.git      ← 我们的分叉，push 这里
# upstream  https://github.com/manaflow-ai/cmux.git ← 上游，只读，只 fetch
```

## 分支布局（2026-10-31 定）

| 分支 | 角色 | 说明 |
| --- | --- | --- |
| `main` | **上游镜像** | 只跟踪上游 main，可以随时被快速前进（fast-forward）；我们的改动**不放这里** |
| `xhqing` | **我们的分叉线** | 上游 release tag + 我们的补丁；**仓库默认分支、CI 与发版都从这条分支走** |

为什么分开：我们的基线钉在 release tag 上，而上游 main 每天几百个提交，两套历史必然分叉（实测：tag `v0.65.2.2` 与上游 main 最新的 GitHub compare 结果是 `diverged`，谁都快进不了谁）。把两者分开，任何一边都能干净地快进，**全程不需要 force**。

**注意**：默认分支已经切到 `xhqing`，GitHub 网页上的「Sync fork」按钮对 `main` 可能不再好用（它默认同步默认分支）。上游同步统一按本文下面的本地 `git fetch --depth 1 upstream <tag>` + rebase 流程走，**不依赖网页按钮**。

日常推送：

```bash
git push origin HEAD:refs/heads/xhqing   # 或已设跟踪后直接 git push
```

`gh` 命令一律带 `-R xhqing/cmux`：本仓库有两个 remote，`gh` 在本地 `main` 没设上游跟踪的时候会把它自己解析到 `upstream`（报 `workflow not found` 之类的误报），带上 `-R` 就不会错。

## 跟着新 tag 升级（标准流程）

上游发了新 tag，比如 `v0.65.3.0`：

```bash
# 1. 只看这一个 tag，别拉全量历史（出口带宽有限时特别重要）
git fetch --depth 1 upstream tag v0.65.3.0

# 2. 在基线之上重建我们的补丁
git switch -c sync/v0.65.3.0
git rebase --onto v0.65.3.0 v0.65.2.2 main

# 3. 解冲突（大概率集中在 PATCHES.md 列出的那几个文件）
#    解完先本地构建/CI 验证，确认补丁语义没被上游改动吃掉

# 4. 版本号与文档
#    VERSION → 0.65.3.0-xhqing.1（后缀重新从 1 开始）
#    CHANGELOG.md 顶部加一条
#    PATCHES.md 里的基线 tag 与 commit 一起更新

# 5. 合并回 main 并推送
git switch main
git merge --ff-only sync/v0.65.3.0
git push origin main
```

## 如果本地只有浅历史（`--depth 1`）

浅克隆状态下 `git rebase --onto` 有时会因为找不到旧基线的祖先而报错，两个办法：

- 补拉旧基线：`git fetch --depth 1 upstream tag v0.65.2.2`（把老基线也拉到本地）；
- 或者直接 `git cherry-pick` 我们的补丁提交到新基线分支上（补丁只有一两个提交时最省事）：

```bash
git switch -c sync/v0.65.3.0 v0.65.3.0
git cherry-pick <补丁提交1> <补丁提交2>
```

## 判断上游是否改了我们的补丁点

升级前先看一眼上游有没有动这几个文件（有动就要重点验）：

```bash
git fetch --depth 1 upstream tag <新tag>
git diff --stat v0.65.2.2 <新tag> -- \
  Sources/Workspace.swift \
  Packages/macOS/CmuxSettings \
  Packages/macOS/CmuxSettingsUI \
  Resources/Info.plist
```

## 什么时候同步

- 上游发新 tag 且在意的功能/修复出现在我们关心的范围（关闭确认、会话恢复、agent 会话桥接）；
- 我们的补丁和上游新代码出现语义冲突；
- 至少每 1~2 个月看一次 `gh release list -R manaflow-ai/cmux`。

## Sparkle 提醒

每次从上游同步 `Resources/Info.plist` 时，**务必检查 `SUEnableAutomaticChecks` 与 `SUFeedURL` 是否被上游的默认值覆盖回来**——一旦被改回官方 feed，官方版本会直接把我们自建的 app 覆盖掉。
