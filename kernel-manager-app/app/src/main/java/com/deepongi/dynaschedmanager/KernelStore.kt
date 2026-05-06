package com.deepongi.dynaschedmanager

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStoreFile
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import org.json.JSONObject

class KernelStore(context: Context) {
  private val dataStore = PreferenceDataStoreFactory.create(
    produceFile = { context.preferencesDataStoreFile("dynasched-manager.preferences_pb") }
  )

  suspend fun readPrefs(): StoredPrefs {
    return dataStore.data.map { data ->
      StoredPrefs(
        bootSettings = BootSettings(
          autoApplyOnBoot = data[AUTO_APPLY_ON_BOOT] ?: false,
          applyDelaySeconds = data[BOOT_DELAY_SECONDS] ?: 12,
          waitForUnlock = data[WAIT_FOR_UNLOCK] ?: true,
          rollbackToBalanced = data[ROLLBACK_TO_BALANCED] ?: true
        ),
        lastProfile = KernelProfile.fromStoredValue(data[LAST_PROFILE]),
        customTuning = data[CUSTOM_TUNING_JSON]?.let(::decodeCustomTuning) ?: CustomTuning()
      )
    }.first()
  }

  suspend fun updateBootSettings(settings: BootSettings) {
    dataStore.edit {
      it[AUTO_APPLY_ON_BOOT] = settings.autoApplyOnBoot
      it[BOOT_DELAY_SECONDS] = settings.applyDelaySeconds
      it[WAIT_FOR_UNLOCK] = settings.waitForUnlock
      it[ROLLBACK_TO_BALANCED] = settings.rollbackToBalanced
    }
  }

  suspend fun setLastProfile(profile: KernelProfile) {
    dataStore.edit { it[LAST_PROFILE] = profile.name }
  }

  suspend fun setCustomTuning(tuning: CustomTuning) {
    dataStore.edit { it[CUSTOM_TUNING_JSON] = encodeCustomTuning(tuning) }
  }

  companion object {
    private val AUTO_APPLY_ON_BOOT = booleanPreferencesKey("auto_apply_on_boot")
    private val BOOT_DELAY_SECONDS = intPreferencesKey("boot_delay_seconds")
    private val WAIT_FOR_UNLOCK = booleanPreferencesKey("wait_for_unlock")
    private val ROLLBACK_TO_BALANCED = booleanPreferencesKey("rollback_to_balanced")
    private val LAST_PROFILE = stringPreferencesKey("last_profile")
    private val CUSTOM_TUNING_JSON = stringPreferencesKey("custom_tuning_json")

    fun encodeCustomTuning(tuning: CustomTuning): String = JSONObject()
      .put("policy0Min", tuning.policy0Min)
      .put("policy0Max", tuning.policy0Max)
      .put("policy4Min", tuning.policy4Min)
      .put("policy4Max", tuning.policy4Max)
      .put("policy6Min", tuning.policy6Min)
      .put("policy6Max", tuning.policy6Max)
      .put("policy7Min", tuning.policy7Min)
      .put("policy7Max", tuning.policy7Max)
      .put("upRateLimit", tuning.upRateLimit)
      .put("downRateLimit", tuning.downRateLimit)
      .put("swappiness", tuning.swappiness)
      .put("dirtyExpire", tuning.dirtyExpire)
      .put("dirtyWriteback", tuning.dirtyWriteback)
      .put("topAppBoost", tuning.topAppBoost)
      .put("topAppUclampMin", tuning.topAppUclampMin)
      .toString()

    fun decodeCustomTuning(raw: String): CustomTuning {
      val json = JSONObject(raw)
      return CustomTuning(
        policy0Min = json.optString("policy0Min", "500000"),
        policy0Max = json.optString("policy0Max", "1900000"),
        policy4Min = json.optString("policy4Min", "700000"),
        policy4Max = json.optString("policy4Max", "2300000"),
        policy6Min = json.optString("policy6Min", "700000"),
        policy6Max = json.optString("policy6Max", "2400000"),
        policy7Min = json.optString("policy7Min", "850000"),
        policy7Max = json.optString("policy7Max", "2700000"),
        upRateLimit = json.optString("upRateLimit", "6000"),
        downRateLimit = json.optString("downRateLimit", "18000"),
        swappiness = json.optString("swappiness", "80"),
        dirtyExpire = json.optString("dirtyExpire", "300"),
        dirtyWriteback = json.optString("dirtyWriteback", "75"),
        topAppBoost = json.optString("topAppBoost", "15"),
        topAppUclampMin = json.optString("topAppUclampMin", "256")
      )
    }
  }
}

data class StoredPrefs(
  val bootSettings: BootSettings,
  val lastProfile: KernelProfile,
  val customTuning: CustomTuning
)
