#!/bin/bash
# Persistent Time Machine recovery for UniFi UDM SE.
# UniFi OS 5.x may remove apt-installed packages and /etc configuration during
# firmware upgrades. Persistent source files live in /data/timemachine.
#
# IMPORTANT: UniFi launches Avahi inside udapi-server.service. This script
# never enables, starts, stops, or restarts avahi-daemon.service. It only asks
# the already-running UniFi-owned Avahi process to reload its service files.

set -u

BACKUP_DIR="/data/timemachine"
HOOK_DIR="/usr/lib/ubnt/hooks/system/bootup-bottom"
HOOK_WRAPPER="$HOOK_DIR/99-timemachine.sh"
MD_DEVICE="/dev/md3"
VOLUME1="/volume1"
SHARE_DIR="$VOLUME1/timemachine"
SAMBA_FRAGMENT="$BACKUP_DIR/smb-timemachine.conf"
SAMBA_INCLUDE="include = $SAMBA_FRAGMENT"
AVAHI_SOURCE="$BACKUP_DIR/avahi-timemachine.service"
AVAHI_DEST="/etc/avahi/services/timemachine.service"
PASSDB_SOURCE="$BACKUP_DIR/passdb.tdb"
LOG_TAG="timemachine-boot"

log() {
    logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run this script as root"
[ -d "$BACKUP_DIR" ] || fail "$BACKUP_DIR does not exist"
[ -s "$SAMBA_FRAGMENT" ] || fail "$SAMBA_FRAGMENT is missing or empty"
[ -s "$AVAHI_SOURCE" ] || fail "$AVAHI_SOURCE is missing or empty"
[ -s "$PASSDB_SOURCE" ] || fail "$PASSDB_SOURCE is missing or empty"

# Recreate the normal-reboot hook. UniFi OS 5.x firmware updates can remove
# this wrapper, so the first recovery after an upgrade may still require:
#   bash /data/timemachine/99-timemachine.sh
mkdir -p "$HOOK_DIR"
cat > "$HOOK_WRAPPER" <<'EOF'
#!/bin/bash
exec /data/timemachine/99-timemachine.sh "$@"
EOF
chmod 0755 "$HOOK_WRAPPER"

# Wait up to 60 seconds for UniFi to assemble and mount /dev/md3.
MD_MOUNT=""
for _attempt in $(seq 1 30); do
    MD_MOUNT="$(findmnt -rn -S "$MD_DEVICE" -o TARGET 2>/dev/null | head -n 1)"
    [ -n "$MD_MOUNT" ] && [ -d "$MD_MOUNT" ] && break
    sleep 2
done
[ -n "$MD_MOUNT" ] && [ -d "$MD_MOUNT" ] || fail "$MD_DEVICE is not mounted"

# Keep the Samba path stable even if UniFi changes the UUID mount path.
if [ -e "$VOLUME1" ] && [ ! -L "$VOLUME1" ]; then
    fail "$VOLUME1 exists and is not a symlink; refusing to replace it"
fi
ln -sfn "$MD_MOUNT" "$VOLUME1"

# Restore Samba only when firmware has removed it. Avahi belongs to UniFi and
# is deliberately not installed or otherwise package-managed by this script.
NEED_APT=0
command -v smbd >/dev/null 2>&1 || NEED_APT=1
dpkg-query -W -f='${Status}' samba-vfs-modules 2>/dev/null | \
    grep -q 'install ok installed' || NEED_APT=1

if [ "$NEED_APT" -eq 1 ]; then
    log "Required packages are missing; restoring them"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || fail "apt-get update failed"
    apt-get install -y -qq samba samba-vfs-modules || \
        fail "package installation failed"
fi

if ! command -v avahi-daemon >/dev/null 2>&1; then
    log "WARNING: UniFi's Avahi binary is absent; not installing or starting a replacement"
fi

# Recreate the local account if a firmware update removed it.
if ! getent passwd timemachine >/dev/null; then
    useradd -M -s /usr/sbin/nologin timemachine || \
        fail "could not create timemachine user"
fi

mkdir -p "$SHARE_DIR"
chown timemachine:timemachine "$SHARE_DIR"
chmod 0700 "$SHARE_DIR"

# Restore Samba's password database before starting smbd.
mkdir -p /var/lib/samba/private
if ! pdbedit -L 2>/dev/null | grep -q '^timemachine:'; then
    install -m 0600 "$PASSDB_SOURCE" /var/lib/samba/private/passdb.tdb
fi

# Reference the persistent fragment rather than appending the whole share on
# every boot. grep makes this idempotent.
mkdir -p /etc/samba
[ -f /etc/samba/smb.conf ] || printf '[global]\n' > /etc/samba/smb.conf
if ! grep -Fqx "$SAMBA_INCLUDE" /etc/samba/smb.conf; then
    printf '\n%s\n' "$SAMBA_INCLUDE" >> /etc/samba/smb.conf
fi

testparm -s >/dev/null 2>&1 || fail "Samba configuration validation failed"
systemctl restart smbd || fail "could not start Samba"

# Restore the advertisement, then reload ONLY the Avahi process owned by
# udapi-server.service. Never launch a second daemon on UDP 5353.
mkdir -p /etc/avahi/services
install -m 0644 "$AVAHI_SOURCE" "$AVAHI_DEST"

AVAHI_PID=""
for _attempt in $(seq 1 30); do
    for _pid in $(pgrep -x avahi-daemon 2>/dev/null || true); do
        if grep -q '/os.slice/udapi-server.service' "/proc/$_pid/cgroup" 2>/dev/null; then
            AVAHI_PID="$_pid"
            break 2
        fi
    done
    sleep 2
done

if [ -n "$AVAHI_PID" ]; then
    kill -HUP "$AVAHI_PID" && \
        log "Reloaded UniFi-managed Avahi process (PID $AVAHI_PID)"
else
    log "WARNING: UniFi-managed Avahi is not running; SMB works, but automatic discovery may not"
fi

log "Time Machine recovery complete; share path is $SHARE_DIR"
