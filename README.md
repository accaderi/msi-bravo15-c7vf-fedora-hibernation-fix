# Hibernation on the MSI Bravo 15 C7VF with Fedora (KDE)

Make **Hibernate** work like on Windows: save everything that is open, power
off completely, and after power-on continue exactly where you left off. That
includes every app, window and tab.

Out of the box on this laptop, Hibernate in the Fedora KDE menu either looks
like a log-out, or the screens go black with the orange LED on and you have to
hold the power button. This repo fixes that, from a stock Fedora install to a
working, self-adjusting hibernation.

> **Scope:** made for and tested on **one** MSI Bravo 15 C7VF with the exact
> specification below. Laptops with a similar setup (AMD built-in graphics +
> NVIDIA, Fedora's zram, KDE) often have the same problems, so the explanations
> and the script may help there too. The script measures and adapts to the
> machine it runs on, but nobody has confirmed it on other hardware yet.

### Files in this repo

| File | What it is |
|---|---|
| `README.md` | this guide: background, prerequisites, install, use, troubleshooting |
| [`INVESTIGATION.md`](INVESTIGATION.md) | how the fix was found, step by step: every failure in the order it appeared, the exact log lines, what they meant and what fixed them, all measurements, the clean-up of earlier attempts, and the diagnostic commands. Read it if your laptop fails in a different way, or if you want to know *why* each piece is needed |
| `install.sh`, `uninstall.sh` | install and remove the fix |
| `src/hibernate-prepare` | the script that runs before and after every hibernation |
| `src/hibernate-prepare.service`, `src/hibernate-prepare.sleep` | the systemd service and sleep hook that run it |
| `src/hibernate-mode.conf` | systemd setting: power off with `HibernateMode=platform` |
| `src/hibernate-prepare.conf` | the settings file, all commented out |
| `src/nvidia_hibernate_local.te` | the SELinux rule for the NVIDIA driver |
| `tools/check-prerequisites.sh` | checks everything hibernation needs and says which step fixes what; changes nothing |
| `tools/hibernate-stage-test.sh`, `tools/hibernate-write-test.sh` | the kernel test modes used during the investigation |
| `LICENSE` | MIT |

---

## Contents

1. [Tested on](#tested-on)
2. [The basics: what goes wrong](#the-basics-what-goes-wrong)
3. [Hibernation or Save & Shut Down?](#hibernation-or-save--shut-down)
4. [Prerequisites](#prerequisites), steps 1–5
5. [Install](#install)
6. [Check that it works](#check-that-it-works)
7. [Daily use](#daily-use)
8. [Settings](#settings)
9. [Troubleshooting](#troubleshooting)
10. [Uninstall](#uninstall)
11. [License](#license)

---

## Tested on

| | |
|---|---|
| Laptop | MSI Bravo 15 C7VF, BIOS E158NAMS.115 |
| CPU | AMD Ryzen 7 7735HS (8 cores) |
| Graphics | AMD Radeon 680M (built in, drives the laptop screen) + NVIDIA GeForce RTX 4060 Laptop, 8 GB |
| Screen | 15.6" 1920×1080 |
| RAM | 16 GB (Linux sees 15172 MiB; the rest is reserved by the firmware and the built-in graphics) |
| Disk | 1 TB NVMe SSD (Micron 2400), dual boot with Windows |
| Swap | 20 GB swap partition on that SSD, plus Fedora's default 8 GB zram |
| Wi-Fi | MediaTek MT7921K (RZ608), Wi-Fi 6E |
| System | Fedora 44 KDE Plasma 6.7 (Wayland), kernel 7.2.9, systemd 259, ext4 root, SELinux enforcing |
| NVIDIA driver | 615.71.09 *open* kernel modules (RPM Fusion `akmod-nvidia`) |
| Secure Boot | off |

Tested 2026-11-20 to 2026-11-22 with the final setup: 4 test hibernations
(`calibrate`), 9 real hibernations started from the start menu and 3 started
with the power button, all powered off by themselves and resumed. The largest
had about 12 GB of RAM in use, and one was resumed after almost a day powered
off. Before the power-button fix, 5 of 5 power-button hibernations failed; see
[Power button and lid](#power-button-and-lid). Measurements are in
[INVESTIGATION.md](INVESTIGATION.md#measurements).

**Not tested:** other RAM sizes, swap files (only a swap partition), btrfs,
Secure Boot on, the closed-source NVIDIA modules, and other laptop models. The
script computes everything from the machine it runs on, so it should work on
those too, but nobody has confirmed it yet. Reports are welcome.

---

## The basics: what goes wrong

### How Linux hibernation works

1. All programs are frozen.
2. The kernel makes a **copy of the used memory, inside RAM**. This copy is
   the *image*.
3. Devices (GPUs, Wi-Fi, USB) are put to sleep, the image is written to the
   **swap** space on disk, and the laptop powers off.
4. At the next boot, the kernel finds the image in swap, loads it back into
   RAM, and you are back in your session.

Step 2 is the catch. The copy needs free RAM next to the memory it copies, so
**the image can be at most about half of RAM**. On a 16 GB laptop with
browsers, an IDE and a desktop open, you are usually above that. The kernel
tries to make room by pushing memory out to swap first, and on this laptop two
things defeat that.

Windows does not have this limit, because it writes memory straight to
`hiberfil.sys` (compressed) without a full copy in RAM. Linux had such a
design too (TuxOnIce), but it is no longer maintained.

### Problem 1: zram

Fedora's default swap is **zram**, a compressed swap device *in RAM*. When the
kernel "swaps out" memory to make room for the image, the memory lands in zram,
which is still RAM, so nothing is freed. Hibernation fails with
`Image allocation is … pages short` or `Error -12 creating image`.

**Fix:** turn zram off just before hibernating, and push memory to the swap
partition on disk instead. zram comes back on right after.

### Problem 2: the GPU drivers grow after the image is sized

The kernel sizes the image *before* the devices go to sleep. Then the AMD and
NVIDIA drivers save their video memory into RAM, and on this laptop that adds
**1.7–2.8 GB**. The image no longer fits, hibernation aborts
(`Not enough free memory for image creation`), and the NVIDIA driver often
crashes while waking back up. The result is a black screen, the orange LED, and
a long-press on the power button.

**Fix:** before hibernating, push enough memory to disk that the image *plus*
this growth fits. How much is "enough" is measured on your machine, not
guessed (see [Install](#install)).

### Problem 3: NVIDIA, SELinux and the power-off mode

- **NVIDIA** must save its video memory to a file on disk
  (`/var/tmp`, not RAM), and Fedora's SELinux policy blocks that. The driver
  then refuses to hibernate (`NVRM: PM hibernate notifier failed: 0x59`), and
  Hibernate looks like a log-out. **Fix:** a small SELinux rule.
- **The power-off mode:** systemd can power off after hibernating in two
  ways. On this laptop only `platform` (ACPI S4) powers off reliably;
  `shutdown` hangs at the very end with the orange LED on. **Fix:** a systemd
  setting.

### What this repo installs

`hibernate-prepare` runs automatically every time you hibernate:

1. It works out how much memory may stay in RAM: half of RAM, minus the GPU
   growth measured on this machine (at least 3 GB), plus a safety margin.
2. It checks that the swap on disk has room for everything. If not, it
   **cancels** and shows a desktop notification with a suggested swap size.
3. It turns zram off and pushes memory to disk until the target is reached. If
   too much memory cannot be moved, for example GPU memory, it **cancels** with
   a notification instead of risking the crash.
4. After waking up, or after a cancel, it turns zram back on and **learns**
   from the kernel log how much the GPU drivers really added. The next
   hibernation uses that.

A cancelled hibernation is harmless. You keep working and nothing is lost.

---

## Hibernation or Save & Shut Down?

| | Hibernation | Save & Shut Down / Restart |
|---|---|---|
| What comes back | everything, exactly: running programs, terminal output, unsaved work, every tab and every video | apps and windows on their screens, in their order; the content as far as each app restores it (browser tabs, open files, terminal folders); one video per browser at its position |
| Unsaved work | kept as it is | the app asks before closing; the shutdown waits until you answer |
| Limit | the image must fit in about half of the RAM; what decides is the memory that cannot be swapped out, mostly the graphics drivers' (2–3 GB with three screens on a 16 GB laptop), so it can be refused at one try and work at the next | none |
| When it goes wrong | refused: nothing happens, you keep working. Rarely the machine hangs while writing the image: then the session is lost (once in about 40 attempts while testing) | an app that does not close stops the shutdown, and the apps closed so far open again |
| Kernel and system updates | not applied | applied: it is a real restart |
| Setup | swap partition at least as big as the RAM, kernel and driver settings, Secure Boot off; depends on the hardware | per user, no system changes |
| Time | about 1 minute to hibernate and 1 to wake | a normal shutdown; after login the apps take their normal start time |
| Power while off | none | none |

Use hibernation for "continue exactly here" after a short break. Use Save &
Shut Down / Restart for updates, longer breaks, and whenever hibernation is
refused or not available. With both installed: hibernate, and if it is
refused, Save & Shut Down.

Save & Shut Down / Restart for KDE Plasma:
[plasma-reopen-windows](https://github.com/accaderi/plasma-reopen-windows).

---

## Prerequisites

Do these once. `sudo bash tools/check-prerequisites.sh` checks all of them and
tells you which step to look at. It changes nothing, so run it first and only
do the steps it marks `FAIL` or `WARN`.

### 1. Hibernation allowed

Fedora allows hibernation once there is a disk swap (step 2) and Secure Boot is
off (step 4). Nothing else needs to be enabled. If you, or a guide you
followed, edited `/etc/systemd/sleep.conf` or `/etc/systemd/logind.conf`, check
that no `AllowHibernation=no` is left in there.

### 2. Swap on disk, at least as big as RAM

Fedora only creates zram by default, and zram cannot hold a hibernation image.
You need a swap partition or a swap file on disk:

- **Size:** at least the size of RAM. **RAM + 25 %** is better: 20 GB for
  16 GB of RAM, 40 GB for 32 GB. The swap has to hold the memory pushed out
  before hibernating *and* the image itself. Too little swap does not break
  anything: the script tells you, with a size suggestion, and cancels.
- zram can stay. Keep it at its higher priority (Fedora's default) so normal
  swapping still goes to zram; the disk swap is mostly used for hibernation.

**Option A: swap partition** (what was tested). Shrink a partition with KDE
Partition Manager, from a live USB if it is the system partition, and create a
new one of type *linux-swap*. Then:

```bash
sudo mkswap /dev/nvme0n1pX            # X = your new partition
sudo blkid /dev/nvme0n1pX             # note the UUID
echo 'UUID=<that-uuid> none swap defaults,pri=-2 0 0' | sudo tee -a /etc/fstab
sudo swapon -a
swapon --show                         # zram and the partition are both listed
```

**Option B: swap file on btrfs** (Fedora's default file system, *not tested
here*):

```bash
sudo btrfs subvolume create /swap
sudo btrfs filesystem mkswapfile --size 20g /swap/swapfile
sudo semanage fcontext -a -t swapfile_t '/swap(/.*)?' && sudo restorecon -RF /swap
echo '/swap/swapfile none swap defaults,pri=-2 0 0' | sudo tee -a /etc/fstab
sudo swapon -a
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile   # = resume_offset for step 3
```

### 3. Resume at boot

At boot, the kernel has to know where the image is.

```bash
# tell the kernel which swap holds the image (UUID from step 2)
sudo grubby --update-kernel=ALL --args="resume=UUID=<swap-uuid>"
# swap file only: also add the offset printed in step 2
#   sudo grubby --update-kernel=ALL --args="resume_offset=<offset>"

# make sure the initramfs can resume
echo 'add_dracutmodules+=" resume "' | sudo tee /etc/dracut.conf.d/resume.conf
sudo dracut -f --regenerate-all
```

systemd can also find the image without `resume=` on UEFI machines, but
`resume=` is more reliable.

The power-off mode (`HibernateMode=platform`) is set by the installer, so you
do not need to do anything for it. If an old guide had you put
`HibernateMode=shutdown` in `/etc/systemd/sleep.conf`, comment that line out:
it is what hangs the power-off.

### 4. Secure Boot off

With Secure Boot on, Fedora's kernel runs in *lockdown* mode, which disables
hibernation completely. Check:

```bash
cat /sys/kernel/security/lockdown     # [none] is needed; [integrity] = Secure Boot on
```

To turn it off: BIOS (press `Del` at power-on) → **Security** → **Secure
Boot** → **Disabled**. The RPM Fusion NVIDIA driver keeps working; without
Secure Boot it does not need to be signed.

### 5. NVIDIA driver settings

This is for the RPM Fusion driver (`akmod-nvidia`) with the **open** kernel
modules, the default for RTX 20 series and newer since driver 560. Check with
`modinfo -l nvidia`, which should print `Dual MIT/GPL`.

Create `/etc/modprobe.d/nvidia-hibernate.conf`:

```
# Save all video memory into a file during hibernation, on disk not in RAM,
# and let the open driver do it from the kernel's own suspend notifiers.
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp NVreg_UseKernelSuspendNotifiers=1
options nvidia-drm modeset=1
```

Remove any other files in `/etc/modprobe.d/` that set the same options, so
they cannot conflict. Then:

```bash
lsinitrd | grep -q 'nvidia.*\.ko' && sudo dracut -f   # only if NVIDIA is in the initramfs
sudo reboot
# after the reboot:
grep -E 'Preserve|TemporaryFile|UseKernelSuspend' /proc/driver/nvidia/params
#   PreserveVideoMemoryAllocations: 1
#   UseKernelSuspendNotifiers: 1
#   TemporaryFilePath: "/var/tmp"
```

- Leave `nvidia-suspend`, `nvidia-hibernate` and `nvidia-resume` enabled. With
  `UseKernelSuspendNotifiers=1` they skip themselves ("Skipped due to
  'exec-condition'" in the journal), which is correct.
- `/var/tmp` needs free space at least the size of the GPU memory (8 GB on the
  RTX 4060).
- With the **closed** NVIDIA modules, leave out `NVreg_UseKernelSuspendNotifiers=1`;
  the three services do the work instead. Not tested.

---

## Install

```bash
git clone https://github.com/accaderi/msi-bravo15-c7vf-fedora-hibernation-fix.git
cd msi-bravo15-c7vf-fedora-hibernation-fix
sudo bash install.sh
```

The installer:

1. Copies the files:
   - `/usr/local/sbin/hibernate-prepare`: the script;
   - `/etc/systemd/system/hibernate-prepare.service`: runs it before every
     hibernation, *required* by it, so a cancel stops the hibernation;
   - `/usr/lib/systemd/system-sleep/hibernate-prepare`: runs it after waking;
   - `/etc/systemd/sleep.conf.d/hibernate-prepare.conf`: `HibernateMode=platform`;
   - `/etc/hibernate-prepare.conf`: settings, all commented out. Running the
     installer again updates it to the current list and keeps the values you
     set (the previous file is kept as `.old`).
2. Builds and installs the SELinux module `nvidia_hibernate_local`, which lets
   the NVIDIA driver write to `/var/tmp` while hibernating. It installs the
   `checkpolicy` package if missing.
3. Runs `tools/check-prerequisites.sh` and stops if anything fails.
4. Offers **calibration**: a complete test hibernation that restores at once
   instead of powering off. It measures how much your GPU drivers add while
   hibernating. The screens go black for about a minute, then everything comes
   back. Save your work first, and have only a few apps open.

Calibration with few apps does not make later hibernations with many apps
riskier. What it measures is the GPU drivers, which barely depend on how many
apps are open. Your apps are pushed to disk either way. Every real hibernation
measures again, and the largest value ever measured is the one used. To check
the heavy case, run `sudo hibernate-prepare calibrate` once more with your
heaviest GPU app open, for example a video editor with a project loaded.

---

## Check that it works

1. Save your work, then click **Hibernate** in the KDE menu.
2. Wait, hands off (see [Power button and lid](#power-button-and-lid)). The
   screen switches to a text screen:

   | Phase | Screen | Caps Lock light | Time (16 GB, tested) |
   |---|---|---|---|
   | Memory pushed to disk | "HIBERNATING", memory counting down | blinks | 10–30 s |
   | Kernel freezes everything, makes the copy, writes it | kernel messages, then black; fans may run | stops (built-in keyboard disconnected) | 30–90 s |
   | Power-off | off | off | |

   Nothing changing for more than **3 minutes** means it is stuck; see
   [Troubleshooting](#troubleshooting).

   The screen stays black while the image is written, because the AMD driver
   does not wake the screen just before a power-off. With `DETACH_KEYBOARD=0`
   the light keeps blinking through the black phase (steady for 10–20 s while
   the copy is made), but then the power button and keyboard can roll the
   hibernation back.
3. Power on. After GRUB, the screen goes back from the text screen to the lock
   screen; sign in and everything is as you left it. Plasma locks the screen before every sleep. You can turn
   that off in System Settings → Screen Locking.
4. Look at the result:

   ```bash
   sudo tail -6 /var/log/hibernate-prepare.log
   sudo hibernate-prepare status
   ```

   A good run in the log:

   ```
   plan: RAM 15172 MiB, image limit 7330 MiB, GPU allowance 4352 MiB (growth 3072, ...), keep in RAM 2978 MiB (cancel above 3746); in use 10392 MiB ...
   zram swap /dev/zram0 disabled
   in use after pushing to disk: 3170 MiB (target 2978 MiB)
   zram swap /dev/zram0 re-enable requested
   learned: image ok, sized 3567 MiB, needed 6023 MiB, GPU growth 2456 MiB ...
   ```

   Ending a bit above the target is normal: kernel, driver and desktop memory
   cannot be moved to disk. Only ending above "cancel above" stops the
   hibernation.

---

## Daily use

- **Just use Hibernate.** Everything is automatic.
- **The first minute after waking can be slow:** the apps' memory is on disk
  and comes back as you use them.
- **If you get a "Hibernation cancelled" notification,** nothing is lost. It
  says why:
  - *Not enough swap space* — close some apps, or make the swap bigger; the
    notification suggests a size based on what you actually had open.
  - *Not enough memory could be moved to disk* or *Too much GPU memory in
    use* — close graphics-heavy apps (video editors, games, 3D, many browser
    windows with video) and try again.
- **When the image would not fit,** and you also use
  [plasma-reopen-windows](https://github.com/accaderi/plasma-reopen-windows)
  (KDE Plasma), the windows are minimized first: what a window shows is
  graphics memory that stays in RAM, and a minimized playing video gives back
  about 100 MiB after 20-30 s. The desktop is shown for that half minute,
  then memory is moved to disk again and the decision is made again. The
  windows come back after waking. Switch it off in that app (Overview,
  Hibernation). Without it, nothing changes.
- **More RAM later:** nothing to change. The script reads the RAM size every
  time. With 32 GB, about 11 GB can stay in RAM instead of 3 GB, and the swap
  should grow to about 40 GB (RAM + 25 %).
- **Regular swapping while you work does not get in the way.** Memory already
  in swap does not need to go into the image. Only the free space on the disk
  swap matters, and the script checks it every time.

### Power button and lid

**Power button → Hibernate works** with two settings that are on by default:

- On this laptop, a power-button press leaves the laptop's controller (which
  also runs the built-in keyboard) sending stray keyboard bytes and button
  events later. They arrived while the image was being written, the kernel
  took them as user activity and rolled the hibernation back, and the NVIDIA
  driver crashed on the way back: black screen, orange LED, long-press,
  session lost (5 of 5 times). Details in
  [INVESTIGATION.md](INVESTIGATION.md#step-11-the-power-button-rolls-hibernation-back).
- `DETACH_POWER_BUTTON=1` and `DETACH_KEYBOARD=1` disconnect the power-button
  driver and the built-in keyboard controller just before the kernel takes
  over, and reconnect them after waking. Since then: 3 of 3 power-button
  hibernations fine. The firmware still powers the laptop on with the button.
- If you set them to `0` (for example because the keyboard or power button
  ever stays dead after waking; a restart fixes that), hibernate from the
  start menu instead: that works without them.

To use it: System Settings → **Power Management** → "When power button
pressed" → **Hibernate**, in each profile you use (On AC Power, On Battery,
On Low Battery).

**Keyboard shortcut:** System Settings → Keyboard → Shortcuts → Power
Management → **Hibernate**. Works from any keyboard (built-in, USB,
Bluetooth); KDE warns if the keys are already taken. Tested with the
built-in and a USB keyboard: fine. Pick a combination you never type (for
example Meta+Shift+H); a global shortcut such as Shift+Q would hibernate on
every capital Q.

**Lid:** closing the lid → Hibernate works only partly, so it is not
recommended:

- With the lid closed, about 0.5 GB more stayed in RAM than usual; with many
  windows open the safety check cancelled (2 attempts, nothing lost). With
  fewer windows it worked (2 of 2).
- After waking, the desktop left the built-in screen switched off (it turns
  it off when the lid closes and missed the lid opening again). With
  `SCREEN_ON_AFTER_LID=1` (default) the script switches it back on, but only
  if the lid was closed when hibernation started and is open after waking.
  It cannot see whether you had switched that screen off yourself before
  closing the lid (the desktop has already turned it off by then); if you
  keep the built-in screen off on purpose, set `SCREEN_ON_AFTER_LID=0`.
  By hand: `kscreen-doctor output.eDP-1.enable`. (In the second test the
  desktop switched the screen on by itself; the fallback was not needed.)
- The lid is not disconnected like the power button, because reconnecting it
  could report "lid closed" and set off the lid action again.

Keep the lid on *Shut Down* or *Do nothing* and use the power button or a
shortcut.

**Touching things while it hibernates:** with the defaults, the built-in
keyboard and power button are disconnected, and USB devices (mice,
keyboards, receivers, the Bluetooth adapter) and the touchpad cannot wake it
(`NO_INPUT_WAKEUP=1`). Touching them should not cancel the hibernation, but
that has not been tested on purpose: to be safe, hands off until it is off.

- Always choose plain **Hibernate**, not *Hybrid sleep* or *Sleep, then
  hibernate*. Those take a different path in systemd that `hibernate-prepare`
  does not handle yet, so they would run into the original problems (image
  does not fit, NVIDIA crash).
- **Sleep (suspend) is not tested** with this fix. The C7VF only offers
  `s2idle` (`cat /sys/power/mem_sleep`). The screens switching off after a few
  idle minutes is not sleep; real sleep shows up in
  `journalctl -k | grep 'PM: suspend'`.

### Commands

```bash
sudo hibernate-prepare status      # all numbers, changes nothing
sudo hibernate-prepare calibrate   # test hibernation that restores at once, and learns
sudo tail /var/log/hibernate-prepare.log
cat /var/lib/hibernate-prepare/history   # date, image MiB, needed MiB, ok/failed, GPU growth MiB, GPU memory MiB
```

---

## Settings

`/etc/hibernate-prepare.conf` (uncomment to change; the file explains every
setting, with its values and when to change it):

| Setting | Default | Meaning |
|---|---|---|
| `DEFAULT_GROWTH_MIB` | 3072 | GPU growth assumed until a larger one is measured |
| `DEFAULT_VRAM_MIB` | 1024 | GPU memory in use that the default growth already covers; more in use adds to the allowance |
| `GROWTH_FACTOR_PCT` | 125 | safety factor on the growth for the *target* |
| `EXTRA_MARGIN_MIB` | 512 | fixed extra margin |
| `MAX_SECONDS` | 120 | time limit for pushing memory to disk |
| `RESERVED_MIB` | 1024 | RAM kept free for drivers while devices are frozen (`/sys/power/reserved_size`) |
| `LIMIT_SLACK_MIB` | 256 | keep the image this far below half of RAM |
| `IMAGE_RATIO_PCT` | 70 | expected compressed image size vs. memory, for the swap-space check |
| `NOTIFY` | 1 | desktop notification when cancelled (0 = off) |
| `PROGRESS` | 1 | text screen with progress and blinking Caps Lock while hibernating (0 = off; see below) |
| `DETACH_POWER_BUTTON` | 1 | disconnect the power-button driver while hibernating (see [Power button and lid](#power-button-and-lid)) |
| `DETACH_KEYBOARD` | 1 | disconnect the built-in keyboard controller while hibernating; the Caps Lock light stops once the kernel takes over |
| `SCREEN_ON_AFTER_LID` | 1 | hibernated with the lid closed and woken with it open: switch the built-in screen back on (0 if you keep it off on purpose) |
| `MODEL_RUNS` | 3 | after this many successful hibernations with the GPU memory recorded, "does it fit?" is decided from what the graphics driver holds at that moment instead of a fixed worst case; the limit is then the largest image that has worked on this machine |
| `DIAGNOSE` | 1 | log what stays in RAM (kernel, GPU memory) before hibernating, and after waking the slowest devices and driver warnings; `status` then also shows how much may stay in RAM according to your own history (0 = off) |
| `NO_INPUT_WAKEUP` | 1 | USB devices (mice, keyboards, receivers, Bluetooth adapter) and the touchpad cannot cancel the hibernation |
| `PROGRESS_VT` | 8 | text console used for the progress screen |
| `UNLOAD_MODULES` | empty | drivers unloaded while hibernating and reloaded after, for hardware that blocks the power-off; not needed on the C7VF |

### How the numbers are used

For 16 GB:

```
image limit   = RAM/2 − 256           = 15172/2 − 256          = 7330 MiB
target        = limit − growth×1.25 − 512 − extra GPU memory   = 2978 MiB   (aimed for)
cancel above  = limit − growth − 512 − extra GPU memory        = 3746 MiB
```

`growth` is the larger of `DEFAULT_GROWTH_MIB` and the largest growth ever
measured on this machine.

**8 GB of RAM:** half of RAM minus a 3 GB allowance leaves almost nothing, so
hibernation would always cancel. If your GPU drivers grow less, which is
likely without a second GPU, set `DEFAULT_GROWTH_MIB` lower and calibrate. The
script then keeps the largest measured value, so it stays safe.

### Progress screen

On by default (`PROGRESS=1`):

- As soon as you click Hibernate, the script switches from the desktop to a
  full-screen text console (VT 8). It shows how much memory is still in RAM
  while it is pushed to disk, then the kernel's own messages.
- The Caps Lock light gets the kernel's *heartbeat* pattern (blink-blink,
  pause) while memory is pushed to disk. With `DETACH_KEYBOARD=1` (default)
  it stops when the kernel takes over, because the built-in keyboard is then
  disconnected; with `DETACH_KEYBOARD=0` it keeps blinking through the black
  phase.
- After waking up, or after a cancel, it switches back to the desktop and the
  light returns to normal Caps Lock behaviour.
- During `calibrate`, the screen also wakes up while the image is written and
  read back, so you see more kernel text there than in a real hibernation.

If the screen stays on text after waking up, press **Ctrl+Alt+F2** (or F1):
your session is there. A display problem never stops the hibernation; the
script ignores it and continues. To turn it off: `PROGRESS=0` in
`/etc/hibernate-prepare.conf`.

---

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| No Hibernate in the KDE menu | no disk swap, or Secure Boot on | Prerequisites 2 and 4, then reboot |
| Hibernate looks like a log-out, then back at the desktop | NVIDIA blocked by SELinux | `journalctl -b \| grep 'NVRM: PM hibernate notifier'`; run `sudo bash install.sh` again (installs the SELinux module) |
| "Hibernation cancelled" notification | working as designed | follow the text; see [Daily use](#daily-use) |
| Black screen, orange LED, fans, after ~3 min back at the sign-in screen *without* having powered off | image did not fit | `sudo hibernate-prepare status` and the log; send them in an issue |
| Black screen, orange LED, stays like that; after a long-press it boots fresh | image did not fit and the NVIDIA driver crashed (driver bug after an aborted hibernation) | same; after the reboot: `journalctl -b -1 -k \| grep -E 'PM:\|NVRM\|BUG'` |
| Orange LED, silent, never powers off; after a long-press it **does** resume your session | power-off mode is not `platform` | `systemd-analyze cat-config systemd/sleep.conf \| grep HibernateMode`; the last one listed must be `platform` |
| Powers off, but boots a fresh session | resume not found | Prerequisites 3; `cat /proc/cmdline` must show `resume=` |
| Hibernation started with the **power button**: black screen, orange LED, long-press needed, then a fresh boot | `DETACH_POWER_BUTTON` / `DETACH_KEYBOARD` are off: the controller's stray keyboard bytes after the press make the kernel roll the hibernation back (log: `Spurious ACK on isa0060/serio0`, `Wakeup pending, aborting suspend`), and the NVIDIA driver crashes on that path | set both to 1, or hibernate from the start menu; see [Power button and lid](#power-button-and-lid) |
| Built-in keyboard or power button dead after waking | reconnecting it failed (log: `could not reconnect`) | restart, or `echo i8042 \| sudo tee /sys/bus/platform/drivers/i8042/bind` (keyboard), `echo PNP0C0C:00 \| sudo tee /sys/bus/platform/drivers/acpi-button/bind` (power button); if it happens again, set `DETACH_KEYBOARD=0` / `DETACH_POWER_BUTTON=0` and hibernate from the start menu |
| Power button set to Hibernate does nothing | KDE's power management (PowerDevil) gets the key but ignores it; seen after a log-out screen had been left open in the background (`plasma-shutdown` and `ksmserver-logout-greeter` still running) | `systemctl --user restart plasma-powerdevil.service`, or log out and back in |
| Power button light orange instead of white | not a fault: on MSI laptops the light is white when only the built-in AMD graphics run and orange when the NVIDIA card is on. The HDMI and USB-C display outputs are wired to the NVIDIA card, so with an external monitor plugged in it is always orange (already from the end of the MSI logo) | nothing to do; unplug the external monitors and it turns white |
| Wi-Fi missing after waking | driver did not reinitialize | `sudo modprobe -r mt7921e && sudo modprobe mt7921e`; if it happens often, set `UNLOAD_MODULES="mt7921e"` |

Tests that find which stage fails:

```bash
sudo bash tools/hibernate-stage-test.sh   # kernel test modes, one stage at a time (freezer ... core)
sudo hibernate-prepare calibrate          # full image creation, restores instead of powering off
```

The results are in `/var/log/hibernate-stage-test.log` and
`/var/log/hibernate-prepare.log`. When opening an issue, include those, the
output of `sudo bash tools/check-prerequisites.sh`, and
`journalctl -b -1 -k | grep -E 'PM:|NVRM|BUG'` if the laptop had to be
powered off by hand.

---

## Uninstall

```bash
sudo bash uninstall.sh
```

This removes the script, both systemd units, the sleep hook, the power-off
mode setting and the SELinux module. It asks before deleting the settings and
the learned history. Your swap, `resume=` and NVIDIA settings stay; undo those
by hand if you want.

---

## License

MIT, see [LICENSE](LICENSE). Use, change and share it freely. There is no
warranty: hibernation touches drivers and firmware, so save your work before
the first tries.
