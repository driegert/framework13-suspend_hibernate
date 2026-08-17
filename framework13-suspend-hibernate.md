# Framework 13 (AMD 7840U) — Suspend & Hibernate on Ubuntu 26.04

Working notes from fixing suspend/hibernate on **tinkertoy**, 2026-08-12 → 2026-08-16.
Covers what was broken, how it was diagnosed, what was installed, and the
non-obvious traps that cost the most time.

---

## Contents

1. [TL;DR](#tldr)
2. [System context](#system-context)
3. [Part 1 — Spurious wakeups](#part-1--spurious-wakeups)
4. [Part 2 — Deep sleep (s0i3) never being reached](#part-2--deep-sleep-s0i3-never-being-reached)
5. [Part 3 — Enabling hibernation](#part-3--enabling-hibernation)
6. [Part 4 — suspend-then-hibernate](#part-4--suspend-then-hibernate)
7. [Installed files — full inventory](#installed-files--full-inventory)
8. [Diagnostic cookbook](#diagnostic-cookbook)
9. [Gotchas worth remembering](#gotchas-worth-remembering)
10. [Troubleshooting](#troubleshooting)
11. [How to undo everything](#how-to-undo-everything)

---

## TL;DR

| | Before | After |
|---|---|---|
| Armed wake sources | 26 (incl. AC adapter, 4× USB-C PD ports, touchpad, keyboard) | 4 (lid, power button, RTC ×2) |
| Spurious wakes | 12 in 18 min with the lid shut | 0 in 27.8 h |
| s0i3 residency | repeatedly failing | 100.0% |
| Suspend power draw | unmeasured; `didn't reach deepest state` | **0.44 W** (0.79 %/hour) |
| Cost of being away 24 h | ~20% of the battery | **~1.6%, then zero** |
| Hibernate | disabled and unconfigured | working, 32 GB swap |

**Day-to-day behaviour now**

- Lid closed, undocked, on battery → s2idle for 2 h (instant resume), then automatic hibernate to disk
- Lid closed **with an external monitor** → stays awake (clamshell, intended)
- On AC → suspends, never hibernates
- Waking → **power button or lid only**. Keyboard and touchpad will *not* wake it.
- Unplugging the charger no longer wakes it — the original complaint

---

## System context

```
Framework 13, AMD Ryzen 7 7840U
Ubuntu 26.04 LTS, kernel 7.0.0-29-generic, systemd 259, GNOME/Wayland
BIOS 03.20 (all firmware current per fwupdmgr)
Secure Boot: disabled     kernel lockdown: [none]
RAM: 59.4 GiB             page size: 4096

/dev/nvme0n1  (1 TB, WD SN850X)  -- partition table FULL, 0 B unallocated
  p1   977M  ext4  /boot
  p2     1G  vfat  /boot/efi
  p3   95.4G ext4  /       UUID <your-root-uuid>
  p4  834.1G ext4  /home   UUID <your-home-uuid>
No LUKS, no LVM, no RAID.
```

**Critical platform fact:** this machine is **s2idle-only**.

```bash
cat /sys/power/mem_sleep      # -> [s2idle]      (no "deep"/S3 option)
cat /sys/power/state          # -> freeze mem disk
```

There is no S3. "Suspend" means modern-standby: the SoC must reach the hardware
**s0i3** state to actually save power. If it doesn't, the machine sits at
near-idle-desktop draw while nominally asleep — warm bag, dead battery.

---

## Part 1 — Spurious wakeups

### Symptom

Lid closed at 15:46:33 on 2026-08-11. Over the next 18 minutes it woke and
re-suspended **12 times**:

```
15:46:34  suspend entry  ->  15:46:42  suspend exit   (8s)
15:47:11  suspend entry  ->  15:47:17  suspend exit   (6s)
15:48:21  suspend entry  ->  15:48:22  suspend exit   (1s)
...
16:04:32  suspend entry  ->  (finally slept 16 hours)
```

Found with:

```bash
journalctl --since "7 days ago" --no-pager \
| grep -iE "PM: suspend entry|PM: suspend exit|Lid |Suspending"
```

Irregular 1 s–7 min intervals point at physical triggers (cables, movement),
not a timer.

### Root cause

Any device with `power/wakeup = enabled` can pull the machine out of s2idle.
26 were armed. Enumerate them:

```bash
find /sys/devices -path '*/power/wakeup' -type f 2>/dev/null | while read -r f; do
    [ "$(cat "$f")" = "enabled" ] && echo "${f#/sys/devices/}"
done | sed 's|/power/wakeup||' | sort
```

The culprits:

| Device | Why it's a problem |
|---|---|
| `ACPI0003:00/power_supply/ACAD` | **The AC adapter.** Unplug the charger → machine wakes. This was the original complaint. |
| `USBC000:00/power_supply/ucsi-source-psy-*` (×4) | USB-C PD ports. Any renegotiation, cable wiggle or dock blip wakes it. |
| `AMDI0010:03/i2c-1/i2c-PIXA3854:00` | Touchpad. Lid pressure on the pad generates wake events with the lid shut. |
| `platform/i8042/serio0` | Keyboard. |
| `XHC0`–`XHC4`, `NHI0`/`NHI1` + domains | USB controllers and USB4/Thunderbolt. |
| `GPP6`, `GP11`, `GP12` | PCIe bridges. |

> **Careful — a counter that looks like evidence but isn't.**
> `wakeup_active_count` (2321 for the keyboard, 12729 for the touchpad) counts
> every keystroke and touch **while awake**. It is *not* a count of wakeups.
> The useful field is `wakeup_abort_count`, and all sysfs counters reset at boot.

### Fix

A policy script that disarms everything except the lid, the power button, and
the RTC. Run at boot **and again before every sleep**.

Why the pre-sleep run matters: **UCSI power-supply devices are destroyed and
recreated on USB-C PD renegotiation, and come back `wakeup=enabled`.** So do
newly plugged USB devices. A boot-only fix silently drifts back to broken over
the course of a day.

> Confirmed live on 2026-08-16: a **Glorious Model D wireless mouse** (`7-1.3.2`)
> and a **Realtek USB LAN adapter** (`8-1.2`) plugged into the dock both showed
> up `wakeup=enabled`. An armed wireless mouse would wake the laptop on any desk
> bump. The pre-sleep hook disarms them before it ever suspends.

**Safety design:** the script *positively discovers* the lid and power-button
nodes first and **aborts without changing anything** if it can't find exactly
one of each. Without that guard, a renamed sysfs path on a kernel upgrade would
disarm all **83** wakeup nodes — lid and power button included — and still exit
0 reporting success, leaving a laptop that can only be recovered by holding down
the power button. (This defect was caught by an independent Codex review of the
first draft.)

**Why the RTC stays armed:** it cannot fire on its own — only if software
explicitly programs an alarm. It costs nothing and it is a hard prerequisite for
suspend-then-hibernate (Part 4).

### Verification

```
27.8 h suspended, 1 sleep segment, 0 interruptions
last_hw_sleep = 100124.2 s of 100125 s  ->  100.0% s0i3 residency
```

---

## Part 2 — Deep sleep (s0i3) never being reached

### Symptom

```
amd_pmc AMDI0009:00: Last suspend didn't reach deepest state
```

Repeatedly, in the same logs. The machine "suspended" but the SoC never entered
hardware sleep, so it drained at near-idle rates.

### Diagnosis

```bash
cat /sys/power/suspend_stats/last_hw_sleep    # microseconds in s0i3, last suspend
cat /sys/power/suspend_stats/total_hw_sleep
cat /sys/power/suspend_stats/success
sudo cat /sys/kernel/debug/amd_pmc/s0ix_stats  # root only
```

Compare `last_hw_sleep` against the wall-clock duration of the suspend. Anything
near 100% is healthy.

### Fix

No separate fix — it resolved along with Part 1. A device that keeps asserting a
wake signal is frequently the same thing blocking s0i3, and a 1-second suspend
can't reach deep sleep regardless.

### Measured result

```
Elapsed suspend         178.1 s
Timekeeping suspended   177.2 s
last_hw_sleep           177.3 s   ->  99.5%
```

and over 27.8 h: **100.0%**, `0` occurrences of `didn't reach deepest state`.

### Measuring actual power draw

`upower` **cannot log while the machine is asleep**, so comparing its history
before and after compares a sample to itself and reports a bogus `0.00 %/hour`.
Read the live charge counters and subtract the awake time instead — that's what
`~/.local/bin/suspend-report` does.

Note this battery exposes `charge_*` / `current_now` (µAh, µA), **not**
`energy_*`.

```
Result: 28 mA / 0.44 W / 0.79 %/hour  (~19% per 24 h asleep)
```

That is a healthy figure for this platform. It will not match a true S3 laptop
(~0.1 W), because S3 does not exist on the 7840U. **That is the reason for Part 3:
you don't beat 0.44 W, you stop paying it after a couple of hours.**

---

## Part 3 — Enabling hibernation

### Why

s2idle at 0.44 W costs ~20% of the battery per day. Hibernation costs **zero**.
The goal is to pay the s2idle rate briefly for instant resume, then drop to disk.

### Starting state

```bash
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanHibernate      # -> s "no"

cat /sys/power/resume            # -> 0:0     (no resume device configured)
cat /sys/power/resume_offset     # -> 0
swapon --show                    # -> 8 GB /swap.img
```

### Swap sizing

The kernel's default `image_size` is 23.7 GiB (2/5 of RAM). Images observed in
practice:

| Cycle | Pages | Size |
|---|---|---|
| Test cycles, shortly after a reboot (×4) | 2.37M – 2.98M | 9.7 – 12.2 GB |
| **First real overnight run, end of a working day** | **6.35M** | **26.0 GB (24.2 GiB)** |

**The original 8 GB swap could never have held any of them.** Swap does *not*
need to equal RAM — only to hold the image of what's actually in use — but the
2.7× spread above is the point: **hibernating a freshly-booted machine tells you
nothing about the size you actually need.** The 26.0 GB image filled **76%** of
the 32 GiB swapfile, so the headroom is real but not lavish. If `/` ever allows
it, 40 GB would be the more comfortable number.

### Why the swapfile is on `/` and not `/home`

`/home` has vastly more free space, and it was the obvious choice. It does not
work:

```bash
systemctl show systemd-logind -p ProtectHome
# ProtectHome=yes
```

**systemd-logind runs with `/home` hidden from it**, so it cannot `stat()` a
swapfile there and may refuse hibernation regardless of everything else being
correct ([systemd#15354](https://github.com/systemd/systemd/issues/15354)).

Keeping the path as `/swap.img` also meant **`/etc/fstab` needed no change at
all**, which removed a whole class of risk.

### Swapfile vs. swap partition

A swap **partition** needs only `resume=UUID=<swap-uuid>` — no `resume_offset`,
nothing that can drift. But this disk has **0 bytes unallocated**, so it would
mean shrinking `/home` offline from a live USB with 563 GB of data on it. Not
worth it.

The swapfile's one real weakness: **`resume_offset` is a physical block offset
baked into the kernel cmdline.** If the swapfile is ever recreated, resized, or
restored from backup, hibernate still *succeeds* and **resume silently fails,
losing the session.** → *Re-run the setup script if you ever touch the swapfile.*

### The procedure

```bash
# 1. Build the new swapfile BEFORE destroying the old one, so a failure
#    anywhere leaves a bootable machine with working swap.
dd if=/dev/zero of=/swap.img.new bs=1M count=32768 status=progress
chmod 600 /swap.img.new
mkswap /swap.img.new
sync

# 2. Swap over (the only window with no swap is one rm + mv)
swapoff /swap.img            # treat failure as FATAL, do not "|| true" this
rm -f /swap.img
mv /swap.img.new /swap.img   # same fs -> inode and extents unchanged
swapon /swap.img
sync

# 3. Physical offset of the FINAL file at its FINAL path.
#    -b4096 pins the reporting unit to the page size.
filefrag -b4096 -v /swap.img | awk '/^[[:space:]]*0:/{print $4; exit}' | tr -cd '0-9'
# -> 20113408

# 4. Kernel cmdline
#    GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=<root-uuid> resume_offset=20113408"
update-initramfs -u -k all   # BEFORE update-grub (see gotcha below)
update-grub
```

`dd` rather than `fallocate`: a fully written file has no unwritten extents, so
the physical offset is unambiguous. Fragmentation is fine — a 4 MB file already
has 2 extents, and the 32 GB one has **61**. `resume_offset` only locates the
swap header; swsusp chains the rest.

### Ubuntu blocks hibernation at the policy layer

Everything above can be perfect and `CanHibernate` will still say `"no"`:

```js
// /usr/share/polkit-1/rules.d/com.ubuntu.desktop.rules
// "Disable hibernate by default in Ubuntu"
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.login1.hibernate" || ...) {
            return polkit.Result.NO;
    }
});
```

> **Read the return value carefully.** `CanHibernate` returns **`"na"`** when
> hibernation is genuinely *unsupported*, and `"yes"`/`"no"`/`"challenge"` from
> **polkit**. `"no"` means *policy denied*, not *impossible*.

Override, in `/etc/polkit-1/rules.d/10-enable-hibernate.rules` — `10-` sorts
before `com.ubuntu.desktop.rules` and polkit stops at the first rule that
returns a value:

```js
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions" ||
         action.id == "org.freedesktop.upower.hibernate") &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
```

Scoped to `local && active` deliberately — matching upstream systemd's
`allow_active=yes`, and stopping a **remote desktop** session from hibernating
the machine and killing its own access. `hibernate-ignore-inhibit` is deliberately
left at its `auth_admin` default.

There is **no separate `suspend-then-hibernate` polkit action** — systemd
authorises it against `org.freedesktop.login1.hibernate`, so this one rule
covers both.

> `/etc/polkit-1/rules.d/` is mode **0700 root-only** — `ls` as a normal user
> shows nothing. Verify with `sudo ls -la /etc/polkit-1/rules.d/`.

### Verified working

```
PM: hibernation: Need to copy 2904148 pages          (~11.9 GB)
PM: hibernation: Hibernation image restored successfully.
```

**How to tell resume genuinely worked:** resuming from hibernation restores the
*same kernel session*, so the **boot ID does not change**.

```bash
journalctl --list-boots | tail -3
uptime -s
```

If `uptime -s` still shows the pre-hibernate boot time, the session was
preserved. A *failed* resume produces a **new** boot ID. This also means
`journalctl -b -1` after a successful hibernate points at the boot *before* the
one you were in — which looks alarming and is actually the proof it worked.

---

## Part 4 — suspend-then-hibernate

### Config

`/etc/systemd/sleep.conf.d/10-hibernate-delay.conf`
```ini
[Sleep]
HibernateDelaySec=2h
HibernateOnACPower=no
```

`/etc/systemd/logind.conf.d/10-lid-sleep.conf`
```ini
[Login]
HandleLidSwitch=sleep
HandleLidSwitchExternalPower=sleep
```

### Why `sleep` and not `suspend-then-hibernate`

`HandleLidSwitch=suspend` is a **literal** suspend — `SleepOperation=` does not
apply to it. Setting `sleep` instead makes logind evaluate candidates **at the
moment the lid closes**, in a fixed order:

```
suspend-then-hibernate -> hybrid-sleep -> suspend -> hibernate
```

taking the first the machine currently supports. So if hibernation ever breaks —
swapfile recreated, kernel change — the lid **falls back to a plain suspend by
itself** instead of failing to sleep.

### Why `HibernateDelaySec=2h` rather than leaving it unset

Unset, systemd estimates from the battery discharge rate and hibernates only
when the battery is nearly flat. More convenient, but it drains most of the pack
first — exactly the outcome this whole exercise was meant to prevent.

At 0.44 W, 2 h costs ~1.6% of the battery before it goes to disk, whether you're
away overnight or all weekend.

### Why `HibernateOnACPower=no`

Plugged in, the battery isn't draining, so hibernating buys nothing and costs
~18 s of WiFi firmware reload on resume. On AC it just stays suspended.

### Reliability

**6 cycles, 5 hibernated.** The single failure was the very first cycle, before
debug logging was enabled, and was never explained — same alarm, same `IRQ 9`
wake, same power state, opposite outcome. Cycles 2–6 were consecutive clean
successes.

Cycles 1–5 were short bench tests with `HibernateDelaySec` cut to 1–2 min.
Cycle 6, on 2026-08-16, was the first **real** one and the most informative:

```
18:57:03  lid closed   -> suspend
19:57:03  woke to sample the discharge rate, re-suspended
20:57:03  2 h elapsed  -> hibernate  (6353520 pages, 26.0 GB)
08:40:58  next morning -> image restored, 11 h 44 min at zero draw
```

The intermediate wake at the 1 h mark is systemd sampling the battery, not a
leaked wake source, and `HibernateDelaySec=2h` was honoured exactly. Resume
preserved boot ID `c38fad9e…` — the same session, unbroken across the night.

> **The failure mode matters:** if the handoff doesn't happen, the machine
> **wakes and stays awake**. The lid is already shut so no new lid event
> arrives; the only backstop is GNOME's `sleep-inactive-battery-timeout`
> (30 min). In a bag that is worse than plain suspend. If it ever recurs, see
> [Troubleshooting](#troubleshooting).

### Clamshell behaviour

With an external monitor attached, the lid does nothing — **by design, twice
over**:

1. logind reports `Docked=true`, so `HandleLidSwitchDocked=ignore` applies
2. `gsd-power` holds a `handle-lid-switch` **block** inhibitor
   ("External monitor attached"), so logind never sees the lid at all

That second one comes from
`org.gnome.settings-daemon.plugins.power lid-close-suspend-with-external-monitor false`.
GNOME only takes that inhibitor **when a monitor is present** — undocked, logind
owns the lid.

---

## Installed files — full inventory

| Path | Purpose |
|---|---|
| `/usr/local/sbin/framework-wakeup-policy` | Disarms all wake sources except lid, power button, RTC. Aborts without changes if it can't find lid + power button. Also sets `pm_debug_messages=1`. |
| `/etc/systemd/system/framework-wakeup-policy.service` | Applies the policy at boot (`After=basic.target`, `Before=sleep.target`) |
| `/etc/systemd/system-sleep/framework-wakeup-policy` | **Re-applies before every sleep** — the important one; catches USB/UCSI drift. `timeout 15` guarded, since systemd waits on sleep hooks. |
| `/etc/polkit-1/rules.d/10-enable-hibernate.rules` | Overrides Ubuntu's blanket hibernate denial (local + active only) |
| `/etc/systemd/sleep.conf.d/10-hibernate-delay.conf` | `HibernateDelaySec=2h`, `HibernateOnACPower=no` |
| `/etc/systemd/logind.conf.d/10-lid-sleep.conf` | `HandleLidSwitch=sleep` (+ external power) |
| `~/.local/bin/suspend-report` | Health report on the last suspend cycle |
| `/etc/default/grub` | `resume=UUID=<your-root-uuid> resume_offset=20113408` appended; timestamped `.bak` alongside |

**Current verified state**

```
armed wake sources:  PNP0C0D (lid), PNP0C0C (power button), pnp0/00:00 + rtc0/alarmtimer
/sys/power/resume        = 259:3
/sys/power/resume_offset = 20113408
swap                     = 32 G at /swap.img
CanSuspend / CanHibernate / CanSuspendThenHibernate = yes / yes / yes
```

---

## Diagnostic cookbook

```bash
# Health report on the last suspend cycle (duration, s0i3 %, wakes, drain)
suspend-report

# What is currently allowed to wake the machine
find /sys/devices -path '*/power/wakeup' -type f | while read -r f; do
    [ "$(cat "$f")" = "enabled" ] && echo "${f#/sys/devices/}"
done | sed 's|/power/wakeup||' | sort

# Hardware deep-sleep residency of the last suspend (microseconds)
cat /sys/power/suspend_stats/last_hw_sleep
cat /sys/power/suspend_stats/{success,fail}

# What woke it (requires pm_debug_messages=1, which the policy script sets)
journalctl -b | grep "Triggering wakeup"
#   IRQ 9 = the shared ACPI SCI = lid or power button.
#   ANY OTHER IRQ means a disarmed source is getting through.

# Count real sleep segments, NOT raw wake lines --
# one physical action fires a BURST of SCIs (a single button press logged 5).
journalctl -b | grep -c "Timekeeping suspended"

# Live watch of a sleep cycle
journalctl -f -o short-precise \
| grep -E "Lid (opened|closed)|sleep operation|[Hh]ibernat|PM: suspend (entry|exit)|Timekeeping suspended|Triggering wakeup|discharge rate|Attempting to|Set EFI variable" \
| grep -vE "Marking nosave|Disabling GPIO|memory bitmaps|efivarfs:"
#   NB: use "Lid (opened|closed)", not -i "lid " -- the latter matches "Invalid argument"

# suspend-then-hibernate success rate
echo "cycles:     $(journalctl -b -u systemd-suspend-then-hibernate | grep -c 'Starting systemd-suspend')"
echo "hibernated: $(journalctl -b -u systemd-suspend-then-hibernate | grep -c "operation 'hibernate'")"

# Capability check (remember: "na" = unsupported, "no" = polkit denial)
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanHibernate

# Confirm the swapfile offset still matches the cmdline (silent-failure guard)
grep -o 'resume_offset=[0-9]*' /proc/cmdline
sudo filefrag -b4096 -v /swap.img | head -4

# Who is blocking sleep / the lid
systemd-inhibit --list

# Effective merged config
systemd-analyze cat-config systemd/sleep.conf
systemd-analyze cat-config systemd/logind.conf
```

---

## Gotchas worth remembering

1. **`update-initramfs` here is a `dracut` shim, not initramfs-tools.**
   `dpkg -S /usr/sbin/update-initramfs` → `dracut`. So
   `/etc/initramfs-tools/conf.d/resume` is **inert**. Worse, dracut's
   `74resume/module-setup.sh` `check()` **excludes** the resume module unless
   `/proc/cmdline` *already* contains `resume=` — so the initramfs must be
   rebuilt **after** the GRUB change and a reboot. Verify with:
   ```bash
   sudo lsinitrd /boot/initrd.img-$(uname -r) | grep -i hibernate-resume
   ```

2. **The kernel cannot resolve a filesystem `UUID=` for resume** — only
   `PARTUUID=` or a device path. `resume=UUID=…` depends entirely on the
   initramfs resolving it. **`/sys/power/resume` reading `0:0` after boot means
   the initramfs resolver is missing.** Working value here is `259:3`.
   (`PARTUUID=<your-root-partuuid>` would be kernel-resolvable
   and independent of the initramfs, if that ever becomes a problem.)

3. **`ProtectHome=yes` on logind rules out `/home` for the swapfile.**

4. **Ubuntu disables hibernation via polkit**, and `CanHibernate="no"` means
   *policy denied*, not *unsupported* (that's `"na"`).

5. **`HoldoffTimeoutSec=30s`** — logind ignores lid events for 30 s after any
   resume, so the connectors can be re-detected. A lid test done too soon looks
   like a failure and isn't. Also true in real use: wake, then shut the lid
   within 30 s, and it won't sleep.

6. **Closing the lid while already suspended does fire an SCI**, but the s2idle
   loop filters it and returns to s0i3 — verified: one continuous suspend, two
   `Timekeeping suspended` segments totalling 99.2% residency, and only **one**
   `PM: suspend exit`. It does not wake the machine.

7. **Kernel PM messages are timestamped at resume**, not when they happened —
   the console is suspended and the ring buffer flushes on wake. So
   `Suspending console(s)` legitimately appears *after* `Lid opened`.

8. **MT7922 WiFi fails `pci_pm_restore` (-110) on hibernate resume** and does a
   full firmware reload instead. Not a fault — but WiFi takes **~18 s** to come
   back (vs ~3 s from s2idle). Worth knowing before walking into a lecture.

9. **`filefrag` reports in filesystem blocks (4096 B here)**, matching the page
   size, so the value is directly usable as `resume_offset`. Confirmed
   independently — systemd computed the *same* `offset: 20113408` via its own
   FIEMAP call when writing the EFI `HibernateLocation` variable.

---

## Troubleshooting

**Machine wakes on its own again**
```bash
journalctl -b | grep "Triggering wakeup"     # any IRQ other than 9 = a leaked source
systemctl status framework-wakeup-policy.service
sudo /usr/local/sbin/framework-wakeup-policy  # re-apply by hand
```

**Battery drains while "asleep"**
```bash
suspend-report        # residency well below 95% means s0i3 isn't being reached
journalctl -b | grep "deepest state"
```

**Hibernate stopped working after touching the swapfile**
Re-run the setup script. The physical offset changed. Symptom: hibernate
succeeds, then the machine boots fresh and the session is gone.

**suspend-then-hibernate wakes but stays awake**
Enable debug logging and reproduce with a short delay:
```bash
sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' | \
  sudo tee /etc/systemd/system/systemd-suspend-then-hibernate.service.d/debug.conf
printf '[Sleep]\nHibernateDelaySec=2min\n' | sudo tee /etc/systemd/sleep.conf.d/99-test.conf
sudo systemctl daemon-reload

systemctl suspend-then-hibernate
journalctl -b -u systemd-suspend-then-hibernate | grep -E "Starting|Attempting|Performing"
```
A healthy cycle shows `Attempting to hibernate` → `Performing sleep operation 'hibernate'`.
**Remove both test files afterwards.**

If it turns out to be genuinely intermittent, the fallback is an explicit
`/etc/systemd/system-sleep/` hook: record a target timestamp and arm the RTC on
suspend, then on wake compare wall-clock against the target and trigger
hibernate if the deadline passed. No inference, nothing to be flaky.

**Can't wake the machine by typing**
Working as configured. Keyboard and touchpad are deliberately disarmed. Use the
power button. To re-arm just the keyboard:
```bash
echo enabled | sudo tee /sys/devices/platform/i8042/serio0/power/wakeup
```
(and add an exception to `framework-wakeup-policy` to make it stick).

---

## How to undo everything

**Wake-source policy**
```bash
sudo systemctl disable --now framework-wakeup-policy.service
sudo rm /etc/systemd/system/framework-wakeup-policy.service \
        /etc/systemd/system-sleep/framework-wakeup-policy \
        /usr/local/sbin/framework-wakeup-policy
sudo systemctl daemon-reload
# wake sources return to kernel defaults on next reboot
```

**suspend-then-hibernate (keep plain suspend)**
```bash
sudo rm /etc/systemd/logind.conf.d/10-lid-sleep.conf \
        /etc/systemd/sleep.conf.d/10-hibernate-delay.conf
sudo systemctl restart systemd-logind   # or just reboot
```

**Hibernation entirely**
```bash
sudo rm /etc/polkit-1/rules.d/10-enable-hibernate.rules
sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub
sudo rm -f /etc/initramfs-tools/conf.d/resume
sudo update-initramfs -u -k all && sudo update-grub
# optionally shrink /swap.img back to 8 GB and re-run mkswap
```

---

## Maintenance notes

- **Exclude `/swap.img` from backups** (Déjà Dup, Timeshift, rsync) — 32 GB of
  swap state with no reason to archive.
- **`/` sits at ~22 GB free** after the 32 GB swapfile. Keep an eye on snaps and
  `/var`.
- **Baseline for comparison: 0.44 W / 0.79 %/hour** in s2idle, 100% s0i3
  residency. Run `suspend-report` if something feels off.
- **Re-run the hibernate setup if the swapfile is ever recreated.**
