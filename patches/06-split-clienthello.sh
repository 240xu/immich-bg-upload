#!/usr/bin/env bash
# 06-split-clienthello.sh
#
# 背景（2026-11-01 实测确诊，详见 ~/AGENTS.md §三「阿里云杭州小包 RST」）：
#   阿里云杭州入口 118.178.58.100 对 **ClientHello 单包 < ~1441 字节** 的 TLS 握手
#   直接回 RST，且该规则只对 SNI=*.sepic.space 生效（所有端口一致）。
#
#   实测：
#     - 一次性发完整 197B ClientHello            -> RST
#     - 先发 1 字节，再发其余 196 字节            -> ServerHello ✅
#     - OpenSSL/curl/Python-ssl 的 CH ~1500B     -> 天然放行
#     - JDK JSSE 441B / Android Conscrypt ~450B   -> 必被 RST
#
#   ⇒ Immich App（OkHttp + Conscrypt，CH ~460B）连不上 nas.sepic.space，
#     而手机 Chrome（BoringSSL，CH ~1500B）能正常打开同一域名。
#
# 修法：
#   用 SSLEngine 手写一个 SSLSocket 实现，把 ClientHello 拆成 1+N 两段写出。
#   已在 JDK 17 上端到端验证通过（握手 TLSv1.3 + HTTP 200 + 正确拿到
#   /.well-known/immich 的 json）。
#
#   注意：不能简单包装 getOutputStream()——JSSE/Conscrypt 内部用 native 层
#   直接写 socket，不经过 getOutputStream()。必须用 SSLEngine 才能拿到
#   ClientHello 字节并控制发送方式。
#
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
CORE_DIR="$ROOT/immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core"
HM="$CORE_DIR/HttpClientManager.kt"

if [ ! -f "$HM" ]; then
  echo "ERROR: 找不到 HttpClientManager.kt: $HM" >&2
  exit 1
fi

echo "==> 目标目录: $CORE_DIR"

# ---------------------------------------------------------------- 1) 新文件
cat > "$CORE_DIR/SplitClientHelloSocketFactory.kt" << 'KOTLIN_EOF'
package app.alextran.immich.core

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.nio.ByteBuffer
import java.security.cert.X509Certificate
import java.util.Collections
import javax.net.ssl.HandshakeCompletedListener
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult
import javax.net.ssl.SSLSession
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.SSLContext

/**
 * 阿里云杭州入口对「ClientHello 首包 < ~1441 字节」的 TLS 握手直接 RST
 * （只对 SNI=*.sepic.space 生效）。Android Conscrypt 的 ClientHello 只有
 * 约 460 字节，因此 Immich App 连 nas.sepic.space 会报 "Server is not reachable"，
 * 而手机 Chrome（BoringSSL，CH ~1500B）却能正常打开同一域名。
 *
 * 绕过方式：把 ClientHello 拆成「1 字节 + 其余」两段发送。网关不做 TCP 重组，
 * 看到的首段不是完整 ClientHello，于是放行；对端 TLS 栈按流重组，完全无感。
 *
 * 实现要点：不能用包装 getOutputStream() 的方式——JSSE/Conscrypt 内部走 native
 * 层直接写 socket。必须用 SSLEngine 自己控制握手字节流。
 */
class SplitClientHelloSocketFactory(private val context: SSLContext) : SSLSocketFactory() {

    override fun getDefaultCipherSuites(): Array<String> =
        context.defaultSSLParameters.cipherSuites

    override fun getSupportedCipherSuites(): Array<String> =
        context.supportedSSLParameters.cipherSuites

    override fun createSocket(s: Socket, host: String, port: Int, autoClose: Boolean): Socket =
        wrap(s, host, port)

    override fun createSocket(host: String, port: Int): Socket =
        wrap(connect(host, port), host, port)

    override fun createSocket(
        host: String,
        port: Int,
        localHost: InetAddress,
        localPort: Int,
    ): Socket = wrap(connect(host, port, localHost, localPort), host, port)

    override fun createSocket(host: InetAddress, port: Int): Socket =
        wrap(connect(host.hostAddress ?: host.toString(), port), host.hostAddress ?: "", port)

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = wrap(
        connect(address.hostAddress ?: "", port, localAddress, localPort),
        address.hostAddress ?: "",
        port,
    )

    private fun connect(host: String, port: Int): Socket {
        val s = Socket()
        s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        return s
    }

    private fun connect(
        host: String,
        port: Int,
        localHost: InetAddress,
        localPort: Int,
    ): Socket {
        val s = Socket()
        s.bind(InetSocketAddress(localHost, localPort))
        s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        return s
    }

    private fun wrap(raw: Socket, host: String, port: Int): SSLSocket {
        // 只有受阿里云「小包 RST」影响的域名才走分段逻辑，其余保持原生 Conscrypt 行为
        if (!needsSplit(host)) {
            @Suppress("DEPRECATION")
            return (context.socketFactory.createSocket(raw, host, port, true)) as SSLSocket
        }
        val engine = context.createSSLEngine(host, port).apply {
            useClientMode = true
            val p = sslParameters
            p.serverNames = Collections.singletonList(SNIHostName(host))
            p.applicationProtocols = arrayOf("http/1.1")
            sslParameters = p
        }
        return EngineSocket(raw, engine)
    }

    private fun needsSplit(host: String): Boolean = SPLIT_HOST_SUFFIXES.any {
        host.equals(it, ignoreCase = true) || host.endsWith(".$it", ignoreCase = true)
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 30_000
        /** 受阿里云杭州入口「小包 RST」影响的域名后缀 */
        val SPLIT_HOST_SUFFIXES = arrayOf("sepic.space")
    }
}

/**
 * 基于 SSLEngine 的 SSLSocket 最小实现。
 * 只在 TLS 握手第一包上做「1 字节 + 其余」的分段发送，其余行为标准。
 */
private class EngineSocket(
    private val raw: Socket,
    private val engine: SSLEngine,
) : SSLSocket() {

    private val netIn = ByteBuffer.allocate(NET_BUF)
    private val appIn = ByteBuffer.allocate(APP_BUF)
    private val netOut = ByteBuffer.allocate(NET_BUF)
    private val appOut = ByteBuffer.allocate(APP_BUF)

    private var handshakeDone = false
    private var inStream: InputStream? = null
    private var outStream: OutputStream? = null

    init {
        raw.soTimeout = READ_TIMEOUT_MS
        netIn.clear(); appIn.clear(); netOut.clear(); appOut.clear()
    }

    // ---------------------------------------------------------------- 握手
    override fun startHandshake() {
        if (handshakeDone) return
        engine.beginHandshake()
        sendClientHelloSplit()
        handshakeLoop()
        handshakeDone = true
    }

    /**
     * 把 ClientHello 拆成 1 字节 + 其余两段写出。
     * 这是绕过阿里云「小包 RST」的关键。
     */
    private fun sendClientHelloSplit() {
        netOut.clear()
        engine.wrap(ByteBuffer.allocate(0), netOut)
        netOut.flip()
        if (!netOut.hasRemaining()) return

        val pkt = ByteArray(netOut.remaining())
        netOut.get(pkt)

        val os = raw.getOutputStream()
        val head = if (pkt.size > 1) 1 else pkt.size
        os.write(pkt, 0, head)
        os.flush()
        if (pkt.size > head) {
            os.write(pkt, head, pkt.size - head)
            os.flush()
        }
    }

    private fun handshakeLoop() {
        while (true) {
            when (engine.handshakeStatus) {
                SSLEngineResult.HandshakeStatus.NEED_WRAP -> {
                    netOut.clear()
                    val r = engine.wrap(ByteBuffer.allocate(0), netOut)
                    netOut.flip()
                    if (netOut.hasRemaining()) {
                        val b = ByteArray(netOut.remaining())
                        netOut.get(b)
                        raw.getOutputStream().apply { write(b); flush() }
                    }
                    if (r.status == SSLEngineResult.Status.CLOSED) {
                        throw IOException("TLS closed during handshake")
                    }
                }

                SSLEngineResult.HandshakeStatus.NEED_UNWRAP -> {
                    // 先消化缓冲区里已有的密文
                    if (netIn.position() > 0) {
                        netIn.flip()
                        val rr = engine.unwrap(netIn, appIn)
                        netIn.compact()
                        if (rr.status != SSLEngineResult.Status.BUFFER_UNDERFLOW) continue
                    }
                    val n = raw.getInputStream().read(
                        netIn.array(),
                        netIn.position(),
                        netIn.remaining(),
                    )
                    if (n < 0) throw EOFException("peer closed during handshake")
                    netIn.position(netIn.position() + n)
                    netIn.flip()
                    engine.unwrap(netIn, appIn)
                    netIn.compact()
                }

                SSLEngineResult.HandshakeStatus.NEED_TASK -> {
                    while (true) {
                        val t = engine.delegatedTask ?: break
                        t.run()
                    }
                }

                SSLEngineResult.HandshakeStatus.FINISHED,
                SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING -> return
                else -> return
            }
        }
    }

    // ---------------------------------------------------------------- 流
    override fun getInputStream(): InputStream {
        ensureHandshake()
        inStream?.let { return it }
        val s = object : InputStream() {
            override fun read(): Int {
                val b = ByteArray(1)
                val n = read(b, 0, 1)
                return if (n <= 0) -1 else b[0].toInt() and 0xff
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                drainAppIn(b, off, len)?.let { return it }
                while (true) {
                    val n = raw.getInputStream().read(
                        netIn.array(),
                        netIn.position(),
                        netIn.remaining(),
                    )
                    if (n < 0) return -1
                    netIn.position(netIn.position() + n)
                    netIn.flip()
                    val r = engine.unwrap(netIn, appIn)
                    netIn.compact()
                    drainAppIn(b, off, len)?.let { return it }
                    if (r.status == SSLEngineResult.Status.CLOSED) return -1
                }
            }
        }
        inStream = s
        return s
    }

    private fun drainAppIn(b: ByteArray, off: Int, len: Int): Int? {
        if (appIn.position() == 0) return null
        appIn.flip()
        val n = minOf(len, appIn.remaining())
        appIn.get(b, off, n)
        appIn.compact()
        return if (n > 0) n else null
    }

    override fun getOutputStream(): OutputStream {
        ensureHandshake()
        outStream?.let { return it }
        val s = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

            override fun write(b: ByteArray, off: Int, len: Int) {
                appOut.clear()
                appOut.put(b, off, len)
                appOut.flip()
                while (appOut.hasRemaining()) {
                    netOut.clear()
                    engine.wrap(appOut, netOut)
                    netOut.flip()
                    if (netOut.hasRemaining()) {
                        val x = ByteArray(netOut.remaining())
                        netOut.get(x)
                        raw.getOutputStream().apply { write(x); flush() }
                    }
                }
            }
        }
        outStream = s
        return s
    }

    private fun ensureHandshake() {
        if (!handshakeDone) startHandshake()
    }

    // ---------------------------------------------------------------- 委托
    override fun getSupportedCipherSuites(): Array<String> = engine.supportedCipherSuites
    override fun getEnabledCipherSuites(): Array<String> = engine.enabledCipherSuites
    override fun setEnabledCipherSuites(suites: Array<String>) { engine.enabledCipherSuites = suites }
    override fun getSupportedProtocols(): Array<String> = engine.supportedProtocols
    override fun getEnabledProtocols(): Array<String> = engine.enabledProtocols
    override fun setEnabledProtocols(protocols: Array<String>) { engine.enabledProtocols = protocols }
    override fun getSession(): SSLSession = engine.session
    override fun getHandshakeSession(): SSLSession = engine.handshakeSession
    override fun addHandshakeCompletedListener(l: HandshakeCompletedListener) = Unit
    override fun removeHandshakeCompletedListener(l: HandshakeCompletedListener) = Unit
    override fun getUseClientMode(): Boolean = engine.useClientMode
    override fun setUseClientMode(mode: Boolean) { engine.useClientMode = mode }
    override fun getNeedClientAuth(): Boolean = engine.needClientAuth
    override fun setNeedClientAuth(need: Boolean) { engine.needClientAuth = need }
    override fun getWantClientAuth(): Boolean = engine.wantClientAuth
    override fun setWantClientAuth(want: Boolean) { engine.wantClientAuth = want }
    override fun getEnableSessionCreation(): Boolean = engine.enableSessionCreation
    override fun setEnableSessionCreation(flag: Boolean) { engine.enableSessionCreation = flag }

    override fun getInetAddress(): InetAddress = raw.inetAddress
    override fun getPort(): Int = raw.port
    override fun getLocalAddress(): InetAddress = raw.localAddress
    override fun getLocalPort(): Int = raw.localPort
    override fun getRemoteSocketAddress(): SocketAddress? = raw.remoteSocketAddress
    override fun getLocalSocketAddress(): SocketAddress? = raw.localSocketAddress
    override fun setSoTimeout(timeout: Int) { raw.soTimeout = timeout }
    override fun getSoTimeout(): Int = raw.soTimeout
    override fun setTcpNoDelay(on: Boolean) { raw.tcpNoDelay = on }
    override fun getTcpNoDelay(): Boolean = raw.tcpNoDelay
    override fun isConnected(): Boolean = raw.isConnected
    override fun isClosed(): Boolean = raw.isClosed

    override fun close() {
        try {
            engine.closeOutbound()
        } catch (_: Exception) {
        }
        raw.close()
    }

    private companion object {
        const val NET_BUF = 65536
        const val APP_BUF = 65536
        const val READ_TIMEOUT_MS = 30_000
    }
}
KOTLIN_EOF

echo "    created SplitClientHelloSocketFactory.kt ($(wc -l < "$CORE_DIR/SplitClientHelloSocketFactory.kt") 行)"

# ---------------------------------------------------------------- 2) 接线
cp "$HM" "$HM.bak-split-ch"
python3 - "$HM" << 'PY'
import sys, io
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

if 'SplitClientHelloSocketFactory' in src:
    print('    HttpClientManager.kt 已接线，跳过')
    sys.exit(0)

old = '.sslSocketFactory(sslContext.socketFactory, trustManager)'
new = ('.sslSocketFactory(\n'
       '        SplitClientHelloSocketFactory(sslContext), trustManager\n'
       '      )')
if old not in src:
    print('    ERROR: 找不到 .sslSocketFactory(sslContext.socketFactory, trustManager)', file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(src)
print('    patched HttpClientManager.kt -> 使用 SplitClientHelloSocketFactory')
PY

echo
echo "==> 校验"
grep -n "SplitClientHelloSocketFactory" "$HM" | head -3
echo "==> 06 补丁完成"
