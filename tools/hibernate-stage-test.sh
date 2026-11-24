#!/bin/bash
# Runs hibernation step by step using the kernel's built-in test modes, to find
# which stage hangs. Each stage blanks the screen for ~5 seconds and returns.
# Progress is written to disk after every step, so after a hard power-off the
# log shows the last stage that passed.
#
# Run as root:  sudo bash tools/hibernate-stage-test.sh

set -u
LOG=/var/log/hibernate-stage-test.log
STAGES="freezer devices platform processors core"

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; sync; }

echo 1 > /sys/power/pm_print_times
echo 1 > /sys/power/pm_debug_messages

log "=== start; disk mode: $(cat /sys/power/disk)"
for stage in $STAGES; do
    log "STARTING stage: $stage"
    echo "$stage" > /sys/power/pm_test
    if echo disk > /sys/power/state; then
        log "PASSED stage: $stage"
    else
        log "ERROR stage: $stage (exit $?)"
        break
    fi
    dmesg > "/var/log/hibernate-stage-test.dmesg.$stage"
    sync
    sleep 3
done
echo none > /sys/power/pm_test
log "=== done"
