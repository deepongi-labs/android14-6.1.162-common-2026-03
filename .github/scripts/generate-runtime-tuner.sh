#!/bin/bash
mkdir -p success-metadata
TUNER_SCRIPT="success-metadata/pixel8-runtime-tuner-${KSU_VARIANT}.sh"
GOV_MODE="${GOVERNOR_MODE}"
if [ "${RUNTIME_TUNER}" != "true" ]; then
  cat << 'EOF' > "$TUNER_SCRIPT"
#!/system/bin/sh
# Runtime tuner generation disabled for this run.
# Governor mode: __GOV_MODE__
exit 0
EOF
  sed -i "s/__GOV_MODE__/${GOV_MODE}/g" "$TUNER_SCRIPT"
  chmod +x "$TUNER_SCRIPT"
  exit 0
fi
cat << 'EOF' > "$TUNER_SCRIPT"
#!/system/bin/sh
# Pixel 8 runtime tuner for responsiveness + battery life.
# Custom mode "dynasched" exports schedutil under a kernel-specific governor name.
# Run as root (KernelSU/Magisk service.d) on boot.

set -u
GOV_MODE="__GOV_MODE__"

LOG_TAG="dynasched-tuner"
LOG_FILE="/data/local/tmp/dynasched.log"

# Rotate log if larger than 512KB
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
fi

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
}

cleanup() {
  log "Received SIGTERM, resetting governor to schedutil"
  write_if_exists schedutil /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  # Reset max frequencies to safe stock values
  write_if_exists 1900000 /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  write_if_exists 2300000 /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
  write_if_exists 2400000 /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
  write_if_exists 2700000 /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq
  exit 0
}

trap cleanup SIGTERM SIGINT

write_if_exists() {
  local value="$1"
  shift
  for node in "$@"; do
    [ -e "$node" ] && echo "$value" > "$node" 2>/dev/null || true
  done
}

governor_sysfs_dir() {
  if [ "$GOV_MODE" = "dynasched" ]; then
    echo dynasched
  else
    echo schedutil
  fi
}

apply_governor_defaults() {
  if [ "$GOV_MODE" = "dynasched" ]; then
    write_if_exists dynasched /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  else
    write_if_exists schedutil /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  fi
}

write_governor_tuning() {
  local up="$1"
  local down="$2"
  local gov_dir
  gov_dir="$(governor_sysfs_dir)"
  write_if_exists "$up" /sys/devices/system/cpu/cpufreq/policy*/"$gov_dir"/up_rate_limit_us
  write_if_exists "$down" /sys/devices/system/cpu/cpufreq/policy*/"$gov_dir"/down_rate_limit_us
}

set_policy_limits() {
  local policy="$1"
  local minf="$2"
  local maxf="$3"
  write_if_exists "$minf" "/sys/devices/system/cpu/cpufreq/${policy}/scaling_min_freq"
  write_if_exists "$maxf" "/sys/devices/system/cpu/cpufreq/${policy}/scaling_max_freq"
}

apply_dynasched() {
  local mode="$1"
  case "$mode" in
    eco)
      set_policy_limits policy0 300000 1700000
      set_policy_limits policy4 500000 2000000
      set_policy_limits policy6 500000 2100000
      set_policy_limits policy7 500000 2200000
      write_governor_tuning 25000 60000
      ;;
    turbo)
      set_policy_limits policy0 600000 2100000
      set_policy_limits policy4 700000 2600000
      set_policy_limits policy6 700000 2700000
      set_policy_limits policy7 900000 2918000
      write_governor_tuning 4000 12000
      ;;
    *)
      set_policy_limits policy0 300000 1900000
      set_policy_limits policy4 500000 2300000
      set_policy_limits policy6 500000 2400000
      set_policy_limits policy7 700000 2700000
      write_governor_tuning 9000 25000
      ;;
  esac
}

is_screen_off() {
  local brightness
  brightness=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || echo 1)
  [ "$brightness" -eq 0 ] && return 0
  return 1
}

get_thermal_temp() {
  # Read the hottest thermal zone (in millidegrees C)
  local max_temp=0
  for tz in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$tz" ] || continue
    local t
    t=$(cat "$tz" 2>/dev/null) || continue
    [ "${t:-0}" -gt "$max_temp" ] && max_temp="$t"
  done
  echo "$max_temp"
}

apply_governor_defaults

# FKM / kernel-manager profile override support.
# External managers write one of: performance, balanced, battery
# to this file. The tuner respects it instead of auto-detecting.
PROFILE_OVERRIDE_FILE="/data/local/tmp/.dynasched_profile"
TCP_OVERRIDE_FILE="/data/local/tmp/.dynasched_tcp_congestion"

# Initialize default files if missing
if [ ! -f "$PROFILE_OVERRIDE_FILE" ]; then
  echo "auto" > "$PROFILE_OVERRIDE_FILE"
fi
if [ ! -f "$TCP_OVERRIDE_FILE" ]; then
  echo "bbr" > "$TCP_OVERRIDE_FILE"
fi

# Log available TCP congestion algorithms
if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
  log "tcp_available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
fi
log "tcp_active=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)"

apply_tcp_congestion() {
  if [ -r "$TCP_OVERRIDE_FILE" ]; then
    local algo
    algo=$(cat "$TCP_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$algo" ] && grep -qw "$algo" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      echo "$algo" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    fi
  fi
}

# GPU Governor Management
GPU_OVERRIDE_FILE="/data/local/tmp/.dynasched_gpu_governor"
IO_OVERRIDE_FILE="/data/local/tmp/.dynasched_io_scheduler"
DISPLAY_OVERRIDE_FILE="/data/local/tmp/.dynasched_display_mode"
OVERCLOCK_FILE="/data/local/tmp/.dynasched_overclock"

# Initialize state files with safe defaults if they don't exist
[ -f "$GPU_OVERRIDE_FILE" ] || echo "auto" > "$GPU_OVERRIDE_FILE"
[ -f "$IO_OVERRIDE_FILE" ] || echo "auto" > "$IO_OVERRIDE_FILE"
[ -f "$DISPLAY_OVERRIDE_FILE" ] || echo "auto" > "$DISPLAY_OVERRIDE_FILE"
[ -f "$OVERCLOCK_FILE" ] || echo "disabled" > "$OVERCLOCK_FILE"

apply_gpu_governor() {
  local mode="$1"
  local gov=""
  case "$mode" in
    performance) gov="performance" ;;
    powersave) gov="powersave" ;;
    balanced) gov="simple_ondemand" ;;
    simple_ondemand) gov="simple_ondemand" ;;
    userspace) gov="userspace" ;;
    *) gov="simple_ondemand" ;;
  esac
  for node in /sys/class/devfreq/*/governor; do
    [ -e "$node" ] && echo "$gov" > "$node" 2>/dev/null || true
  done
}

apply_io_scheduler() {
  local sched="$1"
  case "$sched" in
    bfq|mq-deadline|kyber|none) ;;
    *) sched="bfq" ;;
  esac
  for queue in /sys/block/*/queue/scheduler; do
    [ -e "$queue" ] && echo "$sched" > "$queue" 2>/dev/null || true
  done
}

apply_display_mode() {
  local mode="$1"
  # Pixel 8 uses /sys/devices/platform/exynos-drm/* for panel control
  # Also try generic drm idle_timeout approach
  case "$mode" in
    60hz)
      write_if_exists 0 /sys/devices/platform/exynos-drm/*/idle_timeout
      for node in /sys/class/drm/card*/device/idle_timeout; do
        [ -e "$node" ] && echo 0 > "$node" 2>/dev/null || true
      done
      # Force 60Hz by setting min refresh interval
      write_if_exists 16666 /sys/devices/platform/exynos-drm/*/min_vrefresh_interval
      ;;
    120hz)
      write_if_exists 1 /sys/devices/platform/exynos-drm/*/idle_timeout
      for node in /sys/class/drm/card*/device/idle_timeout; do
        [ -e "$node" ] && echo 1 > "$node" 2>/dev/null || true
      done
      write_if_exists 8333 /sys/devices/platform/exynos-drm/*/min_vrefresh_interval
      ;;
    *)
      # Auto/adaptive: let the system manage refresh rate
      write_if_exists 100 /sys/devices/platform/exynos-drm/*/idle_timeout
      ;;
  esac
}

# Overclock safety constants (conservative 5-10% above stock max)
OC_POLICY0_MAX=2100000   # stock max ~1900000, +10%
OC_POLICY4_MAX=2500000   # stock max ~2300000, +8%
OC_POLICY6_MAX=2600000   # stock max ~2400000, +8%
OC_POLICY7_MAX=3000000   # stock max ~2700000, +11%

SAFE_POLICY0_MAX=1900000
SAFE_POLICY4_MAX=2300000
SAFE_POLICY6_MAX=2400000
SAFE_POLICY7_MAX=2700000

THERMAL_OC_LIMIT=90000    # 90C - disable overclock
BATTERY_OC_LIMIT=450      # 45C - disable overclock

apply_overclock() {
  local oc_state
  oc_state=$(cat "$OVERCLOCK_FILE" 2>/dev/null | tr -d '[:space:]')

  # Only act if user has explicitly enabled overclock
  if [ "$oc_state" != "enabled" ]; then
    return
  fi

  local thermal_t
  thermal_t=$(get_thermal_temp)
  local batt_t
  batt_t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 320)

  # Safety check: disable overclock if thermal limits exceeded
  if [ "${thermal_t:-0}" -ge "$THERMAL_OC_LIMIT" ] || [ "${batt_t:-320}" -ge "$BATTERY_OC_LIMIT" ]; then
    log "OVERCLOCK SAFETY: thermal=$thermal_t batt=$batt_t - forcing safe frequencies"
    # Reset to safe limits
    set_policy_limits policy0 300000 "$SAFE_POLICY0_MAX"
    set_policy_limits policy4 500000 "$SAFE_POLICY4_MAX"
    set_policy_limits policy6 500000 "$SAFE_POLICY6_MAX"
    set_policy_limits policy7 700000 "$SAFE_POLICY7_MAX"
    return
  fi

  # Apply overclock limits only to max freq
  write_if_exists "$OC_POLICY0_MAX" /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  write_if_exists "$OC_POLICY4_MAX" /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
  write_if_exists "$OC_POLICY6_MAX" /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
  write_if_exists "$OC_POLICY7_MAX" /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq
}

apply_tcp_congestion

while true; do
  # Check for external profile override (FKM, Dynasched Manager, etc.)
  fkm_profile=""
  if [ -r "$PROFILE_OVERRIDE_FILE" ]; then
    fkm_profile=$(cat "$PROFILE_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]')
  fi

  # Apply TCP congestion override each cycle
  apply_tcp_congestion

  batt_cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 50)
  batt_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 320)
  thermal_temp=$(get_thermal_temp)
  load_one=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
  load_int=${load_one%.*}

  # Use FKM override if set, otherwise auto-detect
  case "$fkm_profile" in
    performance)
      profile_mode="turbo"
      write_if_exists 110 /proc/sys/vm/swappiness
      write_if_exists 200 /proc/sys/vm/dirty_expire_centisecs
      ;;
    battery)
      profile_mode="eco"
      write_if_exists 60 /proc/sys/vm/swappiness
      write_if_exists 500 /proc/sys/vm/dirty_expire_centisecs
      ;;
    balanced)
      profile_mode="balanced"
      write_if_exists 90 /proc/sys/vm/swappiness
      write_if_exists 300 /proc/sys/vm/dirty_expire_centisecs
      ;;
    *)
      # Auto-detect based on device state
      if is_screen_off || [ "$batt_cap" -le 30 ] || [ "$batt_temp" -ge 420 ] || [ "${thermal_temp:-0}" -ge 85000 ]; then
        profile_mode="eco"
        write_if_exists 60 /proc/sys/vm/swappiness
        write_if_exists 500 /proc/sys/vm/dirty_expire_centisecs
      elif [ "${load_int:-0}" -ge 5 ] && [ "$batt_temp" -le 390 ]; then
        profile_mode="turbo"
        write_if_exists 110 /proc/sys/vm/swappiness
        write_if_exists 200 /proc/sys/vm/dirty_expire_centisecs
      else
        profile_mode="balanced"
        write_if_exists 90 /proc/sys/vm/swappiness
        write_if_exists 300 /proc/sys/vm/dirty_expire_centisecs
      fi
      ;;
  esac

  log "profile=$profile_mode batt=$batt_cap% temp=$batt_temp thermal=$thermal_temp load=$load_one"

  if [ "$GOV_MODE" = "dynasched" ]; then
    apply_dynasched "$profile_mode"
  else
    # stock schedutil with adaptive response limits only
    if [ "$profile_mode" = "eco" ]; then
      write_governor_tuning 20000 50000
    elif [ "$profile_mode" = "turbo" ]; then
      write_governor_tuning 4000 12000
    else
      write_governor_tuning 8000 20000
    fi
  fi

  # Apply GPU governor based on override or profile
  gpu_mode=""
  if [ -r "$GPU_OVERRIDE_FILE" ]; then
    gpu_mode=$(cat "$GPU_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$gpu_mode" in
    performance|powersave|balanced|simple_ondemand|userspace) apply_gpu_governor "$gpu_mode" ;;
    *) apply_gpu_governor "$profile_mode" ;;
  esac

  # Apply I/O scheduler based on override or profile
  io_sched=""
  if [ -r "$IO_OVERRIDE_FILE" ]; then
    io_sched=$(cat "$IO_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$io_sched" in
    bfq|mq-deadline|kyber|none) apply_io_scheduler "$io_sched" ;;
    *)
      case "$profile_mode" in
        eco) apply_io_scheduler "bfq" ;;
        turbo) apply_io_scheduler "none" ;;
        *) apply_io_scheduler "bfq" ;;
      esac
      ;;
  esac

  # Apply display mode based on override or profile
  disp_mode=""
  if [ -r "$DISPLAY_OVERRIDE_FILE" ]; then
    disp_mode=$(cat "$DISPLAY_OVERRIDE_FILE" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$disp_mode" in
    60hz|120hz) apply_display_mode "$disp_mode" ;;
    *)
      case "$profile_mode" in
        eco) apply_display_mode "60hz" ;;
        turbo) apply_display_mode "120hz" ;;
        *) apply_display_mode "auto" ;;
      esac
      ;;
  esac

  # Apply overclock (function checks oc_state internally)
  apply_overclock

  sleep 20
done
EOF

sed -i "s/__GOV_MODE__/${GOV_MODE}/g" "$TUNER_SCRIPT"
chmod +x "$TUNER_SCRIPT"

