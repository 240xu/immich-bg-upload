#!/usr/bin/env bash
# 03-handoff-on-background.sh
#
# 目标：App 退到后台的**那一刻**，把未完成的前台备份交接到后台服务，
#       实现「按 home → 立刻由 WorkManager 接手」，而不是等到下次系统调度。
#
# 官方现状（v3.3.5）app_life_cycle.provider.dart:
#   Future<void> _performPause() {
#     if (authenticated) {
#       backupNotifier.stopForegroundBackup(reason: "the app being sent to the background");
#       websocketProvider.disconnect();
#     }
#   }
# 直接掐掉，没有任何交接。
#
# 改法：取消前先判断前台是否在跑，在跑就把候选队列交给 BackgroundUploadService。
# 安全性：getCandidates() 用 checksum 与服务器资产表 join 去重，
#        已传完的不会重复入队。
set -euo pipefail
cd "$(dirname "$0")/.."

LC="immich/mobile/lib/providers/app_life_cycle.provider.dart"
BACKUP="immich/mobile/lib/providers/backup/backup.provider.dart"

for f in "$LC" "$BACKUP"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

echo "=== A. BackupNotifier: 暴露 isForegroundBackupRunning ==="
python3 - "$BACKUP" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

if 'isForegroundBackupRunning' in s:
    print("  skip: 已存在")
else:
    old = """  void stopForegroundBackup({required String reason}) {"""
    new = """  /// 前台备份是否正在运行（用于切后台时决定要不要交接）
  bool get isForegroundBackupRunning => _cancelToken != null;

  void stopForegroundBackup({required String reason}) {"""
    if old not in s:
        print("ERROR: stopForegroundBackup 未匹配", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== B. _performPause: 取消前先交接 ==="
python3 - "$LC" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

if 'handoffToBackground' in s:
    print("  skip: 已存在")
else:
    old = """  Future<void> _performPause() {
    if (_ref.read(authProvider).isAuthenticated) {
      _ref.read(backupProvider.notifier).stopForegroundBackup(reason: "the app being sent to the background");

      _ref.read(websocketProvider.notifier).disconnect();
    }

    return LogService.I.flush().catchError((_) {});
  }"""

    new = """  Future<void> _performPause() async {
    if (_ref.read(authProvider).isAuthenticated) {
      final backupNotifier = _ref.read(backupProvider.notifier);

      // 切后台时，如果前台备份还在跑，先把它交接到后台上传服务
      // （background_downloader -> WorkManager + 前台服务），
      // 这样上传不会因为 App 进入后台而被中断。
      // getCandidates() 以 checksum 与服务器资产表 join 去重，
      // 已传完的不会重复入队。
      if (backupNotifier.isForegroundBackupRunning) {
        // 确保 background engine 锁已释放，否则后台 worker 启动时会被 skip
        // （BackgroundWorker.startWork: isLocked && connectEngines>0 -> skip）
        // 用超时保护：切后台有时限，不能因平台通道慢而阻塞
        try {
          await _ref
              .read(backgroundWorkerLockServiceProvider)
              .unlock()
              .timeout(const Duration(milliseconds: 1500));
        } catch (e) {
          _log.warning("unlock before handoff failed/timed out: $e");
        }
        final currentUser = _ref.read(currentUserProvider);
        if (currentUser != null) {
          _log.info("Handing off foreground backup to background service");
          unawaited(
            _ref
                .read(backgroundUploadServiceProvider)
                .uploadBackupCandidates(currentUser.id)
                .catchError((Object e) {
                  _log.warning("Background handoff failed: $e");
                }),
          );
        }
      }

      backupNotifier.stopForegroundBackup(reason: "the app being sent to the background");

      _ref.read(websocketProvider.notifier).disconnect();
    }

    return LogService.I.flush().catchError((_) {});
  }"""

    if old not in s:
        print("ERROR: _performPause 结构不匹配", file=sys.stderr); sys.exit(1)
    s = s.replace(old, new, 1)

    # 补 import
    needed = [
        ("import 'package:immich_mobile/providers/user.provider.dart';",
         "import 'package:immich_mobile/providers/user.provider.dart';"),
        ("import 'package:immich_mobile/services/background_upload.service.dart';",
         "import 'package:immich_mobile/services/background_upload.service.dart';"),
    ]
    if "providers/user.provider.dart" not in s:
        s = s.replace(
            "import 'package:immich_mobile/providers/backup/backup.provider.dart';",
            "import 'package:immich_mobile/providers/backup/backup.provider.dart';\n"
            "import 'package:immich_mobile/providers/user.provider.dart';",
            1)
    if "services/background_upload.service.dart" not in s:
        s = s.replace(
            "import 'package:immich_mobile/providers/user.provider.dart';",
            "import 'package:immich_mobile/providers/user.provider.dart';\n"
            "import 'package:immich_mobile/services/background_upload.service.dart';",
            1)

    p.write_text(s); print("  ok")
PY

echo "=== C. 自检：确认改动确实落盘 ==="
python3 - "$LC" "$BACKUP" << 'PY'
import sys, pathlib
lc = pathlib.Path(sys.argv[1]).read_text()
bk = pathlib.Path(sys.argv[2]).read_text()

checks = [
    ("isForegroundBackupRunning 定义", "isForegroundBackupRunning => _cancelToken != null" in bk),
    ("交接调用", "uploadBackupCandidates(currentUser.id)" in lc),
    ("handoff 日志", "Handing off foreground backup to background service" in lc),
    ("user provider import", "providers/user.provider.dart" in lc),
    ("background upload import", "services/background_upload.service.dart" in lc),
    ("保留了 disconnect", "websocketProvider.notifier).disconnect()" in lc),
]
bad = 0
for name, ok in checks:
    print(f"  {'✅' if ok else '❌'} {name}")
    if not ok: bad += 1
sys.exit(1 if bad else 0)
PY

echo "03-handoff-on-background.sh done"
