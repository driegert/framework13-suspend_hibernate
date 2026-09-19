# Framework 13 (AMD 7840U) — Suspend & Hibernate on Ubuntu 26.04

Working notes from fixing suspend/hibernate on **tinkertoy**, 2026-08-12 → 2026-08-19,
plus the postmortems that followed (Parts 6–10, to 2026-09-18).
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
7. [Part 5 — Migrating to a swap partition](#part-5--migrating-to-a-swap-partition)
8. [Part 6 — A lost session, diagnosed](#part-6--a-lost-session-diagnosed)
9. [Part 7 — The kernel-upgrade trap](#part-7--the-kernel-upgrade-trap)
10. [Part 8 — A panic during hibernation, and no vmcore](#part-8--a-panic-during-hibernation-and-no-vmcore)
11. [Part 9 — A lockup an hour after resume: the drm/ttm bulk_move bug](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)
12. [Part 10 — Part 8's panic, named — and the capture kernel that ate the image](#part-10--part-8s-panic-named--and-the-capture-kernel-that-ate-the-image)
13. [Installed files — full inventory](#installed-files--full-inventory)
14. [Diagnostic cookbook](#diagnostic-cookbook)
15. [Gotchas worth remembering](#gotchas-worth-remembering)
16. [Troubleshooting](#troubleshooting)
17. [How to undo everything](#how-to-undo-everything)

---

## TL;DR

| | Before | After |
|---|---|---|
| Armed wake sources | 26 (incl. AC adapter, 4× USB-C PD ports, touchpad, keyboard) | 4 (lid, power button, RTC ×2) |
| Spurious wakes | 12 in 18 min with the lid shut | 0 in 27.8 h |
| s0i3 residency | repeatedly failing | 100.0% |
| Suspend power draw | unmeasured; `didn't reach deepest state` | **0.44 W** (0.79 %/hour) |
| Cost of being away 24 h | ~20% of the battery | **~1.6%, then zero** |
| Hibernate | disabled and unconfigured | working, **64 GB swap partition** |
| Resume fragility | — | `resume_offset` eliminated; nothing left to drift |
| Emergency hibernate reserve | 2% of battery (packaged default) | **7%** |
| Hibernating on a stale kernel | silently lost the session **and** 72% of the battery | lid plain-suspends until you reboot |
| WiFi back after hibernate resume | ~18 s (MT7922 firmware reload) | **~4 s** (AX210, clean restore) |
| Resume from hibernation on 7.0.0-28 … -31 | can lock the machine minutes–hours later (upstream drm/ttm bug) | **reboot after a hibernation resume** until the fix ships; `ttm-fix-check` says when |

**Day-to-day behaviour now**

- Lid closed, undocked, on battery → s2idle for 2 h (instant resume), then automatic hibernate to disk
- Lid closed **with an external monitor** → stays awake (clamshell, intended)
- On AC → suspends and stays suspended; **unplug and the 2 h countdown starts from that moment**
- Waking → **power button or lid only**. Keyboard and touchpad will *not* wake it.
- Unplugging the charger no longer wakes it — the original complaint
- Battery critically low while awake → hibernates at 7%, with enough charge left to finish writing the image
- **A kernel was installed but not yet booted** → lid closed *plain-suspends* instead of hibernating, until you reboot ([Part 7](#part-7--the-kernel-upgrade-trap))
- **Resumed from a hibernation image** → reboot before doing anything that matters, until Ubuntu ships the drm/ttm fix ([Part 9](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)). A plain suspend afterwards is fine.
- **A panic while an image is on disk** → the kdump capture kernel currently erases the image ([Part 10](#part-10--part-8s-panic-named--and-the-capture-kernel-that-ate-the-image)); stay on AC when the session matters so the 7% emergency hibernate never fires.

---

## System context

```
Framework 13, AMD Ryzen 7 7840U
Ubuntu 26.04 LTS, kernel 7.0.0-31-generic (7.0.0-29 when first written), systemd 259, GNOME/Wayland
BIOS 03.20 (all firmware current per fwupdmgr)
Secure Boot: disabled     kernel lockdown: [none]
RAM: 59.4 GiB             page size: 4096

/dev/nvme0n1  (1 TB, WD SN850X)
  p1   977M  ext4  /boot
  p2     1G  vfat  /boot/efi
  p3   95.4G ext4  /       UUID <your-root-uuid>
  p4  770.1G ext4  /home   UUID <your-home-uuid>
  p5    64G  swap          UUID <your-swap-uuid>   <- added 2026-08-19, see Part 5
No LUKS, no LVM, no RAID.

Until 2026-08-19 the table was FULL (0 B unallocated) with p4 running to the end
of the disk; that constraint shaped every decision in Part 3.
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
the 32 GiB swapfile, so the headroom was real but not lavish.

> That 76% is what eventually forced the issue. On the 64 GB partition installed
> in [Part 5](#part-5--migrating-to-a-swap-partition), the same class of image
> sits under 41%, and a light session measured **18.8%**.

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
nothing that can drift. But this disk had **0 bytes unallocated**, so it would
mean shrinking `/home` offline from a live USB. At the time, not worth it.

The swapfile's one real weakness: **`resume_offset` is a physical block offset
baked into the kernel cmdline.** If the swapfile is ever recreated, resized, or
restored from backup, hibernate still *succeeds* and **resume silently fails,
losing the session.**

> **This was the right call for about four days, and then it wasn't.**
> The migration is [Part 5](#part-5--migrating-to-a-swap-partition); the lost
> session that made the case for it is
> [Part 6](#part-6--a-lost-session-diagnosed).
>
> Worth noting what actually tipped the decision, because it was *not* the
> offset. The offset never drifted — it was verified correct at the moment of
> the failure. What mattered was **fragmentation**: the 32 GB swapfile lived in
> **61 extents scattered across 92 GB** of a 94 GB filesystem, making the image
> write slow, and a slow write is a wide window in which to lose power.

### The procedure (swapfile — superseded by Part 5)

> Kept because the *shape* of it is the reusable lesson: build the replacement
> before destroying the original, so any failure leaves a bootable machine.
> For the current setup, use `setup-hibernate.sh --partition /dev/…` instead.

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
~18 s of WiFi firmware reload on resume.

**This does not mean "suspend on AC and you never get the disk handoff."** The
man page is explicit:

> If this option is disabled, the countdown of `HibernateDelaySec=` starts only
> after AC power is disconnected, keeping the system in the suspend state
> otherwise.

So suspending while plugged in parks the machine in s2idle indefinitely, and
**pulling the charger starts the 2 h clock from that moment.** The setting defers
the countdown until it matters rather than cancelling it.

One caveat: systemd can only notice the unplug while it is briefly awake, and
`SuspendEstimationSec` defaults to **60 min** — so detection lags by up to about
an hour, making the worst case roughly *1 h + 2 h* from unplug to hibernate.

> **This interacts with Part 1 on purpose.** The AC adapter (`ACAD`) is
> deliberately disarmed as a wake source — it was the original complaint — so an
> unplug event can no longer wake the machine to trigger an immediate
> re-evaluation. The trade is a possibly-delayed countdown start in exchange for
> a laptop that doesn't wake in your bag. Clearly worth it.

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

**Verified end-to-end on the swap partition, 2026-08-19:**

```
15:50:31  lid closed   -> suspend
17:50:31  Timekeeping suspended for 7198.836 seconds   <- 2 h, one unbroken segment
17:50:31  Performing sleep operation 'hibernate'...
18:22:17  Timekeeping suspended for 1897.523 seconds   <- 31.6 min at zero draw
18:22:17  PM: hibernation: hibernation exit            <- same boot ID
```

`HibernateDelaySec=2h` was honoured to within 1.2 s, and the whole cycle cost
about 4% of the battery.

> **Note the single segment.** On 2026-08-16 the same 2 h window was split into
> two ~3599 s halves, because systemd woke at the 1 h mark to sample the battery.
> It now has a **learned discharge rate** on file
> (`/var/lib/systemd/sleep/battery_discharge_percentage_rate_per_hour`, 1 %/hour,
> matching the 0.79 %/hour measured in Part 2), so it can schedule one alarm for
> the whole delay instead of waking to re-measure. Fewer wake/re-suspend cycles
> as the machine learns its own hardware.

**Then, on 2026-08-17, a cycle failed in a completely different way.** The
handoff worked perfectly — it hibernated exactly as designed — and the *resume*
lost the session. That one is [Part 6](#part-6--a-lost-session-diagnosed), and
it is the most useful thing in this document, because the technique for
diagnosing it generalises to every future hibernate failure.

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

## Part 5 — Migrating to a swap partition

*2026-08-19.* Retires `resume_offset` permanently and replaces 61 scattered
extents with one contiguous span.

### The direction of the shrink is the whole game

`/home` ran to the end of the disk. That leaves two ways to free 64 GB, and they
are **not** comparable:

| | What moves | Risk |
|---|---|---|
| Trim `/home`'s **right** edge, swap in the freed tail | only data living in that last slice | low — `/`, `/home`'s start, and every UUID untouched |
| **Grow `/`** instead | `/home`'s start sector, so all ~508 GB relocates | hours of I/O, and the one operation where a power cut destroys the filesystem |

Same live USB, wildly different exposure. Confirm afterwards that the start
sector genuinely didn't move:

```bash
for p in 3 4 5; do
  s=$(cat /sys/block/nvme0n1/nvme0n1p$p/start)
  z=$(cat /sys/block/nvme0n1/nvme0n1p$p/size)
  printf "p%s start=%-12s size=%-12s end=%s\n" "$p" "$s" "$z" "$((s+z-1))"
done
```

```
p3 start=4204544      size=200001536    end=204206079
p4 start=204206080    size=1615104000   end=1819310079   <- start UNCHANGED
p5 start=1819310080   size=134213632    end=1953523711   <- exactly p4's end + 1
```

`p4`'s start is identical to its pre-resize value, so no bulk relocation
happened. `p5` begins on the very next sector and runs to the last sector of the
disk.

### Configuration

```bash
sudo ./setup-hibernate.sh --partition /dev/nvme0n1p5
```

The script's ordering is the part worth copying. It activates the **new** swap
before disturbing the old, and it leaves the old swapfile on disk:

1. `mkswap` the partition (refuses whole disks, mounted devices, and anything
   backing `/`, `/home`, `/boot`, `/boot/efi`; needs `--force` to erase a real
   filesystem)
2. `swapon` the new partition
3. rewrite `/etc/fstab` — new `UUID=` entry added, old swap entries commented
   out, timestamped backup alongside
4. `swapoff /swap.img` but **do not delete it** — it stays as a fallback until a
   resume is proven
5. strip **both** `resume=` and `resume_offset=` from the cmdline, then write
   back `resume=UUID=<swap-uuid>` with **no offset**, and abort if a stale
   `resume_offset` survived the edit
6. `update-initramfs`, then `update-grub`

### Then the dracut two-step, again

Same trap as gotcha 1, and easy to skip because everything *looks* finished:

```bash
sudo reboot                        # 1. now /proc/cmdline finally has resume=
sudo update-initramfs -u -k all    # 2. only now will dracut include the module
sudo reboot                        # 3.
```

### Verification

```bash
cat /proc/cmdline | tr ' ' '\n' | grep resume   # -> resume=UUID=…, and NO resume_offset
cat /sys/power/resume                           # -> 259:5   (major 259, minor 5 = nvme0n1p5)
cat /sys/power/resume_offset                    # -> 0       (correct for a partition)
swapon --show
```

**`/sys/power/resume` is the check that matters**, and it subsumes the
`lsinitrd` grep: the kernel *cannot* resolve a filesystem `UUID=` by itself
(gotcha 2), so a real device number there is proof the initramfs resume module
is present and working. If it reads `0:0`, step 2 above didn't take.

### Result

```
PM: hibernation: Need to copy 3156089 pages     ->  12.04 GiB, 18.8% of the partition
ACPI: PM: Waking up from system sleep state S4      real S4, fully powered off
PM: hibernation: Hibernation image restored successfully.
efivarfs: removing variable HibernateLocation-…     pointer cleaned up
```

Boot ID unchanged. `/` went from **73% → 36% used** once `/swap.img` was
deleted, and resume was noticeably faster — partly the smaller image, but partly
one contiguous read instead of 61 scattered ones. Only the second half of that
is permanent.

---

## Part 6 — A lost session, diagnosed

*The failure that justified Part 5, worked through in full — because the method
matters more than this particular fault.*

### Symptom

"The machine was suspended a couple of nights ago. When I turned it on today it
seemed like it just started, not resumed."

### Step 1 — did it resume, or cold-boot?

This is the only question that matters first, and it has an exact answer.
**A successful resume keeps the same boot ID; a failed one starts a new boot.**

```bash
journalctl --list-boots
```

```
-6  c38fad9e…  Sun 2026-08-16 11:16:51  →  Mon 2026-08-17 20:29:01
-5  6fa9f292…  Wed 2026-08-19 13:37:10  →  Wed 2026-08-19 13:42:25
```

New boot ID, and ~41 hours unaccounted for. It cold-booted.

### Step 2 — did it actually hibernate?

Read the *tail* of the boot that ended:

```bash
journalctl -b -6 | tail -60
```

```
Aug 17 18:29:00  Suspending, then hibernating...
Aug 17 20:29:01  Timekeeping suspended for 6457.005 + 740.978 seconds   <- 2 h
Aug 17 20:29:01  System returned from sleep operation 'suspend-then-hibernate'.
Aug 17 20:29:01  Performing sleep operation 'hibernate'...
Aug 17 20:29:01  PM: hibernation: hibernation entry
```

suspend-then-hibernate did its job exactly. The journal ending there is *correct*
for a machine powering off. Note this also rules out a **failed** hibernate: had
the image not fit, the kernel would have thawed and the machine would have
stayed awake, logging it.

### Step 3 — what did the resume attempt say?

```bash
journalctl -b -5 | grep -iE 'resume|hibernat'
```

```
systemd-hibernate-resume-generator: Reported hibernation image:
  ID=ubuntu VERSION_ID=26.04 kernel=7.0.0-29-generic UUID=9cb3dc28-… offset=20113408
systemd-hibernate-resume: Unable to resume from device
  '/dev/disk/by-uuid/9cb3dc28-…' (259:3) offset 20113408, continuing boot process.
kernel: PM: Image not found (code -22)
```

**`-22` is `-EINVAL`: the kernel went to the right place and found no valid
swsusp signature there.**

### Step 4 — rule things out

| Suspect | Verdict |
|---|---|
| Stale `resume_offset` | **No.** The EFI `HibernateLocation` variable survived intact and pointed correctly. |
| Wrong offset all along | **No.** The same swapfile at the same offset had resumed 11 h 44 min of hibernation the previous night, same boot ID. |
| The partition resize | **No.** Boot -5 logged `nvme0n1: p1 p2 p3 p4` — `p5` did not exist yet. The resize happened at 14:04, *after* the failed resume at 13:37. |
| Image too large to fit | **No.** That aborts and leaves the machine awake (Step 2). |

### Step 5 — the conclusion

The image was written to a valid location but was **invalid on read-back**. That
is diagnostic, because of how swsusp orders its writes:

> **swsusp writes the page data first and the header signature LAST.**
> So an image write that doesn't complete produces *exactly* `-22` — and produces
> it silently. The machine cold-boots and the session is simply gone, with no
> error surfaced to the user.

The machine had been on battery since ~17:34 the previous day — over a day of
`ConditionACPower=true` jobs skipping — and was writing ~26 GB to this:

```
Adding 33554428k swap on /swap.img.  Priority:-1  extents:61 across:92004352k
```

**61 extents scattered across 92 GB of a 94 GB filesystem**, at the tail end of a
very long battery run. Losing power partway through is the leading explanation
and fits every piece of evidence.

> **Stated honestly: this is not proven.** The competing explanation is that a
> good image was invalidated later in that 41-hour window — an aborted resume
> would do it, and would leave no journal trace. Both explanations are addressed
> by the fixes below, which is why it was not worth chasing further.

### Step 6 — the fixes

**Faster write** — Part 5. One contiguous span instead of 61 extents directly
shrinks the window in which losing power destroys the session.

**More reserve** — the packaged UPower policy fires its emergency hibernate at
**2% battery**, which is a very thin margin from which to write a multi-gigabyte
image. `/etc/UPower/UPower.conf.d/10-hibernate-reserve.conf`:

```ini
[UPower]
PercentageCritical=10.0
PercentageAction=7.0
```

```
                    packaged   now
PercentageLow           20.0   20.0   (unchanged)
PercentageCritical       5.0   10.0
PercentageAction         2.0    7.0   <- the emergency hibernate trigger
```

`PercentageCritical` had to move as well — UPower requires
`Low > Critical > Action`, and an Action of 7.0 under a Critical of 5.0 would
have inverted them.

UPower 1.91.1 supports drop-ins, but the filename is validated against
`^[0-9][0-9]-[a-zA-Z0-9_-]*\.conf$` — a file that doesn't match is silently
ignored. Verify:

```bash
systemctl restart upower
journalctl -u upower --since -5min          # any parse error shows here
busctl call org.freedesktop.UPower /org/freedesktop/UPower \
    org.freedesktop.UPower GetCriticalAction    # -> s "HybridSleep"
```

> **The thresholds themselves are not exposed on D-Bus**, so that restart plus
> `GetCriticalAction` is the whole of the available verification. The return
> value is still worth reading: with `AllowRiskyCriticalPowerAction=false`,
> UPower falls back to a different action when it can't hibernate, so
> `HybridSleep` coming back confirms it still sees hibernation as available.

`CriticalPowerAction` is deliberately left at `HybridSleep`: it writes the image
*and* stays in s2idle, so plugging in resumes instantly while the disk image
covers the battery actually dying.

---

## Part 7 — The kernel-upgrade trap

*2026-08-19 → 08-21.* A second lost session, four days after
[Part 6](#part-6--a-lost-session-diagnosed) — same `-22`, entirely different
cause. The machine was left at ~93% with the lid shut and came back the next
evening at 22%, cold-booted, session gone.

The initial suspicion was the WiFi card, which had been swapped that afternoon.
It was the wrong suspect, and ruling it out took one line of log.

### The timeline

```
Aug 19 18:22:17  hibernation exit          <- a 2 h cycle that worked perfectly
Aug 19 18:25:16  apt upgrade starts        (Requested-By: dave)
Aug 19 18:26:14  linux-image-generic-hwe-26.04  7.0.0-29 -> 7.0.0-30
Aug 19 18:33:12  Lid closed.               <- still running 7.0.0-29
Aug 19 18:33:14  PM: suspend entry (s2idle)
Aug 19 20:33:14  Timekeeping suspended for 7199.006 seconds
Aug 19 20:33:15  Performing sleep operation 'hibernate'...
Aug 19 20:33:15  PM: hibernation: hibernation entry     <- last log, ever
Aug 20 18:16:15  cold boot, GRUB picks 7.0.0-30, RTC reset to 2023-01-01
Aug 20 18:16:03  PM: Image not found (code -22)
```

The upgrade **finished** seven minutes before the lid closed. Nothing was
mid-flight; dpkg was done and the system was idle. The trap is subtler than
"don't touch a laptop during an update": installing a kernel and *booting* it
are separate events, and hibernation silently depends on the second one.

### Two independent failures

Either one alone would have cost the session.

**1. The hibernate never completed.** `-22` is `-EINVAL` out of `swsusp_check()`
— the `S1SUSPEND` signature is not on the swap partition. Per
[gotcha 10](#gotchas-worth-remembering) that signature is written *last*, so its
absence means the write did not finish. The battery proves the machine never
powered off (below).

**2. The image would have been rejected anyway.** The EFI pointer records who
wrote it:

```
systemd-hibernate-resume-generator: Reported hibernation image:
    ID=ubuntu VERSION_ID=26.04 kernel=7.0.0-29-generic
    UUID=d7158588-… offset=0
```

`GRUB_DEFAULT=0` with `GRUB_TIMEOUT=0` boots the newest installed kernel
unconditionally, so the machine came up on 7.0.0-30. swsusp compares
`uts_release` in the image header and refuses a mismatch. **The session was
unrecoverable the moment the upgrade landed**, independent of the write failing.

> Note the two failures produce *different* errors. A kernel mismatch on a
> valid image gives `PM: Image mismatch`, not `Image not found`. Seeing `-22`
> means the write failed first; the mismatch never got a chance to fire.

### The battery arithmetic

This is what separated "hibernated" from "hung pretending to". At
`energy-full = 53.85 Wh`, 1% = 0.538 Wh:

| State | Draw | Per hour | Per day |
|---|---|---|---|
| Hibernated / off | ~0 W | 0% | 0% |
| Correct s2idle (s0i3) | 0.44 W | 0.8% | ~20% |
| **What actually happened** | **1.74 W** | **3.2%** | **~78%** |
| Awake, idle | ~6 W | 11% | — |

```
 93%  Aug 19 18:30:28   last sample before the lid closed
  −0.4%   ~3 min awake
  −1.6%   2 h of real s2idle @ 0.44 W      <- this part worked correctly
 −70.2%   21.7 h hung @ 1.74 W             <- the entire loss
 ────
 21%  Aug 20 18:16:59   first sample after the cold boot
```

1.74 W is unremarkable — 4× a correct suspend, a quarter of an idle awake
machine. Invisible over an evening, fatal over a day: from full it flattens the
battery in **31 hours**. The RTC coming up at `2023-01-01` says the machine
eventually lost power entirely; EFI NVRAM survived (SPI flash, no backup power
needed), which is why the hibernate pointer was still readable.

**Hibernation draws 0 W because the machine is off. Any measurable drain across
a hibernation means it never got there.** That single fact is the diagnostic.

### The WiFi card was not involved

The card had been swapped from MT7922 to AX210 that afternoon, which made it the
obvious suspect. One line settles it:

```
Aug 19 14:35:28  iwlwifi 0000:01:00.0: Detected Intel(R) Wi-Fi 6E AX210 160MHz
```

The AX210 was already installed at the *start* of the boot that then ran
suspend-then-hibernate three times flawlessly, including a full 2 h cycle
resuming at 18:22. A component present during the successes cannot explain the
failure. (It did improve things — see [gotcha 8](#gotchas-worth-remembering).)

### The fix — a stale-kernel lid guard

The rule to enforce: **while the running kernel is not the newest installed one,
a lid close must not escalate to hibernation.**

`/usr/local/sbin/stale-kernel-lid-guard` compares `uname -r` against
`linux-version list | linux-version sort --reverse | head -1`. If they differ it
writes `/run/systemd/logind.conf.d/99-stale-kernel.conf`:

```ini
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
```

and reloads logind. Plain suspend is resumed from RAM by the kernel already
running — no image, no disk, no version check, nothing to reject.

Two properties make this safe to forget about:

- **The override lives on tmpfs.** `/run` is cleared at boot, and rebooting is
  exactly the event that resolves the condition. There is no state file, no flag
  that can stick armed, and no cleanup path to get wrong. *Rebooting is both the
  fix and the reset.*
- **`99-` beats `10-`.** systemd orders drop-ins by filename across `/etc`,
  `/run` and `/usr`, so a `/run` file wins despite the lower-priority directory
  ([gotcha 15](#gotchas-worth-remembering)).

Two triggers, because there are two ways to end up on a stale kernel:

| Trigger | Covers |
|---|---|
| `/etc/kernel/postinst.d/zzz-stale-kernel-lid-guard` | apt installs a kernel and you don't reboot — the case that caused this |
| `stale-kernel-lid-guard.service` (boot) | you deliberately pick an older kernel from the GRUB menu |

It also fires a desktop notification when it arms, since the whole failure mode
is invisibility.

### What it does not cover

An explicit `systemctl hibernate`, and UPower's `CriticalPowerAction`
(`HybridSleep` here) if the battery runs flat while suspended.

Neither is a real loss, and this is worth being precise about rather than
"fixing": **with a stale kernel there is no configuration that survives a dead
battery**, because the only restorable image is one written by the kernel you
are not running. Masking hibernation would swap one lost session for an
identical one, and would forfeit the case where you plug in before it dies.
Plain suspend at 0.44 W gives roughly **five days** from full — that is the
window you have to reboot in.

### Verifying it

The guard fires only during rare events, so it ships with a self-test that
proves the mechanism end to end rather than asserting it:

```bash
sudo /usr/local/sbin/stale-kernel-lid-guard --self-test
#   baseline      HandleLidSwitch=sleep
#   guard armed   HandleLidSwitch=suspend
#   guard cleared HandleLidSwitch=sleep
#   PASS: sleep -> suspend -> sleep. The guard works.
```

It reads the *effective* value from logind over D-Bus, not from the config files
it just wrote, and restores whatever the real evaluation calls for afterwards.

```bash
stale-kernel-lid-guard --status     # verdict + armed state, warns if they disagree
```

`--status` deliberately reports the **verdict** as well as the file state: a
bare file check would report "not armed" on a stale kernel, which is true and
useless. A disagreement between the two means the boot unit or the kernel hook
did not run.

---

## Part 8 — A panic during hibernation, and no vmcore

A third lost session, 2026-08-24. Same outcome as [Part 6](#part-6--a-lost-session-diagnosed)
and [Part 7](#part-7--the-kernel-upgrade-trap) — desktop gone, machine
cold-booted — but a **different failure entirely**, and one neither earlier fix
could have prevented. The cause of the hibernation panic is **still unknown**.

What this part is really about is the second-order problem that made it unknown:
**every mechanism that should have recorded the panic was defeated, one of them
by kdump itself.** That part is now understood and fixed, and it took a
deliberate crash to get there.

### Symptom

Lid closed on battery at 11:34. Opened hours later to a fresh login screen.
No `PM: Image not found`, no `-22`, none of the Part 6/7 signatures.

### Step 1 — read the boot list correctly

```
-2  aa4ea588…  Sun 2026-08-23 09:23:09  Mon 2026-08-24 13:34:19
-1  e8949085…  Mon 2026-08-24 13:34:31  Mon 2026-08-24 13:34:31
 0  1281bde9…  Mon 2026-08-24 13:35:46  …
```

**Two** new boot IDs, not one, and the middle one lasts seconds. That middle
entry is not a boot — it is the **kdump capture kernel**:

```bash
journalctl -b -1 | grep "Kernel command line"
# elfcorehdr=0xfde000000 … reset_devices systemd.unit=kdump-tools-dump.service \
#   nr_cpus=1 irqpoll usbcore.nousb
```

`elfcorehdr=` is decisive. `kexec -p` fires **only on a panic**, so its presence
proves one happened — the cheapest positive test available, and it needs no dump.
Read as three ordinary boots, the same evidence looks like a reboot loop.

### Step 2 — where the journal stops is *not* where it died

The last line ever persisted from the doomed boot:

```
13:34:19.110358  systemd-sleep[…]: Performing sleep operation 'hibernate'...
13:34:19.111257  kernel: PM: hibernation: hibernation entry
```

It is tempting to conclude it panicked microseconds into hibernation entry.
**That conclusion is wrong**, and the same boot contains the proof. It had
already hibernated successfully once that morning, and the entry sequence for
*that* cycle reads:

```
10:32:34.060774  kernel: PM: hibernation: hibernation entry
10:58:03.703109  kernel: Filesystems sync: 0.013 seconds
10:58:03.713340  kernel: Freezing user space processes
```

`Filesystems sync` and `Freezing user space processes` describe work done at
**10:32**, but carry the **10:58 resume timestamp**. journald is frozen moments
after `hibernation entry`; everything after it accumulates in the kmsg ring and
only reaches disk **when the machine wakes up**. This is [gotcha 7](#gotchas-worth-remembering)
taken to its conclusion: a hibernation that never resumes never flushes, so
**the blind window is the entire hibernation** — notifier chain, device suspend,
the ~12 GB image write and power-down are all equally suspect.

### Step 3 — the obvious suspect, ruled out

An `apt upgrade` had run **eight minutes** before the lid closed, which after
Part 7 is exactly the thing to suspect. It was not the cause:

```
11:26:17  teams-for-linux, microsoft-edge-stable, r-base-core,
          r-cran-data.table, r-cran-recipes, r-cran-ggfortify
```

Entirely userspace. Checks that settle it, worth re-running in this order:

```bash
zgrep -h "^$(date +%F)" /var/log/dpkg.log* | grep -EI 'linux-image|linux-modules|firmware|microcode|systemd'
stat -c '%y' /lib/modules/$(uname -r)      # unchanged since the last kernel install
ls /var/run/reboot-required                # absent
```

No kernel, module, firmware, microcode or systemd package was touched; the
modules directory was five days old; no reboot was pending; `7.0.0-30` ran before
and after. The Part 7 trap did **not** recur and `stale-kernel-lid-guard`
correctly had nothing to arm — an absence of action, not a miss.

### Step 4 — one lid close, three hibernations

The counts don't reconcile at first glance, and the reason matters when
reconstructing a timeline from memory.

| | Event |
|---|---|
| 08:32:31 | `Lid closed.` → suspend → hibernate 10:32 → resumed 10:58 ✅ |
| 11:34:16 | `Lid closed.` → suspend → **hibernate 13:34 → panic** 💥 |
| 13:36:16 | `Suspending, then hibernating…` — **no `Lid closed.` before it** |
| 15:36:22 | hibernate → resumed 18:51 on `Lid opened.` ✅ |

The machine rebooted with the lid still shut, so logind saw the *closed state*
about 24 s after it began watching the switch and re-ran the whole lid policy by
itself. Net: **two lid closes, three hibernations, two of them successful.**

> Count `Lid closed.` / `Lid opened.` from `systemd-logind` when reconciling
> against what you actually did. `Performing sleep operation` lines count sleep
> *attempts*, which a crash-and-reboot can silently inflate.

### Step 5 — why there was no vmcore: the capture kernel dies too

kdump was enabled, loaded, and reported `ready to kdump`. `/var/crash` held only
`kdump_lock` and `kexec_cmd` — **no dated directory has ever appeared there.**

The first hypothesis was that the capture kernel walks the hibernation-resume
path: `kdump-config` builds its cmdline from `/proc/cmdline` stripping only
`crashkernel`, `hugepages`, `hugepagesz` and `abm` (line 732), so `resume=` is
inherited, and the 08-24 capture kernel did log
`Reported hibernation image … kernel=7.0.0-30-generic` and
`Successfully cleared HibernateLocation EFI variable`.

**That hypothesis was wrong.** `noresume` was added, and a deliberate
`echo c > /proc/sysrq-trigger` on 2026-08-25 reproduced the failure exactly:
no vmcore, journal stopping at the same place, the same ~75 s. The flag did do
what it claims — zero hibernate-resume activity in the new capture kernel — it
just was not what was breaking capture. **Keep it; it is correct and harmless.
It is not the fix.**

The real answer was in `pstore`:

```bash
ls /var/lib/systemd/pstore/          # NOT /sys/fs/pstore -- that is root-only
```

Every record there is written by a kernel whose uptime is **10 to 32 seconds**.
The kernel that was hibernating had been up 28 hours. **The capture kernel is
panicking on device re-initialisation, before it can save anything:**

```
2026-08-24  [   10.295] RIP: 0010:acp63_irq_handler+0x44/0x610 [snd_pci_ps]
                        BUG: kernel NULL pointer dereference, address: 0…08
                        Call Trace: <IRQ> __handle_irq_event_percpu
                                    handle_irq_event  try_one_irq  note_interrupt

2026-08-25  [   30.287] iwlwifi: Microcode SW error detected. Restarting 0x0.
            [   32.128] RIP: 0010:0x0
            [   32.128] Kernel panic - not syncing: Fatal exception
```

Different driver each time, same shape. Note the 08-24 call path:
`note_interrupt` → `try_one_irq` is the **spurious-IRQ polling that `irqpoll`
enables** — and `irqpoll` is in kdump's own default command line. It calls every
registered handler on every tick, including an audio handler whose device state
was never set up.

### Step 6 — and kdump destroyed the evidence that would have explained it

This is the part worth internalising. With kdump armed, `panic()` calls
`__crash_kexec()` **before** `kmsg_dump()`. The jump to the capture kernel never
returns, so **pstore never records the original panic.**

The proof is local, not from reading kernel source. On 08-24 the capture kernel
logged:

```
systemd-pstore.service … skipped, unmet condition check ConditionDirectoryNotEmpty=/sys/fs/pstore
```

`/sys/fs/pstore` was **empty** immediately after the hibernation panic — and
minutes later that same capture kernel wrote *its own* panic there (nothing is
armed inside a capture kernel, so `kmsg_dump()` runs normally).

So the machine had two recording mechanisms and got neither: kdump pre-empted
pstore, then the capture kernel panicked before writing a vmcore. Enabling kdump
made the situation **worse** than leaving it off, because a plain
`efi_pstore` dmesg would very likely have named the offending driver — exactly
as it did for `acp63` and `iwlwifi` above, in seconds.

### The fix

Two independent changes; the first is the important one.

**1. `crash_kexec_post_notifiers=1` on the *main* kernel cmdline** — run
`kmsg_dump()` (and therefore `efi_pstore`) *before* the kexec jump, so the panic
dmesg survives whether or not the capture kernel makes it.

```sh
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=… crash_kexec_post_notifiers=1"
```

It is also live-togglable, which means it can be armed without a reboot:

```bash
echo Y | sudo tee /sys/module/kernel/parameters/crash_kexec_post_notifiers
```

The documented trade-off: running panic notifiers in a crashed kernel is
marginally less reliable than jumping straight to kexec. For an intermittent
fault on a laptop, evidence beats purity.

**2. `module_blacklist=…` on the *capture* kernel cmdline** — it needs `nvme`
and `ext4`; it does not need audio, WiFi, the GPU or Thunderbolt, and those are
what have killed it.

```sh
# /etc/default/kdump-tools -- one line, wrapped here
KDUMP_CMDLINE_APPEND="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 irqpoll usbcore.nousb noresume module_blacklist=snd_pci_ps,snd_pci_acp6x,snd_pci_acp5x,snd_pci_acp3x,snd_rn_pci_acp3x,snd_acp_pci,snd_acp_config,snd_acp_legacy_common,iwlwifi,amdgpu,thunderbolt"
```

`framework13-suspend-scripts/crash-evidence-setup.sh` applies both idempotently,
with backups, and verifies the result.

**The trap in that second one:** `KDUMP_CMDLINE_APPEND` **replaces** the built-in
default rather than extending it —

```bash
sed -n '60p' /usr/sbin/kdump-config
# KDUMP_CMDLINE_APPEND=${KDUMP_CMDLINE_APPEND:="reset_devices systemd.unit=… nr_cpus=1 irqpoll usbcore.nousb"}
```

Drop `systemd.unit=kdump-tools-dump.service` and kdump stops capturing entirely
while still cheerfully reporting *ready to kdump*. Verify against
`/var/crash/kexec_cmd`, never against the config file.

### What this does and does not buy

It does **not** make hibernation more reliable, and it does not prevent the
panic. If it recurs the session is still lost. What changes is that the next one
should leave a readable dmesg in `/var/lib/systemd/pstore/` naming the driver —
which is all that was ever needed to stop calling this "unexplained".

### Verified 2026-08-25 — both halves, against a real panic

A second deliberate crash, `echo c > /proc/sysrq-trigger` at 13:08:52, after both
changes. **Both mechanisms produced evidence.**

**A vmcore, for the first time on this machine:**

```
/var/crash/202608251309/
  dmesg.202608251309    151 KB
  dump.202608251309     456 MB
kdump-tools: makedumpfile Completed.
kdump-tools: saved vmcore in /var/crash/202608251309
```

The capture kernel lived **19 s** (13:09:26 → 13:09:45) and did its job, versus
dying at 10 s and 32 s on the two previous attempts. `Module iwlwifi is
blacklisted` appears in its log; no Oops, no panic.

**And pstore caught the *real* panic, not the capture kernel:**

```
1787677733  kernel uptime 5435.5 .. 7497.7 s
              sysrq: Trigger a crash
              Kernel panic - not syncing: sysrq triggered crash
```

`7497 s` is the decisive number. Every earlier pstore record had an uptime of
**10–35 seconds**, because it was written by the capture kernel as it died. This
one was written by the kernel that panicked, before the kexec jump — which is
exactly what `crash_kexec_post_notifiers=1` exists to do.

| | Status |
|---|---|
| `crash_kexec_post_notifiers` ordering | **VERIFIED** against a real panic |
| `module_blacklist` → capture kernel survives → vmcore | **VERIFIED** against a real panic |
| `noresume` | Verified to work, and verified *not* to be the fix |

Caveat worth keeping: this was a `sysrq` panic on a healthy running system. A
panic *during hibernation* happens with tasks frozen and devices half-suspended,
which is a harder case for the capture kernel. The belt-and-braces design is the
point — if the capture kernel dies in that situation, pstore still has the dmesg.

> **Reading the uptime is the whole trick, and there is a trap in it.** Kernel
> printk timestamps come from the monotonic clock, which **does not advance
> during s2idle**. Here: 15194 s of wall clock, 7497 s on the kernel clock, and
> the 7697 s difference matches the logged suspend segments
> (7198.217 + 493.373 + 3.974 = 7695.6 s) to within rounding. Never convert a
> printk timestamp to wall-clock on a laptop that suspends — compare it against
> *other* printk timestamps instead.

> **If you take one thing from Part 8:** check `/var/lib/systemd/pstore/`, not
> `/sys/fs/pstore`. The latter is root-only and returns *permission denied*,
> which is easy to misread as "empty" — that misreading cost a full extra
> diagnostic cycle here.

---

## Part 9 — A lockup an hour after resume: the drm/ttm bulk_move bug

Everything before this part was about sleep that didn't save power, or a
session that didn't come back. This one is new: on 2026-09-17 the resume
**succeeded** — same boot ID, desktop intact, WiFi up in seconds — and then an
hour later, in the middle of a lecture being streamed over Teams, the machine
froze solid. The cause is a **known upstream kernel bug** in the GPU driver's
memory manager, and the thing that arms it is *resuming from hibernation*.
That makes it this document's problem.

### Symptom

Lid opened at 09:06, resumed from the image written the previous day (lid
closed 09:42 on 09-16, hibernated at 11:43 when the 2 h countdown expired).
Teaching setup: Teams in Edge, a UGREEN USB capture card pulling an iPad
screen, DJI mic, projector on `DP-3` over a USB-C adapter. At roughly 10:03
the display froze and input died. Forced power-off.

### Step 1 — the journal stops, but not where it died

```
10:03:14  usb 1-2: New USB device found ... Product: DJI MIC MINI
10:03:14  wireplumber: link failed: some node was destroyed before the link was created
10:03:17  boltd: probing: timeout, done
                                            <- nothing after this
```

A USB re-enumeration and then silence, with no kernel complaint at all. It
reads exactly like a hard hang. It was not — Part 8's lesson applies in the
other direction: the journal stopped *flushing* at 10:03, the kernel died at
10:06, and `pstore` had it.

### Step 2 — the warning, 56 minutes earlier

`journalctl -b -3 -k | grep -B2 -A40 'cut here'` turns up four back-to-back
`WARNING`s at **09:10:36–37**, from mutter's KMS thread and two kworkers:

```
 slab kmalloc-rnd-08-192 start ffff8d8d86f01680 pointer offset 64 size 192
------------[ cut here ]------------
list_del corruption. prev->next should be ffff8d8d808d6b80, but was ffff8d8d91e9f780.
WARNING: lib/list_debug.c:62 at __list_del_entry_valid_or_report+0xe4/0x10b, CPU#0: KMS thread/5352
Hardware name: Framework Laptop 13 (AMD Ryzen 7040Series)/FRANMDCP07, BIOS 03.20 06/23/2026
Call Trace:
 ttm_resource_move_to_lru_tail.cold [ttm]
 ttm_bo_move_to_lru_tail [ttm]
 amdgpu_dm_plane_helper_prepare_fb [amdgpu]
 drm_atomic_helper_prepare_planes
 drm_atomic_helper_commit
 drm_mode_atomic_ioctl
```

Three things in that block matter. `list_del corruption` means a linked-list
node's neighbours no longer point back at it — someone wrote through a stale
pointer. The `slab kmalloc-rnd-08-192` line above it is the kernel telling you
the bad pointer lands *inside a freed-and-reused slab object* — a
use-after-free. And it is a **`WARNING`**, not a `BUG`: `CONFIG_DEBUG_LIST`
reported the corruption and then let the kernel carry on with the mangled
list. From here the machine was on borrowed time; the desktop kept working
for another 56 minutes.

### Step 3 — the death, from pstore

The `efi_pstore` records are split into ~1 KB parts (`Oops#1 Part1` …
`Part15`) spread across several timestamped directories. Concatenate the
`dmesg.txt` files and sort on the `[uptime]` field to get one readable trace:

```bash
sudo cat /var/lib/systemd/pstore/1789654*/*/dmesg.txt \
  | grep -E '^<[0-9]>\[' | sort -t']' -k1,1 -s | sed 's/^<[0-9]>//'
```

```
[10820.977586] BUG: unable to handle page fault for address: 00000002000000d8
[10820.977603] CPU: 2 UID: 1000 PID: 29805 Comm: nautilus  Tainted: G   W   7.0.0-31-generic
[10820.977610] RIP: 0010:ttm_lru_bulk_move_tail+0x172/0x360 [ttm]
[10820.977625] RAX: 0000000200000000 ...
Call Trace:
 amdgpu_vm_move_to_lru_tail [amdgpu]
 amdgpu_cs_submit [amdgpu]
 amdgpu_cs_ioctl [amdgpu]
 drm_ioctl
```

`10820 − 7441 = 3379 s` after the warning → **10:06:55**. The faulting address
is `0x2_0000_00d8`: a register holding `0x2_0000_0000` (not a pointer at all)
plus a struct offset. A pointer in the bulk-move cursor had been overwritten
with garbage, and the first process to submit GPU work through that cursor —
Nautilus, of all things — dereferenced it. The `Tainted: G W` is the 09:10
warning; the kernel had flagged itself an hour earlier.

### Step 4 — the red herring

What was going on at 09:10? Reconstructing the minutes before the first
warning:

| | Event |
|---|---|
| 09:06:27 | `Lid opened.` → `PM: hibernation: hibernation exit` |
| 09:06–09:08 | capture card plugged in, moved to a different port; DJI mic |
| 09:09:02 | projector connects (`DP-3`, VIA USB-C billboard adapter) |
| 09:09:08 | terminal opened — `ipad-capture_screen` (mpv on the capture card) |
| 09:10:34 | `xdg-desktop-portal-gnome: Failed to associate portal window` — the Teams screen-share picker |
| **09:10:36** | `list_del corruption` ×4 |

Two seconds after screen sharing started, in the compositor's KMS thread,
while preparing a framebuffer for a plane. Multi-monitor, PipeWire screencast
exporting dma-bufs, a UVC stream — every ingredient for "the capture card /
projector / Teams combination is unstable". That is the wrong conclusion, and
it took an upstream search to see why: screen-share start is simply a burst
of large GPU allocations, and it was the first one to walk through the
already-broken cursor. The same configuration had run for a full day on 09-16
without incident.

### Step 5 — the actual trigger: the hibernation resume four minutes earlier

This is a known bug. The matching report is from **the same hardware**, a
Framework 13 / 7840U, via Debian #1139599, and the mechanism was worked out on
amd-gfx / dri-devel between June and September 2026:

- amdgpu keeps each process's GPU buffers grouped in a *bulk-move range* on the
  driver's LRU list, tracked by a cursor (`first`/`last` pointers).
- Hibernation makes TTM **swap every GPU buffer out** to system memory so it
  lands in the image. A May 2026 stable commit — `drm/ttm: Fix ttm_bo_swapout()
  infinite LRU walk on swapout failure` (upstream `b2ed01e7ad3d`) — put the
  "remove this buffer from its bulk-move range" step under `if (!ret)`. But the
  swapout function returns the *number of pages swapped* on success, so the
  cleanup **never runs**. Swapped-out buffers stay in the range.
- After resume, when any of those buffers is freed (a window closes, a process
  exits), the cursor is left pointing at freed memory. The next allocation on
  that cursor reads it → `list_del corruption` → eventually a fault.

That is exactly the sequence in this boot:

```
Sep 16 09:42:58  PM: suspend entry (s2idle)
Sep 16 11:43:00  PM: hibernation: hibernation entry        <- buffers swapped out
Sep 17 09:06:27  PM: hibernation: hibernation exit
Sep 17 09:10:36  list_del corruption                        <- 4 min later
Sep 17 10:06:55  BUG: unable to handle page fault           <- 56 min after that
```

Why it is intermittent: the bug needs one of the swapped-out buffers to be
*freed* and the cursor then *reused*. The three boots before this one (from
08-25, 09-07 and 09-13) resumed from hibernation ten times between them on
affected kernels and got away with it every time. The upstream
reports say "minutes to hours after resuming from hibernation", and add that
heavy GPU memory swapout *without* hibernation — loading a large llama.cpp or
Ollama model — trips it too.

**Which kernels.** The bad commit reached Ubuntu with the v7.0.10 stable pull
in `7.0.0-28`; every kernel since carries it, including the `7.0.0-30` that
this document was written against:

| Ubuntu kernel | v7.0.y merged | bulk_move bug |
|---|---|---|
| 7.0.0-26 | ≤ 7.0.9 | no |
| 7.0.0-28 | 7.0.10 – 7.0.12 | **yes** — first affected |
| 7.0.0-30, 7.0.0-31 | up to 7.0.14 | **yes** |

The fix is a one-liner — `if (!ret)` → `if (ret > 0)` — landed in
`drm-misc-fixes` on 2026-09-09 as `drm/ttm: fix swapped-out resources never
leaving their bulk_move range` (`3db7d7d58341`) plus a follow-up
`drm/ttm: apply the swapout bulk_move fix to the intended condition`
(`fcfe64715b42`), both tagged `Cc: stable`. As of 2026-09-18 it is **not in
mainline, not in any stable release, and not in Ubuntu.** You can check the
changelog yourself; the changelog Ubuntu ships in
`/usr/share/doc/linux-image-*/` is truncated, so fetch the full one:

```bash
V=$(dpkg-query -W -f='${Version}' linux-image-$(uname -r))
curl -sL "https://changelogs.ubuntu.com/changelogs/pool/main/l/linux/linux_$V/changelog" \
  | grep -E 'infinite LRU walk on swapout|never leaving their bulk_move'
# first line present, second absent  = buggy
# both present                        = fixed
# neither                             = predates the bug
```

### The decision

Four options, in order of how much they change:

1. Turn hibernation off (`HandleLidSwitch=suspend`, or `HibernateDelaySec`
   pushed out to days) until Ubuntu ships the fix.
2. Build a patched `ttm.ko` — a one-line change, but a hand-built module on a
   machine whose Part 7 already showed how kernel/module drift bites.
3. Keep everything, and **reboot after any hibernation resume before doing
   anything that matters.** A fresh boot has no swapped-out-during-hibernation
   buffers, so the cursor is never armed. A plain s2idle suspend afterwards is
   fine; only hibernation swaps GPU buffers out.
4. Live with it.

**Chosen: 3.** The config in Parts 3–7 stays as it is. The operating rule is
*resumed from hibernation → reboot before teaching*. Two things make that
workable rather than a memory test:

```bash
# Did THIS session come back from a hibernation image?  (yes → reboot first)
journalctl -b -k | grep -c 'Hibernation image restored successfully'
```

and `ttm-fix-check`, a daily user timer (`framework13-suspend-scripts/ttm-fix-check*`)
that fetches the Ubuntu changelog for the running kernel and the apt candidate,
classifies each as *clean / buggy / fixed*, and sends a desktop notification
the day a fixed kernel is available — and again once it is the one running, at
which point the rule can be dropped.

And, because "remember to check" is not a plan: **`zz-hibernate-resume-warn`**,
a `post`-phase sleep hook (the same mechanism as `framework-wakeup-policy.sleep`)
that after every wake counts `PM: hibernation: hibernation entry` lines in the
current boot's kernel log — the larger of `dmesg` and `journalctl -b -k`, since
the ring buffer can wrap and journald can lag — and, if the count rose since the
last wake, hands off to `hibernate-resume-warn` in each graphical user's own
`systemd --user` manager via `systemd-run --machine=user@ --user`. That script
posts a **critical** notification (GNOME does not auto-dismiss those, and they
survive the lock screen) and a `zenity` dialog with **Reboot now / Later** that
stays up until answered. State lives in `/run`, which is RAM — restored with
the image, empty on a fresh boot — so a plain suspend after the reboot warns
nothing, and a hibernation resume warns exactly once.

The handoff is **two stages**, and the reason is the subject of the next
section: the hook itself only counts and, if the count rose, asks the *system*
manager for a transient timer (`systemd-run --on-active=3 … dispatch`); the
timer's service, three seconds later, is what walks `loginctl list-sessions`
and starts the dialog in each session. Both stages log to the journal under
`hibernate-resume-warn`, so "did it fire?" is a `journalctl -t` away.

Counting *image creations* rather than *restores* is deliberate: the GPU buffers
are swapped out when the image is written, so a hybrid-sleep that woke from
RAM, or a hibernation that failed after the snapshot, is armed too. False
positives cost a reboot; false negatives cost the session.

```
$ ttm-fix-check
running   7.0.0-31.31    buggy
candidate 7.0.0-31.31    buggy
No fix yet — keep rebooting before class.
```

> **If you take one thing from Part 9:** a `WARNING: ... list_del corruption`
> in `dmesg` is not noise to scroll past. It is a use-after-free that the kernel
> has decided to survive, and the survival is temporary. Save your work.

> **And the second thing:** the event that armed the failure (a hibernation
> resume at 09:06) and the event that fired it (screen sharing at 09:10) and the
> event that killed the machine (a file-manager GPU submit at 10:06) were three
> different things an hour apart. Correlating the crash with whatever was on
> screen at the time would have blamed the capture card.

### Second occurrence (2026-09-19) — and the warning that never fired

Two days later, the same bug, two minutes instead of an hour, and this time
with a vmcore. The user-visible story was "I plugged in a USB-C dock, turned
off the internal panel, and the laptop rebooted." The journal's story:

```
10:25:31  PM: hibernation: Hibernation image restored successfully   <- asleep 15h50m; image from 18:34 the day before
10:25:31  ttm-fix-check: running 7.0.0-31.31 buggy                    <- the daily timer, catching up
10:26:23  list_add corruption ... ttm_resource_move_to_lru_tail  (kitty)   <- ×4, before the dock
10:26:34  list_del corruption ... (kitty)
10:27:08  usb 5-1.3.2: Glorious Model D Wireless                      <- the dock's mouse
10:27:24  gnome-control-center                                        <- Displays panel
10:27:33  (journal ends)
```

and the kdump dmesg's, 60 ms apart:

```
[25075.951] WARNING ... RIP: dcn31_program_compbuf_size+0xcc [amdgpu]   Comm: KMS thread
[25076.010] BUG: kernel NULL pointer dereference, address: 0000000000000008
[25076.010] RIP: 0010:ttm_lru_bulk_move_tail+0x1a5/0x360 [ttm]         Comm: papers
[25076.559] Kernel panic - not syncing: Fatal exception
```

Same `RIP` as [Step 3](#step-3--the-death-from-pstore) (a different
offset, since this time it was a `list_add` walk rather than a `list_del`). The
corruption was already logged **before** the dock was plugged in; turning the
panel off made the KMS thread reallocate the display buffers, and the next
process to touch the LRU — a PDF viewer — walked into the NULL. The dock was the
trigger. A fresh-boot session would have taken it in stride.

What made this occurrence worth a section is the part that was supposed to be
solved: the reboot-me dialog from the previous day was installed, had been
tested by hand, and did not appear. `journalctl -b -2 | grep hibernate-resume-warn`
showed the manual test from the day before and nothing at 10:25. The hook had
no logging of its own, and its one external call was `systemd-run --quiet … || :`.

The cause is in `systemd-sleep` itself. Since v255 it freezes `user.slice` for
the duration of the sleep — and in `sleep.c` the freeze is in `run()`, the
`post` hooks are in `execute()`, and the thaw is back in `run()` *after*
`execute()` returns. Every `post` hook therefore runs while every user session,
and every user's `systemd --user`, is a frozen cgroup. The timestamps agree:

```
10:25:31.431620  systemd-sleep: System returned from sleep operation 'suspend-then-hibernate'.
10:25:31.547403  systemd-sleep: Successfully thawed unit 'user.slice'.
```

The hooks ran inside those 116 ms. `systemd-run --machine=dave@ --user` needs
the user manager to answer; it could not; the hook swallowed the failure. The
manual test had passed because a shell on the desktop is not frozen.

Reproduced on demand, from a transient *system* unit so the freeze does not
freeze the test:

```
A: freezing user.slice, calling stage two INLINE (the old behaviour)
   hibernate-resume-warn: FAILED to start the dialog for dave (session 2), rc=1
B: freezing user.slice, calling the hook as systemd-sleep does (post, test mode)
   systemd[1]: Started hibernate-resume-warn-dispatch-1789828689.timer
   ...thaw...
   systemd[1]: Started hibernate-resume-warn-dispatch-1789828689.service   <- +5 s
   hibernate-resume-warn: dialog started for dave (session 2)
```

Hence the two-stage hook described above. The general rule, which applies to
any `system-sleep` hook that wants to reach a user: **you are not in the
session, you are in the 100 ms before it exists again.** Decide in the hook;
act from a timer.

---

## Part 10 — Part 8's panic, named — and the capture kernel that ate the image

Same day, 12:48. The machine had been running on battery since the morning
reboot (the projector was on the port that usually carries the charger). At
**7%** UPower fired `CriticalPowerAction=HybridSleep` — the Part 6 reserve
doing precisely what it was installed to do. The image was written cleanly.
And then the kernel panicked, in the same driver and at the same instruction
that Part 8 had only ever seen inside the capture kernel.

This time both of Part 8's mechanisms recorded it: a pstore dmesg of the
**hibernating** kernel (uptime 6226 s, not 10 s) and a 456 MB vmcore in
`/var/crash/202609171250/`. The outstanding item at the bottom of this document
since 2026-08-25 now has a name.

### The record

```
[ 6207.122758] PM: hibernation: Creating image
[ 6207.122758] PM: hibernation: Image created (3050496 pages copied, 664795 zero pages)
[ 6210.363961] snd_hda_intel 0000:c1:00.1: azx_get_response timeout, switching to polling mode
[ 6211.365744] snd_hda_intel 0000:c1:00.1: No response from codec, disabling MSI
[ 6212.377850] PM: thaw of devices complete after 5203.481 msecs          <- audio was already unhappy
[ 6212.386770] PM: hibernation: Writing hibernation image.
[ 6225.238460] PM: hibernation: Wrote 12231012 kbytes in 12.83 seconds (953.31 MB/s)
[ 6225.238470] PM: Image saving done
[ 6225.238591] PM: S|                                                      <- swap signature written: image is COMPLETE
[ 6226.145739] BUG: kernel NULL pointer dereference, address: 0000000000000008
[ 6226.145767] CPU: 0 UID: 0 PID: 0 Comm: swapper/0 Kdump: loaded Not tainted 7.0.0-31-generic
[ 6226.145776] RIP: 0010:acp63_irq_handler+0x44/0x610 [snd_pci_ps]
Call Trace:
 <IRQ>
 __handle_irq_event_percpu
 handle_irq_event
 handle_fasteoi_irq
 __common_interrupt
 </IRQ>
 cpuidle_enter_state ... do_idle
[ 6227.718699] amdgpu 0000:c1:00.0: Fence fallback timer expired on ring sdma0
[ 6228.897723] Kernel panic - not syncing: Fatal exception in interrupt
```

`PM: S|` is `swap_writer_finish()` writing the `S1SUSPEND` signature — the
last step of a hibernation write. The image on disk was valid and resumable.
0.9 s later, while the kernel was suspending devices for the S3 half of
hybrid-sleep, the AMD ACP 6.3 audio interrupt handler ran, followed a pointer
in its private data that was already `NULL` (`address: 0x8` = field at offset 8
of a null struct), and because it was in interrupt context there was nothing
to unwind to. Fatal.

### Why this is Part 8's panic

Compare with the 08-24 record in Part 8, written by the *capture* kernel at
10 s uptime:

```
2026-08-24  [   10.295] RIP: 0010:acp63_irq_handler+0x44/0x610 [snd_pci_ps]
                        BUG: kernel NULL pointer dereference, address: 0…08
```

Same module, same function, **same offset `+0x44`, same address `0x8`.** Part 8
read that as the capture kernel's own problem — `irqpoll` calling every handler
including one whose device was never set up — and fixed it with a module
blacklist. That was correct, and the blacklist held on 09-17 (the capture
kernel survived and wrote the vmcore). But the 09-17 record shows the handler
does the same thing in the *main* kernel, from a real `fasteoi` interrupt, in
the device-suspend phase that follows image writing. That phase is common to
plain hibernation (`hibernation_platform_enter`) and hybrid-sleep, so the
08-24 hibernation panic — whose own dmesg was lost to the ordering problem
Part 8 fixed — was very probably this. It cannot be proven from the 08-24
evidence; it is the same driver, the same instruction and the same phase.

`snd_pci_ps` is the driver for the ACP 6.3 audio block on Phoenix; this is a
driver bug, not configuration, and nothing in this repository can fix it.
Ubuntu's 7.0.0-28 changelog does carry a batch of AMD SoundWire / ACP
backports (`Backport ASoC SDCA, AMD SoundWire, and RT722 audio fixes`), which
makes the timing at least suggestive — both panics post-date it.

### And the session was still lost

The image was complete. `crash_kexec_post_notifiers` delivered the dmesg. The
capture kernel worked. The next boot should have resumed. It did not:

```
Sep 17 12:50:30  systemd-hibernate-resume[422]: Unable to resume from device '/dev/disk/by-uuid/<your-swap-uuid>' (259:5) offset 0, continuing boot process.
Sep 17 12:50:30  kernel: PM: Image not found (code -22)
```

Part 6's signature — image written, invalid on read-back. The capture kernel's
journal (the 21-second boot in between) says why:

```
Sep 17 12:49:58  systemd-hibernate-resume[232]: Reported hibernation image: ... kernel=7.0.0-31-generic
Sep 17 12:49:58  systemd-hibernate-resume[232]: Successfully cleared HibernateLocation EFI variable.
Sep 17 12:50:00  systemd[1]: Activating swap dev-disk-by\x2duuid-<your-swap-uuid>.swap ...
Sep 17 12:50:00  swapon[304]: swapon: /dev/nvme0n1p5: software suspend data detected. Rewriting the swap signature.
Sep 17 12:50:03  kdump-tools[721]: Starting kdump-tools:
```

**The capture kernel activated swap from `/etc/fstab`, and `swapon` overwrote
the hibernation signature.** `noresume` did what Part 8 verified it does — the
kernel made no attempt to resume — but nothing told the capture kernel's
systemd to leave the fstab swap entry alone, and util-linux `swapon` treats a
`S1SUSPEND` signature as stale data to be cleaned up. It even said so. Two
seconds later the image that Part 6's 7% reserve had been carefully sized to
protect was gone, and the vmcore was written to disk over a swap partition
that no longer contained anything.

So with kdump armed, **any** panic during hibernation costs the session even
when the image write completed — the capture kernel guarantees it. Without
kdump, this 09-17 panic would have left a resumable image (the signature was
on disk before the fault) and the next boot would have restored the desktop.

### The fix — proposed, not yet applied

Keep the capture kernel from touching swap at all. Either of these on the
capture cmdline in `/etc/default/kdump-tools` should do it:

```sh
# narrowest: stop systemd pulling in swap units
KDUMP_CMDLINE_APPEND="... noresume systemd.mask=swap.target module_blacklist=..."

# broader: ignore /etc/fstab entirely (root= comes from the cmdline; /var/crash is on /)
KDUMP_CMDLINE_APPEND="... noresume fstab=no module_blacklist=..."
```

Neither has been tested on this machine yet. Verify the token reached the
live capture cmdline via `/var/crash/kexec_cmd` after `kdump-config reload`
(never via the config file — see Part 8's `KDUMP_CMDLINE_APPEND` trap). A
*fair* test needs a panic while an unconsumed image is on disk, and there is
no cheap way to stage that: a sysrq panic on a resumed session has already
consumed the image, and booting with `noresume` by hand makes the main
kernel's own `swapon` do exactly what the capture kernel did. So the first
real recurrence is the test — look for the absence of `software suspend data
detected` in the capture kernel's journal, and a resume instead of a login
screen. Until then the operating rule from the TL;DR stands: **stay on AC when
the session matters**, so the 7% action never fires, and treat a
capture-kernel boot after a hibernation as a lost session.

> **If you take one thing from Part 10:** a kdump capture kernel is a full boot
> that processes `/etc/fstab`. `noresume` keeps it off the resume path; it does
> **not** keep `swapon` off the swap partition, and `swapon` erases hibernation
> images on sight. Check for `software suspend data detected` in the capture
> kernel's journal before blaming the image write.

> **And note what the reserve arithmetic looked like from the other side:**
> `grep Percentage /etc/UPower/UPower.conf` still prints the packaged `2.0`,
> and it is easy to conclude from that the 7% drop-in never took. It did — the
> live value is only visible via `/etc/UPower/UPower.conf.d/` or
> `busctl call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetCriticalAction`,
> and the charge curve after the event (18% after 8 min at 31 W) puts the
> trigger at 7%, not 2%.

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
| `/usr/local/sbin/stale-kernel-lid-guard` | Forces plain suspend on a lid close while the running kernel isn't the newest installed (see [Part 7](#part-7--the-kernel-upgrade-trap)). `--status`, `--self-test`. |
| `/etc/systemd/system/stale-kernel-lid-guard.service` | Evaluates the guard at boot — catches booting an old kernel from the GRUB menu |
| `/etc/kernel/postinst.d/zzz-stale-kernel-lid-guard` | Evaluates the guard whenever apt installs a kernel. `zzz-` sorts after `zz-update-grub`. |
| `/run/systemd/logind.conf.d/99-stale-kernel.conf` | **Written at runtime, tmpfs, not installed.** Present only while the guard is armed; gone after a reboot. |
| `/etc/UPower/UPower.conf.d/10-hibernate-reserve.conf` | Raises the emergency-hibernate battery floor from 2% to 7% (see [Part 6](#part-6--a-lost-session-diagnosed)) |
| `/etc/default/kdump-tools` | `KDUMP_CMDLINE_APPEND=… noresume module_blacklist=…` — keeps the capture kernel off the resume path and away from the audio/WiFi/GPU drivers that have twice panicked it (see [Part 8](#part-8--a-panic-during-hibernation-and-no-vmcore)). Packaged conffile, edited in place; timestamped `.bak-` alongside. |
| `~/.local/bin/suspend-report` | Health report on the last suspend cycle |
| `~/.local/bin/ttm-fix-check` | Classifies the running kernel and the apt candidate as clean / buggy / fixed for the drm/ttm bulk_move bug, from the Ubuntu changelog; notifies on change ([Part 9](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)) |
| `~/.config/systemd/user/ttm-fix-check.{service,timer}` | Runs it daily (`Persistent=true`) |
| `/etc/systemd/system-sleep/zz-hibernate-resume-warn` | `post`-phase sleep hook: if this boot has written a hibernation image since the last wake, schedules a 3 s system timer that launches the warning in every graphical user's session — two stages, because the hook runs while `user.slice` is still frozen ([Part 9](#second-occurrence-2026-09-19--and-the-warning-that-never-fired)). State in `/run/hibernate-resume-warn.count`; logs as `hibernate-resume-warn`. |
| `/usr/local/bin/hibernate-resume-warn` | The warning itself: critical notification + zenity **Reboot now / Later** dialog. `--quiet` prints this boot's image count; no args warns only if it is > 0. |
| `/etc/default/grub` | `resume=UUID=<your-swap-uuid>` appended — **no `resume_offset`** — plus `crash_kexec_post_notifiers=1` so a panic reaches `pstore` before the kexec jump ([Part 8](#part-8--a-panic-during-hibernation-and-no-vmcore)); timestamped `.bak` alongside |
| `/etc/fstab` | swap entry now `UUID=<your-swap-uuid>`; the old `/swap.img` line commented out, timestamped `.bak` alongside |

**Current verified state** *(2026-09-18)*

```
armed wake sources:  PNP0C0D (lid), PNP0C0C (power button), pnp0/00:00 + rtc0/alarmtimer
/sys/power/resume        = 259:5          (nvme0n1p5)
/sys/power/resume_offset = 0              (correct for a partition)
swap                     = 64 G at /dev/nvme0n1p5, contiguous
/                        = 36% used, 57 G free
UPower PercentageAction  = 7.0            (packaged default 2.0)
CanSuspend / CanHibernate / CanSuspendThenHibernate = yes / yes / yes
stale-kernel lid guard   = installed, enabled, self-test PASS, not armed
kdump                    = ready to kdump; capture cmdline carries noresume
                           + module_blacklist. VERIFIED 2026-08-25: saved a
                           456 MB vmcore to /var/crash/202608251309.
crash_kexec_post_notifiers = Y  (efi_pstore records the panic BEFORE the kexec
                           jump). VERIFIED 2026-08-25: pstore record at kernel
                           uptime 7497 s = the real kernel, not the capture one.
WiFi                     = Intel AX210 (iwlwifi), ~4 s to activated after resume
kernel 7.0.0-31          = carries the drm/ttm bulk_move bug (Part 9); fix not
                           yet in Ubuntu. ttm-fix-check.timer enabled, reports
                           "buggy / buggy". Operating rule: reboot after any
                           hibernation resume.
kdump capture cmdline    = still activates swap from fstab and ERASES a pending
                           hibernation image (Part 10). Fix proposed, not applied.
```

`/swap.img` is **gone** — deleted only after a resume from the partition was
confirmed working.

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

# Confirm the resume device is resolved. 259:5 = nvme0n1p5; 0:0 means the
# initramfs resume module is missing (see gotcha 1).
cat /sys/power/resume
cat /proc/cmdline | tr ' ' '\n' | grep resume    # expect NO resume_offset

# DID THE LAST HIBERNATE ACTUALLY RESUME?  Same boot ID = yes, new = no.
journalctl --list-boots | tail -3

# ...and if it did not, why. -22 = image written but invalid on read-back.
journalctl -b -1 | tail -60 | grep -iE 'hibernat|sleep operation'   # did it hibernate?
journalctl -b 0 | grep -iE 'resume|Image not found'                 # what resume said

# Swap fragmentation (a partition should report no extent count at all)
journalctl -b | grep 'Adding .* swap on'

# Who is blocking sleep / the lid
systemd-inhibit --list

# Is hibernation currently safe? (stale kernel = lid will plain-suspend)
stale-kernel-lid-guard --status
uname -r; linux-version list | linux-version sort --reverse | head -1

# What logind will ACTUALLY do with the lid, straight from the daemon.
# "sleep" = normal (suspend-then-hibernate); "suspend" = guard armed.
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager HandleLidSwitch

# Effective merged config
systemd-analyze cat-config systemd/sleep.conf
systemd-analyze cat-config systemd/logind.conf

# DID IT PANIC?  A short extra boot whose cmdline has elfcorehdr= is the
# kdump capture kernel, and kexec -p fires ONLY on a panic. Not a reboot loop.
journalctl --list-boots | tail -4
journalctl -b -1 | grep "Kernel command line"

# Is crash capture armed, and will a panic leave evidence at all?
kdump-config status
grep -oE 'noresume|module_blacklist=[^ "]*' /var/crash/kexec_cmd   # verify HERE, not in /etc/default
cat /sys/module/kernel/parameters/crash_kexec_post_notifiers       # MUST be Y

# THE CRASH RECORDS.  /sys/fs/pstore is root-only and prints nothing when you
# lack permission -- which reads exactly like "empty". Use the archive instead.
ls -la /var/lib/systemd/pstore/                 # one dir per record, epoch-named
sudo grep -l 'Kernel panic\|BUG:' /var/lib/systemd/pstore/*/*/dmesg.txt

# Which kernel wrote a record?  Capture-kernel uptimes are seconds; the real
# kernel's are hours. That distinction is the whole diagnosis.
sudo grep -oE '^<[0-9]>\[ *[0-9]+\.' /var/lib/systemd/pstore/<epoch>/001/dmesg.txt | tail -1

ls -la /var/crash/                     # dated dir = a vmcore was captured

# REASSEMBLE a pstore record.  One panic is split into ~1 KB parts across
# several epoch dirs (Oops#1 Part1..Part15, not in order). Sort on uptime.
sudo cat /var/lib/systemd/pstore/<epoch-prefix>*/*/dmesg.txt \
  | grep -E '^<[0-9]>\[' | sort -t']' -k1,1 -s | sed 's/^<[0-9]>//' \
  | grep -vE '^\[[0-9. ]+\]  ?\? '          # drop the "? maybe-frame" noise

# DID THIS SESSION COME BACK FROM A HIBERNATION IMAGE?  (yes -> reboot before
# anything that matters, until the drm/ttm fix ships; see Part 9)
journalctl -b -k | grep -c 'Hibernation image restored successfully'
hibernate-resume-warn --quiet          # same question, counting images WRITTEN this boot
sudo /etc/systemd/system-sleep/zz-hibernate-resume-warn post hibernate   # simulate a wake; dialog iff count rose
sudo /etc/systemd/system-sleep/zz-hibernate-resume-warn post test        # dialog unconditionally, ~3 s later
journalctl -b -t hibernate-resume-warn                                   # did it fire, and did the dialog start?

# COUNT REAL HIBERNATIONS, not sleep attempts.  "Operation 'suspend-then-
# hibernate' finished" fires on every wake, including the ones that only
# suspended. Kernel entry/exit pairs are the honest count.
journalctl -b -k | grep -cE 'PM: hibernation: hibernation (entry|exit)'

# A COUNTDOWN, NOT NOISE: any of these in the current boot = save work, reboot.
journalctl -b -k | grep -E 'list_(del|add) corruption|cut here'

# Does the running / candidate kernel carry the drm/ttm bulk_move bug? (Part 9)
ttm-fix-check

# Did the capture kernel erase a pending hibernation image? (Part 10)
journalctl -b -1 | grep 'software suspend data detected'

# The LIVE emergency-hibernate threshold. /etc/UPower/UPower.conf still says
# 2.0; the drop-in is what runs.
grep -h Percentage /etc/UPower/UPower.conf.d/*.conf
busctl call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetCriticalAction
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
   the initramfs resolver is missing.** Working value here is `259:5`
   (`259:3` before the Part 5 migration).
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

8. **WiFi resume cost depends on the card, and this one changed.** The original
   MT7922 failed `pci_pm_restore` (-110) on hibernate resume and did a full
   firmware reload, taking **~18 s** to come back (vs ~3 s from s2idle) — worth
   knowing before walking into a lecture. It was swapped for an **Intel AX210**
   on 2026-08-19 for unrelated association-loss problems, and the AX210 restores
   cleanly: no `pci_pm_restore` failure, no firmware reload, `PM: restore of
   devices complete after 648 msecs`, and NetworkManager reporting `activated`
   **4 s** after resume. If the card is ever swapped again, re-measure — this
   number is a property of the driver, not of the hibernate configuration.

9. **`filefrag` reports in filesystem blocks (4096 B here)**, matching the page
   size, so the value is directly usable as `resume_offset`. Confirmed
   independently — systemd computed the *same* `offset: 20113408` via its own
   FIEMAP call when writing the EFI `HibernateLocation` variable.
   *(Swapfile-era only — a partition has no offset.)*

10. **swsusp writes the page data first and the header signature LAST.** So an
    interrupted image write fails as **`PM: Image not found (code -22)`** on the
    next boot — the same error you'd get from a wrong offset, which makes it easy
    to misdiagnose. `-22` means *no valid signature at that location*, not
    *wrong location*. Check the EFI pointer before blaming the offset.

11. **A failed resume is silent.** No dialog, no notification — the machine just
    cold-boots and the session is gone. `journalctl --list-boots` is the only
    routine way to notice, since a **new boot ID** after a hibernate is the tell.

12. **A failed *hibernate* and a failed *resume* look nothing alike.** A hibernate
    that can't proceed thaws and leaves the machine **awake**, logging why. If the
    machine powered off, hibernation ran — any fault is on the resume side.

13. **UPower drop-in filenames are validated**, against
    `^[0-9][0-9]-[a-zA-Z0-9_-]*\.conf$`. A file that doesn't match is ignored
    without complaint. The thresholds are also not exposed on D-Bus, so
    verification is limited to a clean restart plus `GetCriticalAction`.

14. **Installing a kernel and booting it are separate events, and hibernation
    silently depends on the second one.** A swsusp image is stamped with the
    kernel that wrote it; any other kernel refuses it. With `GRUB_DEFAULT=0` the
    next boot takes the *newest installed* kernel, so from the moment apt lands a
    kernel until you reboot, every hibernation is a one-way trip. Nothing warns
    you — `/var/run/reboot-required` exists but no desktop surface shows it at
    lid-close time. This is what [Part 7](#part-7--the-kernel-upgrade-trap) is
    about, and what the lid guard now prevents.

15. **systemd drop-ins are ordered by *filename*, across all search directories.**
    `/run/systemd/logind.conf.d/99-x.conf` beats `/etc/systemd/logind.conf.d/10-y.conf`
    even though `/etc` is the higher-priority *directory* — the `99-` prefix is
    what decides. That is what lets the lid guard live entirely on tmpfs and
    disappear at reboot. Read the effective value from logind rather than
    inferring it from files:
    ```bash
    busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandleLidSwitch
    ```

16. **A hibernation that never resumes flushes *nothing*.** [Gotcha 7](#gotchas-worth-remembering)
    says kernel PM messages are timestamped at resume; the consequence is that if
    there is no resume, every message after `PM: hibernation: hibernation entry`
    dies in the ring buffer. **The last journal line is where logging stopped, not
    where the kernel stopped.** Proof, from a *successful* cycle: its
    `Filesystems sync` and `Freezing user space processes` lines carry the
    **resume** timestamp, 25 minutes after the entry they describe. Treat the
    whole hibernation as the blind window and get a vmcore
    ([Part 8](#part-8--a-panic-during-hibernation-and-no-vmcore)).

17. **`kdump` armed means `pstore` gets nothing.** `panic()` calls
    `__crash_kexec()` **before** `kmsg_dump()`, and the jump to the capture kernel
    never returns — so with kdump enabled, the original panic is never written to
    `efi_pstore`. Proven locally: after the 08-24 hibernation panic the capture
    kernel logged `systemd-pstore.service … skipped, unmet condition check
    ConditionDirectoryNotEmpty=/sys/fs/pstore`, then wrote *its own* panic there
    minutes later (nothing is armed inside a capture kernel). Enabling kdump
    therefore made things **worse** until `crash_kexec_post_notifiers=1` was set,
    which reverses the order. It is live-togglable:
    ```bash
    cat /sys/module/kernel/parameters/crash_kexec_post_notifiers   # Y = safe
    ```

18. **Read `/var/lib/systemd/pstore/`, not `/sys/fs/pstore`.** The latter is
    root-only and `ls` returns *permission denied*, printing nothing — which is
    trivially misread as "empty, no crash records". `systemd-pstore.service`
    archives records to `/var/lib/systemd/pstore/<epoch>/<n>/` at boot and
    reassembles the chunks into a `dmesg.txt`. That misreading cost a full extra
    diagnostic cycle here, including a deliberate crash.

19. **A capture kernel is a real boot, and re-probes real hardware.** It runs the
    actual root filesystem with systemd, udev and apparmor, and it has panicked
    twice on this machine doing so — `acp63_irq_handler [snd_pci_ps]` and
    `iwlwifi`. `irqpoll`, which kdump adds by default, makes this worse: it polls
    **every** registered IRQ handler, so a driver whose device state was never
    initialised gets called anyway (the 08-24 trace runs
    `note_interrupt` → `try_one_irq` → `acp63_irq_handler`). A capture kernel
    needs `nvme` and the root filesystem and nothing else — blacklist the rest.

20. **printk timestamps do not advance during suspend.** They come from the
    monotonic clock, which s2idle pauses — so on a laptop that suspends, kernel
    log timestamps and wall-clock time diverge without warning. Measured here on
    2026-08-25: 15194 s wall, 7497 s on the kernel clock, difference 7697 s,
    matching the sum of that boot's `Timekeeping suspended` segments (7695.6 s).
    This is what makes uptime a reliable way to tell a **capture kernel** record
    (10–35 s) from a **real kernel** one (thousands) in
    [Part 8](#part-8--a-panic-during-hibernation-and-no-vmcore) — but it also
    means you cannot map a printk timestamp back to a clock time. Distinct from
    [gotcha 7](#gotchas-worth-remembering), which is about *when messages are
    flushed*; this is about *what the numbers in them mean*.

21. **A `list_del corruption` `WARNING` is a use-after-free the kernel chose to
    survive.** `CONFIG_DEBUG_LIST` reports it and carries on; the machine ran
    another 56 minutes on 2026-09-17 before the mangled list was dereferenced
    ([Part 9](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)).
    The `slab kmalloc-…` line printed just above it says the stale pointer lands
    in a reused slab object. Treat it as a countdown, and look for the cause
    *earlier* than the warning — here, a hibernation resume four minutes before.

22. **Resuming from hibernation is not the end of the hibernation's effects.**
    On Ubuntu kernels `7.0.0-28` through at least `-31`, every GPU buffer swapped
    out for the image stays on a bulk-move cursor after resume, and freeing one
    leaves the cursor dangling (upstream drm/ttm bug, fix queued 2026-09-09,
    not shipped). The crash comes minutes to hours later, from whatever process
    next submits GPU work. Until the fix lands: reboot after a hibernation
    resume. Only hibernation swaps GPU buffers out; s2idle does not.

23. **The kdump capture kernel activates swap from `/etc/fstab`, and `swapon`
    erases hibernation images.** `noresume` stops the *kernel* resuming; it does
    not stop systemd's fstab generator, and util-linux prints
    `software suspend data detected. Rewriting the swap signature.` as it
    destroys the image. So with kdump armed, any panic between `PM: S|` and
    power-off costs the session even though the image was complete
    ([Part 10](#part-10--part-8s-panic-named--and-the-capture-kernel-that-ate-the-image)).
    `systemd.mask=swap.target` or `fstab=no` on the capture cmdline is the
    proposed fix, unverified.

24. **`grep Percentage /etc/UPower/UPower.conf` lies by omission.** It still
    shows the packaged `PercentageAction=2.0`; the live 7% comes from
    `/etc/UPower/UPower.conf.d/10-hibernate-reserve.conf`. Read the drop-in dir
    or ask the daemon (`GetCriticalAction` over `busctl`) before concluding the
    reserve "didn't take". The 2026-09-17 emergency hybrid-sleep fired at 7%,
    as designed.

25. **`Operation 'suspend-then-hibernate' finished` is logged on every wake,
    hibernated or not.** Counting it over-reports hibernations by the number of
    plain-suspend wakes. `PM: hibernation: hibernation entry` / `exit` pairs in
    the kernel log are the real count, and
    `Hibernation image restored successfully` is the one-line answer to "did
    this session come from an image".

26. **`system-sleep` `post` hooks run while every user session is frozen.**
    `systemd-sleep` (v255+) freezes `user.slice` in `run()`, runs the hooks
    in `execute()`, and thaws after `execute()` returns — on this machine the
    hooks had 116 ms between "System returned from sleep" and "thawed unit
    'user.slice'". `systemd-run --user`, `notify-send`, anything over the
    session bus: fails or hangs, and a hand test from a desktop shell passes
    because nothing is frozen then. Decide in the hook; act from a
    `systemd-run --on-active=` timer in the system manager
    ([Part 9](#second-occurrence-2026-09-19--and-the-warning-that-never-fired)).

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
If the drain spans a *hibernation*, residency is the wrong place to look —
hibernation is 0 W, so **any** measurable loss means it never powered off. See
[Part 7](#part-7--the-kernel-upgrade-trap).

**The lid suspends but no longer hibernates after 2 h**
```bash
stale-kernel-lid-guard --status     # "ARMED" = working as intended; reboot to clear
```
Expected right after a kernel upgrade. If it says ARMED and you have already
rebooted, the `/run` file should have vanished — check
`systemctl status stale-kernel-lid-guard.service`.

**Session lost, and the journal just stops at `hibernation entry`**
```bash
journalctl --list-boots | tail -4                  # TWO new boot IDs = a panic
journalctl -b -1 | grep "Kernel command line"      # elfcorehdr= -> capture kernel
ls -la /var/crash/                                 # dated dir = dump captured
```
This is [Part 8](#part-8--a-panic-during-hibernation-and-no-vmcore), not a Part 6/7
image failure — there will be no `-22` and no `Image mismatch`. Do **not** read the
last journal line as the point of death ([gotcha 16](#gotchas-worth-remembering)).
If `/var/crash` has no dated directory, the capture kernel died before saving —
look for **its** panic in `/var/lib/systemd/pstore/` (uptime in seconds gives it
away) and blacklist whatever driver it crashed in. The panic you actually care
about is only there if `crash_kexec_post_notifiers` is `Y`. A reboot with the lid
still shut re-runs the lid policy on its own, so the hibernate count can exceed
the number of times you actually closed it — count `Lid closed.` from
`systemd-logind`.

**Session lost across a hibernate**
```bash
journalctl --list-boots | tail -3            # new boot ID = the resume failed
journalctl -b 0 | grep -E "PM: Image (not found|mismatch)"
journalctl -b 0 | grep "Reported hibernation image"   # which kernel wrote it
uname -r                                              # which kernel read it
```
A `kernel=` in the reported image that differs from `uname -r` is the Part 7
failure. `Image not found (code -22)` on its own is an incomplete write
([gotcha 10](#gotchas-worth-remembering)).

**The machine "just started" instead of resuming — session lost**
Work it in this order; the full worked example is
[Part 6](#part-6--a-lost-session-diagnosed).
```bash
journalctl --list-boots | tail -3     # new boot ID after a hibernate = resume failed
journalctl -b -1 | tail -60           # did it actually hibernate? look for 'hibernation entry'
journalctl -b 0 | grep -iE 'resume|Image not found'
```
`PM: Image not found (code -22)` means the image was **invalid**, not
mislocated — check whether the EFI pointer was intact before suspecting the
resume device. If the machine had been on battery a long time, suspect an
incomplete write and confirm the UPower reserve is still in place:
```bash
grep -r Percentage /etc/UPower/UPower.conf.d/
```

**Hibernate stopped working after touching swap**
Re-run `setup-hibernate.sh`. On the current partition setup there is no offset
to drift, so this should only matter if the partition is recreated (new UUID).
In the swapfile era this was the standing hazard: hibernate succeeded, then the
machine booted fresh and the session was gone.

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

**Machine freezes minutes to hours after a hibernation resume**
```bash
journalctl -b -k | grep -E 'Hibernation image restored|list_(del|add) corruption'
ttm-fix-check
```
A restored image plus `list_del corruption` in the same boot is the drm/ttm
bulk_move bug ([Part 9](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)).
If the corruption line is already there, save work and reboot now — the crash
follows within the hour. If `ttm-fix-check` says `buggy`, the only prevention
is not to work on a resumed session: reboot after hibernation resumes until it
says `fixed`. If it says `fixed` and this still happens, it is something new —
reassemble the pstore record (cookbook) and look at the `RIP:` line.

**Panicked during hibernation, image was written, next boot didn't resume**
```bash
journalctl -b -1 | grep -E 'elfcorehdr|software suspend data detected'
sudo grep -l 'PM: S|' /var/lib/systemd/pstore/*/*/dmesg.txt   # image completed?
```
`elfcorehdr=` means the middle boot was the kdump capture kernel; the `swapon`
line means it erased the image ([Part 10](#part-10--part-8s-panic-named--and-the-capture-kernel-that-ate-the-image)).
The session is gone, but the pstore record names the driver — `acp63_irq_handler
[snd_pci_ps]` both times so far. Apply the Part 10 capture-cmdline fix and
verify it in `/var/crash/kexec_cmd`.

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

**Stale-kernel lid guard**
```bash
sudo systemctl disable --now stale-kernel-lid-guard.service
sudo rm -f /etc/systemd/system/stale-kernel-lid-guard.service \
           /etc/kernel/postinst.d/zzz-stale-kernel-lid-guard \
           /usr/local/sbin/stale-kernel-lid-guard \
           /run/systemd/logind.conf.d/99-stale-kernel.conf
sudo systemctl daemon-reload
sudo systemctl reload systemd-logind
```
Removing it restores the old behaviour: hibernating on a stale kernel silently
loses the session.

**kdump `noresume`**
```bash
sudo cp -a /etc/default/kdump-tools.bak-<timestamp> /etc/default/kdump-tools
sudo kdump-config unload && sudo kdump-config load
grep -c noresume /var/crash/kexec_cmd    # expect 0
```
Reverting restores the packaged behaviour, in which a panic during hibernation
produces no usable dump.

**suspend-then-hibernate (keep plain suspend)**
```bash
sudo rm /etc/systemd/logind.conf.d/10-lid-sleep.conf \
        /etc/systemd/sleep.conf.d/10-hibernate-delay.conf
sudo systemctl restart systemd-logind   # or just reboot
```

**Hibernation entirely**
```bash
sudo rm /etc/polkit-1/rules.d/10-enable-hibernate.rules
sudo rm -f /etc/UPower/UPower.conf.d/10-hibernate-reserve.conf
sudo systemctl restart upower
sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub
sudo cp /etc/fstab.bak.<timestamp> /etc/fstab
sudo rm -f /etc/initramfs-tools/conf.d/resume
sudo update-initramfs -u -k all && sudo update-grub
```
The 64 GB `p5` can stay as ordinary swap — nothing about it requires
hibernation. Reclaiming it means deleting the partition and growing `/home`
back from a live USB.

---

## Maintenance notes

- **No swapfile to exclude from backups any more** — swap is a partition, and
  backup tools skip it automatically. (`/swap.img` used to need explicit
  exclusion from Déjà Dup / Timeshift / rsync.)
- **`/` sits at ~57 GB free** now that the 32 GB swapfile is gone. Still worth
  watching snaps and `/var`.
- **Baseline for comparison: 0.44 W / 0.79 %/hour** in s2idle, 100% s0i3
  residency. Run `suspend-report` if something feels off.
- **After any long unplugged stretch, check `journalctl --list-boots`.** A new
  boot ID where you expected a resume is the only signal you'll get.
- **If the swap partition is ever recreated, re-run `setup-hibernate.sh`** — the
  UUID changes even though there's no offset to worry about.
- **Reboot reasonably promptly after a kernel upgrade.** The guard makes
  forgetting safe rather than catastrophic, but while it's armed you're on plain
  suspend — ~0.8%/hour, about five days from full before the battery matters.
- **Re-run `--self-test` after any systemd major-version upgrade.** The guard
  rests on drop-in filename ordering and on logind honouring a reload; both are
  stable, neither is a promise. The test is non-destructive and takes a second.
- **Crash capture works, and was proven on 2026-08-25** (456 MB vmcore + a
  pstore dmesg of the real panic). Note `kdump-config status` reporting *ready to
  kdump* is NOT evidence of that — it reported exactly the same thing while
  capturing nothing on 08-24 and earlier on 08-25. Re-prove with
  `echo c | sudo tee /proc/sysrq-trigger` after any kernel or `kdump-tools`
  upgrade, and check **both** `/var/crash` and `/var/lib/systemd/pstore/`.
- **Dumps are ~456 MB each and `KDUMP_NUM_DUMPS=3`**, so budget ~1.4 GB of `/`.
- **`crash_kexec_post_notifiers` must read `Y`** — that is what makes a panic
  reach `pstore` at all while kdump is armed. It is set on the GRUB cmdline and
  is also live-togglable, so a config drift shows up at runtime:
  `cat /sys/module/kernel/parameters/crash_kexec_post_notifiers`
- **Check `/var/lib/systemd/pstore/` after any unexplained cold boot**, and
  re-check `/var/crash/kexec_cmd` after a `kdump-tools` upgrade — the settings
  live in a packaged conffile, so an upgrade may prompt to replace it.
- **Reboot after any hibernation resume, until `ttm-fix-check` reports the
  running kernel as `fixed`.** Then drop the rule, and disable the timer
  (`systemctl --user disable --now ttm-fix-check.timer`) — or leave it; it is
  silent once both columns read `fixed`. When the fix arrives it will show in
  the Ubuntu changelog as `drm/ttm: fix swapped-out resources never leaving
  their bulk_move range`.
- **Stay on AC whenever the session matters**, until the Part 10 capture-kernel
  fix is applied and verified — an emergency hybrid-sleep is currently a lost
  session if the audio driver panics during it, and it has done so twice.
- **Watch for `acp63_irq_handler` disappearing from future pstore records** after
  audio-driver updates; that is the only signal that the Part 10 panic is fixed.
- **If the WiFi card is swapped again, re-measure the resume time**
  ([gotcha 8](#gotchas-worth-remembering)) — it's a driver property, not a
  hibernate one.

---

*Last updated 2026-09-18. **The outstanding item from 08-25 is closed:** the
panic during hibernation has a name — `acp63_irq_handler [snd_pci_ps]`, a NULL
dereference in the AMD audio interrupt handler during the device-suspend phase
after the image is written, recorded on 2026-09-17 by both `pstore` (uptime
6226 s, the real kernel) and a 456 MB vmcore, exactly as Part 8's fixes were
meant to deliver ([Part 10](#part-10--part-8s-panic-named--and-the-capture-kernel-that-ate-the-image)).
It is a driver bug, outside this repository's reach.
**Two things are now outstanding instead.** First, the same day's other failure:
resuming from hibernation on any Ubuntu kernel since `7.0.0-28` arms a known
drm/ttm use-after-free that locked the machine an hour after a clean resume
([Part 9](#part-9--a-lockup-an-hour-after-resume-the-drmttm-bulk_move-bug)).
The upstream fix is queued but unshipped; until `ttm-fix-check` says
otherwise, the rule is *reboot after a hibernation resume*. Second, the kdump
capture kernel erases a pending hibernation image by activating swap from
`fstab` — a fix is proposed in Part 10 and not yet applied. Everything else
remains as verified on 08-25: the wake-source policy, the swap partition,
suspend-then-hibernate, the stale-kernel lid guard, and crash capture — which
has now proven itself against a real hibernation panic, not just a `sysrq`.*
