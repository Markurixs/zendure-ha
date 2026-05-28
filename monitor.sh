#!/usr/bin/env bash
# Collects observability metrics from the HA SQLite DB for the fork's
# 24-48h observation window.
#
# Usage:
#   ./monitor.sh pre    # snapshot baseline BEFORE deploy
#   ./monitor.sh post   # snapshot AFTER deploy + delta-compare to pre
#   ./monitor.sh tail   # live-tail Zendure-related log lines
#
# Snapshots are stored at /tmp/zendure_fork_metrics_<phase>.txt on the
# HA host AND fetched to ./metrics/ locally for diffing.
#
# Metrics collected:
#   - regulator activity:  count of zendure_manager.power state changes / 1h
#   - deadzone skips:      sensor.zendure_manager_deadzone_skips_total delta
#   - grid bezug:          ecotracker_zahler_bezug delta
#   - grid einspeisung:    ecotracker_zahler_einspeisung delta
#   - error-log count:     grep zendure errors in ha core logs
#   - p1 update rate:      ecotracker_leistung updates / 5min

set -euo pipefail

HA_HOST="root@192.168.44.250"
PHASE="${1:-pre}"
LOCAL_OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/metrics"
REMOTE_OUT="/tmp/zendure_fork_metrics_${PHASE}.txt"

mkdir -p "$LOCAL_OUT"

snapshot() {
  local phase="$1"
  info "Collecting snapshot phase=$phase to $REMOTE_OUT"
  ssh "$HA_HOST" "bash -s" <<EOF >"$LOCAL_OUT/${phase}.txt"
set -u
echo "=== ZENDURE FORK METRICS — PHASE: $phase ==="
echo "Timestamp: \$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

DB=/config/home-assistant_v2.db
NOW=\$(date +%s)
T_1H=\$((NOW - 3600))
T_24H=\$((NOW - 86400))
T_5M=\$((NOW - 300))

echo "--- P1 update rate (ecotracker_leistung, last 5min) ---"
sqlite3 "\$DB" "SELECT COUNT(*) as updates_5min FROM states s
  JOIN states_meta sm ON s.metadata_id=sm.metadata_id
  WHERE sm.entity_id='sensor.ecotracker_leistung' AND s.last_updated_ts > \$T_5M;"

echo ""
echo "--- Zendure manager power state changes (last 1h) ---"
sqlite3 "\$DB" "SELECT COUNT(*) as power_updates_1h FROM states s
  JOIN states_meta sm ON s.metadata_id=sm.metadata_id
  WHERE sm.entity_id='sensor.zendure_manager_power' AND s.last_updated_ts > \$T_1H;"

echo ""
echo "--- Zendure manager state distribution (last 24h) ---"
sqlite3 "\$DB" "SELECT s.state, COUNT(*) as cnt FROM states s
  JOIN states_meta sm ON s.metadata_id=sm.metadata_id
  WHERE sm.entity_id='sensor.zendure_manager_operation_state'
    AND s.last_updated_ts > \$T_24H
  GROUP BY s.state ORDER BY cnt DESC;"

echo ""
echo "--- Deadzone skips counter (current value) ---"
sqlite3 "\$DB" "SELECT s.state FROM states s
  JOIN states_meta sm ON s.metadata_id=sm.metadata_id
  WHERE sm.entity_id='sensor.zendure_manager_deadzone_skips_total'
  ORDER BY s.last_updated_ts DESC LIMIT 1;" 2>/dev/null || echo "n/a (fork not deployed?)"

echo ""
echo "--- Grid totals (last 24h, kWh delta) ---"
for ent in sensor.ecotracker_zahler_bezug sensor.ecotracker_zahler_einspeisung; do
  result=\$(sqlite3 "\$DB" "
    SELECT
      ROUND(CAST((SELECT s.state FROM states s
                   JOIN states_meta sm ON s.metadata_id=sm.metadata_id
                   WHERE sm.entity_id='\$ent' AND s.state NOT IN ('unknown','unavailable')
                   ORDER BY s.last_updated_ts DESC LIMIT 1) AS REAL)
         - CAST((SELECT s.state FROM states s
                   JOIN states_meta sm ON s.metadata_id=sm.metadata_id
                   WHERE sm.entity_id='\$ent' AND s.state NOT IN ('unknown','unavailable')
                     AND s.last_updated_ts < \$T_24H
                   ORDER BY s.last_updated_ts DESC LIMIT 1) AS REAL), 3);
  ")
  printf "  %-45s %s kWh\n" "\$ent" "\$result"
done

echo ""
echo "--- Cluster aggregations (current) ---"
for ent in sensor.zendure_cluster_soc sensor.zendure_cluster_output sensor.zendure_cluster_input sensor.zendure_cluster_solinput sensor.zendure_cluster_bilanz; do
  v=\$(sqlite3 "\$DB" "SELECT s.state FROM states s
        JOIN states_meta sm ON s.metadata_id=sm.metadata_id
        WHERE sm.entity_id='\$ent' ORDER BY s.last_updated_ts DESC LIMIT 1;")
  printf "  %-40s %s\n" "\$ent" "\$v"
done

echo ""
echo "--- Zendure-related errors in HA log (last 200 lines) ---"
ha core logs --lines 200 2>&1 | grep -iE 'zendure|hyper' | grep -iE 'error|warning|exception' | tail -10 || echo "  (no errors)"

echo ""
echo "--- Manifest version installed ---"
python3 -c "import json; print(json.load(open('/config/custom_components/zendure_ha/manifest.json'))['version'])" 2>&1 || echo "  (not installed)"
EOF
  ok "Snapshot saved: $LOCAL_OUT/${phase}.txt"
}

color()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()   { color '36' "[INFO] $*"; }
ok()     { color '32' "[ OK ] $*"; }
err()    { color '31' "[ERR ] $*" >&2; }

diff_phases() {
  if [[ ! -f "$LOCAL_OUT/pre.txt" ]]; then
    err "No pre.txt snapshot. Run './monitor.sh pre' before deploy."
    exit 1
  fi
  info "Diff pre.txt vs post.txt:"
  diff -u "$LOCAL_OUT/pre.txt" "$LOCAL_OUT/post.txt" || true
}

tail_logs() {
  info "Live-tailing HA logs for zendure activity (Ctrl-C to exit)..."
  ssh "$HA_HOST" 'ha core logs --follow 2>&1 | grep --line-buffered -iE "zendure|hyper|p1"'
}

case "$PHASE" in
  pre|post)
    snapshot "$PHASE"
    if [[ "$PHASE" == "post" ]]; then
      diff_phases
    fi
    ;;
  tail)
    tail_logs
    ;;
  *)
    err "Unknown phase: $PHASE. Use: pre | post | tail"
    exit 1
    ;;
esac
