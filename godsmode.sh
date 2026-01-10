#!/bin/sh
# Flint 2 GOD MODE (Static MTU + DSCP tagging) + SQM AutoTune (3-hour) — “Near-100” build
# Fixes the 3 things that kept it from 100:
#  1) Speedtest load: skip autotune if network is busy (or during gaming hours)
#  2) SQM restart cost: only restart SQM if change is meaningful, and prioritize upload changes
#  3) DSCP reality: optional toggle to disable DSCP marking if your ISP ignores it
#
# Save as:
#   /root/godmode/godmode_static.sh
#
# Dependencies (recommended):
#   opkg update && opkg install speedtest-netperf
#
# Usage:
#   /root/godmode/godmode_static.sh                 # apply base + (safe) autotune once
#   /root/godmode/godmode_static.sh --install       # apply + install boot + daily + 3-hour autotune
#   /root/godmode/godmode_static.sh --apply         # re-apply base + SQM (last known) safely
#   /root/godmode/godmode_static.sh --autotune      # run speedtest and adjust SQM (safe checks)
#   /root/godmode/godmode_static.sh --uninstall     # remove boot + cron hooks

set -eu

# -----------------------------
# Your observed T-Mobile max
# -----------------------------
CAP_DOWN_MBIT=777
CAP_UP_MBIT=140

# Safety floors (avoid bad/low test results)
MIN_DOWN_MBIT=120
MIN_UP_MBIT=20

# SQM target percentages of measured speed
DOWN_PCT=92
UP_PCT=88

# Prevent flapping: only apply if change >= threshold
# Separate thresholds: upload is more important for latency
THRESH_DOWN_PCT=10
THRESH_UP_PCT=6

# WAN MTU (you tested best)
WAN_MTU=1370

# DSCP (toggle)
ENABLE_DSCP=1
DSCP_GAME=46
GAME_PORTS="{ 3074, 3478-3479, 3659, 9295-9304, 1935 }"

# Busy-skip thresholds (reduce speedtest disruption)
# If current WAN traffic exceeds these, skip autotune.
BUSY_RX_BYTES_PER_SEC=2500000   # ~2.5 MB/s
BUSY_TX_BYTES_PER_SEC=1000000   # ~1.0 MB/s

# Gaming-hour skip (no speedtests during your play window)
# Set ENABLE_GAMING_HOURS_SKIP=0 to disable this feature.
ENABLE_GAMING_HOURS_SKIP=1
GAMING_START_HOUR=18            # 18 = 6pm
GAMING_END_HOUR=1               # 1 = 1am (wraps past midnight)

# Extra protection: if game UDP packets are active, skip autotune
ENABLE_GAME_TRAFFIC_SKIP=1
GAME_PKT_DELTA_SKIP=10          # if >10 packets between samples, assume active gaming

# Schedules (router local time)
DAILY_HOUR=4
DAILY_MINUTE=17

# Autotune every 3 hours at :07 => 00:07, 03:07, 06:07, ...
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
GAME_PKTS_LAST="$STATE_DIR/game_pkts_last.txt"

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
# nftables DSCP (IPv4 + IPv6) + counters
# -----------------------------
NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_SET="game_udp_ports"

ensure_nft_dscp() {
  [ "$ENABLE_DSCP" -eq 1 ] || { echo "[INFO] DSCP disabled by config (ENABLE_DSCP=0)."; return 0; }
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

  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip  dscp set $DSCP_GAME counter comment "GM_GAME_DSCP4" >/dev/null 2>&1 || true
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip6 dscp set $DSCP_GAME counter comment "GM_GAME_DSCP6" >/dev/null 2>&1 || true

  echo "[OK] nftables DSCP ensured (IPv4+IPv6) with counters."
}

# Game traffic activity check (uses nft counters; skips autotune if active)
get_game_udp_pkts() {
  have_cmd nft || { echo 0; return; }
  nft -a list chain $NFT_TABLE $NFT_CHAIN 2>/dev/null | \
    awk '/GM_GAME_DSCP4|GM_GAME_DSCP6/ && /packets/ {for(i=1;i<=NF;i++){if($i=="packets"){print $(i+1); exit}}}'
}

game_traffic_active() {
  [ "$ENABLE_GAME_TRAFFIC_SKIP" -eq 1 ] || return 1
  pkts_now="$(get_game_udp_pkts 2>/dev/null || echo 0)"
  [ -n "${pkts_now:-}" ] || pkts_now=0
  pkts_prev="$(cat "$GAME_PKTS_LAST" 2>/dev/null || echo 0)"
  [ -n "${pkts_prev:-}" ] || pkts_prev=0
  echo "$pkts_now" > "$GAME_PKTS_LAST" 2>/dev/null || true
  delta=$((pkts_now - pkts_prev))
  [ "$delta" -gt "$GAME_PKT_DELTA_SKIP" ]
}

# -----------------------------
# Busy link check (skip speedtest if WAN is busy)
# -----------------------------
read_bytes() {
  dev="$1"; dir="$2"
  cat "/sys/class/net/$dev/statistics/${dir}_bytes" 2>/dev/null || echo 0
}

is_link_busy() {
  dev="$1"
  b1r="$(read_bytes "$dev" rx)"; b1t="$(read_bytes "$dev" tx)"
  sleep 2
  b2r="$(read_bytes "$dev" rx)"; b2t="$(read_bytes "$dev" tx)"
  rxps=$(((b2r - b1r) / 2))
  txps=$(((b2t - b1t) / 2))
  echo "[INFO] WAN load: rx=${rxps}B/s tx=${txps}B/s"
  [ "$rxps" -ge "$BUSY_RX_BYTES_PER_SEC" ] && return 0
  [ "$txps" -ge "$BUSY_TX_BYTES_PER_SEC" ] && return 0
  return 1
}

# -----------------------------
# Gaming hours check (skip speedtests during your play window)
# -----------------------------
in_gaming_hours() {
  [ "$ENABLE_GAMING_HOURS_SKIP" -eq 1 ] || return 1
  h="$(date +%H 2>/dev/null || echo 12)"
  h="${h#0}" 2>/dev/null || true
  [ -z "${h:-}" ] && h=12

  s="$GAMING_START_HOUR"
  e="$GAMING_END_HOUR"

  if [ "$s" -lt "$e" ]; then
    # normal window: s..e-1
    [ "$h" -ge "$s" ] && [ "$h" -lt "$e" ]
  else
    # wraps midnight: h>=s OR h<e
    [ "$h" -ge "$s" ] || [ "$h" -lt "$e" ]
  fi
}

# -----------------------------
# SQM apply (single restart) — only when we decide to apply
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

  # Restart once (SQM needs restart to apply), but only when necessary
  /etc/init.d/sqm restart >/dev/null 2>&1 || true

  echo "$down $up" > "$LAST_RATES" 2>/dev/null || true
  echo "[OK] SQM applied: ${down}/${up} Mbps"
}

# -----------------------------
# Speedtest + compute targets
# -----------------------------
run_speedtest() {
  have_cmd speedtest-netperf || { echo "[ERR] speedtest-netperf not installed. Install: opkg update && opkg install speedtest-netperf"; return 1; }

  out="$(speedtest-netperf 2>/dev/null || true)"
  echo "$out" | tail -n 80 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done

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

change_pct_ge() {
  new="$1"; old="$2"; thr="$3"
  [ "$old" -le 0 ] && return 0
  diff=$((new - old)); [ "$diff" -lt 0 ] && diff=$(( -diff ))
  # diff/old >= thr?
  [ $(( diff * 100 )) -ge $(( old * thr )) ]
}

autotune_sqm() {
  echo "[INFO] AutoTune requested..."

  WAN_DEV="$(resolve_wan_dev)"
  echo "[INFO] WAN_DEV: $WAN_DEV"

  # Skip during gaming hours
  if in_gaming_hours; then
    echo "[SKIP] Gaming hours window active; skipping speedtest."
    return 0
  fi

  # Skip if game traffic seems active right now
  if game_traffic_active; then
    echo "[SKIP] Game UDP traffic active; skipping speedtest."
    return 0
  fi

  # Skip if link is busy (reduce disruption)
  if is_link_busy "$WAN_DEV"; then
    echo "[SKIP] Link busy; skipping speedtest."
    return 0
  fi

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

  # Decide whether to apply:
  # - Upload change uses tighter threshold (more important)
  # - If only download changes slightly, skip to avoid unnecessary SQM restart hiccups
  apply_up=0
  apply_down=0

  if change_pct_ge "$target_up" "$prev_up" "$THRESH_UP_PCT"; then
    apply_up=1
  fi
  if change_pct_ge "$target_down" "$prev_down" "$THRESH_DOWN_PCT"; then
    apply_down=1
  fi

  if [ "$apply_up" -eq 0 ] && [ "$apply_down" -eq 0 ]; then
    echo "[OK] Changes below thresholds (down ${THRESH_DOWN_PCT}%, up ${THRESH_UP_PCT}%); no SQM restart."
    echo "[OK] Keeping SQM at ${prev_down}/${prev_up} Mbps"
    return 0
  fi

  # If upload changed meaningfully, apply both down+up targets (best latency result).
  # If only download changed meaningfully, still apply (but only when big change), to avoid repeated restarts.
  echo "[INFO] Applying SQM (prev ${prev_down}/${prev_up})..."
  apply_sqm "$target_down" "$target_up"
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
# Apply last known SQM (no speedtest), optional
# -----------------------------
apply_last_sqm_if_present() {
  [ -f "$LAST_RATES" ] || return 1
  d="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
  u="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
  [ "$d" -gt 0 ] && [ "$u" -gt 0 ] || return 1
  WAN_DEV="$(resolve_wan_dev)"
  echo "[INFO] Re-applying last SQM: ${d}/${u} Mbps"
  apply_sqm "$d" "$u"
  return 0
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

  # Remove older entries for this script so we don't duplicate
  sed -i '/godmode_static\.sh/d' "$CR" 2>/dev/null || true

  # Daily maintenance apply (re-enforce base + last-known SQM, no speedtest)
  echo "$DAILY_MINUTE $DAILY_HOUR * * * $SELF_PATH --apply >/root/godmode/logs/cron_apply.log 2>&1" >> "$CR"

  # Autotune every N hours
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
    # Prefer re-applying last known SQM to avoid unnecessary speedtests
    apply_last_sqm_if_present || true
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
    echo "  $SELF_PATH                 # apply base + (safe) autotune once"
    echo "  $SELF_PATH --install       # apply + install boot + daily + 3-hour autotune"
    echo "  $SELF_PATH --apply         # re-apply base + last known SQM (no speedtest)"
    echo "  $SELF_PATH --autotune      # speedtest + adjust SQM (skips if busy/gaming)"
    echo "  $SELF_PATH --uninstall     # remove boot + cron hooks"
    exit 2
    ;;
esac

exit 0