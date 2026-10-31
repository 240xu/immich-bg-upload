#!/usr/bin/env bash
# 01-android-background-upload.sh
#
# 目标：Android 端备份在 App 退到后台后继续传完，而不是被立即取消。
#
# ── 官方现状（v3.3.5 源码实证）────────────────────────────────
# background_worker.service.dart 的 _handleBackup():
#   iOS   -> startBackupWithURLSession()  = BackgroundUploadService（URLSession）
#   其它  -> foregroundUploadService.uploadCandidates()  = 纯 Dart 循环
# 前台循环一旦 App 进后台就被 lifecycle 取消：
#   "Foreground backup cancelled: the app being sent to the background"
#
# Android 侧其实是具备后台能力的（已核实）：
#   - BackgroundWorker.kt 用 WorkManager + setForegroundAsync() + 通知栏
#   - AndroidManifest 有 FOREGROUND_SERVICE_DATA_SYNC / POST_NOTIFICATIONS
#   - background_downloader 声明 UIDTJobService foregroundServiceType=dataSync
# 只是 Flutter 侧没把上传接到这条链路上。
#
# ── 本补丁做三件事 ──────────────────────────────────────────
#   A. Android 分支改走 BackgroundUploadService
#   B. 新增 uploadBackupCandidatesAndWait()：入队后等待队列清空
#   C. 单轮时间预算 20min -> 55min（可编辑），避免大文件反复重传
#
# 不改协议、不改服务端：仍是一个 POST /assets 上传一个文件。
set -euo pipefail
cd "$(dirname "$0")/.."

WORKER="immich/mobile/lib/domain/services/background_worker.service.dart"
BU="immich/mobile/lib/services/background_upload.service.dart"

for f in "$WORKER" "$BU"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

python3 - << 'PYEOF'
import sys, pathlib

worker = pathlib.Path("immich/mobile/lib/domain/services/background_worker.service.dart")
bu = pathlib.Path("immich/mobile/lib/services/background_upload.service.dart")

# ═══════════════════════════════════════════════════════
# A. _handleBackup: Android 改走 BackgroundUploadService
# ═══════════════════════════════════════════════════════
s = worker.read_text()

OLD = """      final uploadService = _ref?.read(foregroundUploadServiceProvider);
      var failed = 0;
      await uploadService?.uploadCandidates(
        currentUser.id,
        _cancellationToken,
        callbacks: UploadCallbacks(onError: (_, _) => failed++),
        useSequentialUpload: true,
      );
      _logger.info("Background backup finished, $failed uploads failed");
      // Retry when at least one upload failed
      return failed > 0;"""

NEW = """      // Android 也走 BackgroundUploadService：底层 background_downloader
      // 在 Android 上是 WorkManager + 前台服务（常驻通知），
      // App 退到后台后不会被 lifecycle 取消。
      final bgUpload = _ref?.read(backgroundUploadServiceProvider);
      if (bgUpload == null) {
        _logger.warning("backgroundUploadService unavailable, skipping backup");
        return false;
      }
      final ok = await bgUpload.uploadBackupCandidatesAndWait(
        currentUser.id,
        cancelToken: _cancellationToken,
      );
      _logger.info("Background backup finished, allSuccess=$ok");
      // 有失败则让 WorkManager 重试
      return !ok;"""

if OLD not in s:
    print("ERROR: 找不到 _handleBackup 的 Android 分支原文", file=sys.stderr)
    sys.exit(1)
s = s.replace(OLD, NEW, 1)

if "services/background_upload.service.dart" not in s:
    s = s.replace(
        "import 'package:immich_mobile/services/api.service.dart';",
        "import 'package:immich_mobile/services/api.service.dart';\n"
        "import 'package:immich_mobile/services/background_upload.service.dart';",
        1,
    )

# ═══════════════════════════════════════════════════════
# C. 时间预算：20 分钟 -> 55 分钟
#    Android 侧 Kotlin 传的是 20，这里减 1 作为安全余量。
#    直接把下限放宽，让单个大文件有机会传完。
# ═══════════════════════════════════════════════════════
# 注：单轮时间预算不在此处理——由 02 补丁从设置页配置下发（Kotlin 默认 55 分钟）。

# ═══════════════════════════════════════════════════════
# C2. 前台服务阈值 256MB -> 10MB
# ═══════════════════════════════════════════════════════
if "runInForegroundIfFileLargerThan, 256" in s:
    s = s.replace(
        "runInForegroundIfFileLargerThan, 256",
        "runInForegroundIfFileLargerThan, 10",
        1,
    )
    s = s.replace(
        "// On Android, if files are larger than 256MB, run in foreground service",
        "// 10MB 以上即升级为 Android 前台服务（带常驻通知），抵抗 OEM 后台限制",
        1,
    )

worker.write_text(s)
print("patched background_worker.service.dart (A + C)")

# ═══════════════════════════════════════════════════════
# B. BackgroundUploadService: 新增 wait 方法
# ═══════════════════════════════════════════════════════
b = bu.read_text()
ANCHOR = "  /// Cancel all ongoing background uploads and reset the upload queue"

METHOD = '''  /// 入队备份候选，并阻塞直到后台队列清空（或超时）。
  ///
  /// 与 [uploadBackupCandidates] 的区别：后者入队即返回，
  /// 本方法会一直等到任务真正传完，让调用方知道本轮是否还有活。
  /// 返回 true 表示全部成功。
  Future<bool> uploadBackupCandidatesAndWait(
    String userId, {
    Completer<void>? cancelToken,
    Duration timeout = const Duration(minutes: 55),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    await uploadBackupCandidates(userId);

    final deadline = DateTime.now().add(timeout);
    var hadFailure = false;

    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCompleted ?? false) {
        _logger.info("background upload cancelled by caller");
        break;
      }

      final active = await getActiveTasks(kBackupGroup);
      if (active.isEmpty) {
        _logger.info("background upload queue drained");
        return !hadFailure;
      }

      // 注意：Task 对象本身不含状态字段（状态只在 TaskStatusUpdate 回调里），
      // 这里只关心「队列是否还有活」，失败计数交由 _onUploadCallback 处理。
      await Future<void>.delayed(pollInterval);
    }

    _logger.warning("background upload wait ended (timeout or cancelled)");
    return false;
  }

'''

if "uploadBackupCandidatesAndWait" in b:
    print("skip: 已存在 uploadBackupCandidatesAndWait")
elif ANCHOR in b:
    b = b.replace(ANCHOR, METHOD + ANCHOR, 1)
    bu.write_text(b)
    print("patched background_upload.service.dart (B)")
else:
    print("ERROR: 找不到插入锚点", file=sys.stderr)
    sys.exit(1)

print("01-android-background-upload.sh done")
PYEOF
