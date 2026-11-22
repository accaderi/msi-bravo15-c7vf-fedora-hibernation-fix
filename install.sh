#!/bin/bash
# Installs the hibernation fix. Run from this folder:  sudo bash install.sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

echo "== Installing hibernate-prepare"
install -D -m 755 src/hibernate-prepare        /usr/local/sbin/hibernate-prepare
install -D -m 755 src/hibernate-prepare.sleep  /usr/lib/systemd/system-sleep/hibernate-prepare
install -D -m 644 src/hibernate-prepare.service /etc/systemd/system/hibernate-prepare.service
install -D -m 644 src/hibernate-mode.conf      /etc/systemd/sleep.conf.d/hibernate-prepare.conf
# Settings file: the current version, with the values you set in yours kept
conf=/etc/hibernate-prepare.conf
if [ -e "$conf" ]; then
    new=$(mktemp)
    cp src/hibernate-prepare.conf "$new"
    grep -E '^[A-Z_]+=' "$conf" | while IFS= read -r line; do
        key=${line%%=*}
        # replace the commented default of that setting, or append it
        LINE=$line awk -v key="$key" '
            !done && $0 ~ "^#?" key "=" { print ENVIRON["LINE"]; done = 1; next }
            { print }
            END { if (!done) print ENVIRON["LINE"] }' "$new" > "$new.2" && mv "$new.2" "$new"
    done
    if ! cmp -s "$new" "$conf"; then
        cp "$conf" "$conf.old"
        install -m 644 "$new" "$conf"
        echo "   updated $conf (your settings kept; previous file: $conf.old)"
    fi
    rm -f "$new"
else
    install -m 644 src/hibernate-prepare.conf "$conf"
fi
mkdir -p /var/lib/hibernate-prepare

if [ "$(getenforce 2>/dev/null)" != Disabled ] && command -v getenforce >/dev/null; then
    echo "== Installing SELinux module nvidia_hibernate_local"
    if ! command -v checkmodule >/dev/null; then
        echo "   needs the 'checkpolicy' package to build it"
        dnf install -y checkpolicy
    fi
    tmp=$(mktemp -d)
    checkmodule -M -m -o "$tmp/nvidia_hibernate_local.mod" src/nvidia_hibernate_local.te
    semodule_package -o "$tmp/nvidia_hibernate_local.pp" -m "$tmp/nvidia_hibernate_local.mod"
    semodule -i "$tmp/nvidia_hibernate_local.pp"
    rm -rf "$tmp"
    restorecon -F /usr/local/sbin/hibernate-prepare /usr/lib/systemd/system-sleep/hibernate-prepare \
        /etc/systemd/system/hibernate-prepare.service /etc/hibernate-prepare.conf \
        /etc/systemd/sleep.conf.d/hibernate-prepare.conf 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable hibernate-prepare.service
echo "== Installed"
echo

echo "== Checking prerequisites"
bash tools/check-prerequisites.sh || {
    echo
    echo "Fix the FAIL items first (see README, Prerequisites), then run: sudo hibernate-prepare calibrate"
    exit 1
}
echo
echo "Next: calibration measures how much memory your GPU drivers add while hibernating."
echo "Do it with only a few apps open."
/usr/local/sbin/hibernate-prepare calibrate
