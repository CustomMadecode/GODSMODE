#!/bin/sh
# ============================================================
# Flint 2 GOD MODE — OpenWrt / BusyBox / Kernel 5.4 SAFE
# - Live decisions: CAKE stats (tc -s) + nft counters + optional telemetry
# - nftables DSCP tagging + game detection counters (no conntrack polling)
# - SQM CAKE tuned for low latency; only adjusts on state changes
# - Optional uplink ACK prioritization for smoother upload gaming/voice
# ============================================================

set -eu

# -----------------------
# Single-instance guard (FIXED)
# -----------------------
PIDFILE="/tmp/godmode.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
echo $$ > "$PIDFILE"

# -----------------------
# Paths / Logging
# -----------------------
GODMODE_DIR="/root/godmode"
LOG_DIR="$GODMODE_DIR/logs"
STATE_DIR="$GODMODE_DIR/state"
CREDS_DIR="$GODMODE_DIR/credentials"
TELEM_DIR="$GODMODE_DIR/telemetry"
FLENT_DIR="$GODMODE_DIR/flent"

LOG="$LOG_DIR/godmode.log"
SLA_LOG="$LOG_DIR/isp_sla.log"
TELEM_LATEST="$TELEM_DIR/latest.json"
GAME_FLAG="$STATE_DIR/game_active.flag"
PREV_STATE_FILE="$STATE_DIR/prev_state.txt"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$CREDS_DIR" "$TELEM_DIR" "$FLENT_DIR"
chmod 700 "$GODMODE_DIR" "$LOG_DIR" "$STATE_DIR" "$CREDS_DIR" "$TELEM_DIR" "$FLENT_DIR"

exec >>"$LOG" 2>&1
echo "=== GOD MODE START $(date) ==="

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -----------------------
# Read secrets (optional)
# -----------------------
# /root/godmode/credentials/secrets.env (chmod 600)
SECRETS="$CREDS_DIR/secrets.env"
if [ -f "$SECRETS" ]; then
  chmod 600 "$SECRETS" || true
  # shellcheck disable=SC1090
  . "$SECRETS"
else
  echo "[WARN] Missing $SECRETS (Telegram + modem reboot optional)."
fi

send_telegram() {
  [ "${TG_BOT_TOKEN:-}" = "" ] && return 0
  [ "${TG_CHAT:-}" = "" ] && return 0
  msg="$1"
  api="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  curl -s -X POST "$api" -d chat_id="$TG_CHAT" -d text="$msg" >/dev/null 2>&1 || true
}

# -----------------------
# Kernel version guard
# -----------------------
KVER="$(uname -r 2>/dev/null || echo unknown)"
echo "[INFO] Kernel: $KVER"

# -----------------------
# Speeds / Profiles
# -----------------------
MAX_DOWN=750
MAX_UP=100

BASE_DOWN=712   # ~95% of 750
BASE_UP=95      # ~95% of 100

GAME_DOWN=680
GAME_UP=90

TIGHT_DOWN_STEP=40
TIGHT_UP_STEP=6

# MTU
MTU_NORMAL=1500
MTU_GAME=1370

# -----------------------
# DSCP tuning (UPDATED)
# -----------------------
# CAKE diffserv4 typically treats:
# - EF (46) as highest priority (voice)
# - CS5 as high priority (gaming)
# - CS4 as high-ish (ACK/control)
#
# Use *narrow* matches so EF isn't applied broadly.
DSCP_GAME="cs5"   # safer default for gaming packets
DSCP_VOICE="ef"   # voice/party chat only
DSCP_ACK="cs4"    # tiny ACK/SYN for smoother upload

# Optional uplink ACK prioritization (UPDATED)
ACK_PRIORITY=1    # 1=on, 0=off
ACK_LEN_MAX=96    # treat very small packets as ACK/control

# ISP watchdog
MODEM_IP="192.168.1.1"
ISP_THRESHOLD_LATENCY_MS=50
ISP_THRESHOLD_PACKETLOSS_PCT=1
ISP_FAIL_LIMIT=3

# Telemetry UDP
TELEM_UDP_PORT=32123

# Loop throttling
BASE_LOOP_SLEEP=2
HIGH_CPU_SLEEP=5
CPU_LOAD_HIGH=2.0

cpu_sleep() {
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")"
  if have_cmd bc && [ "$(echo "$load > $CPU_LOAD_HIGH" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
    echo "$HIGH_CPU_SLEEP"
  else
    echo "$BASE_LOOP_SLEEP"
  fi
}

# -----------------------
# SQM interface detection
# -----------------------
SQM_IF="$(uci -q get sqm.@queue[0].interface 2>/dev/null || true)"
[ "$SQM_IF" = "" ] && SQM_IF="wan"

set_mtu_safe() {
  dev="$1"; mtu="$2"
  ip link set mtu "$mtu" dev "$dev" >/dev/null 2>&1 || true
}

# ============================================================
# CAKE tuned parameters (kernel 5.4 safe)
# ============================================================
configure_sqm_cake() {
  [ -x /etc/init.d/sqm ] || { echo "[ERROR] SQM not installed."; return 1; }

  # NOTE: Keep your original conservative opts. If you want, you can switch
  # no-ack-filter -> ack-filter later, but we already do ACK DSCP marking below.
  egress_opts="diffserv4 nat wash nowash_ack no-ack-filter rtt 20ms memlimit 16mb besteffort"
  ingress_opts="diffserv4 nat wash nowash_ack no-ack-filter rtt 20ms memlimit 32mb besteffort"

  uci -q set sqm.@queue[0].interface="$SQM_IF"
  uci -q set sqm.@queue[0].qdisc="cake"
  uci -q set sqm.@queue[0].script="piece_of_cake.qos"

  uci -q set sqm.@queue[0].download="$((BASE_DOWN * 1000))"
  uci -q set sqm.@queue[0].upload="$((BASE_UP * 1000))"

  uci -q set sqm.@queue[0].qdisc_advanced="1"
  uci -q set sqm.@queue[0].qdisc_really_really_advanced="1"

  uci -q set sqm.@queue[0].ingress_ecn="ECN"
  uci -q set sqm.@queue[0].egress_ecn="ECN"

  uci -q set sqm.@queue[0].qdisc_opts="$egress_opts"
  uci -q set sqm.@queue[0].qdisc_opts_ingress="$ingress_opts"
  uci -q set sqm.@queue[0].cake_opts="$egress_opts"
  uci -q set sqm.@queue[0].cake_opts_ingress="$ingress_opts"

  uci -q commit sqm
  /etc/init.d/sqm restart >/dev/null 2>&1 || true
  echo "[OK] SQM CAKE configured: ${BASE_DOWN}/${BASE_UP} Mbps (tuned)"
}

apply_sqm_bandwidth_only() {
  down="$1"; up="$2"
  uci -q set sqm.@queue[0].download="$((down * 1000))"
  uci -q set sqm.@queue[0].upload="$((up * 1000))"
  uci -q commit sqm
  /etc/init.d/sqm restart >/dev/null 2>&1 || true
}

# -----------------------
# nftables DSCP + detection (UPDATED)
# -----------------------
NFT_TABLE="inet godmode"
CHAIN_PRE="prerouting_mangle"
CHAIN_POST="postrouting_mangle"

SET_DETECT="gm_detect_ports"
SET_GAME="gm_game_ports"
SET_VOICE="gm_voice_ports"

ensure_nft() {
  have_cmd nft || { echo "[ERROR] nft not found. Install firewall4/nftables."; return 1; }

  nft list table $NFT_TABLE >/dev/null 2>&1 || nft add table $NFT_TABLE

  # Chains: prerouting for LAN->router path marking; postrouting for oif matching (ACK priority)
  nft list chain $NFT_TABLE $CHAIN_PRE >/dev/null 2>&1 && nft flush chain $NFT_TABLE $CHAIN_PRE || true
  nft list chain $NFT_TABLE $CHAIN_PRE >/dev/null 2>&1 || \
    nft add chain $NFT_TABLE $CHAIN_PRE "{ type filter hook prerouting priority -150; policy accept; }"

  nft list chain $NFT_TABLE $CHAIN_POST >/dev/null 2>&1 && nft flush chain $NFT_TABLE $CHAIN_POST || true
  nft list chain $NFT_TABLE $CHAIN_POST >/dev/null 2>&1 || \
    nft add chain $NFT_TABLE $CHAIN_POST "{ type filter hook postrouting priority -150; policy accept; }"

  # Sets
  for s in $SET_DETECT $SET_GAME $SET_VOICE; do
    nft list set $NFT_TABLE $s >/dev/null 2>&1 && nft flush set $NFT_TABLE $s || true
  done

  nft list set $NFT_TABLE $SET_DETECT >/dev/null 2>&1 || \
    nft add set $NFT_TABLE $SET_DETECT "{ type inet_service; flags interval; }"

  nft list set $NFT_TABLE $SET_GAME >/dev/null 2>&1 || \
    nft add set $NFT_TABLE $SET_GAME "{ type inet_service; flags interval; }"

  nft list set $NFT_TABLE $SET_VOICE >/dev/null 2>&1 || \
    nft add set $NFT_TABLE $SET_VOICE "{ type inet_service; flags interval; }"

  # -----------------------
  # Port sets (UPDATED)
  # -----------------------

  # Tight detect set: used ONLY to detect "gaming happening"
  # (Avoid huge ephemeral ranges here to prevent false positives.)
  nft add element $NFT_TABLE $SET_DETECT "{ \
    3074, 3075, \
    3478-3479, 3480, \
    3659, \
    27000-27200, \
    9295-9304 \
  }" 2>/dev/null || true

  # Broader game mark set: includes common Xbox/PSN/Steam + a few widely used game service ports.
  # Still avoids 49152-65535, which tags too much.
  nft add element $NFT_TABLE $SET_GAME "{ \
    53, \
    88, 500, 3544, 4500, \
    3074-3075, \
    3478-3480, \
    3659, \
    27000-27200, \
    10000-10100, \
    1935, \
    9295-9304 \
  }" 2>/dev/null || true

  # Voice ports: SIP + RTP ranges (common), plus WebRTC STUN/TURN ports.
  # Keep narrow enough to not over-prioritize random traffic.
  nft add element $NFT_TABLE $SET_VOICE "{ \
    3478-3481, \
    5004-5005, \
    5060-5061, \
    10000-20000 \
  }" 2>/dev/null || true

  # -----------------------
  # Rules (UPDATED)
  # -----------------------

  # 1) Detection counter (tight)
  nft add rule $NFT_TABLE $CHAIN_PRE udp dport @"$SET_DETECT" counter comment "GM_GAME_UDP_COUNTER" 2>/dev/null || true

  # 2) Voice gets EF (highest) - only UDP voice ports
  nft add rule $NFT_TABLE $CHAIN_PRE udp dport @"$SET_VOICE" ip dscp set $DSCP_VOICE comment "GM_VOICE_EF" 2>/dev/null || true

  # 3) Game gets CS5 - UDP game ports
  nft add rule $NFT_TABLE $CHAIN_PRE udp dport @"$SET_GAME" ip dscp set $DSCP_GAME comment "GM_GAME_CS5" 2>/dev/null || true

  # 4) Optional ACK/control prioritization (postrouting to ensure uplink)
  if [ "${ACK_PRIORITY:-0}" = "1" ]; then
    # Tiny TCP packets (ACK/SYN, control) often matter most for responsiveness under upload load.
    # Match small IP length; avoid SYN/FIN/RST combos that can be weird.
    nft add rule $NFT_TABLE $CHAIN_POST \
      oifname "$SQM_IF" tcp flags & ack == ack ip length < $ACK_LEN_MAX \
      ip dscp set $DSCP_ACK comment "GM_ACK_CS4" 2>/dev/null || true

    nft add rule $NFT_TABLE $CHAIN_POST \
      oifname "$SQM_IF" tcp flags & syn == syn ip length < $ACK_LEN_MAX \
      ip dscp set $DSCP_ACK comment "GM_SYN_CS4" 2>/dev/null || true
  fi

  echo "[OK] nftables ensured (DSCP voice/game + detection counter + optional ACK priority)."
}

get_game_udp_pkts() {
  nft -a list chain $NFT_TABLE $CHAIN_PRE 2>/dev/null \
    | awk '/GM_GAME_UDP_COUNTER/ && /counter/ {for(i=1;i<=NF;i++){if($i=="packets"){print $(i+1); exit}}}' \
    | head -n1
}

# -----------------------
# CAKE stats ingestion
# -----------------------
get_cake_stats() {
  out="$(tc -s qdisc show dev "$SQM_IF" 2>/dev/null || true)"

  drops="$(echo "$out" | awk '
    {for(i=1;i<=NF;i++) if($i=="dropped") sum+=$(i+1)}
    END{if(sum=="") sum=0; print sum}
  ')"

  backlog="$(echo "$out" | awk '
    {for(i=1;i<=NF;i++) if($i=="backlog"){gsub("b","",$(i+1)); sum+=$(i+1)}}
    END{if(sum=="") sum=0; print sum}
  ')"

  echo "$drops $backlog"
}

cake_congestion_score() {
  dd="$1"; backlog="$2"
  if [ "$dd" -gt 0 ]; then echo "0.85"; return; fi
  if [ "$backlog" -gt 200000 ]; then echo "0.75"; return; fi
  if [ "$backlog" -gt 50000 ]; then echo "0.55"; return; fi
  echo "0.20"
}

# -----------------------
# Telemetry listener (optional)
# -----------------------
start_telem_listener() {
  if have_cmd python3; then
    cat > "$TELEM_DIR/udp_listener.py" <<'PY'
import json, socket, time, os
PORT=int(os.environ.get("TELEM_UDP_PORT","32123"))
OUT=os.environ.get("TELEM_LATEST","/tmp/latest.json")
sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))
sock.settimeout(1.0)
while True:
    try:
        data, addr = sock.recvfrom(4096)
        s=data.decode("utf-8","ignore").strip()
        obj=json.loads(s)
        obj["_src"]=addr[0]
        obj["_ts"]=time.time()
        with open(OUT,"w") as f:
            json.dump(obj,f)
    except socket.timeout:
        pass
    except Exception:
        pass
PY
    pgrep -f "$TELEM_DIR/udp_listener.py" >/dev/null 2>&1 || \
      TELEM_UDP_PORT="$TELEM_UDP_PORT" TELEM_LATEST="$TELEM_LATEST" nohup python3 "$TELEM_DIR/udp_listener.py" >/dev/null 2>&1 &
    echo "[OK] Telemetry listener on UDP :$TELEM_UDP_PORT"
  else
    echo "[WARN] python3 missing; telemetry disabled."
  fi
}

read_telem() {
  if [ -f "$TELEM_LATEST" ] && have_cmd jq; then
    fps="$(jq -r '.fps // 0' "$TELEM_LATEST" 2>/dev/null || echo 0)"
    ft="$(jq -r '.frame_ms // 0' "$TELEM_LATEST" 2>/dev/null || echo 0)"
    game="$(jq -r '.game // "unknown"' "$TELEM_LATEST" 2>/dev/null || echo unknown)"
    device="$(jq -r '.device // "unknown"' "$TELEM_LATEST" 2>/dev/null || echo unknown)"
    echo "$fps $ft $game $device"
  else
    echo "0 0 unknown unknown"
  fi
}

# -----------------------
# Flent calibration (NOT live loop)
# -----------------------
run_flent_calibration() {
  [ -f "$GAME_FLAG" ] && return 0
  have_cmd flent || return 0
  have_cmd jq || return 0

  ts="$(date +%F_%H%M%S)"
  jsonfile="$FLENT_DIR/rrul_${ts}.json"

  flent rrul -l 60 -H 1.1.1.1 -f json -o "$jsonfile" >/dev/null 2>&1 || return 0
  find "$FLENT_DIR" -type f -mtime +30 -delete >/dev/null 2>&1 || true
}

# -----------------------
# Game mode enable/disable
# (DSCP tagging happens regardless; game mode focuses on SQM+MTU profile)
# -----------------------
enable_game_mode() {
  [ -f "$GAME_FLAG" ] && return 0
  apply_sqm_bandwidth_only "$GAME_DOWN" "$GAME_UP"
  set_mtu_safe "$SQM_IF" "$MTU_GAME"
  touch "$GAME_FLAG"
  send_telegram "[GAME MODE] ON SQM=${GAME_DOWN}/${GAME_UP} MTU=${MTU_GAME} DSCP(game=${DSCP_GAME}, voice=${DSCP_VOICE}, ack=${DSCP_ACK})"
  echo "GAME MODE ENABLED"
}

disable_game_mode() {
  [ -f "$GAME_FLAG" ] || return 0
  apply_sqm_bandwidth_only "$BASE_DOWN" "$BASE_UP"
  set_mtu_safe "$SQM_IF" "$MTU_NORMAL"
  rm -f "$GAME_FLAG"
  send_telegram "[GAME MODE] OFF SQM=${BASE_DOWN}/${BASE_UP} MTU=${MTU_NORMAL}"
  echo "GAME MODE DISABLED"
}

# -----------------------
# ISP SLA + modem reboot escalation (optional)
# -----------------------
check_isp() {
  pr="$(ping -c 5 1.1.1.1 2>/dev/null | tail -1 | awk -F '/' '{print $5}' | awk '{print int($1)}')"
  [ "$pr" = "" ] && pr=999
  pl="$(ping -c 5 1.1.1.1 2>/dev/null | awk -F'%' '/packet loss/ {gsub(/ /,""); print int($1)}' | tail -1)"
  [ "$pl" = "" ] && pl=100

  echo "$(date) | Latency: ${pr} ms | Loss: ${pl}%" >> "$SLA_LOG"

  fail_file="$STATE_DIR/isp_fail_count"
  [ -f "$fail_file" ] || echo "0" > "$fail_file"
  fail_count="$(cat "$fail_file" 2>/dev/null || echo 0)"

  if [ "$pr" -gt "$ISP_THRESHOLD_LATENCY_MS" ] || [ "$pl" -gt "$ISP_THRESHOLD_PACKETLOSS_PCT" ]; then
    fail_count=$((fail_count + 1))
    echo "$fail_count" > "$fail_file"
    send_telegram "[ISP] Lat ${pr}ms Loss ${pl}% (fail ${fail_count}/${ISP_FAIL_LIMIT})"

    if [ "$fail_count" -ge "$ISP_FAIL_LIMIT" ]; then
      echo "0" > "$fail_file"
      send_telegram "[ISP] Reboot modem @ ${MODEM_IP}"
      if [ "${MODEM_USER:-}" != "" ] && [ "${MODEM_PASS:-}" != "" ]; then
        curl -s -u "$MODEM_USER:$MODEM_PASS" "http://${MODEM_IP}/reboot.htm" -X POST >/dev/null 2>&1 || true
      fi
    fi
  else
    echo "0" > "$fail_file"
  fi
}

# -----------------------
# MAIN LOOP
# - Detect gaming via nft counter delta (tight set)
# - Congestion via CAKE backlog/drops delta
# - Telemetry bias via frame_ms
# -----------------------
main_loop() {
  prev_pkts="$(get_game_udp_pkts || echo 0)"; [ "$prev_pkts" = "" ] && prev_pkts=0

  set -- $(get_cake_stats)
  prev_drops="$1"; [ "$prev_drops" = "" ] && prev_drops=0

  [ -f "$PREV_STATE_FILE" ] || echo "normal" > "$PREV_STATE_FILE"

  while true; do
    now_pkts="$(get_game_udp_pkts || echo 0)"
    [ "$now_pkts" = "" ] && now_pkts="$prev_pkts"
    delta_pkts=$((now_pkts - prev_pkts))
    prev_pkts="$now_pkts"

    set -- $(get_cake_stats)
    drops="$1"; backlog="$2"
    [ "$drops" = "" ] && drops="$prev_drops"
    dd=$((drops - prev_drops))
    prev_drops="$drops"

    cake_conf="$(cake_congestion_score "$dd" "$backlog")"

    set -- $(read_telem)
    fps="$1"; ft="$2"; game="$3"; device="$4"

    telem_bias="0"
    if have_cmd bc && [ "$ft" != "0" ] && [ "$(echo "$ft > 20.0" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
      telem_bias="1"
    fi

    # -----------------------
    # Game mode toggling (DEBOUNCED HOLD — UPDATED)
    # - Uses score + hold to prevent flapping
    # -----------------------
    hold_file="$STATE_DIR/gm_hold_until"
    score_file="$STATE_DIR/gm_score"
    [ -f "$score_file" ] || echo 0 > "$score_file"
    [ -f "$hold_file" ] || echo 0 > "$hold_file"

    now="$(date +%s)"
    hold_until="$(cat "$hold_file" 2>/dev/null || echo 0)"
    score="$(cat "$score_file" 2>/dev/null || echo 0)"

    if [ "$delta_pkts" -gt 10 ]; then
      score=$((score + 5))
      hold_until=$((now + 300))
      echo "$hold_until" > "$hold_file"
    else
      score=$((score - 1))
    fi

    [ "$score" -lt 0 ] && score=0
    [ "$score" -gt 30 ] && score=30
    echo "$score" > "$score_file"

    if [ "$score" -ge 12 ] || [ "$now" -lt "$hold_until" ]; then
      enable_game_mode
    else
      disable_game_mode
    fi

    # -----------------------
    # Tighten logic
    # -----------------------
    prev_state="$(cat "$PREV_STATE_FILE" 2>/dev/null || echo normal)"
    new_state="$prev_state"
    target_down="$BASE_DOWN"
    target_up="$BASE_UP"

    if [ -f "$GAME_FLAG" ]; then
      target_down="$GAME_DOWN"
      target_up="$GAME_UP"

      if have_cmd bc && [ "$(echo "$cake_conf >= 0.75" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        target_down=$((GAME_DOWN - TIGHT_DOWN_STEP))
        target_up=$((GAME_UP - TIGHT_UP_STEP))
        new_state="game_tight"
      elif [ "$telem_bias" = "1" ]; then
        target_down=$((GAME_DOWN - 30))
        target_up=$((GAME_UP - 4))
        new_state="game_telem_tight"
      else
        new_state="game_base"
      fi
    else
      if have_cmd bc && [ "$(echo "$cake_conf >= 0.75" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        target_down=$((BASE_DOWN - 60))
        target_up=$((BASE_UP - 8))
        new_state="normal_tight"
      else
        new_state="normal"
      fi
    fi

    if [ "$new_state" != "$prev_state" ]; then
      echo "$new_state" > "$PREV_STATE_FILE"
      apply_sqm_bandwidth_only "$target_down" "$target_up"
      send_telegram "[LIVE] ${new_state} SQM=${target_down}/${target_up} cake=${cake_conf} dropsΔ=${dd} backlog=${backlog}B pktsΔ=${delta_pkts} score=${score} fps=${fps} ft=${ft}ms"
      echo "[LIVE] ${new_state} SQM=${target_down}/${target_up} cake=${cake_conf} dropsΔ=${dd} backlog=${backlog}B pktsΔ=${delta_pkts} score=${score} fps=${fps} ft=${ft}ms"
    fi

    # ISP check every ~30s
    tick_file="$STATE_DIR/tick"
    [ -f "$tick_file" ] || echo "0" > "$tick_file"
    t="$(cat "$tick_file" 2>/dev/null || echo 0)"
    t=$((t + 1))
    echo "$t" > "$tick_file"
    if [ $((t % 15)) -eq 0 ]; then
      check_isp
    fi

    sleep "$(cpu_sleep)"
  done
}

# -----------------------
# One-time setup
# -----------------------
configure_sqm_cake || true
ensure_nft || true
start_telem_listener || true

echo "[INFO] Kernel 5.4 mode: eBPF/XDP probes are OPTIONAL and not required."

set_mtu_safe "$SQM_IF" "$MTU_NORMAL"

# Persist on reboot (OpenWrt may not have full crontab; keep best-effort)
if have_cmd crontab; then
  crontab -l 2>/dev/null | grep -v "$GODMODE_DIR/godmode.sh" > /tmp/cron.godmode 2>/dev/null || true
  echo "@reboot /bin/sh $GODMODE_DIR/godmode.sh" >> /tmp/cron.godmode
  crontab /tmp/cron.godmode >/dev/null 2>&1 || true
  rm -f /tmp/cron.godmode
fi

echo "=== GOD MODE ACTIVE $(date) (SQM_IF=$SQM_IF) ==="
main_loop
