#!/usr/bin/env bash
# 04-align-with-upstream-pr.sh
#
# 目的：让本地构建的后台逻辑**与提交给上游的 PR 完全一致**
#      （immich-app/immich#32955）。
#
# 历史：早先的 01/04 补丁自己实现了一版 uploadBackupCandidatesAndWait，
#      自审时发现两个缺陷并已修正：
#        ① 失败计数原先用 broadcast stream 监听 → 会漏掉入队阶段的事件
#        ② 计数器原先是类字段（Provider 单例）→ 并发调用会互相污染
#      另外 04 曾经加过一次 _uploadRepository.start() 兜底，这是**错误的**：
#      FileDownloader().start() 是 App 启动时的初始化（trackTasks /
#      rehydrateFromDatabase），不是"恢复队列执行"。enqueueAll() 本身就会
#      通过 doEnqueue() 或 HoldingQueue.add()->advanceQueue() 立即调度，
#      不需要也不能靠 start() 来"启动上传"。
#
# 本补丁把 background_upload.service.dart 里的方法替换成 PR 里的最终版本。
set -euo pipefail
cd "$(dirname "$0")/.."

BU="immich/mobile/lib/services/background_upload.service.dart"
[ -f "$BU" ] || { echo "ERROR: 找不到 $BU" >&2; exit 1; }

python3 - "$BU" << 'PY'
import sys, pathlib, re

p = pathlib.Path(sys.argv[1])
s = p.read_text()

# ── 1. 安装 _statusObserver 钩子 + 回退旧的类字段方案 ──
if "_statusObserver" not in s:
    # 去掉可能残留的旧类字段实现
    s = re.sub(
        r"  /// Number of failed tasks observed since the last\n"
        r"  /// \[uploadBackupCandidatesAndWait\] call\.[^\n]*\n"
        r"  /// waiting on the queue; see \[uploadBackupCandidatesAndWait\]\.\n"
        r"  int _failedSinceWaitStarted = 0;\n\n",
        "",
        s,
    )
    s = s.replace(
        "  void _onUploadCallback(TaskStatusUpdate update) {\n"
        "    if (update.status == TaskStatus.failed) {\n"
        "      _failedSinceWaitStarted++;\n"
        "    }\n",
        "  void _onUploadCallback(TaskStatusUpdate update) {\n",
        1,
    )

    old_cb = (
        "  void _onUploadCallback(TaskStatusUpdate update) {\n"
        "    if (!_taskStatusController.isClosed) {"
    )
    new_cb = (
        "  /// Optional observer invoked for every task status update.\n"
        "  ///\n"
        "  /// Used by [uploadBackupCandidatesAndWait] to count failures for the\n"
        "  /// current wait without relying on the broadcast stream (which would\n"
        "  /// miss events emitted before a listener is attached).\n"
        "  void Function(TaskStatusUpdate update)? _statusObserver;\n\n"
        "  void _onUploadCallback(TaskStatusUpdate update) {\n"
        "    _statusObserver?.call(update);\n"
        "    if (!_taskStatusController.isClosed) {"
    )
    if old_cb not in s:
        print("ERROR: _onUploadCallback 结构不匹配", file=sys.stderr)
        sys.exit(1)
    s = s.replace(old_cb, new_cb, 1)
    print("  ok: 已安装 _statusObserver 钩子")

# ── 2. 用 PR 最终版替换方法体 ──
start_marker = "  Future<bool> uploadBackupCandidatesAndWait("
end_marker = "  /// Cancel all ongoing background uploads and reset the upload queue"

i = s.find(start_marker)
j = s.find(end_marker)
if i < 0 or j < 0 or j < i:
    print("ERROR: 找不到 uploadBackupCandidatesAndWait 的范围", file=sys.stderr)
    sys.exit(1)

# 方法定义前的 doc comment 起点也要替换
doc_start = s.rfind("  /// Enqueues backup candidates", 0, i)
if doc_start < 0:
    # 兼容早期措辞
    doc_start = s.rfind("  /// 入队备份候选", 0, i)
if doc_start < 0:
    doc_start = i

NEW = '''  /// Enqueues backup candidates and waits until the background queue drains,
  /// the timeout elapses, or [cancellationToken] completes.
  ///
  /// Unlike [uploadBackupCandidates], which returns as soon as the tasks are
  /// enqueued, this waits for the actual uploads. That lets the caller report
  /// a meaningful result back to WorkManager so it can schedule a retry.
  ///
  /// Returns `true` only when every queued task finished successfully.
  Future<bool> uploadBackupCandidatesAndWait(
    String userId, {
    Completer<void>? cancellationToken,
    Duration timeout = const Duration(minutes: 55),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    var failed = 0;
    // Count failures through the callback hook so nothing emitted during
    // [uploadBackupCandidates] is missed.
    _statusObserver = (update) {
      if (update.status == TaskStatus.failed) {
        failed++;
      }
    };

    try {
      await uploadBackupCandidates(userId);
      return await _awaitQueueDrain(
        cancellationToken: cancellationToken,
        timeout: timeout,
        pollInterval: pollInterval,
        failedCount: () => failed,
      );
    } finally {
      _statusObserver = null;
    }
  }

  Future<bool> _awaitQueueDrain({
    required Completer<void>? cancellationToken,
    required Duration timeout,
    required Duration pollInterval,
    required int Function() failedCount,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancellationToken?.isCompleted ?? false) {
        _logger.info("Background upload cancelled by caller");
        return false;
      }

      final List<Task> active;
      try {
        active = await getActiveTasks(kBackupGroup);
      } catch (error) {
        // The service can be disposed while a background task is still
        // running; treat that as "nothing left to wait for" instead of
        // failing the whole backup.
        _logger.warning("Unable to read active background tasks: $error");
        return failedCount() == 0;
      }

      if (active.isEmpty) {
        _logger.info("Background upload queue drained (failed=${failedCount()})");
        return failedCount() == 0;
      }

      await Future<void>.delayed(pollInterval);
    }

    _logger.warning(
      "Background upload did not finish within ${timeout.inMinutes}m (failed=${failedCount()})",
    );
    return false;
  }

'''

s = s[:doc_start] + NEW + s[j:]
p.write_text(s)
print("  ok: 方法已替换为 PR 最终版")
PY

echo
echo "=== 自检 ==="
python3 - "$BU" << 'PY'
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
checks = [
    ("_statusObserver 钩子", "void Function(TaskStatusUpdate update)? _statusObserver;" in s),
    ("钩子被调用", "_statusObserver?.call(update);" in s),
    ("方法定义", "Future<bool> uploadBackupCandidatesAndWait(" in s),
    ("_awaitQueueDrain 抽出", "Future<bool> _awaitQueueDrain({" in s),
    ("局部失败计数", "var failed = 0;" in s),
    ("钩子在 finally 清理", "_statusObserver = null;" in s),
    # 注意：resume() 里那一行 _uploadRepository.start() 是上游本来就有的，
    # 不能一棍子打死。要判的是「我们的等待方法里没有多叫一次 start()」。
    ("等待方法里无多余 start()",
     "_awaitQueueDrain" in s and
     "await _uploadRepository.start();" not in s.split("Future<bool> uploadBackupCandidatesAndWait(")[1].split("/// Cancel all ongoing")[0]),
    ("无旧类字段", "_failedSinceWaitStarted" not in s),
    ("无 broadcast 监听", "_taskStatusController.stream.listen" not in s),
    ("getActiveTasks 异常保护", "Unable to read active background tasks" in s),
]
bad = 0
for name, ok in checks:
    print(f"  {'✅' if ok else '❌'} {name}")
    if not ok:
        bad += 1
sys.exit(1 if bad else 0)
PY

echo "04-align-with-upstream-pr.sh done"
