#!/usr/bin/env bash
# 00-kotlin-serialization-fix.sh
#
# 背景：background_downloader 的 android/build.gradle 里硬编码声明了
#   id 'org.jetbrains.kotlin.plugin.serialization' version '<某版本>'
# 而 Immich 项目主 Kotlin 版本由 mobile/android/gradle/libs.versions.toml 决定
# （当前 2.2.20）。Gradle 插件 classpath 只允许一个版本，二者不一致即报：
#   "the plugin is already on the classpath with a different version"
#
# 不同 background_downloader 版本硬编码的版本号还不一样
# （9.5.6 -> 2.1.0，9.6.4 -> 2.3.20），所以不能写死替换值，
# 必须动态读项目的 Kotlin 版本，把第三方包对齐过来。
set -euo pipefail
cd "$(dirname "$0")/.."

MOBILE="immich/mobile"
TOML="$MOBILE/android/gradle/libs.versions.toml"

# 1) 读项目主 Kotlin 版本
KOTLIN_VER=$(grep -E '^kotlin = "' "$TOML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "${KOTLIN_VER:-}" ]; then
  echo "ERROR: 无法从 $TOML 读取 kotlin 版本" >&2
  exit 1
fi
echo "项目 Kotlin 版本 = $KOTLIN_VER"

# 2) 读项目的 kotlinx-serialization-json 版本（对齐用）
SER_JSON_VER=$(grep -E '^serialization-json = "' "$TOML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
SER_JSON_VER=${SER_JSON_VER:-1.8.1}
echo "项目 kotlinx-serialization-json = $SER_JSON_VER"

# 3) 项目侧：serialization 插件跟随主 kotlin（对应官方那行 TODO 想做的事）
if grep -q 'kotlin-serialization = .*version = "2\.' "$TOML"; then
  sed -i -E 's|kotlin-serialization = \{ id = "org\.jetbrains\.kotlin\.plugin\.serialization", version = "[^"]+" \}|kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }|' "$TOML"
  echo "patched $TOML"
fi

# settings.gradle 里另有一处显式版本声明
SG="$MOBILE/android/settings.gradle"
if grep -q 'org.jetbrains.kotlin.plugin.serialization" version' "$SG"; then
  sed -i -E "s|id \"org\\.jetbrains\\.kotlin\\.plugin\\.serialization\" version \"[0-9.]+\" apply false|id \"org.jetbrains.kotlin.plugin.serialization\" version \"$KOTLIN_VER\" apply false|" "$SG"
  echo "patched $SG"
fi

# 4) 第三方包：把 pub-cache 里所有 background_downloader 的 serialization
#    插件版本强制改成项目版本（pub get 之后才存在，故可重复执行）
shopt -s nullglob
found=0
for bd in "$HOME"/.pub-cache/hosted/*/background_downloader-*/android/build.gradle; do
  [ -f "$bd" ] || continue
  found=1
  CUR=$(grep -oE "kotlin\.plugin\.serialization' version '[0-9.]+'" "$bd" | head -1 | sed -E "s/.*'([0-9.]+)'/\1/")
  if [ "${CUR:-}" = "$KOTLIN_VER" ]; then
    echo "skip $bd (已是 $KOTLIN_VER)"
    continue
  fi
  sed -i -E "s|(kotlin\.plugin\.serialization' version ')[0-9.]+(')|\1${KOTLIN_VER}\2|" "$bd"
  sed -i -E "s|kotlinx-serialization-json:[0-9.]+|kotlinx-serialization-json:${SER_JSON_VER}|" "$bd"
  echo "patched $bd (serialization ${CUR:-?} -> $KOTLIN_VER, json -> $SER_JSON_VER)"
done
shopt -u nullglob

if [ "$found" -eq 0 ]; then
  echo "note: pub-cache 里暂无 background_downloader（pub get 之前运行属正常）"
fi

echo "00-kotlin-serialization-fix.sh done"
