#!/usr/bin/env bash
# =============================================================================
# resetvps.sh  —  Analyze VPS → strip everything extra → leave base OS like new
# Target: Debian / Ubuntu VPS (root required)
# WARNING: DESTRUCTIVE. Will remove packages, users, data, docker, services.
# Run only on machines you fully control and have already backed up.
# =============================================================================

set -euo pipefail

VERSION="1.0.0"
LOG_FILE="/var/log/resetvps-$(date +%Y%m%d-%H%M%S).log"
CONFIRM_PHRASE="RESET"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[+]${NC} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERR]${NC} $*" | tee -a "$LOG_FILE"; }

# -----------------------------------------------------------------------------
# 0. Root + safety checks
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Must run as root (sudo -i or su -)"
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  err "Cannot detect OS"
  exit 1
fi
# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
  err "Only Debian/Ubuntu supported. Detected: ${ID:-unknown}"
  exit 1
fi

echo
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  resetvps v${VERSION} — FULL SYSTEM STRIP TO NEAR-FACTORY STATE  ║${NC}"
echo -e "${RED}║  This WILL destroy data, users, packages, docker, sites...   ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "OS        : $PRETTY_NAME"
echo "Hostname  : $(hostname)"
echo "Kernel    : $(uname -r)"
echo "Uptime    : $(uptime -p 2>/dev/null || true)"
echo "Disk      : $(df -h / | awk 'NR==2{print $3" used / "$2" total ("$5")"}')"
echo "Log       : $LOG_FILE"
echo
read -r -p "Type exactly '${CONFIRM_PHRASE}' to continue (anything else aborts): " confirm
if [[ "$confirm" != "$CONFIRM_PHRASE" ]]; then
  warn "Aborted by operator."
  exit 0
fi

# Optional dry-run
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  warn "DRY-RUN mode — no changes will be made"
fi

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

# -----------------------------------------------------------------------------
# 1. ANALYZE — snapshot of current state
# -----------------------------------------------------------------------------
log "=== PHASE 1: ANALYZE ==="
{
  echo "=== SYSTEM SNAPSHOT $(date -u) ==="
  uname -a
  cat /etc/os-release
  echo
  echo "=== DISK ==="
  df -h
  echo
  echo "=== TOP LARGEST DIRS (depth 2) ==="
  du -xh / --max-depth=2 2>/dev/null | sort -hr | head -30 || true
  echo
  echo "=== INSTALLED PACKAGES (count) ==="
  dpkg -l | grep -c '^ii' || true
  echo
  echo "=== RUNNING SERVICES ==="
  systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true
  echo
  echo "=== DOCKER ==="
  command -v docker >/dev/null && docker system df 2>/dev/null || echo "docker not installed"
  echo
  echo "=== USERS (uid >= 1000) ==="
  awk -F: '$3 >= 1000 && $1 != "nobody" {print $1":"$3":"$6}' /etc/passwd
  echo
  echo "=== CRON ==="
  ls -la /etc/cron* 2>/dev/null || true
  crontab -l 2>/dev/null || true
} | tee -a "$LOG_FILE"

ok "Analysis written to $LOG_FILE"

# -----------------------------------------------------------------------------
# 2. STOP HEAVY SERVICES / DOCKER
# -----------------------------------------------------------------------------
log "=== PHASE 2: STOP SERVICES & DOCKER ==="

if command -v docker >/dev/null 2>&1; then
  log "Stopping all containers..."
  run "docker stop \$(docker ps -q) 2>/dev/null || true"
  log "Removing all containers, images, volumes, networks..."
  run "docker system prune -a --volumes -f 2>/dev/null || true"
  run "docker network prune -f 2>/dev/null || true"
fi

# Stop common web / panel / db services so files can be removed
for svc in nginx apache2 httpd mysql mariadb postgresql redis-server mongod docker containerd snapd; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "Stopping $svc"
    run "systemctl stop $svc 2>/dev/null || true"
    run "systemctl disable $svc 2>/dev/null || true"
  fi
done

# -----------------------------------------------------------------------------
# 3. PURGE USER DATA / HOME / WWW / OPT / CUSTOM FOLDERS
# -----------------------------------------------------------------------------
log "=== PHASE 3: WIPE USER DATA & CUSTOM FOLDERS ==="

# Remove all non-system users (uid >= 1000) and their homes
while IFS=: read -r user _ uid _ _ home _; do
  if [[ "$uid" -ge 1000 && "$user" != "nobody" ]]; then
    log "Removing user $user (uid $uid) and home $home"
    run "userdel -r -f '$user' 2>/dev/null || true"
    run "rm -rf '$home' 2>/dev/null || true"
  fi
done < /etc/passwd

# Common application / site locations
for path in \
  /var/www \
  /var/lib/mysql \
  /var/lib/postgresql \
  /var/lib/docker \
  /var/lib/containerd \
  /opt/* \
  /home/* \
  /root/.cache \
  /root/.npm \
  /root/.local \
  /root/.cargo \
  /root/go \
  /tmp/* \
  /var/tmp/* \
  /srv/* \
  /usr/local/bin/* \
  /usr/local/src/* \
  /etc/nginx/sites-enabled/* \
  /etc/nginx/sites-available/* \
  /etc/apache2/sites-enabled/* \
  /etc/apache2/sites-available/*
do
  if [[ -e $path || -L $path ]]; then
    log "Clearing $path"
    run "rm -rf $path 2>/dev/null || true"
  fi
done

# Recreate minimal empty dirs that packages expect
run "mkdir -p /var/www /home /opt /tmp /var/tmp"
run "chmod 1777 /tmp /var/tmp"

# -----------------------------------------------------------------------------
# 4. PURGE PACKAGES — desktop, panels, databases, extra tools
# -----------------------------------------------------------------------------
log "=== PHASE 4: PACKAGE PURGE ==="

run "export DEBIAN_FRONTEND=noninteractive"
run "apt-get update -qq 2>/dev/null || true"

PURGE_LIST=(
  ubuntu-desktop* gdm3 lightdm sddm xserver-xorg* xorg*
  cyberpanel* cpanel* plesk* webmin* virtualmin*
  nginx* apache2* httpd* mysql* mariadb* postgresql* redis* mongodb* php* nodejs* npm*
  docker* containerd* runc*
  snapd*
  libreoffice* thunderbird* firefox* chromium*
)

for pkg in "${PURGE_LIST[@]}"; do
  if dpkg -l 2>/dev/null | grep -qE "^ii.*${pkg//\*/}"; then
    log "Purging pattern: $pkg"
    run "apt-get purge -y $pkg 2>/dev/null || true"
  fi
done

log "Autoremove + clean"
run "apt-get autoremove -y --purge 2>/dev/null || true"
run "apt-get autoclean -y 2>/dev/null || true"
run "apt-get clean 2>/dev/null || true"

run "rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || true"

# -----------------------------------------------------------------------------
# 5. LOGS, CACHES, JOURNAL, TMP
# -----------------------------------------------------------------------------
log "=== PHASE 5: LOGS & CACHES ==="

run "journalctl --vacuum-time=1s 2>/dev/null || true"
run "find /var/log -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true"
run "find /var/log -type f -name '*.gz' -delete 2>/dev/null || true"
run "find /var/log -type f -name '*.1' -delete 2>/dev/null || true"
run "rm -rf /var/cache/apt/archives/* /var/cache/apt/*.bin 2>/dev/null || true"
run "rm -rf /var/lib/apt/lists/* 2>/dev/null || true"
run "rm -rf /tmp/* /var/tmp/* 2>/dev/null || true"
run "rm -rf /root/.bash_history /home/*/.bash_history 2>/dev/null || true"
run "history -c 2>/dev/null || true"

run "sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true"

# -----------------------------------------------------------------------------
# 6. CRON / SYSTEMD USER UNITS / CUSTOM SERVICES
# -----------------------------------------------------------------------------
log "=== PHASE 6: CRON & CUSTOM UNITS ==="

run "rm -f /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/* 2>/dev/null || true"
run "mkdir -p /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly"
run "rm -f /var/spool/cron/crontabs/* 2>/dev/null || true"

run "find /etc/systemd/system -type f -name '*.service' ! -path '*/sysinit.target.wants/*' -delete 2>/dev/null || true"
run "systemctl daemon-reload 2>/dev/null || true"

# -----------------------------------------------------------------------------
# 7. NETWORK / SSH KEEP MINIMAL (do not lock yourself out)
# -----------------------------------------------------------------------------
log "=== PHASE 7: KEEP SSH ALIVE — minimal network hygiene ==="

run "systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true"
run "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true"

run "rm -f /root/.ssh/known_hosts 2>/dev/null || true"

# -----------------------------------------------------------------------------
# 8. FINAL REPORT
# -----------------------------------------------------------------------------
log "=== PHASE 8: FINAL STATE ==="
{
  echo
  echo "=== AFTER RESET ==="
  df -h /
  echo
  echo "Package count now: $(dpkg -l 2>/dev/null | grep -c '^ii' || echo '?')"
  echo
  echo "Remaining non-system users:"
  awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd || echo "(none)"
  echo
  echo "Docker present? $(command -v docker >/dev/null && echo yes || echo no)"
  echo
  echo "Log saved: $LOG_FILE"
} | tee -a "$LOG_FILE"

ok "resetvps finished."
echo
echo -e "${GREEN}VPS is now as close to brand-new base OS as possible without full reinstall.${NC}"
echo -e "${YELLOW}Recommended next steps:${NC}"
echo "  1. Reboot:  reboot"
echo "  2. apt update && apt upgrade -y"
echo "  3. Re-install only what you need"
echo
echo "If you need a true zero-state OS, use your provider panel 'Reinstall' or a DD script."
echo

exit 0
