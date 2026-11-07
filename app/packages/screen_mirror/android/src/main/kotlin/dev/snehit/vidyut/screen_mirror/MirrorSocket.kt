package dev.snehit.vidyut.screen_mirror

import android.util.Base64
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * A send-mostly WebSocket client for the mirror stream (ADR 0030).
 *
 * The relay only reads binary messages on this socket and closes it when the
 * laptop window closes, so this client sends masked binary frames, answers
 * pings and reports the close. It speaks plain `ws://` on the LAN; each
 * record is already sealed before it gets here.
 */
internal class MirrorSocket(
    url: String,
    private val onClosed: (reason: String) -> Unit,
) {
    private val uri = URI(url)
    private val random = SecureRandom()
    private val socket = Socket()
    private lateinit var output: BufferedOutputStream
    private lateinit var input: InputStream
    private val writeLock = ReentrantLock()

    @Volatile
    private var closed = false

    fun connect(timeoutMs: Int) {
        require(uri.scheme == "ws") { "The mirror stream needs a ws:// URL." }
        val port = if (uri.port == -1) 80 else uri.port
        socket.tcpNoDelay = true
        // A small send buffer keeps queued frames on the phone, where the
        // encoder can drop them, instead of in the kernel.
        socket.sendBufferSize = 256 * 1024
        socket.connect(InetSocketAddress(uri.host, port), timeoutMs)
        socket.soTimeout = timeoutMs
        output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
        input = BufferedInputStream(socket.getInputStream())

        val keyBytes = ByteArray(16).also(random::nextBytes)
        val key = Base64.encodeToString(keyBytes, Base64.NO_WRAP)
        val path = uri.rawPath.ifEmpty { "/" }
        val request = buildString {
            append("GET $path HTTP/1.1\r\n")
            append("Host: ${uri.host}:$port\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Key: $key\r\n")
            append("Sec-WebSocket-Version: 13\r\n")
            append("\r\n")
        }
        output.write(request.toByteArray(Charsets.US_ASCII))
        output.flush()

        val status = readLine()
        if (!status.startsWith("HTTP/1.1 101")) {
            throw IOException("The laptop refused the mirror stream ($status).")
        }
        var accept: String? = null
        while (true) {
            val line = readLine()
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0 && line.substring(0, colon).trim().equals("Sec-WebSocket-Accept", true)) {
                accept = line.substring(colon + 1).trim()
            }
        }
        val expected = Base64.encodeToString(
            MessageDigest.getInstance("SHA-1")
                .digest((key + WEBSOCKET_GUID).toByteArray(Charsets.US_ASCII)),
            Base64.NO_WRAP,
        )
        if (accept != expected) throw IOException("The laptop sent a bad WebSocket accept.")
        socket.soTimeout = 0
        Thread(::readLoop, "vidyut-mirror-reader").apply { isDaemon = true }.start()
    }

    /** Sends one binary message. Blocks while the socket's buffer is full. */
    fun sendBinary(payload: ByteArray) {
        sendFrame(OPCODE_BINARY, payload)
    }

    /**
     * Closes the stream. Safe before [connect] has finished and from any
     * thread. The close frame is only a courtesy: when the sender is stuck
     * on a full socket, the socket is closed without it, so a dead network
     * cannot hold this up.
     */
    fun close() {
        if (closed) return
        if (::output.isInitialized && writeLock.tryLock()) {
            try {
                writeFrame(OPCODE_CLOSE, byteArrayOf(0x03, 0xE8.toByte()))
            } catch (_: IOException) {
                // The socket is already gone.
            } finally {
                writeLock.unlock()
            }
        }
        finish("phone_stopped")
    }

    private fun sendFrame(opcode: Int, payload: ByteArray) {
        writeLock.withLock { writeFrame(opcode, payload) }
    }

    /** Writes one masked frame. The caller holds [writeLock]. */
    private fun writeFrame(opcode: Int, payload: ByteArray) {
        if (closed) throw IOException("The mirror stream is closed.")
        val mask = ByteArray(4).also(random::nextBytes)
        val length = payload.size
        val header = when {
            length < 126 -> byteArrayOf((0x80 or opcode).toByte(), (0x80 or length).toByte())
            length < 65536 -> byteArrayOf(
                (0x80 or opcode).toByte(),
                (0x80 or 126).toByte(),
                (length ushr 8).toByte(),
                length.toByte(),
            )
            else -> ByteArray(10).also {
                it[0] = (0x80 or opcode).toByte()
                it[1] = (0x80 or 127).toByte()
                val long = length.toLong()
                for (i in 0 until 8) it[2 + i] = (long ushr (56 - 8 * i)).toByte()
            }
        }
        val masked = ByteArray(length)
        for (i in 0 until length) masked[i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
        output.write(header)
        output.write(mask)
        output.write(masked)
        output.flush()
    }

    private fun readLoop() {
        var reason = "laptop_closed"
        try {
            while (!closed) {
                val first = input.read()
                if (first < 0) break
                val second = input.read()
                if (second < 0) break
                val opcode = first and 0x0F
                var length = (second and 0x7F).toLong()
                if (length == 126L) {
                    length = ((readByte() shl 8) or readByte()).toLong()
                } else if (length == 127L) {
                    length = 0
                    repeat(8) { length = (length shl 8) or readByte().toLong() }
                }
                if (length > MAX_CONTROL_BYTES) throw IOException("Unexpected large frame from the laptop.")
                val maskKey = if ((second and 0x80) != 0) ByteArray(4).also(::readFully) else null
                val payload = ByteArray(length.toInt()).also(::readFully)
                if (maskKey != null) {
                    for (i in payload.indices) {
                        payload[i] = (payload[i].toInt() xor maskKey[i and 3].toInt()).toByte()
                    }
                }
                when (opcode) {
                    OPCODE_PING -> sendFrame(OPCODE_PONG, payload)
                    OPCODE_CLOSE -> {
                        if (payload.size > 2) reason = String(payload, 2, payload.size - 2, Charsets.UTF_8)
                        break
                    }
                }
            }
        } catch (_: IOException) {
            reason = "connection_lost"
        }
        finish(reason)
    }

    private fun finish(reason: String) {
        synchronized(this) {
            if (closed) return
            closed = true
        }
        try {
            socket.close()
        } catch (_: IOException) {
        }
        onClosed(reason)
    }

    private fun readByte(): Int {
        val value = input.read()
        if (value < 0) throw IOException("The laptop closed the mirror stream.")
        return value
    }

    private fun readFully(buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val read = input.read(buffer, offset, buffer.size - offset)
            if (read < 0) throw IOException("The laptop closed the mirror stream.")
            offset += read
        }
    }

    private fun readLine(): String {
        val line = StringBuilder()
        while (true) {
            val value = input.read()
            if (value < 0) throw IOException("The laptop closed the mirror stream.")
            if (value == '\n'.code) break
            if (value != '\r'.code) line.append(value.toChar())
            if (line.length > 8192) throw IOException("The laptop sent a bad handshake.")
        }
        return line.toString()
    }

    private companion object {
        const val WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        const val OPCODE_BINARY = 0x2
        const val OPCODE_CLOSE = 0x8
        const val OPCODE_PING = 0x9
        const val OPCODE_PONG = 0xA
        const val MAX_CONTROL_BYTES = 64 * 1024L
    }
}
