#!/usr/bin/env bash
# 02-editable-max-upload-minutes.sh
#
# 目标：把「后台上传单轮最大运行时间」做成备份设置页里可调的选项。
#
# 官方做法：BackgroundWorker.kt 里硬编码
#     flutterApi?.onAndroidUpload(maxMinutesArg = 20)
#
# 本补丁改成读 SharedPreferences，并在备份设置页加一个滑块：
#     5 / 15 / 30 / 55 / 120 分钟
#
# 涉及 4 层：
#   1. pigeon 定义      -> BackgroundWorkerSettings 增加 maxUploadMinutes
#   2. Kotlin 存储      -> BackgroundWorkerPreferences 增加读写
#   3. Kotlin 读取      -> BackgroundWorker 用配置值而非写死的 20
#   4. Dart 设置页      -> 新增滑块 + 调用 configure()
set -euo pipefail
cd "$(dirname "$0")/.."

PIGEON="immich/mobile/pigeon/background_worker_api.dart"
PREFS="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/background/BackgroundWorkerPreferences.kt"
WORKER_KT="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/background/BackgroundWorker.kt"
WORKER_DART="immich/mobile/lib/domain/services/background_worker.service.dart"
SETTINGS_UI="immich/mobile/lib/widgets/settings/backup_settings/backup_settings.dart"
BACKUP_CFG="immich/mobile/lib/domain/models/config/backup_config.dart"
SETTINGS_KEY="immich/mobile/lib/domain/models/settings_key.dart"
APP_CONFIG="immich/mobile/lib/domain/models/config/app_config.dart"

for f in "$PIGEON" "$PREFS" "$WORKER_KT" "$WORKER_DART" "$SETTINGS_UI" "$BACKUP_CFG" "$SETTINGS_KEY" "$APP_CONFIG"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

echo "=== 0a. BackupConfig: 新增 maxUploadMinutes 字段 ==="
python3 - "$BACKUP_CFG" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'maxUploadMinutes' in s:
    print("  skip: 已存在")
else:
    old = "    @Default(false) bool syncAlbums,\n  }) = _BackupConfig;"
    new = ("    @Default(false) bool syncAlbums,\n"
           "    /// 后台上传单轮最大运行分钟数（Android）\n"
           "    @Default(55) int maxUploadMinutes,\n"
           "  }) = _BackupConfig;")
    if old not in s:
        print("ERROR: BackupConfig 结构不匹配", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== 0b. SettingsKey: 新增 backupMaxUploadMinutes ==="
python3 - "$SETTINGS_KEY" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'backupMaxUploadMinutes' in s:
    print("  skip: 已存在")
else:
    old = "  backupTriggerDelay<int>(),"
    new = ("  backupTriggerDelay<int>(),\n"
           "  backupMaxUploadMinutes<int>(),")
    if old not in s:
        print("ERROR: SettingsKey 结构不匹配", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== 1. pigeon: BackgroundWorkerSettings 加 maxUploadMinutes ==="
python3 - "$PIGEON" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = """class BackgroundWorkerSettings {
  final bool requiresCharging;
  final int minimumDelaySeconds;

  const BackgroundWorkerSettings({required this.requiresCharging, required this.minimumDelaySeconds});
}"""
new = """class BackgroundWorkerSettings {
  final bool requiresCharging;
  final int minimumDelaySeconds;

  /// 后台上传单轮最大运行分钟数（Android）。
  /// 官方原本在 BackgroundWorker.kt 里写死 20，这里做成可配置。
  final int maxUploadMinutes;

  const BackgroundWorkerSettings({
    required this.requiresCharging,
    required this.minimumDelaySeconds,
    required this.maxUploadMinutes,
  });
}"""
if old not in s:
    if 'maxUploadMinutes' in s:
        print("  skip: 已有 maxUploadMinutes")
    else:
        print("ERROR: pigeon 结构不匹配", file=sys.stderr); sys.exit(1)
else:
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== 2. Kotlin Preferences: 新增 maxUploadMinutes 读写 ==="
python3 - "$PREFS" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

if 'SHARED_PREF_MAX_MINUTES_KEY' in s:
    print("  skip: 已存在")
else:
    s = s.replace(
        '    private const val SHARED_PREF_NOTIF_MSG_KEY = "BackgroundWorker::notificationMessage"',
        '    private const val SHARED_PREF_NOTIF_MSG_KEY = "BackgroundWorker::notificationMessage"\n'
        '    private const val SHARED_PREF_MAX_MINUTES_KEY = "BackgroundWorker::maxUploadMinutes"',
        1)

    s = s.replace(
        '    private const val DEFAULT_NOTIF_MSG = "Checking for new assets…"',
        '    private const val DEFAULT_NOTIF_MSG = "Checking for new assets…"\n'
        '    private const val DEFAULT_MAX_UPLOAD_MINUTES = 55',
        1)

    # updateSettings: 一并保存
    s = s.replace(
        """      putLong(SHARED_PREF_MIN_DELAY_KEY, settings.minimumDelaySeconds)
      putBoolean(SHARED_PREF_REQUIRE_CHARGING_KEY, settings.requiresCharging)""",
        """      putLong(SHARED_PREF_MIN_DELAY_KEY, settings.minimumDelaySeconds)
      putBoolean(SHARED_PREF_REQUIRE_CHARGING_KEY, settings.requiresCharging)
      putLong(SHARED_PREF_MAX_MINUTES_KEY, settings.maxUploadMinutes.toLong())""",
        1)

    # getSettings: 一并读出
    s = s.replace(
        """      requiresCharging = sp.getBoolean(
        SHARED_PREF_REQUIRE_CHARGING_KEY,
        DEFAULT_REQUIRE_CHARGING
      ),
    )""",
        """      requiresCharging = sp.getBoolean(
        SHARED_PREF_REQUIRE_CHARGING_KEY,
        DEFAULT_REQUIRE_CHARGING
      ),
      maxUploadMinutes = sp.getLong(
        SHARED_PREF_MAX_MINUTES_KEY,
        DEFAULT_MAX_UPLOAD_MINUTES.toLong()
      ).toInt(),
    )""",
        1)

    # 供 BackgroundWorker 直接读取（不进 settings 对象也能用）
    if 'fun getMaxUploadMinutes' not in s:
        s = s.replace(
            "  fun setLocked(paused: Boolean) {",
            """  fun getMaxUploadMinutes(): Int =
    sp.getLong(SHARED_PREF_MAX_MINUTES_KEY, DEFAULT_MAX_UPLOAD_MINUTES.toLong()).toInt()

  fun setLocked(paused: Boolean) {""",
            1)

    p.write_text(s); print("  ok")
PY

echo "=== 2b. app_config.dart: read/write 两个 switch 补 backupMaxUploadMinutes 分支 ==="
python3 - "$APP_CONFIG" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'backupMaxUploadMinutes' in s:
    print("  skip: 已有")
else:
    # read(): .backupTriggerDelay => backup.triggerDelay,
    old_read = "            .backupTriggerDelay => backup.triggerDelay,"
    new_read = ("            .backupTriggerDelay => backup.triggerDelay,\n"
                "            .backupMaxUploadMinutes => backup.maxUploadMinutes,")
    # write(): .backupTriggerDelay => copyWith(backup: backup.copyWith(triggerDelay: value as int)),
    old_write = "      .backupTriggerDelay => copyWith(backup: backup.copyWith(triggerDelay: value as int)),"
    new_write = ("      .backupTriggerDelay => copyWith(backup: backup.copyWith(triggerDelay: value as int)),\n"
                 "      .backupMaxUploadMinutes => copyWith(backup: backup.copyWith(maxUploadMinutes: value as int)),")

    ok = True
    if old_read in s:
        s = s.replace(old_read, new_read, 1)
    else:
        print("ERROR: read() switch 未匹配", file=sys.stderr); ok = False
    if old_write in s:
        s = s.replace(old_write, new_write, 1)
    else:
        print("ERROR: write() switch 未匹配", file=sys.stderr); ok = False
    if ok:
        p.write_text(s); print("  ok")
    else:
        sys.exit(1)
PY

echo "=== 3. Kotlin Worker: 用配置值替代写死的 20 ==="
python3 - "$WORKER_KT" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "flutterApi?.onAndroidUpload(maxMinutesArg = 20) { handleHostResult(it) }"
new = ("val maxMinutes = BackgroundWorkerPreferences(ctx).getMaxUploadMinutes()\n"
       "    Log.i(TAG, \"Starting background upload with maxMinutes=$maxMinutes\")\n"
       "    flutterApi?.onAndroidUpload(maxMinutesArg = maxMinutes) { handleHostResult(it) }")
if old not in s:
    if 'getMaxUploadMinutes()' in s:
        print("  skip: 已改过")
    else:
        print("ERROR: 找不到 onAndroidUpload 调用", file=sys.stderr); sys.exit(1)
else:
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== 3b. Dart BackgroundWorkerFgService.configure(): 支持 maxUploadMinutes ==="
python3 - "$WORKER_DART" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'maxUploadMinutes' in s and 'int? maxUploadMinutes' in s:
    print("  skip: 已支持")
else:
    old = """  Future<void> configure({int? minimumDelaySeconds, bool? requireCharging}) {
    final backup = SettingsRepository.instance.appConfig.backup;
    return _foregroundHostApi.configure(
      BackgroundWorkerSettings(
        minimumDelaySeconds: minimumDelaySeconds ?? backup.triggerDelay,
        requiresCharging: requireCharging ?? backup.requireCharging,
      ),
    );
  }"""
    new = """  Future<void> configure({int? minimumDelaySeconds, bool? requireCharging, int? maxUploadMinutes}) {
    final backup = SettingsRepository.instance.appConfig.backup;
    return _foregroundHostApi.configure(
      BackgroundWorkerSettings(
        minimumDelaySeconds: minimumDelaySeconds ?? backup.triggerDelay,
        requiresCharging: requireCharging ?? backup.requireCharging,
        maxUploadMinutes: maxUploadMinutes ?? backup.maxUploadMinutes,
      ),
    );
  }"""
    if old not in s:
        print("ERROR: configure() 结构不匹配", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1)); print("  ok")
PY

echo "=== 4. Dart: onAndroidUpload 使用传进来的预算 ==="
python3 - "$WORKER_DART" << 'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()

# 若 01 补丁已把常量写进来，这里改为完全跟随传入值
if 'static const int androidBackgroundUploadMinutes' in s:
    s = re.sub(
        r"  static const int androidBackgroundUploadMinutes = \d+;\n\n",
        "", s)
    s = re.sub(
        r"    final budgetMinutes =\n\s+maxMinutes != null && maxMinutes > androidBackgroundUploadMinutes\n\s+\? maxMinutes\n\s+: androidBackgroundUploadMinutes;\n\s+final backupTimeout = Duration\(minutes: budgetMinutes\);",
        "    // 预算由设置页控制（经 pigeon 传到 Kotlin，再回传到这里）\n"
        "    final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes) : null;",
        s)
    p.write_text(s); print("  ok (改为跟随配置)")
else:
    old = "    final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes - 1) : null;"
    new = "    // 预算由设置页控制（经 pigeon 传到 Kotlin，再回传到这里）\n    final backupTimeout = maxMinutes != null ? Duration(minutes: maxMinutes) : null;"
    if old in s:
        p.write_text(s.replace(old, new, 1)); print("  ok")
    else:
        print("  note: 预算行未匹配，跳过（可能已被 01 改写）")
PY

echo "=== 5. Dart 设置页: 新增「后台上传最大运行时间」滑块 ==="
python3 - "$SETTINGS_UI" << 'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

if '_MaxUploadMinutesSlider' in s:
    print("  skip: 已存在")
else:
    # 5a. 挂到 Android 的 background_options 分组里
    s = s.replace(
        """          const _BackupOnlyWhenChargingButton(),
          const _BackupDelaySlider(),""",
        """          const _BackupOnlyWhenChargingButton(),
          const _BackupDelaySlider(),
          const _MaxUploadMinutesSlider(),""",
        1)

    # 5b. 追加 widget 实现（照 _BackupDelaySlider 的写法）
    widget = '''
/// 后台上传单轮最大运行时间（分钟）。
/// 官方在 BackgroundWorker.kt 里写死 20 分钟，这里做成可调。
class _MaxUploadMinutesSlider extends ConsumerWidget {
  const _MaxUploadMinutesSlider();

  static const List<int> _steps = [5, 15, 30, 55, 120];

  static int _toIndex(int minutes) {
    final i = _steps.indexOf(minutes);
    if (i >= 0) return i;
    // 取最接近的档位
    var best = 0;
    for (var j = 0; j < _steps.length; j++) {
      if ((_steps[j] - minutes).abs() < (_steps[best] - minutes).abs()) best = j;
    }
    return best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fgService = ref.watch(backgroundWorkerFgServiceProvider);
    final current = ref.watch(appConfigProvider.select((c) => c.backup.maxUploadMinutes));
    final index = _toIndex(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 24.0, top: 8.0),
          child: Text(
            '后台最大运行时间：${_steps[index]} 分钟',
            style: context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24.0),
          child: Text(
            '单次后台任务最多跑多久。大视频超出会被中断，下一轮重新开始。',
            style: context.textTheme.bodySmall,
          ),
        ),
        Slider(
          value: index.toDouble(),
          onChanged: (_) {},
          onChangeEnd: (double v) async {
            final minutes = _steps[v.toInt()];
            await ref.read(settingsProvider).write(SettingsKey.backupMaxUploadMinutes, minutes);
            unawaited(fgService.configure(maxUploadMinutes: minutes));
          },
          max: (_steps.length - 1).toDouble(),
          min: 0.0,
          divisions: _steps.length - 1,
          label: '${_steps[index]} 分钟',
        ),
      ],
    );
  }
}
'''
    s = s.rstrip() + "\n" + widget
    p.write_text(s); print("  ok")
PY

echo "02-editable-max-upload-minutes.sh done"
