package com.deepongi.dynaschedmanager

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.webkit.URLUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

class KernelManager(private val context: Context) {
  private val store = KernelStore(context)
  private val repoOwner = "deepongi-labs"
  private val repoName = "android14-6.1.162-common-2026-03"

  suspend fun readState(): KernelState {
    val prefs = store.readPrefs()
    val rootAvailable = RootShell.isRootAvailable()
    if (!rootAvailable) {
      return KernelState(
        rootAvailable = false,
        bootSettings = prefs.bootSettings,
        activeProfile = prefs.lastProfile,
        customTuning = prefs.customTuning,
        statusMessage = "Root is required. Grant superuser access to manage dynasched."
      ).withBackup()
    }

    val result = RootShell.run(buildInspectionScript())
    if (result.exitCode != 0) {
      return KernelState(
        rootAvailable = true,
        bootSettings = prefs.bootSettings,
        activeProfile = prefs.lastProfile,
        customTuning = prefs.customTuning,
        diagnostics = DiagnosticsReport(lastError = result.stderr.ifBlank { "Failed to read kernel state." }),
        statusMessage = result.stderr.ifBlank { "Failed to read kernel state." }
      ).withBackup()
    }

    val parsed = parseState(result.stdout, prefs)
    val release = runCatching { fetchLatestRelease() }.getOrNull()
    return parsed.copy(
      latestRelease = release,
      backupPayload = buildBackupPayload(
        bootSettings = parsed.bootSettings,
        lastProfile = parsed.activeProfile,
        customTuning = parsed.customTuning
      )
    )
  }

  suspend fun applyProfile(profile: KernelProfile): String {
    if (profile == KernelProfile.Custom) {
      return applyCustomTuning(store.readPrefs().customTuning)
    }
    val result = RootShell.run(buildProfileScript(profile))
    if (result.exitCode != 0) {
      return result.stderr.ifBlank { "Failed to apply ${profile.title}." }
    }
    store.setLastProfile(profile)
    return "${profile.title} applied."
  }

  suspend fun applyCustomTuning(tuning: CustomTuning): String {
    val result = RootShell.run(buildCustomTuningScript(tuning))
    if (result.exitCode != 0) {
      return result.stderr.ifBlank { "Failed to apply custom tuning." }
    }
    store.setCustomTuning(tuning)
    store.setLastProfile(KernelProfile.Custom)
    return "Custom tuning applied."
  }

  suspend fun restoreBalancedDefaults(): String {
    store.setLastProfile(KernelProfile.Balanced)
    return applyProfile(KernelProfile.Balanced)
  }

  suspend fun updateBootSettings(settings: BootSettings) {
    store.updateBootSettings(settings)
  }

  suspend fun importBackup(rawJson: String): String {
    val json = JSONObject(rawJson)
    val boot = json.optJSONObject("bootSettings")
    val custom = json.optJSONObject("customTuning")
    val profile = KernelProfile.fromStoredValue(json.optString("lastProfile", KernelProfile.Balanced.name))

    val bootSettings = BootSettings(
      autoApplyOnBoot = boot?.optBoolean("autoApplyOnBoot") ?: false,
      applyDelaySeconds = boot?.optInt("applyDelaySeconds") ?: 12,
      waitForUnlock = boot?.optBoolean("waitForUnlock") ?: true,
      rollbackToBalanced = boot?.optBoolean("rollbackToBalanced") ?: true
    )
    val customTuning = custom?.let { KernelStore.decodeCustomTuning(it.toString()) } ?: CustomTuning()

    store.updateBootSettings(bootSettings)
    store.setCustomTuning(customTuning)
    store.setLastProfile(profile)

    return if (profile == KernelProfile.Custom) {
      applyCustomTuning(customTuning)
    } else {
      applyProfile(profile)
    }
  }

  suspend fun downloadLatestReleaseZip(release: ReleaseInfo): Long? = withContext(Dispatchers.IO) {
    val zipUrl = release.zipUrl ?: return@withContext null
    val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    val request = DownloadManager.Request(Uri.parse(zipUrl))
      .setTitle("Dynasched kernel ${release.tagName}")
      .setDescription("Downloading matching kernel ZIP")
      .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
      .setAllowedOverMetered(true)
      .setAllowedOverRoaming(true)

    val filename = URLUtil.guessFileName(zipUrl, null, "application/zip")
    request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename)
    manager.enqueue(request)
  }

  suspend fun setGpuGovernor(governor: String): String {
    val script = """
      echo "$governor" > /data/local/tmp/.dynasched_gpu_governor
      for node in /sys/class/devfreq/*/governor; do
        [ -e "${'$'}node" ] && echo "$governor" > "${'$'}node" 2>/dev/null || true
      done
    """.trimIndent()
    val result = RootShell.run(script)
    return if (result.exitCode == 0) "GPU governor set to $governor" else result.stderr.ifBlank { "Failed to set GPU governor." }
  }

  suspend fun setIoScheduler(scheduler: String): String {
    val script = """
      echo "$scheduler" > /data/local/tmp/.dynasched_io_scheduler
      for queue in /sys/block/*/queue/scheduler; do
        [ -e "${'$'}queue" ] && echo "$scheduler" > "${'$'}queue" 2>/dev/null || true
      done
    """.trimIndent()
    val result = RootShell.run(script)
    return if (result.exitCode == 0) "I/O scheduler set to $scheduler" else result.stderr.ifBlank { "Failed to set I/O scheduler." }
  }

  suspend fun setDisplayMode(mode: String): String {
    val script = """
      echo "$mode" > /data/local/tmp/.dynasched_display_mode
    """.trimIndent()
    val result = RootShell.run(script)
    return if (result.exitCode == 0) "Display mode set to $mode" else result.stderr.ifBlank { "Failed to set display mode." }
  }

  suspend fun setOverclockEnabled(enabled: Boolean): String {
    val value = if (enabled) "enabled" else "disabled"
    val safetyScript = if (!enabled) """
      # Reset to safe max frequencies when disabling
      echo 1900000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
      echo 2300000 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null || true
      echo 2400000 > /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null || true
      echo 2700000 > /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq 2>/dev/null || true
    """.trimIndent() else ""
    val script = """
      echo "$value" > /data/local/tmp/.dynasched_overclock
      $safetyScript
    """.trimIndent()
    val result = RootShell.run(script)
    return if (result.exitCode == 0) "Overclock ${if (enabled) "enabled" else "disabled"}" else result.stderr.ifBlank { "Failed to toggle overclock." }
  }

  private fun parseState(raw: String, prefs: StoredPrefs): KernelState {
    val lines = raw.lines().filter { it.isNotBlank() }
    val dynaschedSupported = lines.value("supported") == "1"
    val kernelVersion = lines.value("kernel")
    val currentGovernor = lines.value("current")
    val variant = lines.value("variant").ifBlank { inferVariant(kernelVersion) }
    val available = lines.value("available")
      .split(" ")
      .filter { it.isNotBlank() }
    val policies = lines.filter { it.startsWith("policy=") }.mapNotNull(::parsePolicy)
    val swappiness = lines.value("swappiness").ifBlank { "80" }
    val dirtyExpire = lines.value("dirty_expire").ifBlank { "300" }
    val dirtyWriteback = lines.value("dirty_writeback").ifBlank { "75" }
    val topAppBoost = lines.value("top_app_boost").ifBlank { "15" }
    val topAppUclampMin = lines.value("top_app_uclamp_min").ifBlank { "256" }
    val tcpCongestion = lines.value("tcp_congestion").ifBlank { "unknown" }
    val tcpAvailable = lines.value("tcp_available").ifBlank { "unknown" }
    val fkmProfile = lines.value("fkm_profile").ifBlank { "auto" }
    val customTuning = CustomTuning.fromPolicies(
      policies = policies,
      swappiness = swappiness,
      dirtyExpire = dirtyExpire,
      dirtyWriteback = dirtyWriteback,
      topAppBoost = topAppBoost,
      topAppUclampMin = topAppUclampMin
    )
    val missingNodes = lines.value("missing_nodes")
      .split(",")
      .map { it.trim() }
      .filter { it.isNotBlank() && it != "none" }

    val diagnostics = DiagnosticsReport(
      selinuxMode = lines.value("selinux"),
      missingNodes = missingNodes,
      supportText = buildSupportText(
        kernelVersion = kernelVersion,
        variant = variant,
        currentGovernor = currentGovernor,
        availableGovernors = available,
        selinux = lines.value("selinux"),
        missingNodes = missingNodes,
        profile = detectProfile(policies),
        tcpCongestion = tcpCongestion,
        tcpAvailable = tcpAvailable,
        fkmProfile = fkmProfile
      ),
      lastError = ""
    )

    val profile = detectProfile(policies)
    val managedKernel = dynaschedSupported && "dynasched" in available

    // GPU state
    val gpuState = GpuState(
      governor = lines.value("gpu_governor").ifBlank { "unknown" },
      currentFreq = lines.value("gpu_freq").ifBlank { "n/a" },
      minFreq = lines.value("gpu_min").ifBlank { "n/a" },
      maxFreq = lines.value("gpu_max").ifBlank { "n/a" },
      availableGovernors = lines.value("gpu_available").split(" ").filter { it.isNotBlank() }
    )

    // I/O scheduler state
    val ioState = IoSchedulerState(
      activeScheduler = lines.value("io_scheduler").ifBlank { "unknown" },
      availableSchedulers = lines.value("io_available").split(" ").filter { it.isNotBlank() },
      blockDevice = lines.value("io_device").ifBlank { "sda" }
    )

    // Display state
    val displayState = DisplayState(
      currentMode = lines.value("display_mode").ifBlank { "auto" }
    )

    // Overclock state
    val overclockState = OverclockState(
      enabled = lines.value("overclock_enabled") == "enabled",
      thermalSafe = (normalizeTemp(lines.value("thermal_temp")).removeSuffix(" C").toFloatOrNull() ?: 0f) < 85f,
      currentMaxFreq = policies.firstOrNull { it.name == "policy7" }?.maxFreq ?: "n/a",
      overclockMaxFreq = "3000000",
      thermalTemp = normalizeTemp(lines.value("thermal_temp")),
      safetyMessage = if ((normalizeTemp(lines.value("thermal_temp")).removeSuffix(" C").toFloatOrNull() ?: 0f) >= 85f) {
        "Thermal limit reached. Overclock disabled for safety."
      } else ""
    )

    val state = KernelState(
      rootAvailable = true,
      dynaschedSupported = dynaschedSupported,
      buildInfo = BuildInfo(
        managedKernel = managedKernel,
        variant = variant,
        kernelVersion = kernelVersion,
        currentGovernor = currentGovernor
      ),
      availableGovernors = available,
      policies = policies,
      telemetry = TelemetrySnapshot(
        loadAverage = lines.value("loadavg"),
        memAvailableMb = kbToMb(lines.value("mem_available_kb")),
        memTotalMb = kbToMb(lines.value("mem_total_kb")),
        batteryTempC = normalizeTemp(lines.value("battery_temp")),
        thermalTempC = normalizeTemp(lines.value("thermal_temp")),
        tcpCongestion = tcpCongestion,
        fkmProfile = fkmProfile
      ),
      detectedProfile = profile,
      bootSettings = prefs.bootSettings,
      activeProfile = profile ?: prefs.lastProfile,
      customTuning = customTuning,
      diagnostics = diagnostics,
      gpuState = gpuState,
      ioState = ioState,
      displayState = displayState,
      overclockState = overclockState,
      statusMessage = if (managedKernel) {
        "Managed kernel detected. Dynasched controls are live."
      } else if (dynaschedSupported) {
        "Dynasched nodes exist, but this build did not fully match the expected kernel signature."
      } else {
        "Dynasched sysfs nodes were not found on this kernel."
      }
    )

    return state
  }

  private fun parsePolicy(line: String): PolicySnapshot? {
    val parts = line.substringAfter("policy=").split("|")
    if (parts.size != 7) return null
    return PolicySnapshot(
      name = parts[0],
      governor = parts[1],
      currentFreq = parts[2],
      minFreq = parts[3],
      maxFreq = parts[4],
      upRateLimit = parts[5],
      downRateLimit = parts[6]
    )
  }

  private fun buildInspectionScript(): String = """
    set +e
    KERNEL_VERSION="${'$'}(cat /proc/version 2>/dev/null)"
    AVAILABLE="${'$'}(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors 2>/dev/null)"
    CURRENT="${'$'}(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
    SELINUX="${'$'}(getenforce 2>/dev/null || echo unknown)"
    LOADAVG="${'$'}(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    MEM_TOTAL_KB="${'$'}(awk '/MemTotal/ { print ${'$'}2 }' /proc/meminfo 2>/dev/null)"
    MEM_AVAILABLE_KB="${'$'}(awk '/MemAvailable/ { print ${'$'}2 }' /proc/meminfo 2>/dev/null)"
    BATT_TEMP="${'$'}(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo unknown)"
    THERMAL_TEMP="${'$'}(for node in /sys/class/thermal/thermal_zone*/temp; do [ -e "${'$'}node" ] && cat "${'$'}node" && break; done)"
    SWAPPINESS="${'$'}(cat /proc/sys/vm/swappiness 2>/dev/null || echo 80)"
    DIRTY_EXPIRE="${'$'}(cat /proc/sys/vm/dirty_expire_centisecs 2>/dev/null || echo 300)"
    DIRTY_WRITEBACK="${'$'}(cat /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || echo 75)"
    TOP_APP_BOOST="${'$'}(cat /dev/stune/top-app/schedtune.boost 2>/dev/null || echo n/a)"
    TOP_APP_UCLAMP_MIN="${'$'}(cat /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null || echo n/a)"
    VARIANT="unknown"
    case "${'$'}KERNEL_VERSION" in
      *tiann*) VARIANT="tiann" ;;
      *kowsu*) VARIANT="kowsu" ;;
      *resukisu*) VARIANT="resukisu" ;;
      *next*) VARIANT="next" ;;
    esac
    MISSING_NODES=""
    [ -d /sys/devices/system/cpu/cpufreq/policy0/dynasched ] || MISSING_NODES="policy0/dynasched"
    [ -e /dev/stune/top-app/schedtune.boost ] || MISSING_NODES="${'$'}{MISSING_NODES},stune/top-app/schedtune.boost"
    [ -e /dev/cpuctl/top-app/cpu.uclamp.min ] || MISSING_NODES="${'$'}{MISSING_NODES},cpuctl/top-app/cpu.uclamp.min"
    if [ -d /sys/devices/system/cpu/cpufreq/policy0/dynasched ]; then
      echo "supported=1"
    else
      echo "supported=0"
    fi
    echo "kernel=${'$'}{KERNEL_VERSION}"
    echo "variant=${'$'}{VARIANT}"
    echo "available=${'$'}{AVAILABLE}"
    echo "current=${'$'}{CURRENT}"
    echo "selinux=${'$'}{SELINUX}"
    echo "loadavg=${'$'}{LOADAVG}"
    echo "mem_total_kb=${'$'}{MEM_TOTAL_KB}"
    echo "mem_available_kb=${'$'}{MEM_AVAILABLE_KB}"
    echo "battery_temp=${'$'}{BATT_TEMP}"
    echo "thermal_temp=${'$'}{THERMAL_TEMP:-unknown}"
    echo "swappiness=${'$'}{SWAPPINESS}"
    echo "dirty_expire=${'$'}{DIRTY_EXPIRE}"
    echo "dirty_writeback=${'$'}{DIRTY_WRITEBACK}"
    echo "top_app_boost=${'$'}{TOP_APP_BOOST}"
    echo "top_app_uclamp_min=${'$'}{TOP_APP_UCLAMP_MIN}"
    echo "missing_nodes=${'$'}{MISSING_NODES:-none}"
    TCP_CONG="${'$'}(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)"
    TCP_AVAILABLE="${'$'}(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo unknown)"
    FKM_PROFILE="${'$'}(cat /data/local/tmp/.dynasched_profile 2>/dev/null || echo auto)"
    echo "tcp_congestion=${'$'}{TCP_CONG}"
    echo "tcp_available=${'$'}{TCP_AVAILABLE}"
    echo "fkm_profile=${'$'}{FKM_PROFILE}"
    # GPU state
    GPU_GOV="unknown"
    GPU_FREQ="n/a"
    GPU_MIN="n/a"
    GPU_MAX="n/a"
    GPU_AVAILABLE=""
    for devfreq in /sys/class/devfreq/*; do
      [ -d "${'$'}devfreq" ] || continue
      GPU_GOV=${'$'}(cat "${'$'}devfreq/governor" 2>/dev/null || echo unknown)
      GPU_FREQ=${'$'}(cat "${'$'}devfreq/cur_freq" 2>/dev/null || echo n/a)
      GPU_MIN=${'$'}(cat "${'$'}devfreq/min_freq" 2>/dev/null || echo n/a)
      GPU_MAX=${'$'}(cat "${'$'}devfreq/max_freq" 2>/dev/null || echo n/a)
      GPU_AVAILABLE=${'$'}(cat "${'$'}devfreq/available_governors" 2>/dev/null || echo "")
      break
    done
    echo "gpu_governor=${'$'}{GPU_GOV}"
    echo "gpu_freq=${'$'}{GPU_FREQ}"
    echo "gpu_min=${'$'}{GPU_MIN}"
    echo "gpu_max=${'$'}{GPU_MAX}"
    echo "gpu_available=${'$'}{GPU_AVAILABLE}"
    # I/O scheduler state
    IO_SCHED="unknown"
    IO_AVAILABLE=""
    IO_DEVICE="sda"
    for blk in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
      [ -e "${'$'}blk/queue/scheduler" ] || continue
      IO_DEVICE=${'$'}(basename "${'$'}blk")
      IO_SCHED_RAW=${'$'}(cat "${'$'}blk/queue/scheduler" 2>/dev/null || echo "")
      IO_SCHED=${'$'}(echo "${'$'}IO_SCHED_RAW" | grep -o '\[.*\]' | tr -d '[]')
      IO_AVAILABLE=${'$'}(echo "${'$'}IO_SCHED_RAW" | tr -d '[]')
      break
    done
    echo "io_scheduler=${'$'}{IO_SCHED}"
    echo "io_available=${'$'}{IO_AVAILABLE}"
    echo "io_device=${'$'}{IO_DEVICE}"
    # Display mode state
    DISPLAY_MODE=${'$'}(cat /data/local/tmp/.dynasched_display_mode 2>/dev/null || echo auto)
    echo "display_mode=${'$'}{DISPLAY_MODE}"
    # Overclock state
    OC_ENABLED=${'$'}(cat /data/local/tmp/.dynasched_overclock 2>/dev/null || echo disabled)
    echo "overclock_enabled=${'$'}{OC_ENABLED}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "${'$'}policy" ] || continue
      name="${'$'}(basename "${'$'}policy")"
      gov="${'$'}(cat "${'$'}policy/scaling_governor" 2>/dev/null || echo unknown)"
      cur="${'$'}(cat "${'$'}policy/scaling_cur_freq" 2>/dev/null || echo n/a)"
      minf="${'$'}(cat "${'$'}policy/scaling_min_freq" 2>/dev/null || echo n/a)"
      maxf="${'$'}(cat "${'$'}policy/scaling_max_freq" 2>/dev/null || echo n/a)"
      up="${'$'}(cat "${'$'}policy/dynasched/up_rate_limit_us" 2>/dev/null || echo n/a)"
      down="${'$'}(cat "${'$'}policy/dynasched/down_rate_limit_us" 2>/dev/null || echo n/a)"
      echo "policy=${'$'}{name}|${'$'}{gov}|${'$'}{cur}|${'$'}{minf}|${'$'}{maxf}|${'$'}{up}|${'$'}{down}"
    done
  """.trimIndent()

  private fun buildProfileScript(profile: KernelProfile): String {
    val profileName = when (profile) {
      KernelProfile.Eco -> "eco"
      KernelProfile.Turbo -> "turbo"
      else -> "balanced"
    }

    val fkmName = when (profile) {
      KernelProfile.Eco -> "battery"
      KernelProfile.Turbo -> "performance"
      else -> "balanced"
    }

    return buildBaseScript() + """
      case "${profileName}" in
        eco)
          set_policy_limits policy0 300000 1700000
          set_policy_limits policy4 500000 2000000
          set_policy_limits policy6 500000 2100000
          set_policy_limits policy7 500000 2200000
          write_if_exists 18000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/up_rate_limit_us
          write_if_exists 45000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/down_rate_limit_us
          apply_vm_values 60 500 100
          apply_latency_values 10 128
          ;;
        turbo)
          set_policy_limits policy0 600000 2100000
          set_policy_limits policy4 700000 2600000
          set_policy_limits policy6 700000 2700000
          set_policy_limits policy7 900000 2918000
          write_if_exists 3000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/up_rate_limit_us
          write_if_exists 10000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/down_rate_limit_us
          apply_vm_values 100 200 50
          apply_latency_values 25 384
          ;;
        *)
          set_policy_limits policy0 500000 1900000
          set_policy_limits policy4 700000 2300000
          set_policy_limits policy6 700000 2400000
          set_policy_limits policy7 850000 2700000
          write_if_exists 6000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/up_rate_limit_us
          write_if_exists 18000 /sys/devices/system/cpu/cpufreq/policy*/dynasched/down_rate_limit_us
          apply_vm_values 80 300 75
          apply_latency_values 15 256
          ;;
      esac
      echo "${fkmName}" > /data/local/tmp/.dynasched_profile
    """.trimIndent()
  }

  private fun buildCustomTuningScript(tuning: CustomTuning): String = buildBaseScript() + """
    set_policy_limits policy0 ${tuning.policy0Min} ${tuning.policy0Max}
    set_policy_limits policy4 ${tuning.policy4Min} ${tuning.policy4Max}
    set_policy_limits policy6 ${tuning.policy6Min} ${tuning.policy6Max}
    set_policy_limits policy7 ${tuning.policy7Min} ${tuning.policy7Max}
    write_if_exists ${tuning.upRateLimit} /sys/devices/system/cpu/cpufreq/policy*/dynasched/up_rate_limit_us
    write_if_exists ${tuning.downRateLimit} /sys/devices/system/cpu/cpufreq/policy*/dynasched/down_rate_limit_us
    apply_vm_values ${tuning.swappiness} ${tuning.dirtyExpire} ${tuning.dirtyWriteback}
    apply_latency_values ${tuning.topAppBoost} ${tuning.topAppUclampMin}
  """.trimIndent()

  private fun buildBaseScript(): String = """
    set -e
    write_if_exists() {
      value="${'$'}1"
      shift
      for node in "${'$'}@"; do
        if [ -e "${'$'}node" ]; then
          echo "${'$'}value" > "${'$'}node"
        fi
      done
    }

    set_policy_limits() {
      policy="${'$'}1"
      minf="${'$'}2"
      maxf="${'$'}3"
      write_if_exists "${'$'}minf" "/sys/devices/system/cpu/cpufreq/${'$'}policy/scaling_min_freq"
      write_if_exists "${'$'}maxf" "/sys/devices/system/cpu/cpufreq/${'$'}policy/scaling_max_freq"
    }

    apply_vm_values() {
      write_if_exists "${'$'}1" /proc/sys/vm/swappiness
      write_if_exists "${'$'}2" /proc/sys/vm/dirty_expire_centisecs
      write_if_exists "${'$'}3" /proc/sys/vm/dirty_writeback_centisecs
    }

    apply_latency_values() {
      write_if_exists 1 /dev/stune/top-app/schedtune.prefer_idle
      write_if_exists "${'$'}1" /dev/stune/top-app/schedtune.boost
      write_if_exists "${'$'}2" /dev/cpuctl/top-app/cpu.uclamp.min
      write_if_exists 1 /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive
    }

    for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
      [ -e "${'$'}governor" ] && echo dynasched > "${'$'}governor"
    done
  """.trimIndent() + "\n"

  private suspend fun fetchLatestRelease(): ReleaseInfo? = withContext(Dispatchers.IO) {
    val endpoint = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
    val connection = URL(endpoint).openConnection() as HttpURLConnection
    connection.requestMethod = "GET"
    connection.setRequestProperty("Accept", "application/vnd.github+json")
    connection.connectTimeout = 6000
    connection.readTimeout = 6000

    try {
      if (connection.responseCode !in 200..299) return@withContext null
      val body = connection.inputStream.bufferedReader().use { it.readText() }
      val json = JSONObject(body)
      val assets = json.optJSONArray("assets") ?: JSONArray()
      var zipUrl: String? = null
      for (index in 0 until assets.length()) {
        val asset = assets.getJSONObject(index)
        val name = asset.optString("name")
        if (name.endsWith(".zip", ignoreCase = true)) {
          zipUrl = asset.optString("browser_download_url")
          break
        }
      }

      ReleaseInfo(
        tagName = json.optString("tag_name"),
        title = json.optString("name").ifBlank { json.optString("tag_name") },
        body = json.optString("body").ifBlank { "No release notes." },
        htmlUrl = json.optString("html_url"),
        zipUrl = zipUrl,
        publishedAt = json.optString("published_at")
      )
    } finally {
      connection.disconnect()
    }
  }

  private fun detectProfile(policies: List<PolicySnapshot>): KernelProfile? {
    val policy0 = policies.firstOrNull { it.name == "policy0" } ?: return null
    val policy7 = policies.firstOrNull { it.name == "policy7" } ?: return null

    return when {
      policy0.minFreq == "300000" &&
        policy7.maxFreq == "2200000" &&
        policy0.upRateLimit == "18000" -> KernelProfile.Eco
      policy0.minFreq == "600000" &&
        policy7.maxFreq == "2918000" &&
        policy0.upRateLimit == "3000" -> KernelProfile.Turbo
      policy0.minFreq == "500000" &&
        policy7.maxFreq == "2700000" &&
        policy0.upRateLimit == "6000" -> KernelProfile.Balanced
      else -> KernelProfile.Custom
    }
  }

  private fun buildBackupPayload(
    bootSettings: BootSettings,
    lastProfile: KernelProfile,
    customTuning: CustomTuning
  ): String = JSONObject()
    .put("app", "Dynasched Manager")
    .put("schemaVersion", 1)
    .put("lastProfile", lastProfile.name)
    .put("bootSettings", JSONObject()
      .put("autoApplyOnBoot", bootSettings.autoApplyOnBoot)
      .put("applyDelaySeconds", bootSettings.applyDelaySeconds)
      .put("waitForUnlock", bootSettings.waitForUnlock)
      .put("rollbackToBalanced", bootSettings.rollbackToBalanced))
    .put("customTuning", JSONObject(KernelStore.encodeCustomTuning(customTuning)))
    .toString(2)

  private fun KernelState.withBackup(): KernelState = copy(
    backupPayload = buildBackupPayload(bootSettings, activeProfile, customTuning)
  )

  private fun List<String>.value(key: String): String = firstOrNull { it.startsWith("$key=") }
    ?.substringAfter("=")
    .orEmpty()

  private fun inferVariant(kernelVersion: String): String {
    val lower = kernelVersion.lowercase(Locale.ROOT)
    return when {
      "tiann" in lower -> "tiann"
      "kowsu" in lower -> "kowsu"
      "resukisu" in lower -> "resukisu"
      "next" in lower -> "next"
      else -> "unknown"
    }
  }

  private fun kbToMb(value: String): String {
    val kb = value.toLongOrNull() ?: return "n/a"
    return "${kb / 1024} MB"
  }

  private fun normalizeTemp(raw: String): String {
    val value = raw.toFloatOrNull() ?: return raw.ifBlank { "n/a" }
    val celsius = when {
      value >= 1000f -> value / 1000f
      value >= 100f -> value / 10f
      else -> value
    }
    return String.format(Locale.US, "%.1f C", celsius)
  }

  private fun buildSupportText(
    kernelVersion: String,
    variant: String,
    currentGovernor: String,
    availableGovernors: List<String>,
    selinux: String,
    missingNodes: List<String>,
    profile: KernelProfile?,
    tcpCongestion: String,
    tcpAvailable: String,
    fkmProfile: String
  ): String = buildString {
    appendLine("Kernel: $kernelVersion")
    appendLine("Variant: $variant")
    appendLine("Governor: $currentGovernor")
    appendLine("Available: ${availableGovernors.joinToString()}")
    appendLine("SELinux: $selinux")
    appendLine("Detected profile: ${profile?.title ?: "Unknown"}")
    appendLine("Missing nodes: ${if (missingNodes.isEmpty()) "none" else missingNodes.joinToString()}")
    appendLine("TCP congestion: $tcpCongestion")
    appendLine("TCP available: $tcpAvailable")
    appendLine("FKM profile override: $fkmProfile")
  }
}
