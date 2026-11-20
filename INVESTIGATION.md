# How the fix was found

This is the route from "Hibernate never works" to the fix in
[README.md](README.md): every failure in the order it showed up, the exact
log lines, what each one meant, and what fixed it. If your laptop fails
differently, the diagnostic commands at the end show where to look.

Everything happened on one MSI Bravo 15 C7VF on 2026-11-20. The hardware and
software are listed in the README, under *Tested on*.

---

## Starting point

- 16 GB RAM, Fedora's default **zram** swap (8 GB), plus a 20 GB swap
  partition and `resume=` on the kernel command line, both set up in earlier
  attempts.
- NVIDIA options spread over three files in `/etc/modprobe.d/`, from earlier
  guides.
- `/etc/tmpfiles.d/` set `/sys/power/image_size` to 16 GiB, and
  `/etc/systemd/sleep.conf` had `HibernateMode=shutdown`, both from earlier
  attempts too.
- **Symptoms:** Hibernate in the KDE menu either looked like a log-out (back
  at the sign-in screen), or the screens went black with the orange LED on and
  the fans running, and only a long-press on the power button helped.

---

## Step 1: which stage fails? (kernel test modes)

The kernel can stop hibernation at each stage and come back, without writing
an image. `tools/hibernate-stage-test.sh` runs them one after another:

```bash
echo freezer > /sys/power/pm_test; echo disk > /sys/power/state   # then devices, platform, processors, core
```

**Result:** all five stages passed. Freezing apps, putting the devices to
sleep and the ACPI calls all work, so the hardware can hibernate in principle.
The problem had to be in creating or writing the image, or in what runs
around it.

## Step 2: hibernation "looks like a log-out" → SELinux blocks NVIDIA

The journal after a click on Hibernate:

```
NVRM: PM hibernate notifier failed: 0x59
systemd-sleep[17782]: Failed to put system to sleep. System resumed again: Operation not permitted
```

and in the audit log:

```
avc:  denied  { write open } for  pid=17782 comm="systemd-sleep" path="/var/tmp/#1311116 (deleted)"
  dev="nvme0n1p7" ino=1311116 scontext=system_u:system_r:systemd_sleep_t:s0
  tcontext=system_u:object_r:tmp_t:s0 tclass=file permissive=0
```

**Meaning:** with `NVreg_UseKernelSuspendNotifiers=1`, the NVIDIA open driver
saves the video memory itself, inside the `systemd-sleep` process, into a
hidden file in `NVreg_TemporaryFilePath=/var/tmp`. Fedora's SELinux policy does
not let `systemd_sleep_t` write files labelled `tmp_t`. The driver refuses to
hibernate, systemd gives up, and you land back in the session, which looks
like a log-out.

**Fix:** a local policy module, `src/nvidia_hibernate_local.te`, that allows
exactly that:

```
allow systemd_sleep_t tmp_t:file { create open read write append getattr setattr unlink };
allow systemd_sleep_t tmp_t:dir  { search getattr write add_name remove_name };
```

Built and installed with `checkmodule`, `semodule_package` and `semodule -i`;
`install.sh` does this.

## Step 3: a test hibernation passes

`echo test_resume > /sys/power/disk; echo disk > /sys/power/state` creates and
writes the full image, then restores it at once instead of powering off. It
passed in 34 s. So with the SELinux fix and *few apps open*, the whole chain
works. Every failure after this one depended on how much memory was in use.

## Step 4: black screen, orange LED, back at the sign-in screen after ~3 min → amdgpu out of memory

```
amdgpu 0000:05:00.0: PM: pci_pm_freeze(): amdgpu_pmops_freeze [amdgpu] returns -12
amdgpu 0000:05:00.0: PM: dpm_run_callback(): pci_pm_freeze returns -12
amdgpu 0000:05:00.0: PM: failed to freeze async: error -12
amdgpu 0000:05:00.0: PM: pci_pm_freeze returned -12 after 147390257 usecs
```

**Meaning:** `-12` is ENOMEM. The AMD driver tried for 147 seconds to get RAM
to save its state into, and there was none. The old tmpfiles rule set
`image_size` to 16 GiB, so the kernel freed no memory at all before
hibernating, and `reserved_size` was 1 MiB, so nothing was kept free for the
drivers.

**Fix, at this point:** `reserved_size` 1 GiB, `image_size` 6 GiB. The old
16 GiB rule was deleted.

## Step 5: "Image allocation is … pages short" → zram

```
PM: hibernation: Image allocation is 101456 pages short
PM: hibernation: Error -12 creating image
```

**Meaning:** to make room, the kernel swaps memory out, but the
highest-priority swap is zram, which lives in RAM. Pages "swapped out" to
zram still use RAM, just compressed, so the kernel cannot shrink memory enough.

**Fix:** `swapoff /dev/zram0` before hibernating. Its contents move back to
RAM and then to the disk swap.

Side problem, found after a test run: `swapon /dev/zram0` failed with

```
swapon: /dev/zram0: read swap header failed
```

because systemd's zram generator resets the device after `swapoff`. Turning it
back on has to go through systemd: `systemctl --no-block start dev-zram0.swap`.
`--no-block` matters because this runs inside a systemd sleep job.

## Step 6: the crash after an aborted hibernation

Every time hibernation aborted *after* the devices had gone to sleep, waking
them back up crashed the NVIDIA driver:

```
WARNING: nvidia/nv.c:4688 at nv_restore_user_channels+0x4e/0x1f0 [nvidia], CPU#13: systemd-sleep/16220
WARNING: nvidia/nv.c:4981 at nv_set_system_power_state.part.0+0x196/0x1b0 [nvidia], CPU#14: systemd-sleep/16220
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Ran out of a critical resource, other than memory [NV_ERR_INSUFFICIENT_RESOURCES] (0x0000001A) returned from status @ mem_utils.c:1205
NVRM: GPU0 nvCheckFailedNoLog: Check failed: pDst != NULL @ mem_utils.c:795
NVRM: GPU0 kgmmuInvalidateTlb_GM107: TLB invalidation failed waiting for prior invalidate (status=0x00000065) ...
BUG: unable to handle page fault for address: 0000000000005320
```

**Meaning:** a bug in the NVIDIA driver's error path. It cannot recover from an
aborted hibernation, and the screens stay black with the orange LED on.
Nothing outside the driver can fix this. It can only be avoided, and avoiding
it is the main reason the final script **cancels before** hibernation starts
when the image might not fit, instead of letting the kernel try.

## Step 7: "Not enough free memory for image creation" → the GPU growth

With zram off and the kernel told to shrink memory to 6 GiB, it still failed:

```
PM: hibernation: Normal pages needed: 2114696 + 1024, available pages: 1870643
PM: hibernation: Not enough free memory for image creation
PM: hibernation: Error -12 creating image
```

Comparing the kernel's numbers across attempts showed two things:

1. **`needed + available` was always about the same** (≈ 3,985,300 pages ≈
   15.2 GiB): the image and its copy share one pool of RAM. The image can be
   at most about half of RAM.
2. **"Needed" was 1.7–2.8 GB more than what the kernel had prepared** a moment
   earlier (`Allocated N pages for snapshot`). The memory grew *during the
   device freeze*, from the AMD and NVIDIA drivers saving video memory into
   RAM. In a run where the kernel freed nothing at all, the growth was close to
   0, so it shows up whenever the image is sized tightly.

**Fix:** before hibernating, actively push memory to the disk swap
(`echo NNNM > /sys/fs/cgroup/memory.reclaim`, step by step) until used memory
is low enough that image + growth fits. The target went from 35 % of RAM
(failed) to 20 % (worked); the final script computes it instead.

Running this from a systemd-sleep hook's `pre` step did not work reliably,
because it ran too late or too briefly. It became a service ordered
`Before=systemd-hibernate.service`, with a 5-minute timeout.

## Step 8: the power-off hangs → `HibernateMode=platform`

With the image now created and written, the last step still hung: black
screen, orange LED, silent, and a long-press needed. After the long-press, the
session **did** resume, so the image was complete. Only the power-off itself
hung.

The old `/etc/systemd/sleep.conf` had `HibernateMode=shutdown`, which powers
off like a normal shutdown. `HibernateMode=platform` hands the power-off to the
firmware (ACPI S4). With `platform`, the laptop powered off by itself for the
first time:

```
PM: hibernation: Normal pages needed: 1673558 + 1024, available pages: 2311731
```

**First fully working hibernation:** about 20–30 s of fans and the orange LED,
then a clean power-off, and after power-on and GRUB, back in the session with
no errors from the NVIDIA driver.

## Step 9: the final, adaptive script, and two bugs found while testing it

The fixes above used fixed numbers tuned by hand. `src/hibernate-prepare`
replaces them with a calculation, a safety check and learning (see the README,
*What this repo installs*). Testing it found two more problems:

1. **Too strict cancel.** The first version cancelled when memory ended more
   than 256 MiB above the target. One run ended at 3289 MiB against a target
   of 2978 MiB and was cancelled, although it would have fitted easily. The
   part of memory that cannot be swapped out (kernel, GPU drivers, desktop,
   the lock screen) changes by a few hundred MiB between runs. **Fix:** two
   levels. The *target* is what the script aims for (growth × 1.25 + 512 MiB
   of room). *Cancel above* is the real limit (growth + 512 MiB of room).
2. **The power-off hung again.** The migration to the final version removed
   the debugging drop-in that set `HibernateMode=platform`, assuming
   `platform` was the default. It is not, on a system where
   `/etc/systemd/sleep.conf` still says `HibernateMode=shutdown`. The
   prerequisite check missed it because it read `/sys/power/disk`, which
   systemd only writes while hibernating.
   - A red herring here: after each hang, the Wi-Fi card failed to wake up
     (`mt7921e 0000:04:00.0: PM: dpm_run_callback(): pci_pm_restore returns -110`).
     Unloading its driver before hibernating did not stop the hang. The Wi-Fi
     error was a result of the long-press, not the cause.
   - **Fix:** the installer now ships its own drop-in,
     `/etc/systemd/sleep.conf.d/hibernate-prepare.conf`
     (`HibernateMode=platform`). The check reads the setting systemd actually
     uses, via `systemd-analyze cat-config systemd/sleep.conf`.

After that, every hibernation powered off by itself and resumed. That included
one with 10.4 GB in use, which was brought down to 3170 MiB before hibernating.

## Step 10: showing progress

While hibernating, the screen gave no sign of life for up to 1–2 minutes, so
it was impossible to tell "working" from "stuck". The script now switches to a
text console (`chvt 8`), shows the memory being pushed out, and raises the
console log level (`/proc/sys/kernel/printk` to 7) so the kernel's own messages
appear there. After waking up, it switches back.

What could and could not be shown:

- **A test hibernation (`calibrate`)** wakes all devices again after the copy
  is made, so kernel text appears while the image is written and read back.
- **A real hibernation** leaves the screen black while the image is written.
  On a normal hibernation the AMD driver does not wake the GPU again just
  before the power-off, and the panel is only connected to the AMD GPU.
  Nothing can be shown on screen there without a modified kernel.
- So the Caps Lock light gets the kernel's `heartbeat` LED trigger
  (`ledtrig_heartbeat`). It is kernel-driven, so it keeps blinking after user
  space is frozen. What was observed during a real hibernation: normal blinking
  with the text screen → faster blinking with the screen off (CPU busy) →
  **steady for about 15 s** (memory copy, keyboard asleep too) → about 3 s of
  blinking (image written) → power-off.
- A first test showed a blank screen with the text console active. The next
  runs, with each switch written to the log, worked; the first time was most
  likely a matter of watching at the wrong moment, as the memory phase lasted
  only 10 s.

## Measurements

From `/var/lib/hibernate-prepare/history` and the kernel log. The image size
is what the kernel prepared; "needed" is what the image had grown to during
the device freeze; the GPU growth is the difference.

| Run | Image MiB | Needed MiB | Result | GPU growth MiB |
|---|---|---|---|---|
| debugging, 6 GiB target | 5520 | 8260 | failed | 2740 |
| debugging | 5542 | 7642 | ok | 2100 |
| debugging | 5480 | 8009 | failed | 2529 |
| debugging, first full success | 4798 | 6537 | ok | 1739 |
| final script, calibration | 3011 | 4887 | ok | 1875 |
| final script | 3949 | 6791 | ok | 2841 |
| final script | 3743 | 6459 | ok | 2715 |
| final script | 3724 | 6363 | ok | 2639 |
| final script, 10.4 GB in use before | 3567 | 6023 | ok | 2456 |
| final script, real, after a 4 h hibernation | 3807 | 6570 | ok | 2762 |
| calibration, progress screen | 3191 | 5267 | ok | 2075 |
| calibration, progress screen | 2957 | 4667 | ok | 1710 |
| real, progress screen | 3551 | 6050 | ok | 2499 |
| real, progress screen + Caps Lock | 3815 | 6334 | ok | 2519 |

The limit on this laptop is about 7330 MiB (half of RAM minus 256 MiB). Every
attempt that needed more failed; every attempt below it worked. The growth
stayed between 1.7 and 2.8 GB whatever the image size, which is why the script
treats it as a property of the machine and learns it.

---

## Cleanup after the debugging

What was removed or merged on the test laptop once the final version was
installed. Check your own system for the same leftovers if you followed other
guides before.

- **Debugging versions of the fix:** an earlier sleep hook
  `/usr/lib/systemd/system-sleep/zram-hibernate`,
  `/etc/tmpfiles.d/hibernate-memory.conf` (fixed `reserved_size` and
  `image_size`; the script now sets both every time), and a hand-made
  `/etc/systemd/sleep.conf.d/hibernate-mode.conf`. All of them are replaced by
  what `install.sh` installs.
- **Old tmpfiles rule** with `image_size` = 16 GiB: deleted. It made the
  kernel free nothing (step 4).
- **Three NVIDIA files** (`nvidia.conf`, `nvidia-power.conf`,
  `nvidia-hibernate-fix.conf`) with the same options repeated, and only one of
  them with `UseKernelSuspendNotifiers=1`. They were merged into one
  `/etc/modprobe.d/nvidia-hibernate.conf` (README, Prerequisites 5). After a
  reboot, `/proc/driver/nvidia/params` showed all three values.
- **`HibernateMode=shutdown` in `/etc/systemd/sleep.conf`:** commented out.
  The drop-in already overrides it, but leaving it there is a trap.
- **Services from earlier attempts that killed apps at shutdown:** removed.
  They did not affect hibernation, but they made shutdowns slower.

Back up anything you remove first, for example with
`sudo tar -czPf ~/hibernation-cleanup-backup.tar.gz <files>`.

---

## Diagnostic commands used

```bash
# what the kernel did in the last attempt (this boot, or the one before a long-press)
journalctl -b -k  | grep -E 'PM: |NVRM|BUG|amdgpu.*-12'
journalctl -b -1 -k | grep -E 'PM: |NVRM|BUG|amdgpu.*-12'

# the key numbers: prepared image vs. what was needed during the device freeze
journalctl -b -k | grep -E 'Allocated [0-9]+ pages for snapshot|Normal pages needed|pages short|Error -12'

# SELinux denials during hibernation
sudo ausearch -m avc -ts recent | grep systemd_sleep

# stage by stage, and a full image without power-off
sudo bash tools/hibernate-stage-test.sh
sudo hibernate-prepare calibrate

# the power-off mode systemd really uses (the last line wins)
systemd-analyze cat-config systemd/sleep.conf | grep HibernateMode

# NVIDIA options actually loaded
grep -E 'Preserve|TemporaryFile|UseKernelSuspend' /proc/driver/nvidia/params

# per-device timing, to find a driver that takes long or fails
echo 1 | sudo tee /sys/power/pm_print_times /sys/power/pm_debug_messages
```
