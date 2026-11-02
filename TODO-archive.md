# TODO 归档

已处理的条目按完成时间倒序归档。编号不复用。


## 已完成

- ✅ **已完成** **T6** CI 注入 `MARKETING_VERSION`（原记录：2026-11-01 02:40）：根因不是注入写法，而是 `scripts/reloads.sh` 从没把 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 这类**环境变量翻成 xcodebuild 的构建设置**——xcodebuild 只认命令行参数，所以 Info.plist 里一直还是工程硬编码的 `0.65.2`。已在 `reloads.sh` 里统一转发 `ARCHS / ONLY_ACTIVE_ARCH / MARKETING_VERSION / CURRENT_PROJECT_VERSION / COMPILER_INDEX_STORE_ENABLE`（同一处 bug 还让「只编 arm64」静默失效，一并修掉）。（完成：2026-11-02 23:10）
- ✅ **已完成** **T1** CI 流水线首次跑通：`build-macos` workflow 在 `macos-26` runner 上完整构建出 Release app 并产出可用 zip（记录：2026-10-31 22:30）（完成：2026-11-01 02:31，run 41211029928 全绿，产物 211MB、ad-hoc 签名、sha256 校验通过）
