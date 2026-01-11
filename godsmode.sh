#!/bin/sh
# Flint 2 GOD MODE UPDATE v3 — OpenWrt 23.05-safe (100x more robust)
# What’s improved vs v2:
# - Bulletproof WAN detection (ubus/jsonfilter -> uci -> default route) + PPPoE-safe busy-dev
# - SQM section normalization (always sqm.wan; disables stray @queue[] / sqm.eth1 so nothing “fights”)
# - Busy-skip autotune (won’t run speedtests while you’re using the net)
# - Speedtest parsing hardened (no more “sh: out of range” / empty values)
# - Uses procd boot service (no rc.local edits) + cron for daily apply + 3h autotune
# - Safer MTU set (only if interface exists) + verification output for tc/nft
#
# Save as: /root/godmode/godmode_static.sh
# chmod +x /root/godmode/godmode_static.sh
#
# Usage:
#   /root/godmode/godmode_static.sh                 # apply base + autotune once (skips if busy)
#   /root/godmode/godmode_static.sh --install       # apply + install boot service + cron
#   /root/godmode/godmode_static.sh --apply         # apply base + re-apply last SQM if present
#   /root/godmode/godmode_static.sh --autotune      # speedtest + adjust SQM (skips if busy)
#   /root/godmode/godmode_static.sh --status        # show current status (wan dev, tc, nft, sqm)
#   /root/godmode/godmode_static.sh --uninstall     # remove boot + cron hooks

set -eu

# -----------------------------
# Tunables (TMHI profile)
# -----------------------------
CAP_DOWN_MBIT=777
CAP_UP_MBIT=140

MIN_DOWN_MBIT=120
MIN_UP_MBIT=20

DOWN_PCT=92
UP_PCT=88

# Apply only if change is meaningful (avoid SQM restart hiccups)
THRESH_DOWN_PCT=10
THRESH_UP_PCT=6

WAN_MTU=1370

# DSCP tagging (EF = 46) for common gaming UDP ports
ENABLE_DSCP=1
DSCP_GAME=46
GAME_PORTS="{ 3074, 3478-3479, 3659, 9295-9304, 1935 }"

# Busy-skip thresholds (bytes/sec over 2 seconds)
BUSY_RX_BYTES_PER_SEC=2500000   # ~2.5 MB/s download
BUSY_TX_BYTES_PER_SEC=1000000   # ~1.0 MB/s upload

# Schedules
DAILY_HOUR=4
DAILY_MINUTE=17
AUTOTUNE_MINUTE=7
AUTOTUNE_EVERY_N_HOURS=3

# SQM CAKE options (note: some builds still show rtt 100ms in tc output)
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

rotate_log() {
  [ -f "$LOG" ] || return 0
  lines="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
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

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# -----------------------------
# WAN device resolution (23.05 safe)
# Prefer ubus network.interface.wan status
# -----------------------------
resolve_wan_dev() {
  if have_cmd ubus && have_cmd jsonfilter; then
    st="$(ubus call network.interface.wan status 2>/dev/null || true)"
    dev="$(echo "$st" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
    [ -n "${dev:-}" ] || dev="$(echo "$st" | jsonfilter -e '@.device' 2>/dev/null || true)"
    [ -n "${dev:-}" ] && { echo "$dev"; return 0; }
  fi

  dev="$(uci -q get network.wan.device 2>/dev/null || true)"
  [ -n "${dev:-}" ] && { echo "$dev"; return 0; }

  dev="$(uci -q get network.wan.ifname 2>/dev/null || true)"
  [ -n "${dev:-}" ] && { echo "$dev"; return 0; }

  dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  [ -n "${dev:-}" ] && { echo "$dev"; return 0; }

  echo "wan"
}

# If WAN is PPPoE, busy-check often needs underlying device
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
  ip link show "$dev" >/dev/null 2>&1 || { echo "[WARN] MTU: dev $dev not found; skipping"; return 0; }
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

  # Guard numeric
  is_uint "$b1r" || b1r=0
  is_uint "$b2r" || b2r=0
  is_uint "$b1t" || b1t=0
  is_uint "$b2t" || b2t=0

  rxps=$(((b2r - b1r) / 2))
  txps=$(((b2t - b1t) / 2))
  echo "[INFO] WAN load($dev): rx=${rxps}B/s tx=${txps}B/s"

  [ "$rxps" -ge "$BUSY_RX_BYTES_PER_SEC" ] && return 0
  [ "$txps" -ge "$BUSY_TX_BYTES_PER_SEC" ] && return 0
  return 1
}

# -----------------------------
# SQM: normalize to a single section sqm.wan (no surprises)
# -----------------------------
normalize_sqm_sections() {
  # Ensure sqm.wan exists
  if ! uci -q get sqm.wan >/dev/null 2>&1; then
    uci -q set sqm.wan='queue' >/dev/null 2>&1 || true
  fi

  # Disable common stray named section
  uci -q delete sqm.eth1 >/dev/null 2>&1 || true

  # Disable any anonymous @queue sections so nothing competes
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

  is_uint "$down" || { echo "[WARN] bad down '$down'"; return 0; }
  is_uint "$up"   || { echo "[WARN] bad up '$up'"; return 0; }
  [ "$down" -gt 0 ] && [ "$up" -gt 0 ] || { echo "[WARN] down/up must be >0"; return 0; }

  normalize_sqm_sections

  # SQM expects kbit/s
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
  echo "[OK] SQM applied: ${down}/${up} Mbps"
}

# -----------------------------
# nftables DSCP (own table only; safe)
# -----------------------------
NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_SET="game_udp_ports"

ensure_nft_dscp() {
  [ "$ENABLE_DSCP" -eq 1 ] || { echo "[INFO] DSCP disabled"; return 0; }
  have_cmd nft || { echo "[WARN] nft not installed; skipping DSCP."; return 0; }

  nft list table $NFT_TABLE >/dev/null 2>&1 || nft add table $NFT_TABLE >/dev/null 2>&1 || true

  if nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1; then
    nft flush chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 || true
  else
    # Use mangle hook name for clarity (OpenWrt uses nftables base chains; this is fine)
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

  echo "[OK] nft DSCP ensured (IPv4+IPv6) with counters."
}

# -----------------------------
# Speedtest (robust + no “out of range”)
# Prefer speedtest-netperf.sh if available (package: speedtest-netperf)
# -----------------------------
parse_speed_out() {
  out="$1"

  # Extract first numeric token after "Download:" and "Upload:"
  down="$(echo "$out" | awk '
    /Download:/ {
      for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}
    }')"
  up="$(echo "$out" | awk '
    /Upload:/ {
      for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}
    }')"

  [ -n "${down:-}" ] && [ -n "${up:-}" ] || return 1

  # Convert to ints safely via awk (avoids shell printf edge cases)
  down_i="$(echo "$down" | awk '{printf "%d\n",$1+0}')"
  up_i="$(echo "$up" | awk '{printf "%d\n",$1+0}')"

  is_uint "$down_i" || return 1
  is_uint "$up_i" || return 1
  [ "$down_i" -gt 0 ] && [ "$up_i" -gt 0 ] || return 1

  echo "$down_i $up_i"
}

run_speedtest() {
  if is_link_busy "$BUSY_DEV"; then
    echo "[SKIP] WAN is busy; skipping speedtest."
    return 2
  fi

  if [ -x /usr/bin/speedtest-netperf.sh ]; then
    echo "[INFO] Running speedtest-netperf.sh (IPv4)..."
    out="$(/usr/bin/speedtest-netperf.sh -4 2>&1 || true)"
  elif have_cmd speedtest-netperf; then
    echo "[INFO] Running speedtest-netperf..."
    out="$(speedtest-netperf 2>&1 || true)"
  else
    echo "[ERR] speedtest-netperf not installed. Run: opkg update && opkg install speedtest-netperf"
    return 1
  fi

  echo "$out" | tail -n 120 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done

  res="$(parse_speed_out "$out" 2>/dev/null || true)"
  [ -n "${res:-}" ] || return 1
  echo "$res"
}

clamp() {
  v="$1"; min="$2"; max="$3"
  is_uint "$v" || v=0
  [ "$v" -lt "$min" ] && v="$min"
  [ "$v" -gt "$max" ] && v="$max"
  echo "$v"
}

pct_of() {
  v="$1"; pct="$2"
  is_uint "$v" || v=0
  echo $(( v * pct / 100 ))
}

change_pct_ge() {
  new="$1"; old="$2"; thr="$3"
  is_uint "$new" || return 1
  is_uint "$old" || return 0
  [ "$old" -le 0 ] && return 0
  diff=$((new - old)); [ "$diff" -lt 0 ] && diff=$(( -diff ))
  [ $(( diff * 100 )) -ge $(( old * thr )) ]
}

autotune_sqm() {
  echo "[INFO] AutoTune starting..."
  res="$(run_speedtest 2>/dev/null || true)"
  rc="$?"
  [ "$rc" -eq 2 ] && return 0

  if [ -z "${res:-}" ]; then
    echo "[WARN] Speedtest failed/unusable; not changing SQM."
    return 0
  fi

  measured_down="$(echo "$res" | awk '{print $1}')"
  measured_up="$(echo "$res" | awk '{print $2}')"
  is_uint "$measured_down" || measured_down=0
  is_uint "$measured_up" || measured_up=0

  if [ "$measured_down" -le 0 ] || [ "$measured_up" -le 0 ]; then
    echo "[WARN] Speedtest returned 0 Mbps; not changing SQM."
    return 0
  fi

  echo "[INFO] Measured: ${measured_down}/${measured_up} Mbps"

  target_down="$(clamp "$(pct_of "$measured_down" "$DOWN_PCT")" "$MIN_DOWN_MBIT" "$CAP_DOWN_MBIT")"
  target_up="$(clamp "$(pct_of "$measured_up" "$UP_PCT")" "$MIN_UP_MBIT" "$CAP_UP_MBIT")"
  echo "[INFO] Target (pct+clamp): ${target_down}/${target_up} Mbps"

  prev_down=0; prev_up=0
  if [ -f "$LAST_RATES" ]; then
    prev_down="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
    prev_up="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
    is_uint "$prev_down" || prev_down=0
    is_uint "$prev_up" || prev_up=0
  fi

  apply_down=0; apply_up=0
  change_pct_ge "$target_down" "$prev_down" "$THRESH_DOWN_PCT" && apply_down=1 || true
  change_pct_ge "$target_up" "$prev_up" "$THRESH_UP_PCT" && apply_up=1 || true

  if [ "$apply_down" -eq 0 ] && [ "$apply_up" -eq 0 ]; then
    echo "[OK] Below thresholds; no SQM restart. Keeping ${prev_down}/${prev_up} Mbps"
    return 0
  fi

  echo "[INFO] Applying new SQM (prev ${prev_down}/${prev_up})..."
  apply_sqm "$target_down" "$target_up"
}

# -----------------------------
# Base apply
# -----------------------------
apply_base_once() {
  WAN_DEV="$(resolve_wan_dev)"
  BUSY_DEV="$(resolve_busy_dev "$WAN_DEV")"
  echo "[INFO] WAN_DEV: $WAN_DEV (busy-check: $BUSY_DEV)"

  set_mtu_safe "$BUSY_DEV" "$WAN_MTU"
  echo "[OK] MTU set (best-effort): dev=$BUSY_DEV mtu=$WAN_MTU"

  ensure_nft_dscp
  echo "[OK] Base rules applied."
}

apply_last_sqm_if_present() {
  [ -f "$LAST_RATES" ] || return 1
  d="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
  u="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
  is_uint "$d" || d=0
  is_uint "$u" || u=0
  [ "$d" -gt 0 ] && [ "$u" -gt 0 ] || return 1
  echo "[INFO] Re-applying last SQM: ${d}/${u} Mbps"
  apply_sqm "$d" "$u"
  return 0
}

# -----------------------------
# Install / Uninstall (procd + cron)
# -----------------------------
install_boot_and_cron() {
  echo "[INFO] Installing procd boot service + cron..."

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
  /etc/init.d/godmode_static restart >/dev/null 2>&1 || true

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
  echo "[INFO] Removing services/cron..."
  /etc/init.d/godmode_static stop >/dev/null 2>&1 || true
  /etc/init.d/godmode_static disable >/dev/null 2>&1 || true
  rm -f /etc/init.d/godmode_static 2>/dev/null || true

  CR=/etc/crontabs/root
  [ -f "$CR" ] && sed -i '/godmode_static\.sh/d' "$CR" >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
  echo "[DONE] Hooks removed."
}

status_report() {
  WAN_DEV="$(resolve_wan_dev)"
  BUSY_DEV="$(resolve_busy_dev "$WAN_DEV")"
  echo "== godmode status =="
  echo "WAN_DEV=$WAN_DEV (busy-check=$BUSY_DEV)"
  echo
  echo "== sqm config (top) =="
  uci show sqm 2>/dev/null | sed -n '1,120p' || true
  echo
  echo "== tc qdisc on WAN_DEV =="
  tc qdisc show dev "$WAN_DEV" 2>/dev/null || true
  echo
  echo "== nft table inet godmode =="
  nft list table inet godmode 2>/dev/null | head -n 80 || true
  echo
  echo "== last rates =="
  [ -f "$LAST_RATES" ] && cat "$LAST_RATES" || echo "(none yet)"
  echo
  echo "== services =="
  /etc/init.d/godmode_static status 2>/dev/null || true
}

# -----------------------------
# CLI
# -----------------------------
case "${1:-}" in
  --install)
    apply_base_once
    autotune_sqm || true
    install_boot_and_cron
    ;;
  --apply)
    apply_base_once
    apply_last_sqm_if_present || true
    ;;
  --autotune)
    apply_base_once
    autotune_sqm || true
    ;;
  --status)
    status_report
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
    echo "  $SELF_PATH                 # apply base + autotune once (skips if busy)"
    echo "  $SELF_PATH --install       # apply + install boot + cron"
    echo "  $SELF_PATH --apply         # re-apply base + last SQM (no speedtest)"
    echo "  $SELF_PATH --autotune      # speedtest + adjust SQM (skips if busy)"
    echo "  $SELF_PATH --status        # show WAN/tc/nft/sqm"
    echo "  $SELF_PATH --uninstall     # remove boot + cron hooks"
    exit 2
    ;;
esac

exit 0