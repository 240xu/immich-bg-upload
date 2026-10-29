# Immich Android 后台上传定制构建

把 Immich 安卓端的上传链路从「前台专用」改成「切后台继续传」。

## 问题

Immich 安卓 App 手动触发备份后切到后台，上传会被立即取消：

```
Foreground backup cancelled: the app being sent to the background
    at 22:07:01.302 in BackupNotifier
```

大视频（数百 MB）因此反复从头传，永远传不完。

## 官方现状（源码实证，v3.3.5）

| 服务 | 引擎 | 谁在用 |
|---|---|---|
| `ForegroundUploadService` | 纯 Dart 循环，逐个 `POST /assets` | **Android 唯一在用** |
| `BackgroundUploadService` | `background_downloader`（Android=WorkManager+前台服务） | 仅 iOS |

`background_worker.service.dart` 的 `_handleBackup()` 里，Android 分支调的是
`foregroundUploadService.uploadCandidates(...)`——即便在后台 worker 里也是如此。

## 本仓库做什么

在官方源码上打补丁后编译 APK。**不改服务端、不改上传协议**，仍走官方 `POST /assets`。

## 构建

Actions 里手动触发 `Build Immich APK`，或：

```bash
git push   # 改动 patches/ 会自动触发
```

产物在 Actions run 的 Artifacts 里（`immich-apk-vX.Y.Z`）。

## 补丁清单

| 补丁 | 作用 |
|---|---|
| `00-kotlin-serialization-fix.sh` | 修 `background_downloader` 与项目 Kotlin 的 serialization 插件版本冲突 |

> 后续补丁（后台上传交接）在验证编译链路后加入。

## 已知约束

- 只构建 arm64-v8a（小米 14 / 绝大多数现代安卓机）
- 无断点续传（那需要 upstream PR #22385 的 RUFH 协议，本项目不涉及）
- 官方每发新版需 rebase 补丁
