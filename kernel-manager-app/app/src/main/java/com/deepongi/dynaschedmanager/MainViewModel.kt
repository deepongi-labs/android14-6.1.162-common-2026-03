package com.deepongi.dynaschedmanager

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class MainViewModel(
  private val manager: KernelManager
) : ViewModel() {
  private val _state = MutableStateFlow(KernelState())
  val state: StateFlow<KernelState> = _state.asStateFlow()

  init {
    refresh()
  }

  fun refresh() {
    viewModelScope.launch {
      _state.update { it.copy(busy = true, statusMessage = "Refreshing kernel state...") }
      _state.value = manager.readState().copy(busy = false)
    }
  }

  fun applyProfile(profile: KernelProfile) {
    runBusyAction("Applying ${profile.title}...") {
      manager.applyProfile(profile)
    }
  }

  fun applyCustomTuning(tuning: CustomTuning) {
    runBusyAction("Applying custom tuning...") {
      manager.applyCustomTuning(tuning)
    }
  }

  fun restoreBalancedDefaults() {
    runBusyAction("Restoring balanced defaults...") {
      manager.restoreBalancedDefaults()
    }
  }

  fun updateBootSettings(settings: BootSettings) {
    viewModelScope.launch {
      runCatching { manager.updateBootSettings(settings) }
        .onFailure { error ->
          _state.update { it.copy(statusMessage = error.message ?: "Failed to update boot behavior.") }
          return@launch
        }
      _state.update {
        it.copy(bootSettings = settings, statusMessage = "Boot behavior updated.")
      }
      refresh()
    }
  }

  fun importBackup(rawJson: String) {
    runBusyAction("Importing backup...") {
      manager.importBackup(rawJson)
    }
  }

  fun downloadLatestRelease() {
    viewModelScope.launch {
      val release = _state.value.latestRelease ?: return@launch
      val downloadId = manager.downloadLatestReleaseZip(release)
      _state.update {
        it.copy(
          statusMessage = if (downloadId != null) {
            "Release download queued."
          } else {
            "No ZIP asset found on the latest release."
          }
        )
      }
    }
  }

  private fun runBusyAction(loadingMessage: String, action: suspend () -> String) {
    viewModelScope.launch {
      _state.update { it.copy(busy = true, statusMessage = loadingMessage) }
      val message = runCatching { action() }
        .getOrElse { error -> error.message ?: "Operation failed." }
      _state.value = manager.readState().copy(busy = false, statusMessage = message)
    }
  }

  companion object {
    fun factory(context: Context): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
      @Suppress("UNCHECKED_CAST")
      override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return MainViewModel(KernelManager(context.applicationContext)) as T
      }
    }
  }
}
