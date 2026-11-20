#!/bin/bash
# Full hibernation including writing the RAM image to the swap partition, but
# instead of powering off, the kernel immediately restores from that image
# (mode "test_resume"). Tests the image write + read, the one part the stage
# test could not cover.
#
# Run as root:  sudo bash tools/hibernate-write-test.sh
# Note: without hibernate-prepare this can fail on low free memory; prefer
# "sudo hibernate-prepare calibrate", which prepares memory first.

set -u
LOG=/var/log/hibernate-write-test.log

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; sync; }

echo 1 > /sys/power/pm_print_times
echo 1 > /sys/power/pm_debug_messages
echo none > /sys/power/pm_test
old_mode=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/power/disk)

log "=== start; image_size: $(cat /sys/power/image_size); swap: $(swapon --show=NAME,SIZE,USED --noheadings | tr '\n' ' ')"
log "STARTING write+restore test"
echo test_resume > /sys/power/disk
if echo disk > /sys/power/state; then
    log "PASSED write+restore test"
else
    log "ERROR write+restore test (exit $?)"
fi
echo "$old_mode" > /sys/power/disk
dmesg > /var/log/hibernate-write-test.dmesg
log "=== done"
