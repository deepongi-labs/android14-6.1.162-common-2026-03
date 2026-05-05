package com.deepongi.dynaschedmanager

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader

object RootShell {
  suspend fun isRootAvailable(): Boolean = withContext(Dispatchers.IO) {
    run("id").exitCode == 0
  }

  suspend fun run(script: String): ShellResult = withContext(Dispatchers.IO) {
    val process = ProcessBuilder("su", "-c", script)
      .redirectErrorStream(false)
      .start()

    val stdout = process.inputStream.bufferedReader().use(BufferedReader::readText)
    val stderr = process.errorStream.bufferedReader().use(BufferedReader::readText)
    val exitCode = process.waitFor()

    ShellResult(
      exitCode = exitCode,
      stdout = stdout.trim(),
      stderr = stderr.trim()
    )
  }
}

data class ShellResult(
  val exitCode: Int,
  val stdout: String,
  val stderr: String
)
