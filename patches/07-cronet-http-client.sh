#!/usr/bin/env bash
# 07-cronet-http-client.sh
#
# 目标：让 Android 端的 HTTP 请求走 Chromium Cronet（BoringSSL），而不是 OkHttp（Conscrypt）。
#
# ── 为什么需要这个补丁 ─────────────────────────────────────────
# 某些接入商（实测：阿里云杭州入口）对 TLS ClientHello 做特征过滤：
#   - 带后量子密钥交换 X25519MLKEM768 → 放行
#   - 不带（只有 X25519 / secp256r1） → 直接 RST
#
# Android 系统 TLS 栈（Conscrypt）不支持后量子，所以 OkHttp 发出的 ClientHello
# 永远没有 X25519MLKEM768，请求被 RST。App 表现为：
#   - 探测阶段："Server is not reachable"
#   - 登录/同步阶段：ClientException: SocketException: Connection reset
#
# Immich APK 已内嵌 Chromium Cronet（libcronet.*.so），其 BoringSSL 带后量子支持。
# 用 dart 官方的 cronet_http 包把 http.Client 换成 CronetClient 即可。
#
# ── 关键：鉴权不会丢 ──────────────────────────────────────────
# 上游 HttpClientManager 里**已经有** getAuthHeaders(url)，
# 它会带出 custom headers + auth cookie + basic auth。
# 只是没暴露给 Dart（目前只给 ExoPlayer 的 CronetDataSource 用）。
# 本补丁把它通过 pigeon 暴露出来，CronetClient 每次请求时注入即可。
#
# ── 本补丁做三件事 ──────────────────────────────────────────
#   A. pubspec 加 cronet_http 依赖
#   B. pigeon + Kotlin 侧暴露 getAuthHeaders(url)
#   C. NetworkRepository：Android 分支改用包装了 header 注入的 CronetClient
#
# iOS 分支完全不动（Network.framework 自带后量子）。
set -euo pipefail
cd "$(dirname "$0")/.."

PUBSPEC="immich/mobile/pubspec.yaml"
NETREPO="immich/mobile/lib/infrastructure/repositories/network.repository.dart"
HCM="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt"
PLUGIN="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt"
PIGEON="immich/mobile/pigeon/network_api.dart"

for f in "$PUBSPEC" "$NETREPO" "$HCM" "$PLUGIN" "$PIGEON"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════
# A. pubspec: 加 cronet_http
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/pubspec.yaml")
s = p.read_text()
if "cronet_http" not in s:
    anchor = "  ok_http:"
    assert anchor in s, "pubspec: 找不到 ok_http"
    idx = s.index(anchor)
    lines = s[idx:].split("\n")
    insert_at = len(s)
    for i, line in enumerate(lines[1:], start=1):
        if line.startswith("  ") and not line.startswith("    ") and line.strip():
            insert_at = idx + len("\n".join(lines[:i])) + 1
            break
    s = s[:insert_at] + "  cronet_http: ^1.8.0\n" + s[insert_at:]
    p.write_text(s)
    print("    pubspec: +cronet_http ^1.10.1")
else:
    print("    pubspec: 已存在")
PYEOF

# ═══════════════════════════════════════════════════════
# B. pigeon: 暴露 getAuthHeaders(url)
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/pigeon/network_api.dart")
s = p.read_text()
if "requestAuthHeaders" not in s:
    old = "  String getAppGroupId();"
    assert old in s, "pigeon: 找不到 getAppGroupId"
    s = s.replace(old, old + """

  /// 返回访问 [url] 时应带的请求头（custom headers + auth cookie + basic auth）。
  ///
  /// 供 Cronet 路径使用：Cronet 不共享 OkHttp 的 CookieJar / 拦截器，
  /// 需要由 Dart 侧在每次请求上显式注入。Kotlin 侧已有同等能力的
  /// HttpClientManager.getAuthHeaders(url)，这里只是透出给 Dart。
  Map<String, String> requestAuthHeaders(String url);""", 1)
    p.write_text(s)
    print("    pigeon: +requestAuthHeaders")
else:
    print("    pigeon: 已存在")
PYEOF

# ═══════════════════════════════════════════════════════
# C. NetworkApiPlugin: 实现 requestAuthHeaders
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt")
s = p.read_text()
if "override fun requestAuthHeaders" not in s:
    anchor = None
    for cand in [
        "  override fun getAppGroupId(): String =",
        "  override fun getAppGroupId(): String {",
        "  override fun setRequestHeaders(",
    ]:
        if cand in s:
            anchor = cand
            break
    assert anchor is not None, "plugin: 找不到插入锚点"
    impl = '''  override fun requestAuthHeaders(url: String): Map<String, String> {
    return HttpClientManager.getAuthHeaders(url)
  }

'''
    s = s.replace(anchor, impl + anchor, 1)
    p.write_text(s)
    print("    NetworkApiPlugin: +requestAuthHeaders")
else:
    print("    NetworkApiPlugin: 已存在")
PYEOF

# ═══════════════════════════════════════════════════════
# D. NetworkRepository: Android → CronetClient（包装 header 注入）
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/lib/infrastructure/repositories/network.repository.dart")
s = p.read_text()

if "CronetClient" in s:
    print("    network.repository: 已存在")
else:
    imp = "import 'package:cronet_http/cronet_http.dart';"
    if imp not in s:
        lines = s.split("\n")
        last_import = max(i for i, l in enumerate(lines) if l.startswith("import "))
        lines.insert(last_import + 1, imp)
        s = "\n".join(lines)

    old = """      _client = OkHttpClient.fromJniGlobalRef(
        clientPointer,
        configuration: const OkHttpClientConfiguration(
          connectTimeout: Duration(seconds: 30),
          readTimeout: Duration(seconds: 60),
          writeTimeout: Duration(seconds: 60),
        ),
      );"""
    new = """      // 用 Chromium Cronet（BoringSSL）替代 OkHttp/Conscrypt。
      //
      // 部分接入商（如阿里云杭州入口）按 ClientHello 是否含后量子密钥交换
      // X25519MLKEM768 过滤流量；系统 Conscrypt 不支持后量子，请求会被 RST。
      // Cronet 的 BoringSSL 带后量子支持，可正常握手。
      //
      // Cronet 不走 OkHttp 的 CookieJar / 拦截器，鉴权由外层的
      // _CronetAuthClient 在每次请求时通过 requestAuthHeaders(url) 注入。
      _client = _CronetAuthClient(CronetClient.defaultCronetEngine());"""
    assert old in s, "network.repository: 找不到 OkHttp Android 分支"
    s = s.replace(old, new, 1)

    wrapper = '''

/// 在每次请求上注入 Immich 鉴权 header 的 [http.Client] 包装。
///
/// Cronet 不共享 OkHttp 的 CookieJar 与拦截器，因此需要在 Dart 侧
/// 用 native 的 HttpClientManager.getAuthHeaders(url) 取出现成的请求头。
class _CronetAuthClient extends http.BaseClient {
  _CronetAuthClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final headers = await networkApi.requestAuthHeaders(request.url.toString());
    if (headers.isNotEmpty) {
      // 请求自带的头优先，native 头只补充缺的部分
      for (final entry in headers.entries) {
        request.headers.putIfAbsent(entry.key, () => entry.value);
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
'''
    if "class _CronetAuthClient" not in s:
        s = s.rstrip() + wrapper
    p.write_text(s)
    print("    network.repository: Android → CronetClient + _CronetAuthClient")
PYEOF

echo ""
echo "==> 校验"
grep -q "cronet_http" immich/mobile/pubspec.yaml && echo "  ✅ pubspec"
grep -q "requestAuthHeaders" immich/mobile/pigeon/network_api.dart && echo "  ✅ pigeon"
grep -q "override fun requestAuthHeaders" immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt && echo "  ✅ NetworkApiPlugin"
grep -q "CronetClient" immich/mobile/lib/infrastructure/repositories/network.repository.dart && echo "  ✅ network.repository"
grep -q "getAuthHeaders" immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt && echo "  ✅ HttpClientManager(上游已有)"
echo ""
echo "==> 07 补丁完成"
