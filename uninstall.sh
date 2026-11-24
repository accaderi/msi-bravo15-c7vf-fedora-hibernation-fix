#!/bin/bash
# Removes the hibernation fix. Run from this folder:  sudo bash uninstall.sh
set -u
[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

systemctl disable hibernate-prepare.service 2>/dev/null
rm -f /etc/systemd/system/hibernate-prepare.service \
      /usr/lib/systemd/system-sleep/hibernate-prepare \
      /usr/local/sbin/hibernate-prepare \
      /etc/systemd/sleep.conf.d/hibernate-prepare.conf
rmdir /etc/systemd/sleep.conf.d 2>/dev/null
systemctl daemon-reload
semodule -l 2>/dev/null | grep -q '^nvidia_hibernate_local$' && semodule -r nvidia_hibernate_local

read -r -p "Also delete settings and learned data (/etc/hibernate-prepare.conf, /var/lib/hibernate-prepare)? [y/N] " a
if [ "$a" = y ] || [ "$a" = Y ]; then
    rm -rf /etc/hibernate-prepare.conf /var/lib/hibernate-prepare /var/log/hibernate-prepare.log
fi
echo "Removed. Kernel memory settings return to defaults at the next boot."
