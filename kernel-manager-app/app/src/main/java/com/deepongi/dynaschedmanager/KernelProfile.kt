package com.deepongi.dynaschedmanager

enum class KernelProfile(
  val title: String,
  val summary: String
) {
  Eco(
    title = "Eco",
    summary = "Cool and conservative. Best for standby and screen-off bias."
  ),
  Balanced(
    title = "Balanced",
    summary = "Daily-driver profile with quicker ramp-up and stable decay."
  ),
  Turbo(
    title = "Turbo",
    summary = "Aggressive response for gaming and heavy interaction."
  ),
  Custom(
    title = "Custom",
    summary = "Manual per-policy and dynasched tuning."
  );

  companion object {
    fun fromStoredValue(value: String?): KernelProfile = when (value) {
      Eco.name -> Eco
      Custom.name -> Custom
      Turbo.name -> Turbo
      else -> Balanced
    }
  }
}
