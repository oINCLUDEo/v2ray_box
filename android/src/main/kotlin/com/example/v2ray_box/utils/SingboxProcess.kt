package com.example.v2ray_box.utils

import android.content.Context
import android.util.Log
import java.io.File

object SingboxProcess {
    private const val TAG = "V2Ray/SingboxProcess"
    private var process: Process? = null
    @Volatile var isRunning: Boolean = false
        private set

    fun getBinaryPath(context: Context): String? {
        val nativeLibDir = context.applicationInfo.nativeLibraryDir
        val binary = File(nativeLibDir, "libsingbox.so")
        if (binary.exists() && binary.canExecute()) {
            return binary.absolutePath
        }
        Log.w(TAG, "sing-box binary not found at: ${binary.absolutePath}")
        return null
    }

    fun getVersion(context: Context): String {
        val binaryPath = getBinaryPath(context) ?: return ""
        return try {
            val proc = ProcessBuilder(binaryPath, "version")
                .redirectErrorStream(true)
                .start()
            val output = proc.inputStream.bufferedReader().readText().trim()
            proc.waitFor()
            val match = Regex("""sing-box version (\S+)""").find(output)
            match?.groupValues?.get(1) ?: output.lines().firstOrNull()?.trim() ?: ""
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get sing-box version", e)
            ""
        }
    }

    fun start(context: Context, configPath: String): Boolean {
        if (isRunning) {
            Log.w(TAG, "sing-box is already running")
            return true
        }

        val binaryPath = getBinaryPath(context) ?: run {
            Log.e(TAG, "sing-box binary not found")
            return false
        }

        return try {
            val workDir = context.getExternalFilesDir(null) ?: context.filesDir
            Log.d(TAG, "Starting sing-box: $binaryPath run -c $configPath -D ${workDir.absolutePath}")

            val pb = ProcessBuilder(binaryPath, "run", "-c", configPath, "-D", workDir.absolutePath)
                .directory(workDir)
                .redirectErrorStream(true)

            process = pb.start()
            isRunning = true

            Thread {
                try {
                    process?.inputStream?.bufferedReader()?.forEachLine { line ->
                        Log.i("SingboxCore", line)
                    }
                } catch (_: Exception) {}
            }.start()

            Thread {
                try {
                    val exitCode = process?.waitFor() ?: -1
                    Log.d(TAG, "sing-box process exited with code: $exitCode")
                } catch (_: InterruptedException) {
                } finally {
                    isRunning = false
                    process = null
                }
            }.start()

            Thread.sleep(500)
            if (process?.isAlive == true) {
                Log.d(TAG, "sing-box started successfully")
                true
            } else {
                Log.e(TAG, "sing-box process died immediately")
                isRunning = false
                process = null
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start sing-box", e)
            isRunning = false
            process = null
            false
        }
    }

    fun stop() {
        try {
            process?.let { proc ->
                Log.d(TAG, "Stopping sing-box process")
                proc.destroy()
                try {
                    proc.waitFor()
                } catch (_: InterruptedException) {
                    proc.destroyForcibly()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping sing-box", e)
        } finally {
            process = null
            isRunning = false
        }
    }
}
