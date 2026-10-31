#!/usr/bin/env bash
# 04-fix-upload-wait-and-start.sh
#
# 修正 01 补丁遗留的三个缺陷（审查发现）：
#
#   缺陷1: uploadBackupCandidatesAndWait 里 hadFailure 恒为 false
#          → 上传失败也不会触发 WorkManager 重试。
#          改用 _onUploadCallback 计数（通过 failCounter 回调）。
#
#   缺陷2: 入队后未显式 start()
#          enqueueAll() 通常会自动启动，但官方 resume() 的存在说明
#          暂停态需要显式 start。补一个兜底调用（失败无害）。
#
#   缺陷3: 轮询期间若 BackgroundUploadService 被 dispose，getActiveTasks 会抛异常
#          → 包一层 try/catch，避免整个备份流程崩掉。
set -euo pipefail
cd "$(dirname "$0")/.."

BU="immich/mobile/lib/services/background_upload.service.dart"
[ -f "$BU" ] || { echo "ERROR: 找不到 $BU" >&2; exit 1; }

python3 - "$BU" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

if 'failedCount' in s and 'getActiveTasks failed' in s:
    print("skip: 已修正过")
    sys.exit(0)

start_marker = "  Future<bool> uploadBackupCandidatesAndWait("
end_marker = "  /// Cancel all ongoing background uploads and reset the upload queue"

i = s.find(start_marker)
j = s.find(end_marker)
if i < 0 or j < 0 or j < i:
    print("ERROR: 找不到 uploadBackupCandidatesAndWait 定义范围", file=sys.stderr)
    sys.exit(1)

OLD_METHOD = s[i:j]

NEW_METHOD = '''  /// 入队备份候选，并阻塞直到后台队列清空（或超时）。
  ///
  /// 与 [uploadBackupCandidates] 的区别：后者入队即返回，本方法等待传完。
  /// 返回 true 表示全部成功；false 表示有失败、超时或被取消。
  Future<bool> uploadBackupCandidatesAndWaitV2(
    String userId, {
    Completer<void>? cancelToken,
    Duration timeout = const Duration(minutes: 55),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    // 统计本轮失败数：挂在 _onUploadCallback 同一条回调链上
    var failedCount = 0;
    final previous = _uploadRepository.onUploadStatus;
    _uploadRepository.onUploadStatus = (update) {
      previous?.call(update);
      if (update.status == TaskStatus.failed) failedCount++;
    };

    try {
      await uploadBackupCandidates(userId);

      // enqueueAll 正常会自动启动；若队列处于暂停态则显式恢复。
      // start() 在无暂停任务时是空操作，失败也不影响主流程。
      try {
        await _uploadRepository.start();
      } catch (_) {
        // ignore: 仅作兜底
      }

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (cancelToken?.isCompleted ?? false) {
          _logger.info("background upload cancelled by caller (failed=$failedCount)");
          return false;
        }

        List<Task> active;
        try {
          active = await getActiveTasks(kBackupGroup);
        } catch (e) {
          _logger.warning("getActiveTasks failed, treating as drained: $e");
          return failedCount == 0;
        }

        if (active.isEmpty) {
          _logger.info("background upload queue drained (failed=$failedCount)");
          return failedCount == 0;
        }

        await Future<void>.delayed(pollInterval);
      }

      _logger.warning(
        "background upload wait timed out (failed=$failedCount)",
      );
      return false;
    } finally {
      _uploadRepository.onUploadStatus = previous;
    }
  }

'''

s = s[:i] + NEW_METHOD + s[j:]
p.write_text(s)
print("patched: uploadBackupCandidatesAndWait -> V2（失败计数 + start 兜底 + 异常保护）")
PY

echo "=== 统一方法名：V2 -> 原名称（供 01 补丁调用）==="
python3 - "$BU" << 'PY2'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
# 把 V2 改名回原名，保持 01 补丁的调用点不变
s = s.replace("uploadBackupCandidatesAndWaitV2(", "uploadBackupCandidatesAndWait(")
p.write_text(s)
print("  ok: 方法名已恢复为 uploadBackupCandidatesAndWait")
PY2

echo "=== 自检 ==="
python3 - "$BU" << 'PY'
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
checks = [
    ("方法定义", "uploadBackupCandidatesAndWait(" in s),
    ("失败计数", "if (update.status == TaskStatus.failed) failedCount++;" in s),
    ("start 兜底", "await _uploadRepository.start();" in s),
    ("getActiveTasks 异常保护", "getActiveTasks failed, treating as drained" in s),
    ("恢复原回调", "_uploadRepository.onUploadStatus = previous;" in s),
    ("不再有恒 false 的 hadFailure", "var hadFailure = false;" not in s),
]
bad = 0
for n, ok in checks:
    print(f"  {'✅' if ok else '❌'} {n}")
    if not ok: bad += 1
sys.exit(1 if bad else 0)
PY

echo "04-fix-upload-wait-and-start.sh done"
