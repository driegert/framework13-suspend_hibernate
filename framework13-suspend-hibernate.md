# Framework 13 (AMD 7840U) — Suspend & Hibernate on Ubuntu 26.04

Working notes from fixing suspend/hibernate on **tinkertoy**, 2026-08-12 → 2026-08-19.
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
9. [Installed files — full inventory](#installed-files--full-inventory)
10. [Diagnostic cookbook](#diagnostic-cookbook)
11. [Gotchas worth remembering](#gotchas-worth-remembering)
12. [Troubleshooting](#troubleshooting)
13. [How to undo everything](#how-to-undo-everything)

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

**Day-to-day behaviour now**

- Lid closed, undocked, on battery → s2idle for 2 h (instant resume), then automatic hibernate to disk
- Lid closed **with an external monitor** → stays awake (clamshell, intended)
- On AC → suspends and stays suspended; **unplug and the 2 h countdown starts from that moment**
- Waking → **power button or lid only**. Keyboard and touchpad will *not* wake it.
- Unplugging the charger no longer wakes it — the original complaint
- Battery critically low while awake → hibernates at 7%, with enough charge left to finish writing the image

---

## System context

```
Framework 13, AMD Ryzen 7 7840U
Ubuntu 26.04 LTS, kernel 7.0.0-29-generic, systemd 259, GNOME/Wayland
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

## Installed files — full inventory

| Path | Purpose |
|---|---|
| `/usr/local/sbin/framework-wakeup-policy` | Disarms all wake sources except lid, power button, RTC. Aborts without changes if it can't find lid + power button. Also sets `pm_debug_messages=1`. |
| `/etc/systemd/system/framework-wakeup-policy.service` | Applies the policy at boot (`After=basic.target`, `Before=sleep.target`) |
| `/etc/systemd/system-sleep/framework-wakeup-policy` | **Re-applies before every sleep** — the important one; catches USB/UCSI drift. `timeout 15` guarded, since systemd waits on sleep hooks. |
| `/etc/polkit-1/rules.d/10-enable-hibernate.rules` | Overrides Ubuntu's blanket hibernate denial (local + active only) |
| `/etc/systemd/sleep.conf.d/10-hibernate-delay.conf` | `HibernateDelaySec=2h`, `HibernateOnACPower=no` |
| `/etc/systemd/logind.conf.d/10-lid-sleep.conf` | `HandleLidSwitch=sleep` (+ external power) |
| `/etc/UPower/UPower.conf.d/10-hibernate-reserve.conf` | Raises the emergency-hibernate battery floor from 2% to 7% (see [Part 6](#part-6--a-lost-session-diagnosed)) |
| `~/.local/bin/suspend-report` | Health report on the last suspend cycle |
| `/etc/default/grub` | `resume=UUID=<your-swap-uuid>` appended — **no `resume_offset`**; timestamped `.bak` alongside |
| `/etc/fstab` | swap entry now `UUID=<your-swap-uuid>`; the old `/swap.img` line commented out, timestamped `.bak` alongside |

**Current verified state** *(2026-08-19)*

```
armed wake sources:  PNP0C0D (lid), PNP0C0C (power button), pnp0/00:00 + rtc0/alarmtimer
/sys/power/resume        = 259:5          (nvme0n1p5)
/sys/power/resume_offset = 0              (correct for a partition)
swap                     = 64 G at /dev/nvme0n1p5, contiguous
/                        = 36% used, 57 G free
UPower PercentageAction  = 7.0            (packaged default 2.0)
CanSuspend / CanHibernate / CanSuspendThenHibernate = yes / yes / yes
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

8. **MT7922 WiFi fails `pci_pm_restore` (-110) on hibernate resume** and does a
   full firmware reload instead. Not a fault — but WiFi takes **~18 s** to come
   back (vs ~3 s from s2idle). Worth knowing before walking into a lecture.

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

---

*Last updated 2026-08-19. Nothing outstanding: manual `systemctl hibernate` and
a full 2 h lid-closed suspend-then-hibernate cycle are both verified on the swap
partition.*
