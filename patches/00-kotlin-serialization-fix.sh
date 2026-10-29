#!/usr/bin/env bash
# 00-kotlin-serialization-fix.sh
#
# background_downloader-9.6.4 的 android/build.gradle 硬编码要求
#   kotlin.plugin.serialization 2.3.20 + kotlinx-serialization-json:1.9.0
# 而 Immich 项目主 Kotlin 是 2.2.20（libs.versions.toml），KSP 也最高只到 2.2.21。
# 直接升 Kotlin 会撞 KSP 无对应版本，故把插件侧要求降回 2.2.20 / 1.8.1。
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="immich/mobile/android"

# 1) libs.versions.toml: serialization 插件跟随主 kotlin 版本（官方 TODO 就是这么写的）
TOML="$TARGET/gradle/libs.versions.toml"
if grep -q 'kotlin-serialization = .*version = "2.1.0"' "$TOML"; then
  sed -i 's|kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version = "2.1.0" }|kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }|' "$TOML"
  echo "patched $TOML (serialization -> version.ref=kotlin)"
fi

# 2) settings.gradle: 同样对齐主 kotlin 版本
SG="$TARGET/settings.gradle"
if grep -q 'kotlin.plugin.serialization.*version "2.1.0"' "$SG"; then
  sed -i 's|id "org.jetbrains.kotlin.plugin.serialization" version "2.1.0" apply false|id "org.jetbrains.kotlin.plugin.serialization" version "2.2.20" apply false|' "$SG"
  echo "patched $SG (serialization 2.1.0 -> 2.2.20)"
fi

# 3) 第三方包 background_downloader：把 2.3.20 降到 2.2.20
#    位置在 pub-cache，pub get 之后才有，故此处做「若存在则改」
PATCH_BD='
shopt -s nullglob
for bd in "$HOME"/.pub-cache/hosted/*/background_downloader-*/android/build.gradle; do
  [ -f "$bd" ] || continue
  sed -i "s|version '"'"'2.3.20'"'"'|version '"'"'2.2.20'"'"'|" "$bd"
  sed -i "s|kotlinx-serialization-json:1.9.0|kotlinx-serialization-json:1.8.1|" "$bd"
  echo "patched $bd"
done
shopt -u nullglob
'
eval "$PATCH_BD" || true

echo "00-kotlin-serialization-fix.sh done"
