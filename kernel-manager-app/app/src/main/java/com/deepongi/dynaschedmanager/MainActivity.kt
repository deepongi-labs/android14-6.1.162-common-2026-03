package com.deepongi.dynaschedmanager

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Restore
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setContent {
      DynaschedTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
          val viewModel: MainViewModel = viewModel(
            factory = MainViewModel.factory(applicationContext)
          )
          val state by viewModel.state.collectAsStateWithLifecycle()
          KernelManagerScreen(
            state = state,
            onRefresh = viewModel::refresh,
            onApplyProfile = viewModel::applyProfile,
            onApplyCustom = viewModel::applyCustomTuning,
            onRestoreDefaults = viewModel::restoreBalancedDefaults,
            onUpdateBootSettings = viewModel::updateBootSettings,
            onImportBackup = viewModel::importBackup,
            onDownloadRelease = viewModel::downloadLatestRelease,
            onSetGpuGovernor = viewModel::setGpuGovernor,
            onSetIoScheduler = viewModel::setIoScheduler,
            onSetDisplayMode = viewModel::setDisplayMode,
            onToggleOverclock = viewModel::toggleOverclock
          )
        }
      }
    }
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KernelManagerScreen(
  state: KernelState,
  onRefresh: () -> Unit,
  onApplyProfile: (KernelProfile) -> Unit,
  onApplyCustom: (CustomTuning) -> Unit,
  onRestoreDefaults: () -> Unit,
  onUpdateBootSettings: (BootSettings) -> Unit,
  onImportBackup: (String) -> Unit,
  onDownloadRelease: () -> Unit,
  onSetGpuGovernor: (String) -> Unit,
  onSetIoScheduler: (String) -> Unit,
  onSetDisplayMode: (String) -> Unit,
  onToggleOverclock: (Boolean) -> Unit
) {
  val context = LocalContext.current
  var customEditor by remember(state.customTuning) { mutableStateOf(state.customTuning) }
  var backupEditor by remember(state.backupPayload) { mutableStateOf(state.backupPayload) }

  Scaffold(
    topBar = {
      CenterAlignedTopAppBar(
        title = { Text("Dynasched Manager") },
        actions = {
          IconButton(onClick = onRefresh, enabled = !state.busy) {
            Icon(Icons.Rounded.Refresh, contentDescription = "Refresh")
          }
        }
      )
    }
  ) { padding ->
    LazyColumn(
      modifier = Modifier
        .fillMaxSize()
        .background(
          Brush.verticalGradient(
            colors = listOf(Color(0xFF0C1118), Color(0xFF1C2632), Color(0xFF111922))
          )
        )
        .padding(padding)
        .padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
      item {
        HeroCard(state = state)
      }

      item {
        ProfileSection(
          selectedProfile = state.activeProfile,
          busy = state.busy || !state.dynaschedSupported,
          onApplyProfile = onApplyProfile,
          onRestoreDefaults = onRestoreDefaults
        )
      }

      item {
        TelemetryCard(state = state)
      }

      item { GpuCard(state = state, busy = state.busy, onSetGovernor = onSetGpuGovernor) }
      item { IoSchedulerCard(state = state, busy = state.busy, onSetScheduler = onSetIoScheduler) }
      item { DisplayCard(state = state, busy = state.busy, onSetMode = onSetDisplayMode) }
      item { OverclockCard(state = state, busy = state.busy, onToggle = onToggleOverclock) }

      item {
        BootCard(
          settings = state.bootSettings,
          busy = state.busy,
          onUpdate = onUpdateBootSettings
        )
      }

      item {
        CustomTuningCard(
          tuning = customEditor,
          busy = state.busy || !state.dynaschedSupported,
          onChange = { customEditor = it },
          onApply = { onApplyCustom(customEditor) },
          onResetFromLive = { customEditor = state.customTuning }
        )
      }

      item {
        ReleaseCard(
          release = state.latestRelease,
          busy = state.busy,
          onOpen = { url -> context.openUrl(url) },
          onDownload = onDownloadRelease
        )
      }

      item {
        BackupCard(
          payload = backupEditor,
          busy = state.busy,
          onPayloadChange = { backupEditor = it },
          onCopy = { context.copyToClipboard("dynasched-backup", backupEditor) },
          onImport = { onImportBackup(backupEditor) }
        )
      }

      item {
        DiagnosticsCard(state = state)
      }

      if (state.policies.isNotEmpty()) {
        item {
          Text(
            text = "Per-policy state",
            style = MaterialTheme.typography.titleMedium,
            color = Color(0xFFE6EDF5)
          )
        }
        items(state.policies) { policy ->
          PolicyCard(policy = policy)
        }
      }
    }
  }
}

@Composable
private fun HeroCard(state: KernelState) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC131C27)),
    shape = RoundedCornerShape(28.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(20.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
      ) {
        Box(
          modifier = Modifier
            .size(54.dp)
            .background(Color(0xFFEA6A2A), RoundedCornerShape(18.dp)),
          contentAlignment = Alignment.Center
        ) {
          Icon(Icons.Rounded.Bolt, contentDescription = null, tint = Color.White)
        }
        if (state.busy) {
          CircularProgressIndicator(
            modifier = Modifier.size(22.dp),
            strokeWidth = 2.dp,
            color = Color(0xFFEA6A2A)
          )
        }
      }
      Text(
        text = if (state.buildInfo.managedKernel) "Managed kernel locked in" else "Kernel check not satisfied",
        style = MaterialTheme.typography.headlineSmall,
        color = Color.White,
        fontWeight = FontWeight.SemiBold
      )
      Text(
        text = state.statusMessage,
        style = MaterialTheme.typography.bodyMedium,
        color = Color(0xFFB7C4D2)
      )
      MetaRow("Governor", state.buildInfo.currentGovernor.ifBlank { "Unavailable" })
      MetaRow("Variant", state.buildInfo.variant)
      MetaRow("Detected profile", state.detectedProfile?.title ?: "Unknown")
      MetaRow("Latest release", state.latestRelease?.tagName ?: "Unavailable")
    }
  }
}

@Composable
private fun ProfileSection(
  selectedProfile: KernelProfile,
  busy: Boolean,
  onApplyProfile: (KernelProfile) -> Unit,
  onRestoreDefaults: () -> Unit
) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
      Text(
        text = "Kernel profiles",
        style = MaterialTheme.typography.titleLarge,
        color = Color.White
      )
      Text(
        text = "Preset profiles mirror the repo's runtime tuner. Custom mode uses the editor below.",
        style = MaterialTheme.typography.bodyMedium,
        color = Color(0xFFB7C4D2)
      )
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        listOf(KernelProfile.Eco, KernelProfile.Balanced, KernelProfile.Turbo, KernelProfile.Custom).forEach { profile ->
          FilterChip(
            selected = profile == selectedProfile,
            onClick = { onApplyProfile(profile) },
            label = { Text(profile.title) },
            enabled = !busy
          )
        }
      }
      Text(
        text = selectedProfile.summary,
        style = MaterialTheme.typography.bodyMedium,
        color = Color(0xFFDDE7F1)
      )
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(onClick = onRestoreDefaults, enabled = !busy) {
          Icon(Icons.Rounded.Restore, contentDescription = null)
          Text("Balanced Reset", modifier = Modifier.padding(start = 8.dp))
        }
      }
    }
  }
}

@Composable
private fun TelemetryCard(state: KernelState) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("Live telemetry", style = MaterialTheme.typography.titleLarge, color = Color.White)
      MetaRow("Load avg", state.telemetry.loadAverage.ifBlank { "Unavailable" })
      MetaRow("Memory", "${state.telemetry.memAvailableMb} free / ${state.telemetry.memTotalMb}")
      MetaRow("Battery temp", state.telemetry.batteryTempC.ifBlank { "Unavailable" })
      MetaRow("Thermal zone", state.telemetry.thermalTempC.ifBlank { "Unavailable" })
      MetaRow("TCP congestion", state.telemetry.tcpCongestion.ifBlank { "Unknown" })
      MetaRow("Profile override", state.telemetry.fkmProfile.ifBlank { "auto" })
      MetaRow("Available governors", state.availableGovernors.joinToString().ifBlank { "Unavailable" })
    }
  }
}

@Composable
private fun BootCard(
  settings: BootSettings,
  busy: Boolean,
  onUpdate: (BootSettings) -> Unit
) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
      Text("Boot safeguards", style = MaterialTheme.typography.titleLarge, color = Color.White)
      SwitchRow(
        label = "Apply on boot",
        description = "Reapply the last active preset or custom tuning after boot.",
        checked = settings.autoApplyOnBoot,
        enabled = !busy,
        onCheckedChange = { onUpdate(settings.copy(autoApplyOnBoot = it)) }
      )
      SwitchRow(
        label = "Wait for unlock",
        description = "Delay root writes until the first unlock broadcast arrives.",
        checked = settings.waitForUnlock,
        enabled = !busy,
        onCheckedChange = { onUpdate(settings.copy(waitForUnlock = it)) }
      )
      SwitchRow(
        label = "Rollback to balanced",
        description = "If boot-time apply fails, restore the balanced preset.",
        checked = settings.rollbackToBalanced,
        enabled = !busy,
        onCheckedChange = { onUpdate(settings.copy(rollbackToBalanced = it)) }
      )
      OutlinedTextField(
        value = settings.applyDelaySeconds.toString(),
        onValueChange = { value ->
          value.toIntOrNull()?.let { onUpdate(settings.copy(applyDelaySeconds = it.coerceIn(0, 120))) }
        },
        label = { Text("Apply delay seconds") },
        singleLine = true,
        enabled = !busy,
        modifier = Modifier.fillMaxWidth()
      )
    }
  }
}

@Composable
private fun CustomTuningCard(
  tuning: CustomTuning,
  busy: Boolean,
  onChange: (CustomTuning) -> Unit,
  onApply: () -> Unit,
  onResetFromLive: () -> Unit
) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("Custom tuning", style = MaterialTheme.typography.titleLarge, color = Color.White)
      Text(
        text = "Edit the live dynasched values directly. This is kernel-specific and assumes the exported sysfs layout matches this repo.",
        style = MaterialTheme.typography.bodyMedium,
        color = Color(0xFFB7C4D2)
      )
      TuningField("policy0 min", tuning.policy0Min) { onChange(tuning.copy(policy0Min = it)) }
      TuningField("policy0 max", tuning.policy0Max) { onChange(tuning.copy(policy0Max = it)) }
      TuningField("policy4 min", tuning.policy4Min) { onChange(tuning.copy(policy4Min = it)) }
      TuningField("policy4 max", tuning.policy4Max) { onChange(tuning.copy(policy4Max = it)) }
      TuningField("policy6 min", tuning.policy6Min) { onChange(tuning.copy(policy6Min = it)) }
      TuningField("policy6 max", tuning.policy6Max) { onChange(tuning.copy(policy6Max = it)) }
      TuningField("policy7 min", tuning.policy7Min) { onChange(tuning.copy(policy7Min = it)) }
      TuningField("policy7 max", tuning.policy7Max) { onChange(tuning.copy(policy7Max = it)) }
      TuningField("dynasched up_rate_limit_us", tuning.upRateLimit) { onChange(tuning.copy(upRateLimit = it)) }
      TuningField("dynasched down_rate_limit_us", tuning.downRateLimit) { onChange(tuning.copy(downRateLimit = it)) }
      TuningField("vm.swappiness", tuning.swappiness) { onChange(tuning.copy(swappiness = it)) }
      TuningField("dirty_expire_centisecs", tuning.dirtyExpire) { onChange(tuning.copy(dirtyExpire = it)) }
      TuningField("dirty_writeback_centisecs", tuning.dirtyWriteback) { onChange(tuning.copy(dirtyWriteback = it)) }
      TuningField("top-app boost", tuning.topAppBoost) { onChange(tuning.copy(topAppBoost = it)) }
      TuningField("top-app uclamp min", tuning.topAppUclampMin) { onChange(tuning.copy(topAppUclampMin = it)) }
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(onClick = onApply, enabled = !busy) {
          Text("Apply custom")
        }
        TextButton(onClick = onResetFromLive, enabled = !busy) {
          Text("Reload live values")
        }
      }
    }
  }
}

@Composable
private fun ReleaseCard(
  release: ReleaseInfo?,
  busy: Boolean,
  onOpen: (String) -> Unit,
  onDownload: () -> Unit
) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("Release channel", style = MaterialTheme.typography.titleLarge, color = Color.White)
      if (release == null) {
        Text("Latest release unavailable.", color = Color(0xFFB7C4D2))
      } else {
        MetaRow("Tag", release.tagName)
        MetaRow("Published", release.publishedAt.ifBlank { "Unknown" })
        Text(
          text = release.title,
          style = MaterialTheme.typography.titleMedium,
          color = Color(0xFFF0F5FA)
        )
        Text(
          text = release.body,
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFFB7C4D2),
          maxLines = 8,
          overflow = TextOverflow.Ellipsis
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
          Button(onClick = { onOpen(release.htmlUrl) }, enabled = !busy) {
            Icon(Icons.Rounded.Public, contentDescription = null)
            Text("Open release", modifier = Modifier.padding(start = 8.dp))
          }
          Button(onClick = onDownload, enabled = !busy && release.zipUrl != null) {
            Icon(Icons.Rounded.CloudDownload, contentDescription = null)
            Text("Download ZIP", modifier = Modifier.padding(start = 8.dp))
          }
        }
      }
    }
  }
}

@Composable
private fun BackupCard(
  payload: String,
  busy: Boolean,
  onPayloadChange: (String) -> Unit,
  onCopy: () -> Unit,
  onImport: () -> Unit
) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("Backup and restore", style = MaterialTheme.typography.titleLarge, color = Color.White)
      OutlinedTextField(
        value = payload,
        onValueChange = onPayloadChange,
        label = { Text("JSON backup payload") },
        modifier = Modifier
          .fillMaxWidth()
          .height(220.dp),
        enabled = !busy
      )
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(onClick = onCopy, enabled = payload.isNotBlank()) {
          Icon(Icons.Rounded.ContentCopy, contentDescription = null)
          Text("Copy", modifier = Modifier.padding(start = 8.dp))
        }
        Button(onClick = onImport, enabled = !busy && payload.isNotBlank()) {
          Text("Import and apply")
        }
      }
    }
  }
}

@Composable
private fun DiagnosticsCard(state: KernelState) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.BugReport, contentDescription = null, tint = Color(0xFFEA6A2A))
        Text("Diagnostics and build info", style = MaterialTheme.typography.titleLarge, color = Color.White)
      }
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.Security, contentDescription = null, tint = Color(0xFFEA6A2A))
        Text(if (state.rootAvailable) "Root available" else "Root missing", color = Color.White)
      }
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.Memory, contentDescription = null, tint = Color(0xFF80C7FF))
        Text(
          text = state.buildInfo.kernelVersion.ifBlank { "Kernel version unavailable" },
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFFD7E2EE),
          maxLines = 4,
          overflow = TextOverflow.Ellipsis
        )
      }
      MetaRow("Managed kernel", if (state.buildInfo.managedKernel) "Yes" else "No")
      MetaRow("SELinux", state.diagnostics.selinuxMode.ifBlank { "Unknown" })
      MetaRow(
        "Missing nodes",
        if (state.diagnostics.missingNodes.isEmpty()) "None" else state.diagnostics.missingNodes.joinToString()
      )
      SelectionContainer {
        Text(
          text = state.diagnostics.supportText.ifBlank { "No diagnostics collected." },
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFFB7C4D2)
        )
      }
    }
  }
}

@Composable
private fun PolicyCard(policy: PolicySnapshot) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xC7182431)),
    shape = RoundedCornerShape(20.dp)
  ) {
    Column(
      modifier = Modifier
        .fillMaxWidth()
        .padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
      Text(policy.name, style = MaterialTheme.typography.titleMedium, color = Color.White)
      MetaRow("Governor", policy.governor)
      MetaRow("Current freq", policy.currentFreq)
      MetaRow("Freq range", "${policy.minFreq} - ${policy.maxFreq}")
      MetaRow("Rate limits", "${policy.upRateLimit} / ${policy.downRateLimit}")
    }
  }
}

@Composable
private fun GpuCard(state: KernelState, busy: Boolean, onSetGovernor: (String) -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier.fillMaxWidth().padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("GPU Governor", style = MaterialTheme.typography.titleLarge, color = Color.White)
      if (state.gpuState.availableGovernors.isEmpty()) {
        Text("Not available on this device", style = MaterialTheme.typography.bodyMedium, color = Color(0xFFB7C4D2))
      } else {
        MetaRow("Active", state.gpuState.governor)
        MetaRow("Frequency", state.gpuState.currentFreq)
        MetaRow("Range", "${state.gpuState.minFreq} - ${state.gpuState.maxFreq}")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          state.gpuState.availableGovernors.forEach { gov ->
            FilterChip(
              selected = gov == state.gpuState.governor,
              onClick = { onSetGovernor(gov) },
              label = { Text(gov) },
              enabled = !busy
            )
          }
        }
      }
    }
  }
}

@Composable
private fun IoSchedulerCard(state: KernelState, busy: Boolean, onSetScheduler: (String) -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier.fillMaxWidth().padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("I/O Scheduler", style = MaterialTheme.typography.titleLarge, color = Color.White)
      if (state.ioState.availableSchedulers.isEmpty()) {
        Text("Not available on this device", style = MaterialTheme.typography.bodyMedium, color = Color(0xFFB7C4D2))
      } else {
        MetaRow("Active", state.ioState.activeScheduler)
        MetaRow("Device", state.ioState.blockDevice)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          state.ioState.availableSchedulers.forEach { sched ->
            FilterChip(
              selected = sched == state.ioState.activeScheduler,
              onClick = { onSetScheduler(sched) },
              label = { Text(sched) },
              enabled = !busy
            )
          }
        }
      }
    }
  }
}

@Composable
private fun DisplayCard(state: KernelState, busy: Boolean, onSetMode: (String) -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier.fillMaxWidth().padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("Display Control", style = MaterialTheme.typography.titleLarge, color = Color.White)
      if (!state.displayState.available) {
        Text("Not available on this device", style = MaterialTheme.typography.bodyMedium, color = Color(0xFFB7C4D2))
      } else {
        MetaRow("Current mode", state.displayState.currentMode)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          state.displayState.availableModes.forEach { mode ->
            FilterChip(
              selected = mode == state.displayState.currentMode,
              onClick = { onSetMode(mode) },
              label = { Text(mode) },
              enabled = !busy
            )
          }
        }
        Text(
          "Controls display refresh rate. 60Hz saves battery, 120Hz maximizes smoothness.",
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFFB7C4D2)
        )
      }
    }
  }
}

@Composable
private fun OverclockCard(state: KernelState, busy: Boolean, onToggle: (Boolean) -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = Color(0xCC101923)),
    shape = RoundedCornerShape(24.dp)
  ) {
    Column(
      modifier = Modifier.fillMaxWidth().padding(18.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      Text("CPU Overclock", style = MaterialTheme.typography.titleLarge, color = Color.White)
      Text(
        "Conservative overclock (5-10% above stock). Thermal safety limits enforced automatically.",
        style = MaterialTheme.typography.bodyMedium,
        color = Color(0xFFB7C4D2)
      )
      MetaRow("Status", if (state.overclockState.enabled) "Enabled" else "Disabled")
      MetaRow("Thermal safe", if (state.overclockState.thermalSafe) "Yes" else "No - throttled")
      MetaRow("Current max (policy7)", state.overclockState.currentMaxFreq)
      MetaRow("OC target (policy7)", state.overclockState.overclockMaxFreq)
      MetaRow("Thermal", state.overclockState.thermalTemp)
      if (state.overclockState.safetyMessage.isNotBlank()) {
        Text(
          state.overclockState.safetyMessage,
          style = MaterialTheme.typography.bodyMedium,
          color = Color(0xFFFF6B6B)
        )
      }
      SwitchRow(
        label = "Enable overclock",
        description = "Push CPU frequencies 5-10% above stock maximum. Use at your own risk.",
        checked = state.overclockState.enabled,
        enabled = !busy && state.overclockState.thermalSafe,
        onCheckedChange = { onToggle(it) }
      )
      if (!state.overclockState.thermalSafe) {
        Text(
          "Overclock disabled: device temperature too high.",
          style = MaterialTheme.typography.bodySmall,
          color = Color(0xFFFF6B6B)
        )
      }
    }
  }
}

@Composable
private fun SwitchRow(
  label: String,
  description: String,
  checked: Boolean,
  enabled: Boolean,
  onCheckedChange: (Boolean) -> Unit
) {
  Row(
    modifier = Modifier.fillMaxWidth(),
    horizontalArrangement = Arrangement.SpaceBetween,
    verticalAlignment = Alignment.CenterVertically
  ) {
    Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
      Text(label, style = MaterialTheme.typography.titleMedium, color = Color.White)
      Text(description, style = MaterialTheme.typography.bodySmall, color = Color(0xFFB7C4D2))
    }
    Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
  }
}

@Composable
private fun TuningField(label: String, value: String, onValueChange: (String) -> Unit) {
  OutlinedTextField(
    value = value,
    onValueChange = { changed ->
      if (changed.all { it.isDigit() }) {
        onValueChange(changed)
      }
    },
    label = { Text(label) },
    singleLine = true,
    modifier = Modifier.fillMaxWidth()
  )
}

@Composable
private fun MetaRow(label: String, value: String) {
  Row(
    modifier = Modifier.fillMaxWidth(),
    horizontalArrangement = Arrangement.SpaceBetween,
    verticalAlignment = Alignment.CenterVertically
  ) {
    Text(label, style = MaterialTheme.typography.bodyMedium, color = Color(0xFF9AA9B8))
    Text(
      text = value,
      style = MaterialTheme.typography.bodyMedium,
      color = Color(0xFFF4F7FB),
      fontWeight = FontWeight.Medium
    )
  }
}

@Composable
private fun DynaschedTheme(content: @Composable () -> Unit) {
  MaterialTheme(
    colorScheme = darkColorScheme(
      primary = Color(0xFFEA6A2A),
      secondary = Color(0xFF80C7FF),
      tertiary = Color(0xFF87DFA2),
      surface = Color(0xFF0F1720),
      background = Color(0xFF0B1118)
    ),
    content = content
  )
}

private fun Context.copyToClipboard(label: String, text: String) {
  val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
  clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}

private fun Context.openUrl(url: String) {
  startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
