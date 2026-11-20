#!/bin/bash
# Checks everything hibernation needs, and says which README section fixes
# what is missing. Changes nothing.
#
# Run as root:  sudo bash tools/check-prerequisites.sh

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

fails=0
ok()   { printf '  \e[32mOK\e[0m    %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }

mem_mib=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1024 ))

echo "System"
echo "  $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)," \
     "BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
echo "  $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r), RAM ${mem_mib} MiB"
[ -r /proc/driver/nvidia/version ] && echo "  $(head -1 /proc/driver/nvidia/version | sed 's/  */ /g')"
echo

echo "Kernel and firmware  (README: Prerequisites 1, 4)"
if grep -q disk /sys/power/state; then ok "kernel supports hibernation"; else fail "kernel has no hibernation support (/sys/power/state)"; fi
lockdown=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/security/lockdown 2>/dev/null)
if [ -z "$lockdown" ] || [ "$lockdown" = none ]; then
    ok "kernel lockdown off (Secure Boot does not block hibernation)"
else
    fail "kernel lockdown is '$lockdown', which disables hibernation; turn off Secure Boot in the BIOS"
fi
can=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null | awk '{ print $2 }' | tr -d '"')
if [ "$can" = yes ]; then ok "systemd allows hibernation"; else warn "systemd CanHibernate: ${can:-unknown} (often fixed by the swap and resume steps)"; fi
echo

echo "Swap  (README: Prerequisites 2)"
disk_swap=$(awk 'NR > 1 && $1 !~ /^\/dev\/zram/ { s += $3 } END { print int(s / 1024) }' /proc/swaps)
if [ "$disk_swap" -eq 0 ]; then
    fail "no swap partition or swap file on disk (zram does not count)"
elif [ "$disk_swap" -lt "$mem_mib" ]; then
    warn "disk swap ${disk_swap} MiB is smaller than RAM ${mem_mib} MiB; works with fewer apps open"
else
    ok "disk swap ${disk_swap} MiB (RAM ${mem_mib} MiB)"
fi
if awk 'NR > 1 && $1 ~ /^\/dev\/zram/' /proc/swaps | grep -q .; then
    ok "zram swap present (hibernate-prepare turns it off while hibernating)"
fi
echo

echo "Resume at boot  (README: Prerequisites 3)"
if grep -qw 'resume=[^ ]*' /proc/cmdline; then
    dev=$(grep -o 'resume=[^ ]*' /proc/cmdline | cut -d= -f2-)
    real=$(readlink -f "$(echo "$dev" | sed 's|^UUID=|/dev/disk/by-uuid/|')" 2>/dev/null)
    if [ -n "$real" ] && awk -v d="$real" '$1 == d' /proc/swaps | grep -q .; then
        ok "resume=$dev points to active swap $real"
    else
        fail "resume=$dev does not point to an active disk swap"
    fi
else
    warn "no resume= on the kernel command line; systemd can resume without it on UEFI, but resume= is more reliable"
fi
if lsinitrd -m 2>/dev/null | grep -qx resume; then
    ok "initramfs contains the dracut 'resume' module"
else
    fail "initramfs has no 'resume' module"
fi
# systemd writes HibernateMode= to /sys/power/disk only when hibernating, so
# read the effective systemd setting (last one wins), not /sys/power/disk.
mode=$(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null |
       awk -F= '/^[[:space:]]*HibernateMode=/ { m = $2 } END { print m }' | awk '{ print $1 }')
case "${mode:-platform}" in
    platform) ok "hibernation power-off mode: platform${mode:+ (systemd sleep config)}" ;;
    *) fail "HibernateMode=$mode in systemd sleep config; 'platform' is needed (other modes hang the power-off on the Bravo 15 C7VF)" ;;
esac
echo

if lsmod | grep -q '^nvidia '; then
    echo "NVIDIA  (README: Prerequisites 5)"
    p=/proc/driver/nvidia/params
    if grep -q 'PreserveVideoMemoryAllocations: 1' $p; then ok "PreserveVideoMemoryAllocations=1"; else fail "NVreg_PreserveVideoMemoryAllocations is not 1"; fi
    tmp=$(awk -F'"' '/TemporaryFilePath/ { print $2 }' $p)
    if [ -z "$tmp" ]; then
        fail "NVreg_TemporaryFilePath is not set"
    elif [ "$(stat -f -c %T "$tmp" 2>/dev/null)" = tmpfs ]; then
        fail "NVreg_TemporaryFilePath=$tmp is on tmpfs (RAM); use /var/tmp"
    else
        ok "TemporaryFilePath=$tmp ($(df -h --output=avail "$tmp" | tail -1 | tr -d ' ') free)"
    fi
    if grep -q 'UseKernelSuspendNotifiers: 1' $p 2>/dev/null; then
        ok "UseKernelSuspendNotifiers=1 (driver saves video memory itself)"
    elif systemctl is-enabled -q nvidia-hibernate.service nvidia-resume.service; then
        ok "nvidia-hibernate/nvidia-resume services enabled"
    else
        fail "neither UseKernelSuspendNotifiers=1 nor the nvidia-hibernate/resume services"
    fi
    echo
fi

echo "SELinux  (README: Install)"
if [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    if semodule -l | grep -q '^nvidia_hibernate_local$'; then
        ok "nvidia_hibernate_local policy module installed"
    elif lsmod | grep -q '^nvidia '; then
        fail "SELinux enforcing, nvidia_hibernate_local module missing (NVIDIA cannot save video memory)"
    fi
else
    ok "SELinux not enforcing"
fi
echo

echo "hibernate-prepare  (README: Install)"
if [ -x /usr/local/sbin/hibernate-prepare ] && systemctl is-enabled -q hibernate-prepare.service; then
    ok "installed and enabled"
    [ -s /var/lib/hibernate-prepare/history ] && ok "calibrated / has learned from $(wc -l < /var/lib/hibernate-prepare/history) attempt(s)" \
        || warn "not calibrated yet: sudo hibernate-prepare calibrate"
else
    fail "not installed: sudo bash install.sh"
fi
echo

if [ $fails -eq 0 ]; then echo "All required checks passed."; else echo "$fails check(s) failed."; fi
exit $(( fails > 0 ))
