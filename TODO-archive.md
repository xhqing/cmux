# TODO 归档

已处理的条目按完成时间倒序归档。编号不复用。


## 已完成

- ✅ **已完成** **T2** 自建版并行安装后验证 P1 的真实行为（记录：2026-10-31 22:30）：用户实测第 1 条「关掉跑着 pi 的工作区不再弹窗」通过；其余两条（设置页开关打开后恢复提示、"Don't ask again" 勾选生效）用户明确表示不需要验收（第 2 条不在乎、第 3 条场景已不存在）。P1 随后续版本发布。（完成：2026-11-04 14:45）
- ✅ **已完成** **T8** 新仓库首次 CI 构建复验（记录：2026-11-02 18:10）：剥离后实跑 `build-macos`（arm64）全绿，run 41469693363 产出 107MB 产物，`校验 Sparkle / 打包 / 上传产物` 三步都 success —— 说明只留 macOS 构建闭包没有打断编译链。（完成：2026-11-03 07:10）
- ✅ **已完成** **T7** 新仓库的 Actions 与 required check（记录：2026-11-02 18:10）：重建后 Actions 直接可用（`build-macos` / `PR Checks` 均 active，旧 fork 那个「HTTP 422 Actions 被禁用」的状态随之消失），`PR Checks` 在 push 与 PR 上都能跑且已绿；`main` 保护已按旧仓库存档重设，并加上 required status check `checks`（strict）+ enforce admins。（完成：2026-11-03 07:15）
- ✅ **已完成** **T6** CI 注入 `MARKETING_VERSION`（原记录：2026-11-01 02:40）：根因不是注入写法，而是 `scripts/reloads.sh` 从没把 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 这类**环境变量翻成 xcodebuild 的构建设置**——xcodebuild 只认命令行参数，所以 Info.plist 里一直还是工程硬编码的 `0.65.2`。已在 `reloads.sh` 里统一转发 `ARCHS / ONLY_ACTIVE_ARCH / MARKETING_VERSION / CURRENT_PROJECT_VERSION / COMPILER_INDEX_STORE_ENABLE`（同一处 bug 还让「只编 arm64」静默失效，一并修掉）。（完成：2026-11-02 23:10）
- ✅ **已完成** **T1** CI 流水线首次跑通：`build-macos` workflow 在 `macos-26` runner 上完整构建出 Release app 并产出可用 zip（记录：2026-10-31 22:30）（完成：2026-11-01 02:31，run 41211029928 全绿，产物 211MB、ad-hoc 签名、sha256 校验通过）
