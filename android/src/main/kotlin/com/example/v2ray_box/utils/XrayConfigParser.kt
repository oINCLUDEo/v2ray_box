package com.example.v2ray_box.utils

import android.net.Uri
import android.util.Log
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import java.net.URLDecoder

object XrayConfigParser {
    private const val TAG = "V2Ray/XrayConfigParser"
    private val gson: Gson = GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create()

    fun buildXrayConfig(link: String, proxyOnly: Boolean = false): String {
        val outbound = parseLink(link) ?: throw Exception("Invalid or unsupported config link")

        val socksPort = 10808
        val httpPort = 10809

        val inbounds = mutableListOf<Map<String, Any>>(
            mapOf(
                "tag" to "socks",
                "port" to socksPort,
                "listen" to "127.0.0.1",
                "protocol" to "socks",
                "sniffing" to mapOf(
                    "enabled" to true,
                    "destOverride" to listOf("http", "tls", "quic"),
                    "routeOnly" to true
                ),
                "settings" to mapOf(
                    "auth" to "noauth",
                    "udp" to true,
                    "userLevel" to 8
                )
            ),
            mapOf(
                "tag" to "http",
                "port" to httpPort,
                "listen" to "127.0.0.1",
                "protocol" to "http",
                "sniffing" to mapOf(
                    "enabled" to true,
                    "destOverride" to listOf("http", "tls", "quic"),
                    "routeOnly" to true
                ),
                "settings" to mapOf<String, Any>()
            )
        )

        if (!proxyOnly) {
            inbounds.add(
                mapOf(
                    "tag" to "tun",
                    "port" to 0,
                    "protocol" to "tun",
                    "settings" to mapOf(
                        "name" to "xray0",
                        "MTU" to 9000,
                        "userLevel" to 8
                    ),
                    "sniffing" to mapOf(
                        "enabled" to true,
                        "destOverride" to listOf("http", "tls", "quic")
                    )
                )
            )
        }

        val config = mutableMapOf<String, Any>(
            "log" to mapOf("loglevel" to "warning"),
            "dns" to buildDns(),
            "inbounds" to inbounds,
            "outbounds" to listOf(
                outbound,
                mapOf("tag" to "direct", "protocol" to "freedom", "settings" to mapOf<String, Any>()),
                mapOf(
                    "tag" to "block",
                    "protocol" to "blackhole",
                    "settings" to mapOf("response" to mapOf("type" to "http"))
                )
            ),
            "routing" to buildRouting(),
            "stats" to mapOf<String, Any>(),
            "policy" to buildPolicy()
        )

        return gson.toJson(config)
    }

    fun parseLink(link: String): Map<String, Any>? {
        return try {
            when {
                link.startsWith("vless://") -> parseVless(link)
                link.startsWith("vmess://") -> parseVmess(link)
                link.startsWith("trojan://") -> parseTrojan(link)
                link.startsWith("ss://") -> parseShadowsocks(link)
                link.startsWith("hy2://") || link.startsWith("hysteria2://") -> parseHysteria2(link)
                link.startsWith("wg://") -> parseWireGuard(link)
                else -> null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse link: ${e.message}", e)
            null
        }
    }

    private fun buildDns(): Map<String, Any> {
        return mapOf(
            "hosts" to mapOf("dns.google" to "8.8.8.8"),
            "servers" to listOf(
                "https://1.1.1.1/dns-query",
                "1.1.1.1",
                "8.8.8.8",
                "localhost"
            )
        )
    }

    private fun buildRouting(): Map<String, Any> {
        return mapOf(
            "domainStrategy" to "IPIfNonMatch",
            "rules" to listOf(
                mapOf(
                    "type" to "field",
                    "outboundTag" to "direct",
                    "ip" to listOf(
                        "10.0.0.0/8",
                        "172.16.0.0/12",
                        "192.168.0.0/16",
                        "100.64.0.0/10",
                        "169.254.0.0/16",
                        "127.0.0.0/8",
                        "fc00::/7",
                        "fe80::/10",
                        "::1/128"
                    )
                ),
                mapOf(
                    "type" to "field",
                    "outboundTag" to "block",
                    "protocol" to listOf("bittorrent")
                )
            )
        )
    }

    private fun buildPolicy(): Map<String, Any> {
        return mapOf(
            "levels" to mapOf(
                "0" to mapOf(
                    "statsUserUplink" to true,
                    "statsUserDownlink" to true
                ),
                "8" to mapOf(
                    "handshake" to 4,
                    "connIdle" to 300,
                    "uplinkOnly" to 1,
                    "downlinkOnly" to 1
                )
            ),
            "system" to mapOf(
                "statsOutboundUplink" to true,
                "statsOutboundDownlink" to true
            )
        )
    }

    private fun parseQueryParams(uri: Uri): Map<String, String> {
        val params = mutableMapOf<String, String>()
        uri.query?.split("&")?.forEach { param ->
            val parts = param.split("=", limit = 2)
            if (parts.size == 2) {
                params[parts[0]] = URLDecoder.decode(parts[1], "UTF-8")
            } else if (parts.size == 1) {
                params[parts[0]] = ""
            }
        }
        return params
    }

    private fun buildStreamSettings(params: Map<String, String>, vmessJson: Map<*, *>? = null): Map<String, Any> {
        val stream = mutableMapOf<String, Any>()
        val networkType = params["type"] ?: vmessJson?.get("net")?.toString() ?: "tcp"
        stream["network"] = networkType

        val security = params["security"]
            ?: if (vmessJson?.get("tls")?.toString() == "tls") "tls" else "none"
        stream["security"] = security

        when (networkType) {
            "ws", "websocket" -> {
                val wsSettings = mutableMapOf<String, Any>()
                val path = params["path"] ?: vmessJson?.get("path")?.toString() ?: "/"
                wsSettings["path"] = path
                val host = params["host"] ?: vmessJson?.get("host")?.toString()
                if (!host.isNullOrEmpty()) {
                    wsSettings["headers"] = mapOf("Host" to host)
                }
                stream["wsSettings"] = wsSettings
            }
            "grpc" -> {
                val grpcSettings = mutableMapOf<String, Any>()
                val sn = params["serviceName"] ?: params["service-name"]
                    ?: vmessJson?.get("path")?.toString()
                if (!sn.isNullOrEmpty()) grpcSettings["serviceName"] = sn
                params["mode"]?.takeIf { it.isNotEmpty() }?.let { grpcSettings["multiMode"] = (it == "multi") }
                stream["grpcSettings"] = grpcSettings
            }
            "h2", "http" -> {
                val httpSettings = mutableMapOf<String, Any>()
                val path = params["path"] ?: vmessJson?.get("path")?.toString()
                if (!path.isNullOrEmpty()) httpSettings["path"] = path
                val host = params["host"] ?: vmessJson?.get("host")?.toString()
                if (!host.isNullOrEmpty()) {
                    httpSettings["host"] = host.split(",").map { it.trim() }
                }
                stream["httpSettings"] = httpSettings
                stream["network"] = "h2"
            }
            "httpupgrade" -> {
                val huSettings = mutableMapOf<String, Any>()
                val path = params["path"] ?: vmessJson?.get("path")?.toString()
                if (!path.isNullOrEmpty()) huSettings["path"] = path
                val host = params["host"] ?: vmessJson?.get("host")?.toString()
                if (!host.isNullOrEmpty()) huSettings["host"] = host
                stream["httpupgradeSettings"] = huSettings
            }
            "splithttp", "xhttp" -> {
                val shSettings = mutableMapOf<String, Any>()
                val path = params["path"] ?: vmessJson?.get("path")?.toString()
                if (!path.isNullOrEmpty()) shSettings["path"] = path
                val host = params["host"] ?: vmessJson?.get("host")?.toString()
                if (!host.isNullOrEmpty()) shSettings["host"] = host
                params["mode"]?.takeIf { it.isNotEmpty() }?.let { shSettings["mode"] = it }
                stream["splithttpSettings"] = shSettings
                stream["network"] = "splithttp"
            }
            "quic" -> {
                val quicSettings = mutableMapOf<String, Any>(
                    "security" to (params["quicSecurity"] ?: "none"),
                    "header" to mapOf("type" to (params["headerType"] ?: "none"))
                )
                params["key"]?.takeIf { it.isNotEmpty() }?.let { quicSettings["key"] = it }
                stream["quicSettings"] = quicSettings
            }
            "kcp", "mkcp" -> {
                val kcpSettings = mutableMapOf<String, Any>(
                    "header" to mapOf("type" to (params["headerType"] ?: "none"))
                )
                params["seed"]?.takeIf { it.isNotEmpty() }?.let { kcpSettings["seed"] = it }
                stream["kcpSettings"] = kcpSettings
                stream["network"] = "kcp"
            }
        }

        when (security) {
            "tls" -> {
                val tlsSettings = mutableMapOf<String, Any>()
                val sni = params["sni"] ?: params["peer"] ?: vmessJson?.get("sni")?.toString()
                if (!sni.isNullOrEmpty()) tlsSettings["serverName"] = sni
                val alpn = params["alpn"] ?: vmessJson?.get("alpn")?.toString()
                if (!alpn.isNullOrEmpty()) {
                    tlsSettings["alpn"] = alpn.split(",").map { it.trim() }
                }
                val fp = params["fp"] ?: params["fingerprint"]
                if (!fp.isNullOrEmpty()) tlsSettings["fingerprint"] = fp
                params["allowInsecure"]?.let {
                    if (it == "1" || it == "true") tlsSettings["allowInsecure"] = true
                }
                stream["tlsSettings"] = tlsSettings
            }
            "reality" -> {
                val realitySettings = mutableMapOf<String, Any>()
                val sni = params["sni"] ?: params["peer"]
                if (!sni.isNullOrEmpty()) realitySettings["serverName"] = sni
                val fp = params["fp"] ?: params["fingerprint"] ?: "chrome"
                realitySettings["fingerprint"] = fp
                params["pbk"]?.takeIf { it.isNotEmpty() }?.let { realitySettings["publicKey"] = it }
                params["sid"]?.takeIf { it.isNotEmpty() }?.let { realitySettings["shortId"] = it }
                params["spx"]?.takeIf { it.isNotEmpty() }?.let { realitySettings["spiderX"] = it }
                stream["realitySettings"] = realitySettings
            }
        }

        return stream
    }

    // ========== Protocol Parsers ==========

    private fun parseVless(link: String): Map<String, Any> {
        val uri = Uri.parse(link)
        val uuid = uri.userInfo ?: throw Exception("Invalid vless link: no UUID")
        val server = uri.host ?: throw Exception("Invalid vless link: no server")
        val port = uri.port.takeIf { it > 0 } ?: 443
        val params = parseQueryParams(uri)

        val user = mutableMapOf<String, Any>(
            "id" to uuid,
            "encryption" to (params["encryption"] ?: "none"),
            "level" to 0
        )
        params["flow"]?.takeIf { it.isNotEmpty() }?.let { user["flow"] = it }

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "vless",
            "settings" to mapOf(
                "vnext" to listOf(
                    mapOf(
                        "address" to server,
                        "port" to port,
                        "users" to listOf(user)
                    )
                )
            ),
            "streamSettings" to buildStreamSettings(params)
        )

        return outbound
    }

    private fun parseVmess(link: String): Map<String, Any> {
        val encoded = link.removePrefix("vmess://")
        val decoded = try {
            android.util.Base64.decode(encoded, android.util.Base64.DEFAULT).toString(Charsets.UTF_8)
        } catch (e: Exception) {
            return parseVmessUrl(link)
        }

        if (!decoded.trimStart().startsWith("{")) return parseVmessUrl(link)

        @Suppress("UNCHECKED_CAST")
        val json = gson.fromJson(decoded, Map::class.java) as Map<String, Any?>
        val server = json["add"]?.toString() ?: throw Exception("Invalid vmess: no server")
        val port = json["port"]?.toString()?.toDoubleOrNull()?.toInt() ?: 443
        val uuid = json["id"]?.toString() ?: throw Exception("Invalid vmess: no id")
        val aid = json["aid"]?.toString()?.toDoubleOrNull()?.toInt() ?: 0
        val security = json["scy"]?.toString()?.takeIf { it.isNotEmpty() } ?: "auto"

        val user = mutableMapOf<String, Any>(
            "id" to uuid,
            "alterId" to aid,
            "security" to security,
            "level" to 0
        )

        val params = mutableMapOf<String, String>()
        json["net"]?.toString()?.let { params["type"] = it }
        if (json["tls"]?.toString() == "tls") params["security"] = "tls"
        json["sni"]?.toString()?.let { params["sni"] = it }
        json["alpn"]?.toString()?.let { params["alpn"] = it }
        json["fp"]?.toString()?.let { params["fp"] = it }
        json["path"]?.toString()?.let { params["path"] = it }
        json["host"]?.toString()?.let { params["host"] = it }
        json["type"]?.toString()?.let { params["headerType"] = it }

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "vmess",
            "settings" to mapOf(
                "vnext" to listOf(
                    mapOf(
                        "address" to server,
                        "port" to port,
                        "users" to listOf(user)
                    )
                )
            ),
            "streamSettings" to buildStreamSettings(params, json)
        )

        return outbound
    }

    private fun parseVmessUrl(link: String): Map<String, Any> {
        val uri = Uri.parse(link)
        val uuid = uri.userInfo ?: throw Exception("Invalid vmess link")
        val server = uri.host ?: throw Exception("Invalid vmess link")
        val port = uri.port.takeIf { it > 0 } ?: 443
        val params = parseQueryParams(uri)

        val user = mutableMapOf<String, Any>(
            "id" to uuid,
            "alterId" to 0,
            "security" to "auto",
            "level" to 0
        )

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "vmess",
            "settings" to mapOf(
                "vnext" to listOf(
                    mapOf(
                        "address" to server,
                        "port" to port,
                        "users" to listOf(user)
                    )
                )
            ),
            "streamSettings" to buildStreamSettings(params)
        )

        return outbound
    }

    private fun parseTrojan(link: String): Map<String, Any> {
        val uri = Uri.parse(link)
        val password = uri.userInfo ?: throw Exception("Invalid trojan link: no password")
        val server = uri.host ?: throw Exception("Invalid trojan link: no server")
        val port = uri.port.takeIf { it > 0 } ?: 443
        val params = parseQueryParams(uri)

        val tlsParams = params.toMutableMap()
        if (!tlsParams.containsKey("security")) {
            tlsParams["security"] = "tls"
        }

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "trojan",
            "settings" to mapOf(
                "servers" to listOf(
                    mapOf(
                        "address" to server,
                        "port" to port,
                        "password" to password,
                        "level" to 0
                    )
                )
            ),
            "streamSettings" to buildStreamSettings(tlsParams)
        )

        return outbound
    }

    private fun parseShadowsocks(link: String): Map<String, Any> {
        val withoutPrefix = link.removePrefix("ss://")
        val fragmentIndex = withoutPrefix.lastIndexOf("#")
        val linkPart = if (fragmentIndex > 0) withoutPrefix.substring(0, fragmentIndex) else withoutPrefix

        val queryIndex = linkPart.indexOf("?")
        val mainPart = if (queryIndex > 0) linkPart.substring(0, queryIndex) else linkPart

        val atIndex = mainPart.lastIndexOf("@")
        val (method, password, server, port) = if (atIndex > 0) {
            val userPart = mainPart.substring(0, atIndex)
            val serverPart = mainPart.substring(atIndex + 1)
            val decoded = try {
                android.util.Base64.decode(userPart, android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE)
                    .toString(Charsets.UTF_8)
            } catch (e: Exception) {
                try {
                    android.util.Base64.decode(userPart, android.util.Base64.DEFAULT)
                        .toString(Charsets.UTF_8)
                } catch (e2: Exception) {
                    userPart
                }
            }
            val colonIdx = decoded.indexOf(":")
            val m = decoded.substring(0, colonIdx)
            val p = decoded.substring(colonIdx + 1)
            val lastColon = serverPart.lastIndexOf(":")
            val s = serverPart.substring(0, lastColon)
            val pt = serverPart.substring(lastColon + 1).toInt()
            listOf(m, p, s, pt.toString())
        } else {
            val decoded = try {
                android.util.Base64.decode(mainPart, android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE)
                    .toString(Charsets.UTF_8)
            } catch (e: Exception) {
                android.util.Base64.decode(mainPart, android.util.Base64.DEFAULT)
                    .toString(Charsets.UTF_8)
            }
            val idx = decoded.lastIndexOf("@")
            val userPart = decoded.substring(0, idx)
            val serverPart = decoded.substring(idx + 1)
            val colonIdx = userPart.indexOf(":")
            val m = userPart.substring(0, colonIdx)
            val p = userPart.substring(colonIdx + 1)
            val lastColon = serverPart.lastIndexOf(":")
            val s = serverPart.substring(0, lastColon)
            val pt = serverPart.substring(lastColon + 1).toInt()
            listOf(m, p, s, pt.toString())
        }

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "shadowsocks",
            "settings" to mapOf(
                "servers" to listOf(
                    mapOf(
                        "address" to server,
                        "port" to port.toInt(),
                        "method" to method,
                        "password" to password,
                        "level" to 0
                    )
                )
            ),
            "streamSettings" to mapOf("network" to "tcp")
        )

        return outbound
    }

    private fun parseHysteria2(link: String): Map<String, Any> {
        val normalized = link.replace("hysteria2://", "hy2://")
        val uri = Uri.parse(normalized)
        val auth = uri.userInfo ?: ""
        val server = uri.host ?: throw Exception("Invalid hy2 link: no server")
        val port = uri.port.takeIf { it > 0 } ?: 443
        val params = parseQueryParams(uri)

        val serverObj = mutableMapOf<String, Any>(
            "address" to server,
            "port" to port,
            "password" to auth,
            "level" to 0
        )

        val outbound = mutableMapOf<String, Any>(
            "tag" to "proxy",
            "protocol" to "hysteria2",
            "settings" to mapOf("servers" to listOf(serverObj))
        )

        val stream = mutableMapOf<String, Any>("network" to "tcp", "security" to "tls")
        val tlsSettings = mutableMapOf<String, Any>()
        params["sni"]?.takeIf { it.isNotEmpty() }?.let { tlsSettings["serverName"] = it }
        params["insecure"]?.let {
            if (it == "1" || it == "true") tlsSettings["allowInsecure"] = true
        }
        params["alpn"]?.takeIf { it.isNotEmpty() }?.let {
            tlsSettings["alpn"] = it.split(",").map { a -> a.trim() }
        }
        stream["tlsSettings"] = tlsSettings
        outbound["streamSettings"] = stream

        return outbound
    }

    private fun parseWireGuard(link: String): Map<String, Any> {
        val uri = Uri.parse(link)
        val privateKey = uri.userInfo ?: ""
        val server = uri.host ?: throw Exception("Invalid wg link: no server")
        val port = uri.port.takeIf { it > 0 } ?: 51820
        val params = parseQueryParams(uri)

        val peer = mutableMapOf<String, Any>(
            "endpoint" to "$server:$port"
        )
        params["publickey"]?.takeIf { it.isNotEmpty() }?.let { peer["publicKey"] = it }
        params["psk"]?.takeIf { it.isNotEmpty() }?.let { peer["preSharedKey"] = it }

        val settings = mutableMapOf<String, Any>(
            "secretKey" to privateKey,
            "peers" to listOf(peer)
        )
        params["address"]?.takeIf { it.isNotEmpty() }?.let {
            settings["address"] = it.split(",").map { a -> a.trim() }
        }
        params["reserved"]?.takeIf { it.isNotEmpty() }?.let { reserved ->
            val bytes = reserved.split(",").mapNotNull { it.trim().toIntOrNull() }
            if (bytes.isNotEmpty()) settings["reserved"] = bytes
        }
        params["mtu"]?.toIntOrNull()?.let { settings["mtu"] = it }

        return mapOf(
            "tag" to "proxy",
            "protocol" to "wireguard",
            "settings" to settings
        )
    }
}
