# 上游同步方法

## 原则

1. **基线只用上游 release tag，不用上游 `main`**。上游 main 每天在动（分叉时已落后 5000+ 个提交），跟 main 等于每天都在解冲突；跟 tag 等于每次发版跟一次。
2. **我们的改动尽量少、尽量小**：一个语义一个提交，改完就能跑 `git rebase` 搬到新 tag 上。
3. **永远不改上游的历史**：本仓库的 `main` 只由「上游基线 + 我们的补丁」组成。
4. **本地历史是压平的**（2026-11-02 脱离 fork network 时做的）：`main` 最底下只有一个「上游 `v0.65.2.2` 剥离后的基线」提交，上面是我们的补丁。下游同步**不依赖与上游共享祖先**，用的是 shallow fetch 新 tag + rebase/cherry-pick（见下文）。

## 远端配置

```bash
git remote -v
# origin    https://github.com/xhqing/cmux.git      ← 本仓库（独立仓库，不在 fork network 里），push 这里
# upstream  https://github.com/manaflow-ai/cmux.git ← 上游，只读，只 fetch（按 tag 浅拉）
```

## 分支布局（2026-11-02 重建后）

| 分支 | 角色 | 说明 |
| --- | --- | --- |
| `main` | **唯一长期分支（默认分支、受保护）** | 压平后的上游基线 + 我们的补丁；CI 与发版都从这条分支走，一切改动经 PR 合并进来 |

- **没有 fork、也没有「Sync fork」按钮**：本仓库是独立仓库（2026-11-02 主动脱离 fork network），上游只是 `upstream` remote。所以不存在「网页点一下同步」这回事，同步一律按本文下面的本地流程走。
- 需要对比「上游 `main` 到哪了」时，临时浅拉一下即可，不必在服务端留快照 ref：
  `git fetch --depth 1 upstream main && git log --oneline FETCH_HEAD -3`。

日常推送（`main` 已开保护，不能直推，必须走分支 + PR）：

```bash
git push origin HEAD:refs/heads/chore/xxx   # 先推到功能/杂事分支
gh pr create --base main --title "..." --body "..."   # PR 目标 main
gh pr merge <分支名> --squash --auto --delete-branch   # 等 checks 绿后自动合并
```

`gh` 命令一律带 `-R xhqing/cmux`：本仓库有两个 remote，`gh` 在本地 `main` 没设上游跟踪的时候可能把它自己解析到 `upstream`（报 `workflow not found` 之类的误报），带上 `-R` 就不会错。

## 跟着新 tag 升级（标准流程）

上游发了新 tag，比如 `v0.65.3.0`：

```bash
# 1. 只看这一个 tag，别拉全量历史（出口带宽有限时特别重要）
git fetch --depth 1 upstream tag v0.65.3.0

# 2. 在基线之上重建我们的补丁
#    注意：本地历史是压平的，所以「旧基线」要用压平后的那个基线提交，
#    不是上游的 12023d89f（那个提交本地没有祖先链）。
#    基线提交 = main 的根提交：git rev-list --max-parents=0 main
git switch -c sync/v0.65.3.0
git rebase --onto v0.65.3.0 $(git rev-list --max-parents=0 main) main

# 3. 解冲突（大概率集中在 PATCHES.md 列出的那几个文件）
#    解完先本地构建/CI 验证，确认补丁语义没被上游改动吃掉

# 4. 版本号与文档
#    VERSION → 0.65.3.0-xhqing.1（后缀重新从 1 开始）
#    CHANGELOG.md 顶部加一条
#    PATCHES.md 里的基线 tag 与 commit 一起更新

# 5. 合并进 main —— 走 PR（main 已保护，不能直推）
#    rebase 出来的线跟旧 main 是两条历史，本地不要 merge 进 main，
#    直接推同步分支、开 PR、squash 合并：main 上会多出一个「同步到 v0.65.3.0」的
#    提交，它的树 == 新 tag + 我们的补丁，语义与 rebase 结果完全一致。
git push -u origin sync/v0.65.3.0
gh pr create --base main --title "sync: upstream v0.65.3.0" --body "..."
gh pr merge sync/v0.65.3.0 --squash --auto --delete-branch

# 合并后本地跟上
git switch main && git pull --ff-only
```

为什么同步也走 PR（而不是像以前那样直推 main）：`main` 现在是受保护的分支（必过 checks、禁 force push、只允许 squash），而且让上游同步同样过一遍 CI 门禁是好事——万一手工解冲突解错（比如把 Sparkle 的 `SUFeedURL` 解回官方地址），门禁至少能拦住编译不过、schema 不同步、密钥泄漏这几类硬错。

> 上游同步一次能改上千个文件，`checks` 里的 Swift 语法检查会对超过 `MAX_SWIFT_PARSE`（当前 1500）的文件清单做等距抽样，日志里会打一条 `::notice::` 说明；完整的编译正确性仍然由 `build-macos` 的 Release 构建负责。

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
