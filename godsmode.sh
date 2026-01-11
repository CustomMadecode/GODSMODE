#!/bin/sh
# Flint 2 GOD MODE — OpenWrt 23.05-safe (30/10)
# - Static MTU (once per run)
# - CAKE SQM with safe section normalization
# - PS5 priority when online (auto-detect from DHCP leases) -> DSCP EF (46)
# - Game UDP ports DSCP EF
# - AutoTune only when WAN is IDLE (won't run during traffic)
# - Self-update script from GitHub (safe)
# - procd boot + cron: daily apply + optional idle autotune + daily selfupdate

set -eu

# -----------------------------
# TMHI profile
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

# -----------------------------
# Priority / QoS
# -----------------------------
ENABLE_DSCP=1
DSCP_GAME=46                      # EF
GAME_PORTS="{ 3074, 3478-3479, 3659, 9295-9304, 1935 }"

# PS5 priority (auto-detect)
ENABLE_PS5_PRIORITY=1
# Optional: pin PS5 IPs if you want (space-separated). Leave empty to auto-detect.
PS5_IPS_V4=""
# Optional: match DHCP hostname patterns (case-insensitive)
PS5_HOST_PAT='(ps5|playstation|sony)'

# -----------------------------
# Busy / Idle thresholds
# -----------------------------
# Busy skip (speedtests) if WAN active
BUSY_RX_BYTES_PER_SEC=2500000     # 2.5 MB/s
BUSY_TX_BYTES_PER_SEC=1000000     # 1.0 MB/s
# "Idle enough to autotune"
IDLE_RX_BYTES_PER_SEC=120000      # 120 KB/s
IDLE_TX_BYTES_PER_SEC=60000       # 60 KB/s

# -----------------------------
# Schedules (router local time)
# -----------------------------
DAILY_HOUR=4
DAILY_MINUTE=17

AUTOTUNE_MINUTE=7
AUTOTUNE_EVERY_N_HOURS=3

SELFUPDATE_HOUR=3
SELFUPDATE_MINUTE=33

# -----------------------------
# SQM CAKE options
# -----------------------------
QDISC_OPTS="diffserv4 nat wash rtt 20ms memlimit 32mb"
QDISC_OPTS_INGRESS="diffserv4 nat wash rtt 20ms memlimit 32mb"

# -----------------------------
# Self-update
# -----------------------------
SELFUPDATE_ENABLE=1
GITHUB_RAW_URL="https://raw.githubusercontent.com/CustomMadecode/GODSMODE/master/godsmode.sh"

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
# WAN device resolution (23.05 safe)
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
# Busy / Idle check (bytes/sec over 2 seconds)
# -----------------------------
read_bytes() {
  dev="$1"; dir="$2"
  cat "/sys/class/net/$dev/statistics/${dir}_bytes" 2>/dev/null || echo 0
}

wan_rates() {
  dev="$1"
  b1r="$(read_bytes "$dev" rx)"; b1t="$(read_bytes "$dev" tx)"
  sleep 2
  b2r="$(read_bytes "$dev" rx)"; b2t="$(read_bytes "$dev" tx)"
  rxps=$(((b2r - b1r) / 2))
  txps=$(((b2t - b1t) / 2))
  echo "$rxps $txps"
}

is_link_busy() {
  dev="$1"
  set -- $(wan_rates "$dev")
  rxps="$1"; txps="$2"
  echo "[INFO] WAN load($dev): rx=${rxps}B/s tx=${txps}B/s"
  [ "$rxps" -ge "$BUSY_RX_BYTES_PER_SEC" ] && return 0
  [ "$txps" -ge "$BUSY_TX_BYTES_PER_SEC" ] && return 0
  return 1
}

is_link_idle_enough() {
  dev="$1"
  set -- $(wan_rates "$dev")
  rxps="$1"; txps="$2"
  echo "[INFO] WAN idle-check($dev): rx=${rxps}B/s tx=${txps}B/s"
  [ "$rxps" -le "$IDLE_RX_BYTES_PER_SEC" ] && [ "$txps" -le "$IDLE_TX_BYTES_PER_SEC" ]
}

# -----------------------------
# SQM: enforce single section sqm.wan
# -----------------------------
normalize_sqm_sections() {
  uci -q get sqm.wan >/dev/null 2>&1 || uci -q set sqm.wan='queue' || true

  # remove common conflicting named section
  uci -q delete sqm.eth1 >/dev/null 2>&1 || true

  # neutralize anonymous queues
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
  echo "[OK] SQM applied: ${down}/${up} Mbps"
}

# -----------------------------
# PS5 detection (IPv4)
# -----------------------------
detect_ps5_ips_v4() {
  # 1) If user pinned PS5_IPS_V4, use it
  if [ -n "${PS5_IPS_V4:-}" ]; then
    echo "$PS5_IPS_V4"
    return 0
  fi

  # 2) Try DHCP leases (dnsmasq)
  # Format: <expiry> <mac> <ip> <hostname> <clientid>
  ips="$(awk -v IGNORECASE=1 -v pat="$PS5_HOST_PAT" '
    NF>=4 && $4 ~ pat {print $3}
  ' /tmp/dhcp.leases 2>/dev/null | tr "\n" " " | sed "s/[ ]\+/ /g; s/^ //; s/ $//")"

  [ -n "${ips:-}" ] && { echo "$ips"; return 0; }

  # 3) Fallback: ARP neighbor table for "playstation/sony" (rare)
  # (We can’t reliably map vendor without OUI db, so leave empty if not found)
  echo ""
}

# -----------------------------
# nftables DSCP (game ports + PS5 all traffic) in OUR table
# -----------------------------
NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_SET="game_udp_ports"
PS5_SET4="ps5_v4"

ensure_nft_dscp() {
  [ "$ENABLE_DSCP" -eq 1 ] || { echo "[INFO] DSCP disabled (ENABLE_DSCP=0)."; return 0; }
  have_cmd nft || { echo "[WARN] nft not installed; skipping nft/DSCP."; return 0; }

  nft list table $NFT_TABLE >/dev/null 2>&1 || nft add table $NFT_TABLE >/dev/null 2>&1 || true

  if nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1; then
    nft flush chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 || true
  else
    nft add chain $NFT_TABLE $NFT_CHAIN "{ type filter hook prerouting priority mangle; policy accept; }" >/dev/null 2>&1 || true
  fi

  # game ports set
  if nft list set $NFT_TABLE $GAME_SET >/dev/null 2>&1; then
    nft flush set $NFT_TABLE $GAME_SET >/dev/null 2>&1 || true
  else
    nft add set $NFT_TABLE $GAME_SET "{ type inet_service; flags interval; }" >/dev/null 2>&1 || true
  fi
  nft add element $NFT_TABLE $GAME_SET "$GAME_PORTS" >/dev/null 2>&1 || true

  # PS5 IPv4 set (optional)
  if [ "$ENABLE_PS5_PRIORITY" -eq 1 ]; then
    if nft list set $NFT_TABLE $PS5_SET4 >/dev/null 2>&1; then
      nft flush set $NFT_TABLE $PS5_SET4 >/dev/null 2>&1 || true
    else
      nft add set $NFT_TABLE $PS5_SET4 "{ type ipv4_addr; flags interval; }" >/dev/null 2>&1 || true
    fi

    ps5ips="$(detect_ps5_ips_v4)"
    if [ -n "${ps5ips:-}" ]; then
      for ip in $ps5ips; do
        nft add element $NFT_TABLE $PS5_SET4 "{ $ip }" >/dev/null 2>&1 || true
      done

      # Priority rules FIRST (all PS5 traffic, TCP+UDP)
      nft add rule $NFT_TABLE $NFT_CHAIN ip saddr @$PS5_SET4 ip dscp set $DSCP_GAME counter comment "GM_PS5_DSCP4_S" >/dev/null 2>&1 || true
      nft add rule $NFT_TABLE $NFT_CHAIN ip daddr @$PS5_SET4 ip dscp set $DSCP_GAME counter comment "GM_PS5_DSCP4_D" >/dev/null 2>&1 || true
      echo "[OK] PS5 priority active for IPv4: $ps5ips"
    else
      echo "[WARN] PS5 priority enabled but PS5 not detected in /tmp/dhcp.leases (set PS5_IPS_V4 to pin)."
    fi
  fi

  # Game port DSCP (IPv4 + IPv6)
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip  dscp set $DSCP_GAME counter comment "GM_GAME_DSCP4" >/dev/null 2>&1 || true
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @$GAME_SET ip6 dscp set $DSCP_GAME counter comment "GM_GAME_DSCP6" >/dev/null 2>&1 || true

  echo "[OK] nftables DSCP ensured (counters enabled)."
}

# -----------------------------
# Speedtest (safe)
# -----------------------------
parse_netperf_out() {
  out="$1"

  # Reject known-bad patterns seen on TMHI
  echo "$out" | grep -qiE 'recv_response: partial|invalid number|WARNING: netperf returned errors' && return 1

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
  # Must be idle enough (stronger than busy-skip)
  if ! is_link_idle_enough "$BUSY_DEV"; then
    echo "[SKIP] Not idle enough; skipping speedtest."
    return 2
  fi

  if [ -x /usr/bin/speedtest-netperf.sh ]; then
    echo "[INFO] Running speedtest-netperf.sh (IPv4)..."
    out="$(/usr/bin/speedtest-netperf.sh -4 2>&1 || true)"
    echo "$out" | tail -n 120 | sed 's/\r//g' | while IFS= read -r line; do echo "[ST] $line"; done
    res="$(parse_netperf_out "$out" 2>/dev/null || true)"
    [ -n "${res:-}" ] && { echo "$res"; return 0; }
    echo "[WARN] speedtest-netperf result unusable (TMHI/netperf errors likely)."
  else
    echo "[WARN] speedtest-netperf.sh missing; autotune will not adjust rates."
  fi

  return 1
}

clamp() { v="$1"; min="$2"; max="$3"; [ "$v" -lt "$min" ] && v="$min"; [ "$v" -gt "$max" ] && v="$max"; echo "$v"; }
pct_of() { v="$1"; pct="$2"; echo $(( v * pct / 100 )); }

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
  [ "$rc" -eq 2 ] && return 0

  if [ -z "${res:-}" ]; then
    echo "[WARN] Speedtest failed/unusable; keeping last SQM."
    return 0
  fi

  measured_down="$(echo "$res" | awk '{print $1}')"
  measured_up="$(echo "$res" | awk '{print $2}')"
  [ "${measured_down:-0}" -gt 0 ] && [ "${measured_up:-0}" -gt 0 ] || { echo "[WARN] Speedtest returned 0; keeping last SQM."; return 0; }

  echo "[INFO] Measured: ${measured_down}/${measured_up} Mbps"

  target_down="$(clamp "$(pct_of "$measured_down" "$DOWN_PCT")" "$MIN_DOWN_MBIT" "$CAP_DOWN_MBIT")"
  target_up="$(clamp "$(pct_of "$measured_up" "$UP_PCT")" "$MIN_UP_MBIT" "$CAP_UP_MBIT")"

  echo "[INFO] Target: ${target_down}/${target_up} Mbps"

  prev_down=0; prev_up=0
  if [ -f "$LAST_RATES" ]; then
    prev_down="$(awk '{print $1}' "$LAST_RATES" 2>/dev/null || echo 0)"
    prev_up="$(awk '{print $2}' "$LAST_RATES" 2>/dev/null || echo 0)"
  fi

  apply_up=0; apply_down=0
  change_pct_ge "$target_up" "$prev_up" "$THRESH_UP_PCT" && apply_up=1
  change_pct_ge "$target_down" "$prev_down" "$THRESH_DOWN_PCT" && apply_down=1

  if [ "$apply_up" -eq 0 ] && [ "$apply_down" -eq 0 ]; then
    echo "[OK] Below thresholds; no SQM restart. Keeping ${prev_down}/${prev_up} Mbps"
    return 0
  fi

  echo "[INFO] Applying SQM (prev ${prev_down}/${prev_up})..."
  apply_sqm "$target_down" "$target_up"
}

# -----------------------------
# Base apply (MTU + DSCP + PS5 detect)
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
# Self update (safe)
# -----------------------------
self_update() {
  [ "$SELFUPDATE_ENABLE" -eq 1 ] || return 0
  have_cmd wget || { echo "[WARN] wget not found; selfupdate skipped."; return 0; }

  tmp="/tmp/godsmode.new.$$"
  echo "[INFO] Self-update: fetching $GITHUB_RAW_URL"
  if ! wget -qO "$tmp" "$GITHUB_RAW_URL"; then
    echo "[WARN] Self-update: fetch failed."
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  if [ ! -s "$tmp" ]; then
    echo "[WARN] Self-update: empty download."
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  # Compare (sha256 if available, else cmp)
  changed=1
  if have_cmd sha256sum; then
    a="$(sha256sum "$SELF_PATH" 2>/dev/null | awk "{print \$1}" || true)"
    b="$(sha256sum "$tmp" 2>/dev/null | awk "{print \$1}" || true)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ] && changed=0
  else
    cmp -s "$SELF_PATH" "$tmp" && changed=0 || true
  fi

  if [ "$changed" -eq 0 ]; then
    echo "[OK] Self-update: no change."
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  mv "$tmp" "$SELF_PATH" 2>/dev/null || { echo "[WARN] Self-update: replace failed."; rm -f "$tmp" 2>/dev/null || true; return 0; }
  chmod +x "$SELF_PATH" 2>/dev/null || true
  echo "[OK] Self-update: updated script."
}

# -----------------------------
# Install / Uninstall (procd + cron)
# -----------------------------
install_service_and_cron() {
  echo "[INFO] Installing procd boot service + cron..."

  cat > /etc/init.d/godmode_static <<'INIT'
#!/bin/sh /etc/rc.common
START=95
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /bin/sh -c "sleep 20; /root/godmode/godsmode.sh --apply >>/root/godmode/logs/boot_apply.log 2>&1"
  procd_set_param respawn 0 0 0
  procd_close_instance
}
INIT

  chmod +x /etc/init.d/godmode_static
  /etc/init.d/godmode_static enable >/dev/null 2>&1 || true

  CR=/etc/crontabs/root
  [ -f "$CR" ] || touch "$CR"
  sed -i '/godsmode\.sh/d' "$CR" 2>/dev/null || true

  # Daily apply (base + last SQM, no speedtest)
  echo "$DAILY_MINUTE $DAILY_HOUR * * * /root/godmode/godsmode.sh --apply >>/root/godmode/logs/cron_apply.log 2>&1" >> "$CR"

  # Autotune only when idle enough (safe)
  echo "$AUTOTUNE_MINUTE */$AUTOTUNE_EVERY_N_HOURS * * * /root/godmode/godsmode.sh --autotune >>/root/godmode/logs/autotune_${AUTOTUNE_EVERY_N_HOURS}hour.log 2>&1" >> "$CR"

  # Self update daily
  echo "$SELFUPDATE_MINUTE $SELFUPDATE_HOUR * * * /root/godmode/godsmode.sh --selfupdate >>/root/godmode/logs/selfupdate.log 2>&1" >> "$CR"

  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true

  echo "[DONE] Boot service + cron installed."
}

uninstall_hooks() {
  echo "[INFO] Removing service/cron hooks..."
  /etc/init.d/godmode_static disable >/dev/null 2>&1 || true
  rm -f /etc/init.d/godmode_static 2>/dev/null || true
  CR=/etc/crontabs/root
  [ -f "$CR" ] && sed -i '/godsmode\.sh/d' "$CR" >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
  echo "[DONE] Hooks removed."
}

# -----------------------------
# CLI
# -----------------------------
case "${1:-}" in
  --install)
    self_update || true
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
  --selfupdate)
    self_update || true
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
    echo "  $SELF_PATH                 # apply base + autotune (idle-only)"
    echo "  $SELF_PATH --install       # install boot+cron + run once"
    echo "  $SELF_PATH --apply         # base + last SQM (no speedtest)"
    echo "  $SELF_PATH --autotune      # idle-only speedtest -> adjust SQM"
    echo "  $SELF_PATH --selfupdate    # update from GitHub"
    echo "  $SELF_PATH --uninstall     # remove hooks"
    exit 2
    ;;
esac

exit 0