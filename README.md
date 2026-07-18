# Time Machine on UniFi UDM SE

This is a UDM SE–specific revision of `scttfrdmn/udm-pro-timemachine` for:

- UniFi OS `5.1.19`
- ARM64 (`aarch64`)
- SSD array `/dev/md3`
- Dynamic UUID mount discovered from `/dev/md3`
- UniFi-managed Avahi running under `udapi-server.service`

The setup installs stock Samba directly on UniFi OS. It does **not** run or
enable a separate `avahi-daemon.service`. UniFi already owns UDP 5353; the
recovery script only reloads that existing Avahi process.

This is an unsupported customization. Back up the UniFi configuration first.
The SSD is represented as a degraded two-member RAID1 (`[U_]`) because the UDM
SE has only one installed data disk; there is no storage redundancy.

## 1. Confirm the data disk

```bash
lsblk
findmnt /dev/md3
MD_MOUNT="$(findmnt -rn -S /dev/md3 -o TARGET)"
test -n "$MD_MOUNT" && df -hT "$MD_MOUNT"
```

Do not continue unless `/dev/md3` is mounted read/write. Create a stable path:

```bash
MD_MOUNT="$(findmnt -rn -S /dev/md3 -o TARGET)"
test -n "$MD_MOUNT" || { echo "md3 is not mounted"; exit 1; }
test ! -e /volume1 || test -L /volume1 || {
  echo "/volume1 exists and is not a symlink"; exit 1;
}
ln -sfn "$MD_MOUNT" /volume1
```

The recovery script recreates this symlink after ordinary restarts.

## 2. Install Samba

Avahi is already supplied and launched by UniFi. Install only Samba and its
Fruit module. The recovery script deliberately does not package-manage Avahi.

```bash
apt update
apt install -y samba samba-vfs-modules
smbd --version
```

Do **NOT** run any of these commands: `# systemctl enable/start/restart avahi-daemon`

UniFi launches its Avahi processes in `/os.slice/udapi-server.service`.

## 3. Create the account and share directory

```bash
getent passwd timemachine >/dev/null || \
  useradd -M -s /usr/sbin/nologin timemachine

mkdir -p /volume1/timemachine
chown timemachine:timemachine /volume1/timemachine
chmod 0700 /volume1/timemachine

smbpasswd -a timemachine
smbpasswd -e timemachine
```

Enter a strong, unique password interactively. Do not put it in a shell script.

## 4. Create persistent configuration

```bash
mkdir -p /data/timemachine
chmod 0700 /data/timemachine
```

Create `/data/timemachine/smb-timemachine.conf`:

```bash
cat > /data/timemachine/smb-timemachine.conf <<'EOF'
[global]
   fruit:aapl = yes
   fruit:model = TimeCapsule8,119
   server min protocol = SMB2

[TimeMachine]
   comment = UDM SE Time Machine
   path = /volume1/timemachine
   browseable = yes
   read only = no
   guest ok = no
   valid users = timemachine
   force user = timemachine
   force group = timemachine
   create mask = 0600
   directory mask = 0700
   vfs objects = catia fruit streams_xattr
   fruit:time machine = yes
   fruit:time machine max size = 1500G
   fruit:metadata = stream
   fruit:resource = file
   fruit:encoding = native
   fruit:zero_file_id = yes
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
EOF
```

The 1500 GB advertised limit reserves substantial headroom on the 1.8 TiB
filesystem. Keep this directory exclusively for Time Machine. Samba's historic
Time Machine size bug affected 32-bit ARM and is fixed; this UDM is ARM64.

Add the persistent fragment to `/etc/samba/smb.conf` exactly once:

```bash
grep -Fqx 'include = /data/timemachine/smb-timemachine.conf' \
  /etc/samba/smb.conf || \
  printf '\ninclude = /data/timemachine/smb-timemachine.conf\n' \
  >> /etc/samba/smb.conf

testparm -s
systemctl enable --now smbd
```

Do not enable `nmbd`; modern macOS uses SMB and mDNS.

## 5. Advertise Time Machine through UniFi's Avahi

Create the persistent source file:

```bash
cat > /data/timemachine/avahi-timemachine.service <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h Time Machine</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_adisk._tcp</type>
    <port>9</port>
    <txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record>
    <txt-record>sys=waMA=0,adVF=0x100</txt-record>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>9</port>
    <txt-record>model=TimeCapsule8,119</txt-record>
  </service>
</service-group>
EOF

mkdir -p /etc/avahi/services
install -m 0644 /data/timemachine/avahi-timemachine.service \
  /etc/avahi/services/timemachine.service
```

Reload only the Avahi parent process owned by UniFi:

```bash
AVAHI_PID=""
for pid in $(pgrep -x avahi-daemon); do
  if grep -q '/os.slice/udapi-server.service' "/proc/$pid/cgroup"; then
    AVAHI_PID="$pid"
    break
  fi
done
test -n "$AVAHI_PID" && kill -HUP "$AVAHI_PID"
```

Verify that Samba remains available:

```bash
systemctl --no-pager --full status smbd
ss -lntp | grep ':445'
pgrep -a avahi-daemon
```

## 6. Save authentication and install recovery

The Samba password database contains password hashes. Protect its persistent
copy and do not share it:

```bash
install -m 0600 /var/lib/samba/private/passdb.tdb \
  /data/timemachine/passdb.tdb
```

Copy the revised `99-timemachine.sh` accompanying this README onto the UDM:

```bash
# Run from the Mac in the directory containing 99-timemachine.sh:
scp 99-timemachine.sh root@<udm-ip>:/data/timemachine/99-timemachine.sh
```

Then, on the UDM:

```bash
chmod 0755 /data/timemachine/99-timemachine.sh
bash -n /data/timemachine/99-timemachine.sh
bash /data/timemachine/99-timemachine.sh
```

The script creates this ordinary-reboot hook automatically:

```text
/usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh
```

Check its result:

```bash
testparm -s
systemctl is-active smbd
grep timemachine-boot /var/log/syslog | tail -20
```

## 7. Connect the Mac

In Finder, press Command-K and connect to:

```text
smb://<udm-ip>/TimeMachine
```

Authenticate as `timemachine`, then open **System Settings → General → Time
Machine → Add Backup Disk**. The destination advertised as “&lt;UDM hostname&gt;
Time Machine” should also appear automatically.

## Restarts and firmware upgrades

Ordinary restarts use the installed boot hook automatically.

UniFi OS 5.x firmware upgrades may erase the wrapper under `/usr/lib`, even
though `/data/timemachine` survives. After an upgrade, run once:

```bash
ssh root@<udm-ip> bash /data/timemachine/99-timemachine.sh
```

The script will:

1. Wait for `/dev/md3` and recreate `/volume1`.
2. Restore Samba packages if UniFi removed them.
3. Recreate the local user and Samba password database when needed.
4. Restore the idempotent Samba include and validate it.
5. Restore the Avahi service file.
6. Reload only the Avahi process owned by `udapi-server.service`.
7. Recreate the ordinary-reboot hook.

It will never enable or launch `avahi-daemon.service`.

## Updating credentials

After changing the Samba password, refresh the protected persistent copy:

```bash
smbpasswd timemachine
install -m 0600 /var/lib/samba/private/passdb.tdb \
  /data/timemachine/passdb.tdb
```

## Diagnostics

```bash
findmnt /dev/md3
df -hT /volume1
testparm -s
systemctl --no-pager --full status smbd
ss -lntp | grep ':445'
pgrep -a avahi-daemon
for pid in $(pgrep -x avahi-daemon); do cat "/proc/$pid/cgroup"; done
tail -100 /var/log/samba/log.smbd
```

If discovery fails but SMB works, connect directly with
`smb://<udm-ip>/TimeMachine`; do not start a second Avahi daemon.

## Removal

Removing backup data is intentionally not included here. First remove the Time
Machine destination from every Mac, then disable the service without deleting
the SSD contents:

```bash
rm -f /usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh
rm -f /etc/avahi/services/timemachine.service
systemctl disable --now smbd
```

Reload the UniFi-owned Avahi process with the safe PID-selection command from
Step 5. Leave `/volume1/timemachine` untouched unless you deliberately intend
to destroy all backups.
