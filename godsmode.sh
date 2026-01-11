#!/bin/sh
# Flint 2 GOD MODE — OpenWrt 23.05-safe (TMHI-hardened)
# - Static MTU set once
# - nft DSCP mark IPv4/IPv6 + counters
# - SQM AutoTune (robust parsing; skips on busy/failed/0Mbps)
# - Installs procd boot service + cron daily apply + autotune every N hours

set -eu

# -----------------------------
# Tunables (your TMHI profile)
# -----------------------------
CAP_DOWN_MBIT=777
CAP_UP_MBIT=140

MIN_DOWN_MBIT=120
MIN_UP_MBIT=20

DOWN_PCT=92
UP_PCT=88

THRESH_DOWN_PCT=10
THRESH_UP_PCT=6

WAN_MTU=1370

ENABLE_DSCP=1
DSCP_GAME=46
GAME_PORTS="{ 3074, 3478-3479, 3659, 9295-9304, 1935 }"

BUSY_RX_BYTES_PER_SEC=2500000
BUSY_TX_BYTES_PER_SEC=1000000

DAILY_HOUR=4
DAILY_MINUTE=17
AUTOTUNE_MINUTE=7
AUTOTUNE_EVERY_N_HOURS=3

# SQM CAKE options (keep your intent; SQM may still show rtt 100ms)
QDISC_OPTS="diffserv4 nat wash rtt 20ms memlimit 32mb"
QDISC_OPTS_INGRESS="diffserv4 nat wash rtt 20ms memlimit 32mb"

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

# Simple log rotate (keep last ~2000 lines)
rotate_log() {
  [ -f "$LOG" ] || return 0
  lines="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
  [ "$lines" -le 2500 ] && return 0
  tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
}

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

rotate_log
exec >>"$LOG" 2>&1
echo "=== GOD MODE START $(date) ==="
echo "[INFO] Script: $SELF_PATH"
echo "[INFO] Kernel: $(uname -r 2>/dev/null || echo unknown)"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# WAN device resolution (OpenWrt 23.05 safe)
# -----------------------------
resolve_wan_dev() {
  if have_cmd ubus && have_cmd jsonfilter; then
    st="$(ubus call network.interface.wan status 2>/dev/null || true)"
    dev="$(echo "$st" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
    [ -n "${dev:-}" ] || dev="$(echo "$st" | jsonfilter -e '@.device' 2>/dev/null || true)"
    [ -n "${dev:-}" ] && echo "$dev" && return 0
  fi

  dev="$(uci -q get network.wan.device 2>/dev/null || true)"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  dev="$(uci -q get network.wan.ifname 2>/dev/null || true)"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  [ -n "${dev:-}" ] && echo "$dev" && return 0

  echo "wan"
}

resolve_busy_dev() {
  dev="$1"
  case "$dev" in
    pppoe-*)
      under="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
      [ -n "${under:-}" ] && echo "$under" || echo "$dev"
      ;;
    *)
      echo "$dev"
      ;;
  esac
}

set_mtu_safe() {
  dev="$1"; mtu="$2"
  ip link show "$dev" >/dev/null 2>&1 || return 0
  ip link set dev "$dev" mtu "$mtu" >/dev/null 2>&1 || true
}

# -----------------------------
# Busy check
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
  echo "[INFO] WAN load($dev): rx=${rxps}B/s tx=${txps}B/s"
  [ "$rxps" -ge "$BUSY_RX_BYTES_PER_SEC" ] && return 0
  [ "$txps" -ge "$BUSY_TX_BYTES_PER_SEC" ] && return 0
  return 1
}

# -----------------------------
# SQM: enforce a single section sqm.wan (no surprises)
# -----------------------------
normalize_sqm_sections() {
  # If sqm.eth1 exists or any @queue exists, we don't want multiple competing instances.
  # Keep ONLY sqm.wan.
  if ! uci -q get sqm.wan >/dev/null 2>&1; then
    uci -q set sqm.wan='queue' || true
  fi

  # Disable common stray sections if present
  uci -q delete sqm.eth1 >/dev/null 2>&1 || true

  # If there are anonymous queues, disable them by setting enabled=0
  # (we don't delete @queue[0] blindly; just neutralize)
  if uci -q show sqm 2>/dev/null | grep -q '^sqm\.\@queue\[[0-9]\+\]\.'; then
    i=0
    while uci -q get "sqm.@queue[$i]" >/dev/null 2>&1; do
      uci -q set "sqm.@queue[$i].enabled=0" >/dev/null 2>&1 || true
      i=$((i+1))
    done
  fi

  uci -q commit sqm >/dev/null 2>&1 || true
}

apply_sqm() {
  down="$1"; up="$2"
  [ -x /etc/init.d/sqm ] || { echo "[WARN] SQM not installed; skipping SQM."; return 0; }

  normalize_sqm_sections

  uci -q batch <<EOF
set sqm.wan.interface='${WAN_DEV}'
set sqm.wan.enabled='1'
set sqm.wan.qdisc='cake'
set sqm.wan.script='piece_of_cake.qos'
set sqm.wan.download='$((down * 1000))'
set sqm.wan.upload='$((up * 1000))'
set sqm.wan.qdisc_advanced='1'
set sqm.wan.qdisc_really_really_advanced='1'
set sqm.wan.ingress_ecn='ECN'
set sqm.wan.egress_ecn='ECN'
set sqm.wan.qdisc_opts='${QDISC_OPTS}'
set sqm.wan.qdisc_opts_ingress='${QDISC_OPTS_INGRESS}'
EOF

  uci -q commit sqm >/dev/null 2>&1 || true
  /etc/init.d/sqm enable >/dev/null 2>&1 || true
  /etc/init.d/sqm restart >/dev/null 2>&1 || true

  echo "$down $up" > "$LAST_RATES" 2>/dev/null || true
  echo "[OK] SQM applied: ${down}/${up} Mbps (note: SQM/CAKE may still display rtt 100ms)"
}

# -----------------------------
# nftables DSCP (own table only)
# -----------------------------
NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_SET="game_udp_ports"

ensure_nft_dscp() {
  [ "$ENABLE_DSCP" -eq 1 ] || { echo "[INFO] DSCP disabled (ENABLE_DSCP=0)."; return 0; }
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

# -----------------------------
# Speedtest (robust)
# - Preferred: speedtest-netperf.sh (OpenWrt package)
# - Optional: librespeed-cli (if installed + reachable)
# - Skips if busy, or if errors/0Mbps/invalid output
# -----------------------------
parse_netperf_out() {
  # Extract numeric Mbps from speedtest-netperf output, even if warnings exist.
  # Return: "DOWN UP" or empty.
  out="$1"
  # Only trust if it does NOT contain netperf fatal error patterns
  echo "$out" | grep -qiE 'invalid number|recv_response: partial|WARNING: netperf returned errors' && return 1

  down="$(echo "$out" | awk '
    /Download:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}
  ')"
  up="$(echo "$out" | awk '
    /Upload:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}
  ')"

  [ -n "${down:-}" ] && [ -n "${up:-}" ] || return 1

  down_i="$(printf "%.0f\n" "$down" 2>/dev/null || echo "")"
  up_i="$(printf "%.0f\n" "$up" 2>/dev/null || echo "")"
  [ -n "${down_i:-}" ] && [ -n "${up_i:-}" ] || return 1

  [ "$down_i" -gt 0 ] && [ "$up_i" -gt 0 ] || return 1
  echo "$down_i $up_i"
}

run_speedtest() {
  if is_link_busy "$BUSY_DEV"; then
    echo "[SKIP] WAN is busy; skipping speedtest."
    return 2
  fi

  # 1) speedtest-netperf.sh
  if have_cmd speedtest-netperf.sh || [ -x /usr/bin/speedtest-netperf.sh ]; then
    echo "[INFO] Running speedtest-netperf.sh (IPv4)..."
    out="$(/usr/bin/speedtest-netperf.sh -4 2>&1 || true)"
    echo "$out" | tail -n 120 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done
    res="$(parse_netperf_out "$out" 2>/dev/null || true)"
    if [ -n "${res:-}" ]; then
      echo "$res"
      return 0
    fi
    echo "[WARN] speedtest-netperf result unusable (TMHI/netperf errors likely)."
  fi

  # 2) librespeed-cli (optional)
  if have_cmd librespeed-cli; then
    echo "[INFO] Running librespeed-cli (may fail on some networks)..."
    out="$(librespeed-cli --simple 2>&1 || true)"
    echo "$out" | tail -n 80 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done
    down_i="$(echo "$out" | awk -F'[: ]+' '/Download/{print int($2)}' | head -n1)"
    up_i="$(echo "$out" | awk -F'[: ]+' '/Upload/{print int($2)}' | head -n1)"
    if [ -n "${down_i:-}" ] && [ -n "${up_i:-}" ] && [ "$down_i" -gt 0 ] && [ "$up_i" -gt 0 ]; then
      echo "$down_i $up_i"
      return 0
    fi
    echo "[WARN] librespeed-cli result unusable (timeout/blocked)."
  fi

  return 1
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
  [ $(( diff * 100 )) -ge $(( old * thr )) ]
}

autotune_sqm() {
  echo "[INFO] AutoTune requested..."
  res="$(run_speedtest 2>/dev/null || true)"
  rc="$?"
  if [ "$rc" -eq 2 ]; then
    return 0
  fi
  if [ -z "${res:-}" ]; then
    echo "[WARN] Speedtest failed/unusable; keeping last SQM."
    return 0
  fi

  measured_down="$(echo "$res" | awk '{print $1}')"
  measured_up="$(echo "$res" | awk '{print $2}')"
  [ "${measured_down:-0}" -gt 0 ] && [ "${measured_up:-0}" -gt 0 ] || {
    echo "[WARN] Speedtest returned 0 Mbps; keeping last SQM."
    return 0
  }

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

  apply_up=0; apply_down=0
  if change_pct_ge "$target_up" "$prev_up" "$THRESH_UP_PCT"; then apply_up=1; fi
  if change_pct_ge "$target_down" "$prev_down" "$THRESH_DOWN_PCT"; then apply_down=1; fi

  if [ "$apply_up" -eq 0 ] && [ "$apply_down" -eq 0 ]; then
    echo "[OK] Below thresholds; no SQM restart. Keeping ${prev_down}/${prev_up} Mbps"
    return 0
  fi

  echo "[INFO] Applying SQM (prev ${prev_down}/${prev_up})..."
  apply_sqm "$target_down" "$target_up"
}

# -----------------------------
# Base apply (MTU + DSCP)
# -----------------------------
apply_base_once() {
  WAN_DEV="$(resolve_wan_dev)"
  BUSY_DEV="$(resolve_busy_dev "$WAN_DEV")"
  echo "[INFO] WAN_DEV: $WAN_DEV (busy-check: $BUSY_DEV)"

  set_mtu_safe "$BUSY_DEV" "$WAN_MTU"
  echo "[OK] MTU set: dev=$BUSY_DEV mtu=$WAN_MTU"

  ensure_nft_dscp
  echo "[OK] Base rules applied."
}

apply_last_sqm_if_present() {
  [ -f "$LAST_RATES" ] || return 1
  d="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
  u="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
  [ "$d" -gt 0 ] && [ "$u" -gt 0 ] || return 1
  echo "[INFO] Re-applying last SQM: ${d}/${u} Mbps"
  apply_sqm "$d" "$u"
  return 0
}

# -----------------------------
# Install / Uninstall (procd + cron)
# -----------------------------
install_service_and_cron() {
  echo "[INFO] Installing procd boot service + cron..."

  mkdir -p /root/godmode/logs /root/godmode/state >/dev/null 2>&1 || true

  cat > /etc/init.d/godmode_static <<'INIT'
#!/bin/sh /etc/rc.common
START=95
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /bin/sh -c "sleep 20; /root/godmode/godmode_static.sh --apply >>/root/godmode/logs/boot_apply.log 2>&1"
  procd_set_param respawn 0 0 0
  procd_close_instance
}
INIT
  chmod +x /etc/init.d/godmode_static
  /etc/init.d/godmode_static enable >/dev/null 2>&1 || true

  CR=/etc/crontabs/root
  [ -f "$CR" ] || touch "$CR"
  sed -i '/godmode_static\.sh/d' "$CR" 2>/dev/null || true

  echo "$DAILY_MINUTE $DAILY_HOUR * * * /root/godmode/godmode_static.sh --apply >>/root/godmode/logs/cron_apply.log 2>&1" >> "$CR"
  echo "$AUTOTUNE_MINUTE */$AUTOTUNE_EVERY_N_HOURS * * * /root/godmode/godmode_static.sh --autotune >>/root/godmode/logs/autotune_${AUTOTUNE_EVERY_N_HOURS}hour.log 2>&1" >> "$CR"

  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
  echo "[DONE] Boot service + cron installed."
}

uninstall_hooks() {
  echo "[INFO] Removing service/cron hooks..."
  /etc/init.d/godmode_static disable >/dev/null 2>&1 || true
  rm -f /etc/init.d/godmode_static 2>/dev/null || true
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
    install_service_and_cron
    ;;
  --apply)
    apply_base_once
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
    echo "  $SELF_PATH                 # apply base + autotune (skips if busy)"
    echo "  $SELF_PATH --install       # apply + install boot service + daily + N-hour autotune"
    echo "  $SELF_PATH --apply         # re-apply base + last known SQM (no speedtest)"
    echo "  $SELF_PATH --autotune      # speedtest + adjust SQM (skips if busy)"
    echo "  $SELF_PATH --uninstall     # remove boot + cron hooks"
    exit 2
    ;;
esac


exit 0