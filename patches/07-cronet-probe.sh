#!/usr/bin/env bash
# 07-cronet-probe.sh
#
# 目标：让「服务器探测 / ping」优先走 Chromium Cronet 网络栈，而不是 OkHttp/Conscrypt。
#
# ── 为什么需要这个补丁 ─────────────────────────────────────────
# 中国大陆某些接入商（实测：阿里云杭州入口）会对 ClientHello 做特征过滤：
#   - 带后量子密钥交换（X25519MLKEM768）→ 正常放行
#   - 不带（只有 X25519 / secp256r1）    → 直接 RST，连接被重置
#
# Android 系统 TLS 栈（Conscrypt）目前不支持后量子密钥交换，所以 OkHttp 发出的
# ClientHello 里没有 X25519MLKEM768，请求被拦，App 报 "Server is not reachable"。
# 实测同一台手机上：浏览器 (BoringSSL) 能正常访问，官方 Immich App 不行。
#
# Immich APK 已内嵌 Chromium Cronet（libcronet.*.so，BoringSSL 内核），
# 它的后量子支持与 Chrome 一致。把探测请求交给 Cronet 即可绕过该过滤。
#
# ── 本补丁做三件事 ──────────────────────────────────────────
#   A. pigeon 定义加 cronetPing(url)
#   B. Kotlin 侧用 CronetEngine + UrlRequest 实现（引擎未就绪时返回 -1）
#   C. Dart 侧探测优先走 Cronet，失败自动回退原有 OkHttp
#
# 不影响普通网络路径：Cronet 探测返回 -1 / 抛异常时，完全沿用原有逻辑。
set -euo pipefail
cd "$(dirname "$0")/.."

PIGEON="immich/mobile/pigeon/network_api.dart"
HCM="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt"
PLUGIN="immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt"
API="immich/mobile/lib/services/api.service.dart"

for f in "$PIGEON" "$HCM" "$PLUGIN" "$API"; do
  [ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════
# A. pigeon: 加 cronetPing
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/pigeon/network_api.dart")
s = p.read_text()
if "cronetPing" not in s:
    old = "  String getAppGroupId();"
    assert old in s, "pigeon: getAppGroupId 未找到"
    s = s.replace(old, old + """

  /// 用 Chromium Cronet 发起一次 GET 探测，返回 HTTP 状态码（失败返回 -1）。
  ///
  /// 某些接入商按 ClientHello 特征过滤（缺后量子密钥交换直接 RST），
  /// 系统 TLS 栈会被拦，而 Cronet（BoringSSL）可通过。
  @async
  int cronetPing(String url);
""", 1)
    p.write_text(s)
    print("    pigeon: +cronetPing")
else:
    print("    pigeon: 已存在")
PYEOF

# ═══════════════════════════════════════════════════════
# B1. HttpClientManager: 加 Cronet 探测实现
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt")
s = p.read_text()

if "fun cronetPing" in s:
    print("    HttpClientManager: 已存在")
else:
    impl = '''  /**
   * 用 Cronet 发起一次 GET，返回 HTTP 状态码；任何失败都返回 -1。
   *
   * 用 CountDownLatch 做同步等待，避免依赖协程 API 的具体签名。
   * Cronet 引擎在 [init] 里异步创建，未就绪时直接返回 -1，
   * 由 Dart 侧回退到原有 OkHttp 探测。
   */
  fun cronetPing(url: String): Int {
    val engine = cronetEngine ?: return -1
    val latch = java.util.concurrent.CountDownLatch(1)
    val result = java.util.concurrent.atomic.AtomicInteger(-1)
    try {
      val callback = object : UrlRequest.Callback() {
        override fun onSucceeded(request: UrlRequest, info: UrlResponseInfo) {
          result.set(info.httpStatusCode)
          latch.countDown()
        }

        override fun onFailed(request: UrlRequest, info: UrlResponseInfo?, error: CronetException) {
          latch.countDown()
        }

        override fun onCanceled(request: UrlRequest, info: UrlResponseInfo?) {
          latch.countDown()
        }

        override fun onRedirectReceived(
          request: UrlRequest,
          info: UrlResponseInfo,
          newLocationUrl: String,
        ) {
          request.followRedirect()
        }

        // 拿到状态码即可结束，不必等 body
        override fun onResponseStarted(request: UrlRequest, info: UrlResponseInfo) {
          result.set(info.httpStatusCode)
          request.cancel()
          latch.countDown()
        }

        override fun onReadCompleted(
          request: UrlRequest,
          info: UrlResponseInfo,
          byteBuffer: java.nio.ByteBuffer,
        ) {
          request.read(java.nio.ByteBuffer.allocateDirect(4096))
        }
      }
      val request = engine.newUrlRequestBuilder(url, callback, cronetExecutor).build()
      request.start()
      if (!latch.await(8, java.util.concurrent.TimeUnit.SECONDS)) {
        runCatching { request.cancel() }
      }
    } catch (e: Exception) {
      return -1
    }
    return result.get()
  }

'''
    anchor = "  private fun build(cacheDir: File): OkHttpClient {"
    assert anchor in s, "HCM: build(cacheDir) 未找到"
    s = s.replace(anchor, impl + anchor, 1)

    # 补齐 import：统一插到现有 import 块末尾
    needed = [
        "import org.chromium.net.CronetEngine",
        "import org.chromium.net.CronetException",
        "import org.chromium.net.UrlRequest",
        "import org.chromium.net.UrlResponseInfo",
    ]
    missing = [i for i in needed if i not in s]
    if missing:
        lines = s.split("\n")
        last_import = max(i for i, l in enumerate(lines) if l.startswith("import "))
        for imp in reversed(missing):
            lines.insert(last_import + 1, imp)
        s = "\n".join(lines)

    p.write_text(s)
    print("    HttpClientManager: +cronetPing")
PYEOF

# ═══════════════════════════════════════════════════════
# B2. NetworkApiPlugin: 暴露 cronetPing
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt")
s = p.read_text()

if "override fun cronetPing" in s:
    print("    NetworkApiPlugin: 已存在")
else:
    # 兼容两种写法：`override fun hasCertificate(): Boolean {` 和表达式体
    anchor = None
    for cand in [
        "  override fun hasCertificate(): Boolean {",
        "  override fun getAppGroupId(): String =",
        "  override fun getAppGroupId(): String {",
    ]:
        if cand in s:
            anchor = cand
            break
    assert anchor is not None, "plugin: 找不到插入锚点"
    impl = '''  override fun cronetPing(url: String, callback: (Result<Long>) -> Unit) {
    scope.launch {
      try {
        callback(Result.success(HttpClientManager.cronetPing(url).toLong()))
      } catch (e: Exception) {
        callback(Result.success(-1L))
      }
    }
  }

'''
    assert anchor in s, "plugin: hasCertificate 未找到"
    s = s.replace(anchor, impl + anchor, 1)

    # 在类外声明协程作用域
    marker = "private class NetworkApiImpl("
    assert marker in s, "plugin: NetworkApiImpl 未找到"
    s = s.replace(
        marker,
        "private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)\n\n" + marker,
        1,
    )

    # 把 4 个 import 一次性插到现有 import 块末尾，避免散落在 package 行后面
    missing = [i for i in [
        "import kotlinx.coroutines.CoroutineScope",
        "import kotlinx.coroutines.SupervisorJob",
        "import kotlinx.coroutines.launch",
    ] if i not in s]
    if missing:
        lines = s.split("\n")
        last_import = max(i for i, l in enumerate(lines) if l.startswith("import "))
        for imp in reversed(missing):
            lines.insert(last_import + 1, imp)
        s = "\n".join(lines)

    p.write_text(s)
    print("    NetworkApiPlugin: +cronetPing")
PYEOF

# ═══════════════════════════════════════════════════════
# C. Dart: 把 Cronet 探测放到 NetworkRepository（本来就依赖 platform.provider）
# ═══════════════════════════════════════════════════════
python3 - << 'PYEOF'
import pathlib

nr = pathlib.Path("immich/mobile/lib/infrastructure/repositories/network.repository.dart")
api = pathlib.Path("immich/mobile/lib/services/api.service.dart")

# ── C1. NetworkRepository 加静态探测方法 ──
s = nr.read_text()
if "cronetProbe" not in s:
    anchor = "  /// Returns a shared HTTP client that uses native SSL configuration."
    assert anchor in s, "network.repository: 找不到插入锚点"
    method = '''  /// 用 Chromium Cronet 探测 URL 是否可达（仅 Android）。
  ///
  /// 返回 true/false 表示 Cronet 给出了判定；返回 null 表示未判定
  /// （非 Android / Cronet 未就绪 / 调用异常），调用方应回退原有逻辑。
  ///
  /// 背景：部分接入商按 ClientHello 特征过滤流量（缺后量子密钥交换直接 RST），
  /// 系统 TLS 栈会被拦；Cronet 用 BoringSSL，带后量子密钥交换，可通过。
  static Future<bool?> cronetProbe(String url) async {
    if (!Platform.isAndroid) return null;
    try {
      final code = await networkApi.cronetPing(url).timeout(const Duration(seconds: 8));
      if (code < 0) return null;
      return code >= 200 && code < 400;
    } catch (_) {
      return null;
    }
  }

'''
    s = s.replace(anchor, method + anchor, 1)
    nr.write_text(s)
    print("    network.repository: +cronetProbe")
else:
    print("    network.repository: 已存在")

# ── C2. api.service.dart 调用它 ──
s = api.read_text()
if "cronetProbe" not in s:
    old = """  Future<bool> _isEndpointAvailable(String serverUrl) async {
    final endpoint = serverUrl.endsWith('/api') ? serverUrl : '$serverUrl/api';
"""
    new = """  Future<bool> _isEndpointAvailable(String serverUrl) async {
    final endpoint = serverUrl.endsWith('/api') ? serverUrl : '$serverUrl/api';

    // 优先用 Cronet 探测：可绕过按 ClientHello 特征过滤的接入商
    final cronetResult = await NetworkRepository.cronetProbe('$endpoint/server/ping');
    if (cronetResult != null) {
      return cronetResult;
    }
"""
    assert old in s, "api.service: 找不到 _isEndpointAvailable"
    s = s.replace(old, new, 1)
    api.write_text(s)
    print("    api.service.dart: 已接入")
else:
    print("    api.service.dart: 已存在")
PYEOF

echo ""
echo "==> 校验"
grep -q "cronetPing" immich/mobile/pigeon/network_api.dart && echo "  ✅ pigeon"
grep -q "fun cronetPing" immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt && echo "  ✅ HttpClientManager"
grep -q "override fun cronetPing" immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core/NetworkApiPlugin.kt && echo "  ✅ NetworkApiPlugin"
grep -q "cronetProbe" immich/mobile/lib/infrastructure/repositories/network.repository.dart && echo "  ✅ network.repository.dart"
grep -q "NetworkRepository.cronetProbe" immich/mobile/lib/services/api.service.dart && echo "  ✅ api.service.dart"
echo ""
echo "==> 07 补丁完成"
