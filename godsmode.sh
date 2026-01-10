#!/bin/sh
# Flint 2 GOD MODE (Static MTU + DSCP tagging) + SQM AutoTune (every 3 hours)
# - MTU set once (1370)
# - nft DSCP mark IPv4 + IPv6 (counter included)
# - SQM autotune via speedtest-netperf, safe thresholds (no flapping)
# - Installs: boot apply + daily apply + autotune every 3 hours (cron)
#
# Save as:
#   /root/godmode/godmode_static.sh
#
# Usage:
#   /root/godmode/godmode_static.sh                 # apply base + run autotune once
#   /root/godmode/godmode_static.sh --install       # apply + install boot + daily + 3-hour autotune
#   /root/godmode/godmode_static.sh --apply         # re-apply base + SQM (last known or autotune)
#   /root/godmode/godmode_static.sh --autotune      # run speedtest and adjust SQM (safe threshold)
#   /root/godmode/godmode_static.sh --uninstall     # remove boot + cron hooks

set -eu

# -----------------------------
# Hard caps (your observed max)
# -----------------------------
CAP_DOWN_MBIT=777
CAP_UP_MBIT=140

# Safety floors (avoid setting too low if a test glitches)
MIN_DOWN_MBIT=120
MIN_UP_MBIT=20

# SQM target percentages of measured speed
DOWN_PCT=92   # 90–95 typical; 92 is safe/fast
UP_PCT=88     # upload drives bufferbloat; be conservative

# Only apply if change is >= this percent (prevents flapping)
APPLY_THRESHOLD_PCT=8

# WAN MTU (you tested best)
WAN_MTU=1370

# DSCP tagging for common game UDP ports
DSCP_GAME=46
GAME_PORTS="{ 3074, 3478-3479, 3659, 9295-9304, 1935 }"

# Schedules (router local time)
DAILY_HOUR=4
DAILY_MINUTE=17

# Autotune every 3 hours at minute 07: 00:07, 03:07, 06:07, ...
AUTOTUNE_MINUTE=7
AUTOTUNE_EVERY_N_HOURS=3

# -----------------------------
# Paths / logging
# -----------------------------
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
GODMODE_DIR="/root/godmode"
LOG_DIR="$GODMODE_DIR/logs"
STATE_DIR="$GODMODE_DIR/state"
LOG="$LOG_DIR/godmode.log"
LAST_RATES="$STATE_DIR/last_sqm_rates.txt"

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 700 "$GODMODE_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

# -----------------------------
# Lock
# -----------------------------
LOCKDIR="/tmp/godmode.lock"
if mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$$" > "$LOCKDIR/pid" 2>/dev/null || true
else
  exit 0
fi
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

exec >>"$LOG" 2>&1
echo "=== GOD MODE START $(date) ==="
echo "[INFO] Script: $SELF_PATH"
echo "[INFO] Kernel: $(uname -r 2>/dev/null || echo unknown)"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# WAN device resolution
# -----------------------------
resolve_wan_dev() {
  dev="$(uci -q get network.wan.device 2>/dev/null || true)"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  dev="$(uci -q get network.wan.ifname 2>/dev/null || true)"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  echo "wan"
}

set_mtu_safe() {
  dev="$1"; mtu="$2"
  ip link set dev "$dev" mtu "$mtu" >/dev/null 2>&1 || true
}

# -----------------------------
# SQM apply (single restart)
# -----------------------------
apply_sqm() {
  down="$1"; up="$2"
  [ -x /etc/init.d/sqm ] || { echo "[WARN] SQM not installed; skipping SQM."; return 0; }

  uci -q set sqm.@queue[0].interface="$WAN_DEV" || true
  uci -q set sqm.@queue[0].qdisc="cake" || true
  uci -q set sqm.@queue[0].script="piece_of_cake.qos" || true

  # SQM expects kbit/s
  uci -q set sqm.@queue[0].download="$((down * 1000))" || true
  uci -q set sqm.@queue[0].upload="$((up * 1000))" || true

  uci -q set sqm.@queue[0].qdisc_advanced="1" || true
  uci -q set sqm.@queue[0].qdisc_really_really_advanced="1" || true
  uci -q set sqm.@queue[0].ingress_ecn="ECN" || true
  uci -q set sqm.@queue[0].egress_ecn="ECN" || true

  uci -q set sqm.@queue[0].qdisc_opts="diffserv4 nat wash rtt 20ms memlimit 32mb" || true
  uci -q set sqm.@queue[0].qdisc_opts_ingress="diffserv4 nat wash rtt 20ms memlimit 32mb" || true

  uci -q commit sqm >/dev/null 2>&1 || true
  /etc/init.d/sqm restart >/dev/null 2>&1 || true

  echo "$down $up" > "$LAST_RATES" 2>/dev/null || true
  echo "[OK] SQM applied: ${down}/${up} Mbps"
}

# -----------------------------
# nftables DSCP (IPv4 + IPv6) + counters
# -----------------------------
NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_SET="game_udp_ports"

ensure_nft_dscp() {
  have_cmd nft || { echo "[WARN] nft not installed; skipping nft/DSCP."; return 0; }

  nft list table $NFT_TABLE >/dev/null 2>&1 || nft add table $NFT_TABLE >/dev/null 2>&1 || true

  if nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1; then
    nft flush chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 || true
  else
    nft add chain $NFT_TABLE $NFT_CHAIN "{ type filter hook prerouting priority -150; policy accept; }" >/dev/null 2>&1 || true
  fi

  if nft list set $NFT_TABLE $GAME_SET >/dev/null 2>&1; then
    nft flush set $NFT_TABLE $GAME_SET >/dev/null 2>&1 || true
  else
    nft add set $NFT_TABLE $GAME_SET "{ type inet_service; flags interval; }" >/dev/null 2>&1 || true
  fi

  nft add element $NFT_TABLE $GAME_SET "$GAME_PORTS" >/dev/null 2>&1 || true

  # Counter included in same rule; mark both IPv4 and IPv6
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip  dscp set $DSCP_GAME counter comment "GM_GAME_DSCP4" >/dev/null 2>&1 || true
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip6 dscp set $DSCP_GAME counter comment "GM_GAME_DSCP6" >/dev/null 2>&1 || true

  echo "[OK] nftables DSCP ensured (IPv4+IPv6) with counters."
}

# -----------------------------
# Speedtest + compute targets
# Requires: speedtest-netperf
# -----------------------------
run_speedtest() {
  have_cmd speedtest-netperf || { echo "[ERR] speedtest-netperf not installed. Install: opkg update && opkg install speedtest-netperf"; return 1; }

  out="$(speedtest-netperf 2>/dev/null || true)"
  echo "$out" | tail -n 60 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done

  down="$(echo "$out" | awk '/Download/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) {print $i; exit}}')"
  up="$(echo "$out" | awk '/Upload/   {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/) {print $i; exit}}')"

  [ -n "${down:-}" ] || return 1
  [ -n "${up:-}" ] || return 1

  down_i="$(printf "%.0f\n" "$down" 2>/dev/null || echo "")"
  up_i="$(printf "%.0f\n" "$up" 2>/dev/null || echo "")"
  [ -n "${down_i:-}" ] || return 1
  [ -n "${up_i:-}" ] || return 1

  echo "$down_i $up_i"
}

clamp() {
  v="$1"; min="$2"; max="$3"
  [ "$v" -lt "$min" ] && v="$min"
  [ "$v" -gt "$max" ] && v="$max"
  echo "$v"
}

pct_of() {
  v="$1"; pct="$2"
  echo $(( v * pct / 100 ))
}

should_apply_change() {
  new="$1"; old="$2"
  [ "$old" -le 0 ] && return 0
  diff=$(( new - old ))
  [ "$diff" -lt 0 ] && diff=$(( -diff ))
  [ $(( diff * 100 )) -ge $(( old * APPLY_THRESHOLD_PCT )) ]
}

autotune_sqm() {
  echo "[INFO] AutoTune starting..."
  res="$(run_speedtest 2>/dev/null || true)"
  if [ -z "${res:-}" ]; then
    echo "[WARN] Speedtest failed; not changing SQM."
    return 0
  fi

  measured_down="$(echo "$res" | awk '{print $1}')"
  measured_up="$(echo "$res" | awk '{print $2}')"
  echo "[INFO] Measured: ${measured_down}/${measured_up} Mbps"

  target_down="$(pct_of "$measured_down" "$DOWN_PCT")"
  target_up="$(pct_of "$measured_up" "$UP_PCT")"

  target_down="$(clamp "$target_down" "$MIN_DOWN_MBIT" "$CAP_DOWN_MBIT")"
  target_up="$(clamp "$target_up" "$MIN_UP_MBIT" "$CAP_UP_MBIT")"

  echo "[INFO] Target (pct+clamp): ${target_down}/${target_up} Mbps"

  prev_down=0; prev_up=0
  if [ -f "$LAST_RATES" ]; then
    prev_down="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
    prev_up="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
  fi

  apply_flag=0
  if should_apply_change "$target_down" "$prev_down"; then apply_flag=1; fi
  if should_apply_change "$target_up" "$prev_up"; then apply_flag=1; fi

  if [ "$apply_flag" -eq 1 ]; then
    echo "[INFO] Applying new SQM (prev ${prev_down}/${prev_up})..."
    apply_sqm "$target_down" "$target_up"
  else
    echo "[OK] Change < ${APPLY_THRESHOLD_PCT}%; keeping SQM at ${prev_down}/${prev_up} Mbps"
  fi
}

# -----------------------------
# Base apply (MTU + DSCP)
# -----------------------------
apply_base_once() {
  WAN_DEV="$(resolve_wan_dev)"
  echo "[INFO] WAN_DEV: $WAN_DEV"

  set_mtu_safe "$WAN_DEV" "$WAN_MTU"
  echo "[OK] MTU set: dev=$WAN_DEV mtu=$WAN_MTU"

  ensure_nft_dscp
  echo "[OK] Base rules applied."
}

# -----------------------------
# Install / Uninstall hooks
# -----------------------------
install_boot_daily_autotune3h() {
  echo "[INFO] Installing boot + daily + autotune every ${AUTOTUNE_EVERY_N_HOURS} hours..."

  # BOOT: rc.local
  [ -f /etc/rc.local ] || printf "%s\n" "#!/bin/sh" "exit 0" > /etc/rc.local
  chmod +x /etc/rc.local
  if ! grep -q "godmode_static.sh" /etc/rc.local 2>/dev/null; then
    sed -i "s#^exit 0#(sleep 20; $SELF_PATH --apply) >/root/godmode/logs/boot_apply.log 2>&1 \&\nexit 0#" /etc/rc.local
    echo "[OK] Boot hook added."
  else
    echo "[OK] Boot hook already present."
  fi

  # CRON
  CR=/etc/crontabs/root
  [ -f "$CR" ] || touch "$CR"

  # Remove any older autotune entries for this script (hourly/other)
  sed -i '/godmode_static\.sh --autotune/d' "$CR" 2>/dev/null || true

  # Daily maintenance apply
  grep -q "godmode_static.sh --apply" "$CR" 2>/dev/null || \
    echo "$DAILY_MINUTE $DAILY_HOUR * * * $SELF_PATH --apply >/root/godmode/logs/cron_apply.log 2>&1" >> "$CR"

  # Autotune every 3 hours
  # minute */3 hour-of-day
  echo "$AUTOTUNE_MINUTE */$AUTOTUNE_EVERY_N_HOURS * * * $SELF_PATH --autotune >/root/godmode/logs/autotune_${AUTOTUNE_EVERY_N_HOURS}hour.log 2>&1" >> "$CR"

  /etc/init.d/cron restart >/dev/null 2>&1 || true
  echo "[DONE] Installed boot + daily + autotune every ${AUTOTUNE_EVERY_N_HOURS} hours."
}

uninstall_hooks() {
  echo "[INFO] Removing boot/cron hooks..."
  [ -f /etc/rc.local ] && sed -i '/godmode_static\.sh/d' /etc/rc.local >/dev/null 2>&1 || true
  CR=/etc/crontabs/root
  [ -f "$CR" ] && sed -i '/godmode_static\.sh/d' "$CR" >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
  echo "[DONE] Hooks removed."
}

# -----------------------------
# CLI
# -----------------------------
case "${1:-}" in
  --install)
    apply_base_once
    autotune_sqm || true
    install_boot_daily_autotune3h
    ;;
  --apply)
    apply_base_once
    # Re-apply last known SQM if present; else run autotune once
    if [ -f "$LAST_RATES" ]; then
      d="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
      u="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
      if [ "$d" -gt 0 ] && [ "$u" -gt 0 ]; then
        WAN_DEV="$(resolve_wan_dev)"
        apply_sqm "$d" "$u"
      else
        autotune_sqm || true
      fi
    else
      autotune_sqm || true
    fi
    ;;
  --autotune)
    apply_base_once
    autotune_sqm || true
    ;;
  --uninstall)
    uninstall_hooks
    ;;
  "" )
    apply_base_once
    autotune_sqm || true
    ;;
  * )
    echo "Usage:"
    echo "  $SELF_PATH                 # apply base + run autotune once"
    echo "  $SELF_PATH --install       # apply + install boot + daily + 3-hour autotune"
    echo "  $SELF_PATH --apply         # re-apply base + SQM (last or autotune)"
    echo "  $SELF_PATH --autotune      # run speedtest and adjust SQM (safe threshold)"
    echo "  $SELF_PATH --uninstall     # remove boot + cron hooks"
    exit 2
    ;;
esac

exit 0