package com.deepongi.dynaschedmanager

data class PolicySnapshot(
  val name: String,
  val governor: String,
  val currentFreq: String,
  val minFreq: String,
  val maxFreq: String,
  val upRateLimit: String,
  val downRateLimit: String
)

data class TelemetrySnapshot(
  val loadAverage: String = "",
  val memAvailableMb: String = "",
  val memTotalMb: String = "",
  val batteryTempC: String = "",
  val thermalTempC: String = "",
  val tcpCongestion: String = "",
  val fkmProfile: String = ""
)

data class BuildInfo(
  val managedKernel: Boolean = false,
  val variant: String = "unknown",
  val kernelVersion: String = "",
  val currentGovernor: String = ""
)

data class BootSettings(
  val autoApplyOnBoot: Boolean = false,
  val applyDelaySeconds: Int = 12,
  val waitForUnlock: Boolean = true,
  val rollbackToBalanced: Boolean = true
)

data class CustomTuning(
  val policy0Min: String = "500000",
  val policy0Max: String = "1900000",
  val policy4Min: String = "700000",
  val policy4Max: String = "2300000",
  val policy6Min: String = "700000",
  val policy6Max: String = "2400000",
  val policy7Min: String = "850000",
  val policy7Max: String = "2700000",
  val upRateLimit: String = "6000",
  val downRateLimit: String = "18000",
  val swappiness: String = "80",
  val dirtyExpire: String = "300",
  val dirtyWriteback: String = "75",
  val topAppBoost: String = "15",
  val topAppUclampMin: String = "256"
) {
  companion object {
    fun fromPolicies(
      policies: List<PolicySnapshot>,
      swappiness: String,
      dirtyExpire: String,
      dirtyWriteback: String,
      topAppBoost: String,
      topAppUclampMin: String
    ): CustomTuning {
      fun policy(name: String) = policies.firstOrNull { it.name == name }
      return CustomTuning(
        policy0Min = policy("policy0")?.minFreq ?: "500000",
        policy0Max = policy("policy0")?.maxFreq ?: "1900000",
        policy4Min = policy("policy4")?.minFreq ?: "700000",
        policy4Max = policy("policy4")?.maxFreq ?: "2300000",
        policy6Min = policy("policy6")?.minFreq ?: "700000",
        policy6Max = policy("policy6")?.maxFreq ?: "2400000",
        policy7Min = policy("policy7")?.minFreq ?: "850000",
        policy7Max = policy("policy7")?.maxFreq ?: "2700000",
        upRateLimit = policy("policy0")?.upRateLimit ?: "6000",
        downRateLimit = policy("policy0")?.downRateLimit ?: "18000",
        swappiness = swappiness,
        dirtyExpire = dirtyExpire,
        dirtyWriteback = dirtyWriteback,
        topAppBoost = topAppBoost,
        topAppUclampMin = topAppUclampMin
      )
    }
  }
}

data class DiagnosticsReport(
  val selinuxMode: String = "",
  val missingNodes: List<String> = emptyList(),
  val supportText: String = "",
  val lastError: String = ""
)

data class ReleaseInfo(
  val tagName: String,
  val title: String,
  val body: String,
  val htmlUrl: String,
  val zipUrl: String?,
  val publishedAt: String
)

data class GpuState(
  val governor: String = "unknown",
  val currentFreq: String = "n/a",
  val minFreq: String = "n/a",
  val maxFreq: String = "n/a",
  val availableGovernors: List<String> = emptyList()
)

data class IoSchedulerState(
  val activeScheduler: String = "unknown",
  val availableSchedulers: List<String> = emptyList(),
  val blockDevice: String = "sda"
)

data class DisplayState(
  val currentMode: String = "auto",
  val availableModes: List<String> = listOf("60hz", "120hz", "auto"),
  val available: Boolean = false
)

data class OverclockState(
  val enabled: Boolean = false,
  val thermalSafe: Boolean = true,
  val currentMaxFreq: String = "n/a",
  val overclockMaxFreq: String = "3000000",
  val thermalTemp: String = "n/a",
  val safetyMessage: String = ""
)

data class KernelState(
  val rootAvailable: Boolean = false,
  val dynaschedSupported: Boolean = false,
  val buildInfo: BuildInfo = BuildInfo(),
  val availableGovernors: List<String> = emptyList(),
  val policies: List<PolicySnapshot> = emptyList(),
  val telemetry: TelemetrySnapshot = TelemetrySnapshot(),
  val detectedProfile: KernelProfile? = null,
  val bootSettings: BootSettings = BootSettings(),
  val activeProfile: KernelProfile = KernelProfile.Balanced,
  val customTuning: CustomTuning = CustomTuning(),
  val diagnostics: DiagnosticsReport = DiagnosticsReport(),
  val gpuState: GpuState = GpuState(),
  val ioState: IoSchedulerState = IoSchedulerState(),
  val displayState: DisplayState = DisplayState(),
  val overclockState: OverclockState = OverclockState(),
  val latestRelease: ReleaseInfo? = null,
  val backupPayload: String = "",
  val statusMessage: String = "Loading...",
  val busy: Boolean = false
)
