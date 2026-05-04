package com.deepongi.dynaschedmanager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
      intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
      intent.action != Intent.ACTION_USER_UNLOCKED) {
      return
    }

    val pendingResult = goAsync()
    CoroutineScope(Dispatchers.IO).launch {
      runCatching {
        val manager = KernelManager(context.applicationContext)
        val prefs = KernelStore(context.applicationContext).readPrefs()
        val settings = prefs.bootSettings
        if (!settings.autoApplyOnBoot) {
          return@runCatching
        }
        if (!settings.waitForUnlock && intent.action == Intent.ACTION_USER_UNLOCKED) {
          return@runCatching
        }
        if (settings.waitForUnlock && intent.action != Intent.ACTION_USER_UNLOCKED) {
          return@runCatching
        }
        if (settings.applyDelaySeconds > 0) {
          kotlinx.coroutines.delay(settings.applyDelaySeconds * 1000L)
        }

        val result = if (prefs.lastProfile == KernelProfile.Custom) {
          manager.applyCustomTuning(prefs.customTuning)
        } else {
          manager.applyProfile(prefs.lastProfile)
        }

        if (settings.rollbackToBalanced && result.contains("Failed", ignoreCase = true)) {
          manager.restoreBalancedDefaults()
        }
      }
      pendingResult.finish()
    }
  }
}
