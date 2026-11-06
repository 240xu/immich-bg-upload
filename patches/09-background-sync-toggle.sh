#!/usr/bin/env bash
# 09-background-sync-toggle.sh
#
# 目标：把「后台同步」做成备份设置页里的可见开关，而不是隐式跟随 App 生命周期。
#
# ── 现状（v3.3.6 源码实证）──────────────────────────────────
# Android 后台 Worker（onAndroidUpload → _backgroundLoop）里**已经**跑了
# _syncAssets()（local sync + remote sync + hash），但：
#   · 没有任何开关能控制「后台要不要同步」
#   · 同步失败也不区分「没同步」和「同步了但没跑完」
#   · 用户完全看不到后台在干什么
# ⇒ 结果：用户想「后台只上传、别动元数据」做不到；
#         想「关掉后台上传但仍然后台同步」也做不到。
#
# ── 本补丁做三件事 ─────────────────────────────────────────
#   A. 新增设置键 backgroundSyncEnabled（默认 true，保持官方行为）
#      + BackupConfig 字段 + AppConfig read/write 映射
#   B. 备份设置页「后台选项」分组里加一个开关
#   C. 后台 Worker 尊重这个开关：关掉就跳过 _syncAssets，
#      直接进备份阶段（上传不需要远端同步也能工作）
#
# ⚠️ 兼容性：默认值 true = 与官方行为完全一致，老用户升级后无感。
set -euo pipefail
cd "$(dirname "$0")/.."

SETTINGS_KEY="immich/mobile/lib/domain/models/settings_key.dart"
BACKUP_CFG="immich/mobile/lib/domain/models/config/backup_config.dart"
APP_CONFIG="immich/mobile/lib/domain/models/config/app_config.dart"
SETTINGS_UI="immich/mobile/lib/widgets/settings/backup_settings/backup_settings.dart"
WORKER="immich/mobile/lib/domain/services/background_worker.service.dart"

for f in "$SETTINGS_KEY" "$BACKUP_CFG" "$APP_CONFIG" "$SETTINGS_UI" "$WORKER"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════
# A0. i18n key（必须先有 key，否则 context.t.xxx 编译不过）
#     只需要加 en.json —— 其余 88 个语种由 easy_localization 自动 fallback
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import json, pathlib, sys, collections

p = pathlib.Path("immich/i18n/en.json")
if not p.exists():
    print("ERROR: 找不到 immich/i18n/en.json", file=sys.stderr); sys.exit(1)

raw = p.read_text()
d = json.loads(raw, object_pairs_hook=collections.OrderedDict)

NEW = {
    "background_sync": "Background sync",
    "background_sync_description": "Sync albums, people and memories while the app is in the background. Turn off to only upload photos in the background.",
}

added = [k for k in NEW if k not in d]
if not added:
    print("    i18n: 已存在")
else:
    # 插在 background_options 之后，保持字母序附近
    out = collections.OrderedDict()
    for k, v in d.items():
        out[k] = v
        if k == "background_options":
            for nk in NEW:
                if nk not in out:
                    out[nk] = NEW[nk]
    # 若没找到锚点，直接追加到末尾
    for nk in NEW:
        if nk not in out:
            out[nk] = NEW[nk]
    p.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print(f"    i18n: +{','.join(NEW.keys())}")
PYEOF

# ═══════════════════════════════════════════════════════
# A. 设置键 + 配置字段 + 映射
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib, sys

# ---- A1. SettingsKey ----
p = pathlib.Path("immich/mobile/lib/domain/models/settings_key.dart")
s = p.read_text()
if "backgroundSyncEnabled" in s:
    print("    settings_key: 已存在")
else:
    old = "  backupSyncAlbums<bool>(),"
    new = ("  backupSyncAlbums<bool>(),\n"
           "  // 后台（Android WorkManager 任务）里是否执行远端同步。\n"
           "  // 默认 true 保持官方行为；关掉后后台只做上传，不动元数据。\n"
           "  backgroundSyncEnabled<bool>(),")
    if old not in s:
        print("ERROR: settings_key 找不到 backupSyncAlbums", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1))
    print("    settings_key: +backgroundSyncEnabled")

# ---- A2. BackupConfig ----
p = pathlib.Path("immich/mobile/lib/domain/models/config/backup_config.dart")
s = p.read_text()
if "backgroundSyncEnabled" in s:
    print("    backup_config: 已存在")
else:
    old = "    @Default(false) bool syncAlbums,"
    new = ("    @Default(false) bool syncAlbums,\n"
           "    @Default(true) bool backgroundSyncEnabled,")
    if old not in s:
        print("ERROR: backup_config 找不到 syncAlbums", file=sys.stderr); sys.exit(1)
    p.write_text(s.replace(old, new, 1))
    print("    backup_config: +backgroundSyncEnabled")

# ---- A3. AppConfig read/write 两个 switch ----
p = pathlib.Path("immich/mobile/lib/domain/models/config/app_config.dart")
s = p.read_text()
if s.count("backgroundSyncEnabled") >= 2:
    print("    app_config: 已存在")
else:
    old_r = "            .backupSyncAlbums => backup.syncAlbums,"
    new_r = ("            .backupSyncAlbums => backup.syncAlbums,\n"
             "            .backgroundSyncEnabled => backup.backgroundSyncEnabled,")
    if old_r not in s:
        print("ERROR: app_config read 分支未找到", file=sys.stderr); sys.exit(1)
    s = s.replace(old_r, new_r, 1)

    # write 侧：真实形态是 `.backupSyncAlbums => copyWith(backup: backup.copyWith(syncAlbums: value as bool)),`
    import re
    m = re.search(
        r"(\.backupSyncAlbums\s*=>\s*copyWith\(backup:\s*backup\.copyWith\(syncAlbums:\s*value\s+as\s+bool\)\),)",
        s)
    if m:
        old_w = m.group(1)
        new_w = (old_w + "\n"
                 "      .backgroundSyncEnabled => copyWith(backup: backup.copyWith(backgroundSyncEnabled: value as bool)),")
        s = s.replace(old_w, new_w, 1)
        print("    app_config: +read/write 映射")
    else:
        print("ERROR: app_config write 分支未匹配", file=sys.stderr); sys.exit(1)
    p.write_text(s)
PYEOF

# ═══════════════════════════════════════════════════════
# B. 设置页开关
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib, sys

p = pathlib.Path("immich/mobile/lib/widgets/settings/backup_settings/backup_settings.dart")
s = p.read_text()

if "_BackgroundSyncSwitch" in s:
    print("    settings_ui: 已存在")
else:
    # B1. 挂进 Android 的 background_options 分组
    # ⚠️ 不要假设「_BackupDelaySlider 后面就是 ],」——补丁 02 会插进
    #    _MaxUploadMinutesSlider，所以锚定 _BackupDelaySlider 那一行本身。
    old = "          const _BackupDelaySlider(),"
    new = ("          const _BackupDelaySlider(),\n"
           "          const _BackgroundSyncSwitch(),")
    if old not in s:
        print("ERROR: settings_ui 找不到 _BackupDelaySlider 锚点", file=sys.stderr); sys.exit(1)
    s = s.replace(old, new, 1)

    # B2. 追加 widget（复用 _BackupSwitchTile，风格与现有开关一致）
    widget = '''
/// 后台同步开关。
///
/// 控制 Android 后台 Worker 里是否执行 `_syncAssets()`：
///   · 开 = 后台既同步元数据（人物/回忆/相册）也上传（官方默认）
///   · 关 = 后台只上传，元数据同步留给 App 在前台时做
///
/// 用途：省流量 / 省电，或不想让后台改动本地数据库时。
class _BackgroundSyncSwitch extends StatelessWidget {
  const _BackgroundSyncSwitch();

  @override
  Widget build(BuildContext context) {
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backgroundSyncEnabled,
      selector: (c) => c.backup.backgroundSyncEnabled,
      title: context.t.background_sync,
      subtitle: context.t.background_sync_description,
    );
  }
}
'''
    s = s.rstrip() + "\n" + widget
    p.write_text(s)
    print("    settings_ui: +_BackgroundSyncSwitch")
PYEOF

# ═══════════════════════════════════════════════════════
# C. 后台 Worker 尊重开关
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib, sys

p = pathlib.Path("immich/mobile/lib/domain/services/background_worker.service.dart")
s = p.read_text()

if "backgroundSyncEnabled" in s:
    print("    worker: 已存在")
else:
    # 在 _backgroundLoop 的同步调用前加开关判断
    old = """    final sw = Stopwatch()..start();
    try {
      if (!await _syncAssets(hashTimeout: hashTimeout, syncBudget: syncBudget)) {"""
    new = """    final sw = Stopwatch()..start();
    try {
      // 后台同步开关（设置页「后台选项 → 后台同步」）。
      // 关掉时跳过元数据同步，直接进备份——上传本身不依赖远端同步。
      // 注意：localSync（本地相册索引）仍然要跑，否则备份找不到候选文件。
      if (_backgroundSyncEnabled) {
        if (!await _syncAssets(hashTimeout: hashTimeout, syncBudget: syncBudget)) {"""
    if old not in s:
        print("ERROR: worker 找不到 _backgroundLoop 同步调用点", file=sys.stderr); sys.exit(1)
    s = s.replace(old, new, 1)

    # 补上对应的闭合大括号 + else 分支
    old2 = """        _logger.warning("Remote sync did not complete, will resume on next background run");
        // 返回 false ⇒ 让 WorkManager 判定「任务未完成」，尽快重新入队。
        // 同步协议是增量的，下次会从上次 ack 处继续，不会重头再来。
        return false;
      }
"""
    new2 = """          _logger.warning("Remote sync did not complete, will resume on next background run");
          // 返回 false ⇒ 让 WorkManager 判定「任务未完成」，尽快重新入队。
          // 同步协议是增量的，下次会从上次 ack 处继续，不会重头再来。
          return false;
        }
      } else {
        _logger.info("Background sync disabled by setting, running local sync only");
        // 本地索引仍要同步，否则备份候选列表是空的
        await _localSyncService.sync();
        if (_isCleanedUp) {
          return false;
        }
      }
"""
    if old2 not in s:
        print("ERROR: worker 找不到同步失败分支", file=sys.stderr); sys.exit(1)
    s = s.replace(old2, new2, 1)

    # 加一个读取设置的 getter（照 _isBackupEnabled 的真实写法：
    #   SettingsRepository.instance.appConfig —— 后台 isolate 里没有 _ref 可用）
    old3 = "  bool get _isBackupEnabled => SettingsRepository.instance.appConfig.backup.enabled;"
    if old3 not in s:
        print("ERROR: worker 找不到 _isBackupEnabled getter", file=sys.stderr); sys.exit(1)
    getter = """  /// 后台同步是否开启（设置页可关）。默认 true = 官方行为。
  bool get _backgroundSyncEnabled =>
      SettingsRepository.instance.appConfig.backup.backgroundSyncEnabled;

"""
    s = s.replace(old3, getter + old3, 1)
    p.write_text(s)
    print("    worker: +开关判断 + getter")
PYEOF

echo ""
echo "==> 校验"
grep -q "background_sync" immich/i18n/en.json && echo "  ✅ i18n key"
grep -q "backgroundSyncEnabled" immich/mobile/lib/domain/models/settings_key.dart && echo "  ✅ SettingsKey"
grep -q "backgroundSyncEnabled" immich/mobile/lib/domain/models/config/backup_config.dart && echo "  ✅ BackupConfig"
grep -q "backgroundSyncEnabled" immich/mobile/lib/domain/models/config/app_config.dart && echo "  ✅ AppConfig 映射"
grep -q "_BackgroundSyncSwitch" immich/mobile/lib/widgets/settings/backup_settings/backup_settings.dart && echo "  ✅ 设置页开关"
grep -q "_backgroundSyncEnabled" immich/mobile/lib/domain/services/background_worker.service.dart && echo "  ✅ 后台开关生效"
echo ""
echo "==> 09 补丁完成"
