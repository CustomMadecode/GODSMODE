#!/bin/sh
set -eu

LOCKDIR="/tmp/godmode.lock"
if mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$$" > "$LOCKDIR/pid" 2>/dev/null || true
else
  exit 0
fi
trap "rm -rf \"$LOCKDIR\"" EXIT INT TERM

GODMODE_DIR="/root/godmode"
LOG_DIR="$GODMODE_DIR/logs"
STATE_DIR="$GODMODE_DIR/state"
LOG="$LOG_DIR/godmode.log"

GAME_FLAG="$STATE_DIR/game_active.flag"
PREV_STATE_FILE="$STATE_DIR/prev_state.txt"
HOLD_FILE="/tmp/gm_hold_until"
SCORE_FILE="/tmp/gm_score"

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 700 "$GODMODE_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

exec >>"$LOG" 2>&1
echo "=== GOD MODE START $(date) ==="
echo "[INFO] Kernel: $(uname -r 2>/dev/null || echo unknown)"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

BASE_DOWN=712
BASE_UP=95
GAME_DOWN=680
GAME_UP=90

MTU_NORMAL=1500
MTU_GAME=1370
DSCP_GAME=46
HOLD_SECONDS=300

SQM_IF="$(uci -q get sqm.@queue[0].interface 2>/dev/null || true)"
[ -z "${SQM_IF:-}" ] && SQM_IF="wan"

set_mtu_safe() { ip link set mtu "$2" dev "$1" >/dev/null 2>&1 || true; }

apply_sqm() {
  down="$1"; up="$2"
  [ -x /etc/init.d/sqm ] || { echo "[WARN] SQM not installed; skipping."; return 0; }

  uci -q set sqm.@queue[0].interface="$SQM_IF" || true
  uci -q set sqm.@queue[0].qdisc="cake" || true
  uci -q set sqm.@queue[0].script="piece_of_cake.qos" || true
  uci -q set sqm.@queue[0].download="$((down * 1000))" || true
  uci -q set sqm.@queue[0].upload="$((up * 1000))" || true
  uci -q set sqm.@queue[0].qdisc_advanced="1" || true
  uci -q set sqm.@queue[0].qdisc_really_really_advanced="1" || true
  uci -q set sqm.@queue[0].ingress_ecn="ECN" || true
  uci -q set sqm.@queue[0].egress_ecn="ECN" || true
  uci -q set sqm.@queue[0].qdisc_opts="diffserv4 nat wash nowash_ack no-ack-filter rtt 20ms memlimit 16mb besteffort" || true
  uci -q set sqm.@queue[0].qdisc_opts_ingress="diffserv4 nat wash nowash_ack no-ack-filter rtt 20ms memlimit 32mb besteffort" || true
  uci -q commit sqm >/dev/null 2>&1 || true
  /etc/init.d/sqm restart >/dev/null 2>&1 || true
  echo "[OK] SQM CAKE set: ${down}/${up} Mbps"
}

NFT_TABLE="inet godmode"
NFT_CHAIN="prerouting_mangle"
GAME_DETECT_SET="game_detect_ports"

ensure_nft() {
  have_cmd nft || { echo "[WARN] nft not installed; skipping."; return 0; }

  nft list table $NFT_TABLE >/dev/null 2>&1 || nft add table $NFT_TABLE >/dev/null 2>&1 || true

  nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 && nft flush chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 || true
  nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1 || \
    nft add chain $NFT_TABLE $NFT_CHAIN "{ type filter hook prerouting priority -150; policy accept; }" >/dev/null 2>&1 || true

  nft list set $NFT_TABLE $GAME_DETECT_SET >/dev/null 2>&1 && nft flush set $NFT_TABLE $GAME_DETECT_SET >/dev/null 2>&1 || true
  nft list set $NFT_TABLE $GAME_DETECT_SET >/dev/null 2>&1 || \
    nft add set $NFT_TABLE $GAME_DETECT_SET "{ type inet_service; flags interval; }" >/dev/null 2>&1 || true

  nft add element $NFT_TABLE $GAME_DETECT_SET "{ 3074, 3478-3479, 3659, 9295-9304, 1935 }" >/dev/null 2>&1 || true

  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @"$GAME_DETECT_SET" counter comment "GM_GAME_UDP_COUNTER" >/dev/null 2>&1 || true

  # ✅ FIXED: DSCP value now correctly set
  nft add rule $NFT_TABLE $NFT_CHAIN udp dport @"$GAME_DETECT_SET" ip dscp set '"$DSCP_GAME"' comment "GM_GAME_DSCP" >/dev/null 2>&1 || true

  echo "[OK] nftables ensured (GM_GAME_UDP_COUNTER + DSCP)."
}

get_game_udp_pkts() {
  have_cmd nft || { echo 0; return; }
  nft -a list chain $NFT_TABLE $NFT_CHAIN 2>/dev/null | \
    awk '/GM_GAME_UDP_COUNTER/ && /packets/ {for(i=1;i<=NF;i++){if($i=="packets"){print $(i+1); exit}}}'
}

enable_game_mode() {
  [ -f "$GAME_FLAG" ] && return 0
  apply_sqm "$GAME_DOWN" "$GAME_UP"
  set_mtu_safe "$SQM_IF" "$MTU_GAME"
  touch "$GAME_FLAG"
  echo "GAME MODE ENABLED"
}

disable_game_mode() {
  [ -f "$GAME_FLAG" ] || return 0
  apply_sqm "$BASE_DOWN" "$BASE_UP"
  set_mtu_safe "$SQM_IF" "$MTU_NORMAL"
  rm -f "$GAME_FLAG" 2>/dev/null || true
  echo "GAME MODE DISABLED"
}

apply_sqm "$BASE_DOWN" "$BASE_UP"
ensure_nft
set_mtu_safe "$SQM_IF" "$MTU_NORMAL"
[ -f "$PREV_STATE_FILE" ] || echo normal > "$PREV_STATE_FILE"
[ -f "$SCORE_FILE" ] || echo 0 > "$SCORE_FILE"
[ -f "$HOLD_FILE" ] || echo 0 > "$HOLD_FILE"

echo "=== GOD MODE ACTIVE $(date) (SQM_IF=$SQM_IF) ==="

prev_pkts="$(get_game_udp_pkts 2>/dev/null || echo 0)"; [ -z "${prev_pkts:-}" ] && prev_pkts=0

while true; do
  now_pkts="$(get_game_udp_pkts 2>/dev/null || echo 0)"
  [ -z "${now_pkts:-}" ] && now_pkts="$prev_pkts"

  delta=$((now_pkts - prev_pkts))
  prev_pkts="$now_pkts"

  now="$(date +%s)"
  hold_until="$(cat "$HOLD_FILE" 2>/dev/null || echo 0)"
  score="$(cat "$SCORE_FILE" 2>/dev/null || echo 0)"

  if [ "$delta" -gt 10 ]; then
    score=$((score + 5))
    hold_until=$((now + HOLD_SECONDS))
    echo "$hold_until" > "$HOLD_FILE" 2>/dev/null || true
  else
    score=$((score - 1))
  fi

  [ "$score" -lt 0 ] && score=0
  [ "$score" -gt 30 ] && score=30
  echo "$score" > "$SCORE_FILE" 2>/dev/null || true

  if [ "$score" -ge 12 ] || [ "$now" -lt "$hold_until" ]; then
    enable_game_mode
    state=game
  else
    disable_game_mode
    state=normal
  fi

  prev_state="$(cat "$PREV_STATE_FILE" 2>/dev/null || echo normal)"
  if [ "$state" != "$prev_state" ]; then
    echo "$state" > "$PREV_STATE_FILE" 2>/dev/null || true
    echo "[LIVE] $state pktsΔ=$delta score=$score hold_until=$hold_until"
  fi

  sleep 2
done
