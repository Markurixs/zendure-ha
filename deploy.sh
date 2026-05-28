#!/usr/bin/env bash
# Deploys this fork to the Home Assistant instance at 192.168.44.250.
#
# Usage:
#   ./deploy.sh           # full deploy (backup + sync + check + restart)
#   ./deploy.sh dry-run   # show what would happen, change nothing
#   ./deploy.sh rollback  # restore the most recent backup, restart
#
# The script is idempotent: re-running it overwrites the integration files
# with the current local state and creates a fresh timestamped backup.
#
# Pre-flight checks before destructive actions:
#   - SSH connectivity to root@192.168.44.250
#   - `ha core check` returns clean
#   - Fork's manifest.json parses
#
# All commands run as root via the SSH addon on port 22.

set -euo pipefail

HA_HOST="root@192.168.44.250"
LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/custom_components/zendure_ha/"
REMOTE_TARGET="/config/custom_components/zendure_ha/"
BACKUP_GLOB="/config/custom_components/zendure_ha.bak.fork_*"
MODE="${1:-deploy}"

color()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()   { color '36' "[INFO] $*"; }
warn()   { color '33' "[WARN] $*"; }
err()    { color '31' "[ERR ] $*" >&2; }
ok()     { color '32' "[ OK ] $*"; }

require_ssh() {
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HA_HOST" 'echo pong' >/dev/null 2>&1; then
    err "Cannot SSH to $HA_HOST (key-based auth required, addon must be running)."
    exit 1
  fi
}

require_local_files() {
  if [[ ! -d "$LOCAL_SRC" ]]; then
    err "Local source not found: $LOCAL_SRC"
    exit 1
  fi
  python3 -c "import json; json.load(open('$LOCAL_SRC/manifest.json'))" \
    || { err "Local manifest.json invalid"; exit 1; }
}

remote_backup() {
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  info "Creating backup: zendure_ha.bak.fork_${ts}"
  ssh "$HA_HOST" "cp -r /config/custom_components/zendure_ha /config/custom_components/zendure_ha.bak.fork_${ts}"
  ok   "Backup created."
}

remote_rsync() {
  info "Syncing files (rsync, excluding __pycache__)..."
  rsync -av --delete --exclude='__pycache__' "$LOCAL_SRC" "$HA_HOST:$REMOTE_TARGET"
  ok   "Files synced."
}

remote_ha_check() {
  info "Running 'ha core check' on remote..."
  if ssh "$HA_HOST" 'ha core check' 2>&1 | tee /tmp/ha_check.out | grep -qiE 'error|invalid'; then
    err "ha core check failed. Output:"
    cat /tmp/ha_check.out >&2
    return 1
  fi
  ok   "ha core check clean."
}

remote_restart() {
  warn "Restarting HA core. ~30s of downtime ahead."
  ssh "$HA_HOST" 'ha core restart'
  ok   "Restart command sent. Wait ~30s, then run: ./monitor.sh post"
}

list_backups() {
  ssh "$HA_HOST" "ls -1dt $BACKUP_GLOB 2>/dev/null || true"
}

rollback() {
  info "Available backups (newest first):"
  local backups
  backups="$(list_backups)"
  if [[ -z "$backups" ]]; then
    err "No backups found matching $BACKUP_GLOB"
    exit 1
  fi
  echo "$backups"
  local latest
  latest="$(echo "$backups" | head -1)"
  warn "Will restore: $latest -> $REMOTE_TARGET"
  read -r -p "Type 'yes' to proceed: " ans
  [[ "$ans" == "yes" ]] || { info "Aborted."; exit 0; }
  ssh "$HA_HOST" "rm -rf $REMOTE_TARGET && cp -r $latest $REMOTE_TARGET"
  ok   "Restored."
  remote_ha_check
  remote_restart
}

dry_run() {
  info "DRY RUN — no changes will be made."
  info "Local source:  $LOCAL_SRC"
  info "Remote target: $HA_HOST:$REMOTE_TARGET"
  info "Files that would be transferred:"
  rsync -avn --delete --exclude='__pycache__' "$LOCAL_SRC" "$HA_HOST:$REMOTE_TARGET" | head -40
  info "Existing remote backups:"
  list_backups | head -5 || true
  info "Local manifest version:"
  python3 -c "import json; print(json.load(open('$LOCAL_SRC/manifest.json'))['version'])"
}

case "$MODE" in
  deploy)
    require_ssh
    require_local_files
    remote_backup
    remote_rsync
    remote_ha_check || {
      warn "Config invalid. Rolling back automatically..."
      ssh "$HA_HOST" "rm -rf $REMOTE_TARGET && cp -r $(list_backups | head -1) $REMOTE_TARGET"
      err "Rolled back. NOT restarting HA. Investigate before retrying."
      exit 1
    }
    remote_restart
    ;;
  dry-run)
    require_ssh
    require_local_files
    dry_run
    ;;
  rollback)
    require_ssh
    rollback
    ;;
  *)
    err "Unknown mode: $MODE. Use: deploy | dry-run | rollback"
    exit 1
    ;;
esac
