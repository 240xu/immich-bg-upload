#!/usr/bin/env bash
# 06-split-clienthello.sh
#
# 背景（2026-11-01 实测确诊）：
#   阿里云杭州入口 118.178.58.100 对 **ClientHello 首包 < ~1441 字节** 的 TLS 握手
#   直接回 RST（所有端口一致）。该规则只对 SNI=*.sepic.space 生效。
#
#   实测数据：
#     - 一次性发 197B 完整 ClientHello            -> RST
#     - 先发 1 字节，再发其余 196 字节             -> ServerHello ✅
#     - 先发 5 字节（TLS 记录头），再发其余        -> ServerHello ✅
#     - OpenSSL/curl/Python-ssl 的 CH ~1500B      -> 天然放行
#     - JDK JSSE 441B / Android Conscrypt ~300-500B -> 必被 RST
#
#   所以 Immich App（OkHttp + Conscrypt，ClientHello 小）连不上，
#   而手机 Chrome（BoringSSL，CH 大）能正常打开同一域名。
#
# 修法：
#   在 TLS socket 的 OutputStream 层做「首包分段」——第一次 write 时
#   先写 1 字节，再写剩余部分。这样阿里云网关看到的是非完整首包，
#   不做 TLS 指纹判定，直接放行；对端 TLS 栈会正常重组，行为不变。
#
#   实现：
#   1) 新建 SplitClientHelloSocketFactory.kt —— 包装 SSLSocketFactory，
#      返回 SSLSocket 子类，其 getOutputStream() 返回 SplittingOutputStream。
#   2) 改 HttpClientManager.kt 的 build()，把 sslContext.socketFactory
#      套上这层包装。
#
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
NET_DIR="$ROOT/immich/mobile/android/app/src/main/kotlin/app/alextran/immich/core"
HM="$NET_DIR/HttpClientManager.kt"

if [ ! -d "$NET_DIR" ]; then
  echo "ERROR: 找不到 core 目录: $NET_DIR" >&2
  exit 1
fi
if [ ! -f "$HM" ]; then
  echo "ERROR: 找不到 HttpClientManager.kt: $HM" >&2
  exit 1
fi

echo "==> 目标目录: $NET_DIR"

# ---------------------------------------------------------------- 1) 新文件
cat > "$NET_DIR/SplitClientHelloSocketFactory.kt" << 'KOTLIN_EOF'
package app.alextran.immich.core

import java.io.FilterOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * 阿里云杭州入口对「ClientHello 首包 < ~1441 字节」的 TLS 握手直接 RST
 * （只对 SNI=*.sepic.space 生效）。Android 的 Conscrypt ClientHello 只有
 * 300~500 字节，因此 Immich App 到 nas.sepic.space 会报 "Server is not reachable"，
 * 而手机 Chrome（BoringSSL，CH ~1500B）却能正常打开同一域名。
 *
 * 实测绕过方式：把 TLS 首包拆成两段发送（先 1 字节，再其余）。
 * 网关不重组 TCP 流，因此不做指纹判定；对端 TLS 栈正常重组，语义不变。
 *
 * 本类包装 SSLSocketFactory，返回的 SSLSocket 的 OutputStream 会在
 * **第一次 write** 时把数据拆成 1 + N 两段写出。
 */
class SplitClientHelloSocketFactory(
    private val delegate: SSLSocketFactory,
    private val headBytes: Int = 1,
) : SSLSocketFactory() {

    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(s: Socket, host: String, port: Int, autoClose: Boolean): Socket =
        wrap(delegate.createSocket(s, host, port, autoClose))

    override fun createSocket(host: String, port: Int): Socket =
        wrap(delegate.createSocket(host, port))

    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
        wrap(delegate.createSocket(host, port, localHost, localPort))

    override fun createSocket(host: InetAddress, port: Int): Socket =
        wrap(delegate.createSocket(host, port))

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = wrap(delegate.createSocket(address, port, localAddress, localPort))

    private fun wrap(socket: Socket): Socket {
        val ssl = socket as? SSLSocket ?: return socket
        return SplittingSSLSocket(ssl, headBytes)
    }
}

/**
 * 把底层 SSLSocket 的 OutputStream 换成会在首包分段写出的包装流。
 * 其余所有行为（ALPN、SNI、证书校验）完全委托给原始 socket。
 */
private class SplittingSSLSocket(
    private val delegate: SSLSocket,
    private val headBytes: Int,
) : SSLSocket() {

    private var splittingStream: OutputStream? = null

    override fun getOutputStream(): OutputStream {
        splittingStream?.let { return it }
        val raw = delegate.outputStream
        val out = SplittingOutputStream(raw, headBytes)
        splittingStream = out
        return out
    }

    // ---- 全部委托 ----
    override fun getInputStream() = delegate.inputStream
    override fun getInetAddress() = delegate.inetAddress
    override fun getPort() = delegate.port
    override fun getLocalAddress() = delegate.localAddress
    override fun getLocalPort() = delegate.localPort
    override fun getRemoteSocketAddress() = delegate.remoteSocketAddress
    override fun getLocalSocketAddress() = delegate.localSocketAddress
    override fun setTcpNoDelay(on: Boolean) = delegate.setTcpNoDelay(on)
    override fun getTcpNoDelay() = delegate.tcpNoDelay
    override fun setSoLinger(on: Boolean, linger: Int) = delegate.setSoLinger(on, linger)
    override fun getSoLinger() = delegate.soLinger
    override fun setSoTimeout(timeout: Int) = delegate.soTimeout = timeout
    override fun getSoTimeout() = delegate.soTimeout
    override fun setSendBufferSize(size: Int) = delegate.sendBufferSize = size
    override fun getSendBufferSize() = delegate.sendBufferSize
    override fun setReceiveBufferSize(size: Int) = delegate.receiveBufferSize = size
    override fun getReceiveBufferSize() = delegate.receiveBufferSize
    override fun setKeepAlive(on: Boolean) = delegate.keepAlive = on
    override fun getKeepAlive() = delegate.keepAlive
    override fun setOOBInline(on: Boolean) = delegate.setOOBInline(on)
    override fun getOOBInline() = delegate.oobInline
    override fun setTrafficClass(tc: Int) = delegate.trafficClass = tc
    override fun getTrafficClass() = delegate.trafficClass
    override fun setReuseAddress(on: Boolean) = delegate.reuseAddress = on
    override fun getReuseAddress() = delegate.reuseAddress
    override fun close() = delegate.close()
    override fun shutdownInput() = delegate.shutdownInput()
    override fun shutdownOutput() = delegate.shutdownOutput()
    override fun toString(): String = delegate.toString()
    override fun isConnected() = delegate.isConnected
    override fun isBound() = delegate.isBound
    override fun isClosed() = delegate.isClosed
    override fun isInputShutdown() = delegate.isInputShutdown
    override fun isOutputShutdown() = delegate.isOutputShutdown
    override fun createChannel() = delegate.channel

    // ---- SSLSocket 专属 ----
    override fun startHandshake() = delegate.startHandshake()
    override fun addHandshakeCompletedListener(l: javax.net.ssl.HandshakeCompletedListener) =
        delegate.addHandshakeCompletedListener(l)
    override fun removeHandshakeCompletedListener(l: javax.net.ssl.HandshakeCompletedListener) =
        delegate.removeHandshakeCompletedListener(l)
    override fun getSession() = delegate.session
    override fun getHandshakeSession() = delegate.handshakeSession
    override fun getEnableSessionCreation() = delegate.enableSessionCreation
    override fun setEnableSessionCreation(flag: Boolean) = delegate.setEnableSessionCreation(flag)
    override fun getEnabledCipherSuites() = delegate.enabledCipherSuites
    override fun setEnabledCipherSuites(suites: Array<String>) = delegate.setEnabledCipherSuites(suites)
    override fun getEnabledProtocols() = delegate.enabledProtocols
    override fun setEnabledProtocols(protocols: Array<String>) = delegate.setEnabledProtocols(protocols)
    override fun getSupportedCipherSuites() = delegate.supportedCipherSuites
    override fun getSupportedProtocols() = delegate.supportedProtocols
    override fun getUseClientMode() = delegate.useClientMode
    override fun setUseClientMode(mode: Boolean) = delegate.setUseClientMode(mode)
    override fun getNeedClientAuth() = delegate.needClientAuth
    override fun setNeedClientAuth(need: Boolean) = delegate.setNeedClientAuth(need)
    override fun getWantClientAuth() = delegate.wantClientAuth
    override fun setWantClientAuth(want: Boolean) = delegate.setWantClientAuth(want)
    override fun getSSLParameters() = delegate.sslParameters
    override fun setSSLParameters(p: javax.net.ssl.SSLParameters) = delegate.sslParameters = p
}

/**
 * 首次 write 时先写 headBytes 字节，再写剩余部分；之后的 write 直接透传。
 *
 * 为什么这样能绕过：阿里云杭州网关对「单个 TCP 段里完整的 ClientHello」
 * 做 TLS 指纹判定，CH 太小（<1441B）就 RST。分段后网关看到的首段不含完整
 * ClientHello，于是放行；对端 TLS 实现按 TCP 流重组，完全无感。
 */
private class SplittingOutputStream(
    private val delegate: OutputStream,
    private val headBytes: Int,
) : FilterOutputStream(delegate) {

    private var headSent = headBytes <= 0

    override fun write(b: Int) {
        delegate.write(b)
    }

    override fun write(b: ByteArray, off: Int, len: Int) {
        if (headSent || len <= headBytes) {
            delegate.write(b, off, len)
            if (!headSent) headSent = true
            return
        }
        // 首包：先写 head 字节
        delegate.write(b, off, headBytes)
        delegate.flush()
        // 再写剩余
        delegate.write(b, off + headBytes, len - headBytes)
        headSent = true
    }

    override fun flush() {
        delegate.flush()
    }

    override fun close() {
        delegate.close()
    }
}
KOTLIN_EOF

echo "    created SplitClientHelloSocketFactory.kt ($(wc -l < "$NET_DIR/SplitClientHelloSocketFactory.kt") 行)"

# ---------------------------------------------------------------- 2) 接线
cp "$HM" "$HM.bak-split-ch"
python3 - "$HM" << 'PY'
import sys, re, io
p = sys.argv[1]
src = io.open(p, encoding='utf-8').read()

if 'SplitClientHelloSocketFactory' in src:
    print('    HttpClientManager.kt 已接线，跳过')
    sys.exit(0)

old = '.sslSocketFactory(sslContext.socketFactory, trustManager)'
new = ('.sslSocketFactory(\n'
       '        SplitClientHelloSocketFactory(sslContext.socketFactory), trustManager\n'
       '      )')
if old not in src:
    print('    ERROR: 找不到 sslSocketFactory 调用点', file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(src)
print('    patched HttpClientManager.kt -> 套上 SplitClientHelloSocketFactory')
PY

echo
echo "==> 校验"
grep -n "SplitClientHelloSocketFactory" "$HM" | head -3
echo "==> 06 补丁完成"
