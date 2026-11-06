#!/usr/bin/env bash
# 08-background-sync-budget.sh
#
# 目标：让「远端同步」在 Android 后台任务里可靠完成，而不是被系统随时掐断后一直原地打转。
#
# ── 现状问题（v3.3.6 源码实证）─────────────────────────────────
# 1) BackgroundWorker.onInitialized() 固定给 20 分钟预算：
#      flutterApi?.onAndroidUpload(maxMinutesArg = 20)
#    但 onAndroidUpload 里这个预算只用来保护「备份」阶段：
#      backupTimeout = maxMinutes - 1
#      cancelTimer = Timer(backupTimeout, () => _cancellationToken.complete())
#    而 _syncAssets() 在 cancelTimer 启动**之前**执行，完全没有预算保护。
#
# 2) SyncStreamService.sync() **永远返回 true**，即使同步流被 abort：
#      await _syncApiRepository.streamChanges(..., abortSignal: _cancellation?.future);
#      ...
#      return true;      // ← 中途被取消也返回 true
#    于是 _backgroundLoop 认为同步成功，继续去备份；WorkManager 也认为
#    整个任务成功，不会触发重试。
#
# 3) 结果：首次全量同步（2164 张图）跑 8.8 分钟后被 Android 杀掉 Worker，
#    但「成功」的假象让系统不再重试；用户只能反复打开 App，
#    而每次打开都从头再来一遍 → 同步永远跑不完 → 人物/回忆永远为空。
#
# ── 本补丁做三件事 ──────────────────────────────────────────
#   A. SyncStreamService.sync() 如实返回「是否真的跑完」
#      （被 abort 时返回 false）
#   B. _syncAssets() 加预算保护：超时则中止同步并返回「未完成」
#   C. _backgroundLoop 在同步未完成时，明确告诉 WorkManager「要重试」
#      （返回 false，让上层 enqueue 重试而不是当成成功）
#
# 这样同步就变成「后台可续跑」：每次 Worker 醒来跑一段，
# 超时前停下，下次接着跑（Immich 同步协议本身是增量 + ack 的）。
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_SVC="immich/mobile/lib/domain/services/sync_stream.service.dart"
BG_SVC="immich/mobile/lib/domain/services/background_worker.service.dart"

for f in "$SYNC_SVC" "$BG_SVC"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════
# A. SyncStreamService.sync(): 如实返回是否跑完
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/lib/domain/services/sync_stream.service.dart")
s = p.read_text()

if "syncCompleted" in s:
    print("    sync_stream.service: 已存在")
else:
    old = """    previousLength = migrations.length;
    await _runPostSyncTasks(migrations);

    if (migrations.length != previousLength) {
      _logger.info("Updated pre-sync migration status: $migrations");
      await Store.put(StoreKey.syncMigrationStatus, jsonEncode(migrations));
    }

    return true;
  }"""
    new = """    previousLength = migrations.length;
    await _runPostSyncTasks(migrations);

    if (migrations.length != previousLength) {
      _logger.info("Updated pre-sync migration status: $migrations");
      await Store.put(StoreKey.syncMigrationStatus, jsonEncode(migrations));
    }

    // 如果同步过程中被取消（后台任务超时 / 用户主动取消），
    // 这条流并没有跑完，必须如实返回 false，否则上层会误以为同步成功：
    //   - _backgroundLoop 会继续跑备份
    //   - WorkManager 认为任务成功，不再重试
    // ⇒ 首次全量同步会永远卡在同一段，人物/回忆之类排在后面的类型永远拿不到。
    final syncCompleted = !isCancelled;
    if (!syncCompleted) {
      _logger.warning("Sync stream was cancelled before completion");
    }
    return syncCompleted;
  }"""
    assert old in s, "sync_stream: 找不到 sync() 尾部"
    s = s.replace(old, new, 1)
    p.write_text(s)
    print("    sync_stream.service: sync() 如实返回")
PYEOF

# ═══════════════════════════════════════════════════════
# B. _syncAssets(): 加预算保护
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/lib/domain/services/background_worker.service.dart")
s = p.read_text()

if "syncBudget" in s:
    print("    background_worker: 已存在")
else:
    old = """  Future<bool> _syncAssets({Duration? hashTimeout}) async {
    await _localSyncService.sync();
    if (_isCleanedUp) {
      return false;
    }

    final isSuccess = await _remoteSyncService.sync();
    if (_isCleanedUp) {
      return isSuccess;
    }
"""
    new = """  Future<bool> _syncAssets({Duration? hashTimeout, Duration? syncBudget}) async {
    await _localSyncService.sync();
    if (_isCleanedUp) {
      return false;
    }

    // 给远端同步一个预算：后台任务有可能被 Android 随时杀掉，
    // 与其死在半路（下次又从头来），不如在超时前主动收尾。
    // Immich 同步协议是增量 + ack 的，主动中止不会丢失已同步的部分，
    // 下一次 Worker 醒来会从上次 ack 的位置继续。
    Future<bool> remoteFuture = _remoteSyncService.sync();
    if (syncBudget != null) {
      remoteFuture = remoteFuture.timeout(
        syncBudget,
        onTimeout: () {
          _logger.warning("Remote sync exceeded budget of ${syncBudget.inMinutes}m, will resume next run");
          if (!_cancellationToken.isCompleted) {
            _cancellationToken.complete();
          }
          return false;
        },
      );
    }

    final isSuccess = await remoteFuture;
    if (_isCleanedUp) {
      return isSuccess;
    }
"""
    assert old in s, "background_worker: 找不到 _syncAssets 头部"
    s = s.replace(old, new, 1)
    p.write_text(s)
    print("    background_worker: _syncAssets 加 syncBudget")
PYEOF

# ═══════════════════════════════════════════════════════
# C. _backgroundLoop / onAndroidUpload: 把预算传下去 + 未完成时要求重试
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/lib/domain/services/background_worker.service.dart")
s = p.read_text()

if "syncBudget:" in s and "will resume on next background run" in s:
    print("    background_worker: 预算传递已存在")
else:
    # C1. onAndroidUpload 算出同步预算
    #
    # ⚠️ 不要锚定 backupTimeout 那一行 —— 补丁 02 会把它从
    #      final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes - 1) : null;
    #    改成
    #      final backupTimeout = Duration(minutes: maxMinutes ?? fallbackMinutes);
    # 锚定它会因补丁执行顺序而匹配失败（CI #48 就栽在这里）。
    # 改为锚定「await _optimizeDB(); + return _backgroundLoop(」，这段 00~07 都不碰。
    marker = """    await _optimizeDB();
    return _backgroundLoop(
      hashTimeout: hashTimeout,
      backupTimeout: backupTimeout,
      debugLabel: 'Android background upload',
    );"""
    new_marker = """    // 同步预算：给总预算的一半，至少 5 分钟。
    // 剩余时间留给哈希 + 备份，避免同步吃光整个后台窗口。
    // maxMinutes 为 null 时不设预算（沿用原行为，不额外限制）。
    final syncBudget = maxMinutes != null
        ? Duration(minutes: maxMinutes ~/ 2 < 5 ? 5 : maxMinutes ~/ 2)
        : null;
    await _optimizeDB();
    return _backgroundLoop(
      hashTimeout: hashTimeout,
      backupTimeout: backupTimeout,
      syncBudget: syncBudget,
      debugLabel: 'Android background upload',
    );"""
    assert marker in s, "background_worker: 找不到 _optimizeDB + _backgroundLoop 调用点"
    s = s.replace(marker, new_marker, 1)

    # C2. _backgroundLoop 签名 + 传预算 + 未完成要重试
    old2 = """  Future<bool> _backgroundLoop({
    required Duration hashTimeout,
    required Duration? backupTimeout,
    required String debugLabel,
  }) async {
    _logger.info(
      '$debugLabel started hashTimeout: ${hashTimeout.inSeconds}s, backupTimeout: ${backupTimeout?.inMinutes ?? '~'}m',
    );
    final sw = Stopwatch()..start();
    try {
      if (!await _syncAssets(hashTimeout: hashTimeout)) {
        _logger.warning("Remote sync did not complete successfully, skipping backup");
        return true;
      }
"""
    new2 = """  Future<bool> _backgroundLoop({
    required Duration hashTimeout,
    required Duration? backupTimeout,
    required String debugLabel,
    Duration? syncBudget,
  }) async {
    _logger.info(
      '$debugLabel started hashTimeout: ${hashTimeout.inSeconds}s, '
      'backupTimeout: ${backupTimeout?.inMinutes ?? '~'}m, '
      'syncBudget: ${syncBudget?.inMinutes ?? '~'}m',
    );
    final sw = Stopwatch()..start();
    try {
      if (!await _syncAssets(hashTimeout: hashTimeout, syncBudget: syncBudget)) {
        _logger.warning("Remote sync did not complete, will resume on next background run");
        // 返回 false ⇒ 让 WorkManager 判定「任务未完成」，尽快重新入队。
        // 同步协议是增量的，下次会从上次 ack 处继续，不会重头再来。
        return false;
      }
"""
    assert old2 in s, "background_worker: 找不到 _backgroundLoop 签名"
    s = s.replace(old2, new2, 1)

    p.write_text(s)
    print("    background_worker: 预算传递 + 未完成返回 false")
PYEOF

echo ""
echo "==> 校验"
grep -q "syncCompleted" immich/mobile/lib/domain/services/sync_stream.service.dart && echo "  ✅ sync_stream.sync() 如实返回"
grep -q "syncBudget" immich/mobile/lib/domain/services/background_worker.service.dart && echo "  ✅ _syncAssets 预算"
grep -q "will resume on next background run" immich/mobile/lib/domain/services/background_worker.service.dart && echo "  ✅ 未完成要求重试"
echo ""
echo "==> 08 补丁完成"
