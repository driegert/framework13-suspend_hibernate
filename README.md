# Framework 13 AMD — suspend & hibernate that actually saves battery

Scripts and config to stop a Framework 13 (AMD Ryzen 7840U) draining its
battery while it's supposed to be asleep, on Ubuntu.

Developed on a Framework 13 AMD / Ryzen 7 7840U running Ubuntu 26.04, kernel
7.0.0-29, systemd 259, GNOME/Wayland. Most of it applies to any AMD Framework;
the parts that don't are called out in [Portability](#portability).

**Result on the test machine:**

| | Before | After |
|---|---|---|
| Armed wake sources | 26 (AC adapter, 4× USB-C PD ports, touchpad, keyboard, …) | 4 (lid, power button, RTC ×2) |
| Spurious wakes | 12 in 18 min with the lid shut | 0 in 27.8 h |
| s0i3 residency | repeatedly failing | 100.0% |
| Suspend power draw | `didn't reach deepest state` | 0.44 W (0.79 %/hour) |
| Cost of being away 24 h | ~20% of the battery | ~1.6%, then zero |

The full investigation — every diagnostic, every dead end, why each decision
went the way it did — is in **[framework13-suspend-hibernate.md](framework13-suspend-hibernate.md)**.
This file is just the practical how-to.

---

## The problem

### There is no S3 on this platform

On an older laptop, "suspend" meant **S3**: the CPU and most of the board were
genuinely powered off, and the machine sipped ~0.1 W. The 7840U doesn't have
it. Check yours:

```bash
cat /sys/power/mem_sleep
# [s2idle]          <- modern standby only, this guide applies
# s2idle [deep]     <- you have S3; most of this is unnecessary
```

`s2idle` ("suspend-to-idle" / modern standby) is a *software* state: the kernel
freezes userspace and idles the CPUs, but the machine is still fundamentally
on. Actually saving power depends on the SoC then dropping into a **hardware**
low-power state called **s0i3**. That's the bit that matters, and it's the bit
that silently fails.

### Two things stop s0i3 from happening

**1. Anything armed as a wake source can prevent or interrupt it.** By default
this laptop had **26** devices with `power/wakeup = enabled`, including:

- the **AC adapter** — unplugging the charger wakes the machine
- **four USB-C PD ports** — any cable wiggle, dock blip or PD renegotiation
- the **touchpad** — lid pressure on the pad generates wake events with the lid *shut*
- the keyboard, USB controllers, USB4/Thunderbolt, PCIe bridges

Each wake costs a full resume/re-suspend cycle, and a suspend that only lasts
one second can't reach s0i3 at all. The observed failure mode was 12 wake/sleep
cycles in 18 minutes with the lid closed — a warm bag and a flat battery.

**2. Even when it works, s0i3 isn't free.** The measured floor here is
**0.44 W**, about 0.79%/hour, roughly **20% of the battery per day** asleep.
That's a healthy number for this platform — it is not going to match a real S3
laptop, because S3 doesn't exist here.

So the fix has two halves: make s0i3 reliable, then **stop paying for it** by
hibernating to disk after a couple of hours. Hibernation costs exactly zero.

### And Ubuntu disables hibernation outright

Even with everything configured perfectly, `CanHibernate` returns `"no"`,
because Ubuntu ships a polkit rule denying it. That's a *policy* denial, not a
capability one — and it's reversible.

---

## Does this apply to me?

Run these four checks first.

```bash
# 1. Modern-standby only? ("[s2idle]" with no "deep" = yes, continue)
cat /sys/power/mem_sleep

# 2. How many things can currently wake the machine?
find /sys/devices -path '*/power/wakeup' -type f 2>/dev/null | while read -r f; do
    [ "$(cat "$f")" = "enabled" ] && echo "${f#/sys/devices/}"
done | sed 's|/power/wakeup||' | sort | tee /dev/stderr | wc -l

# 3. Is s0i3 actually being reached? Compare against how long it was asleep.
#    (microseconds; 0 or tiny after a long suspend = it never got there)
cat /sys/power/suspend_stats/last_hw_sleep

# 4. The smoking gun, if present:
journalctl -b | grep "didn't reach deepest state"
```

You want check 2 to eventually report **4** (lid, power button, and two RTC
nodes). If it reports 20-something today, this repo is for you.

---

## What's in here

| File | Installs to | Portable? |
|---|---|---|
| `framework-wakeup-policy` | `/usr/local/sbin/` (0755) | ✅ as-is |
| `framework-wakeup-policy.service` | `/etc/systemd/system/` (0644) | ✅ as-is |
| `framework-wakeup-policy.sleep` | `/etc/systemd/system-sleep/framework-wakeup-policy` (0755) | ✅ as-is |
| `setup-hibernate.sh` | run once with sudo, not installed | ⚠️ pick `--file` or `--partition`, check size |
| `10-enable-hibernate.rules` | `/etc/polkit-1/rules.d/` (0644) | ⚠️ Ubuntu-specific |
| `10-hibernate-delay.conf` | `/etc/systemd/sleep.conf.d/` (0644) | ✅ tune to taste |
| `10-lid-sleep.conf` | `/etc/systemd/logind.conf.d/` (0644) | ✅ tune to taste |
| `10-hibernate-reserve.conf` | `/etc/UPower/UPower.conf.d/` (0644) | ✅ as-is |
| `suspend-report` | `~/.local/bin/` (0755) | ⚠️ edit battery model |

All of it lives in [`framework13-suspend-scripts/`](framework13-suspend-scripts/).

### Part 1 — `framework-wakeup-policy`

A short POSIX shell script that disarms every wake source except the lid, the
power button, and the RTC.

**It runs at boot *and again before every single sleep*, and the second one is
the important one.** UCSI power-supply devices are destroyed and recreated on
USB-C PD renegotiation and come back `wakeup=enabled`; so does every newly
plugged USB device. A boot-only fix quietly rots back to broken over the course
of a day. (Confirmed in practice: a wireless mouse and a USB LAN adapter
plugged into a dock both showed up armed. An armed wireless mouse wakes the
laptop on any desk bump.)

**Safety:** the script *positively discovers* the lid (`PNP0C0D`) and power
button (`PNP0C0C`) first and **aborts without changing anything** if it can't
find exactly one of each. Without that guard, a renamed sysfs path after a
kernel upgrade would disarm all 83 wakeup nodes — lid and power button
included — exit 0 reporting success, and leave you with a laptop that can only
be recovered by holding down the power button.

The RTC stays armed deliberately: it can't fire unless software programs an
alarm, and it's a hard prerequisite for Part 3.

### Part 2 — `setup-hibernate.sh`

Provisions somewhere to put the hibernation image and wires up `resume=` on the
kernel command line. **It offers two paths, and the choice matters more than it
looks.**

```sh
sudo ./setup-hibernate.sh                          # swapfile on / (default)
sudo ./setup-hibernate.sh --size 48                # ditto, 48 GiB
sudo ./setup-hibernate.sh --partition /dev/nvme0n1p5   # dedicated swap partition
```

| | `--file` (swapfile) | `--partition` |
|---|---|---|
| Repartitioning | none | needs unallocated space, usually a live-USB shrink |
| Kernel cmdline | `resume=UUID=…` **+ `resume_offset=`** | `resume=UUID=…` only |
| Fragility | offset breaks if the file is recreated | nothing to drift |
| `/home` constraint | forced onto `/` by `ProtectHome=yes` | not applicable |
| Maintenance | **re-run this script if you touch the swapfile** | none |

**The offset is the whole difference.** In swapfile mode, `resume_offset` is a
*physical block offset* baked into the kernel command line. Recreate, resize or
restore the swapfile and it goes stale — after which **hibernate still succeeds
and resume silently fails, losing the session.** A swap partition is located
purely by UUID, so that failure mode does not exist.

Take the swapfile if you don't want to repartition. **If you're booting a live
USB anyway, take the partition** — it is strictly more durable, and it also
frees whatever the swapfile was occupying on `/`.

Both paths are written to be safe to interrupt: the new swap is fully
established **before** the old is torn down, so a failure at any point leaves a
bootable machine with working swap.

Both refuse to run unless the ground is provably solid. Swapfile mode checks for
a non-ext4 filesystem, block size ≠ page size, LVM/LUKS/RAID underneath,
insufficient free space, a `GRUB_CMDLINE_LINUX_DEFAULT` it can't safely edit, or
an existing `/swap.img` it can't prove is really swap. Partition mode adds the
guards that matter when a command is about to run `mkswap`: it refuses whole
disks, anything mounted, anything backing `/`, `/home`, `/boot` or `/boot/efi`,
and — without an explicit `--force` — any device holding a filesystem. It then
requires you to type `YES`.

Switching from a swapfile to a partition is handled: the script strips the stale
`resume_offset` from the cmdline, comments out the old swap line in
`/etc/fstab` (backing it up first), and **deliberately leaves `/swap.img` on
disk** so you still have a fallback until you've confirmed a real hibernate and
resume. It tells you when it's safe to delete.

### Part 3 — `10-lid-sleep.conf` + `10-hibernate-delay.conf`

Closing the lid gives you s2idle for 2 hours (instant resume between classes,
meetings, whatever), then an automatic hibernate to disk (zero draw). On AC it
just stays suspended.

`HandleLidSwitch=sleep` rather than `suspend` is deliberate: `sleep` makes
logind pick the best available option *at the moment the lid closes*, trying
`suspend-then-hibernate → hybrid-sleep → suspend → hibernate` in order. So if
hibernation ever breaks — swapfile recreated, kernel change — **the lid falls
back to a plain suspend by itself** instead of failing to sleep at all.

### Part 4 — `suspend-report`

Prints a health report on the last suspend cycle: duration, s0i3 residency
percentage, whether it surfaced mid-sleep and on what IRQ, and the actual
measured power draw.

It reads live charge counters rather than trusting `upower --dump`, because
**upower cannot log while the machine is asleep** — comparing its history
before and after compares a sample to itself and cheerfully reports `0.00
%/hour`.

---

## Before you install: values to change

There are exactly **two** hardcoded machine-specific values. Everything else is
discovered at runtime.

### 1. Swap size — `--size`, or the size of your partition

```sh
sudo ./setup-hibernate.sh --size 48                    # swapfile, 48 GiB
sudo ./setup-hibernate.sh --partition /dev/nvme0n1p5   # size = the partition's
```

Swapfile mode defaults to 32 GiB at `/swap.img` (Ubuntu desktop's path; Debian
often uses `/swapfile` — change `SWAPFILE` at the top of the script if so).

**Swap does not need to equal RAM, but don't cut it fine either.** It needs to
hold the hibernation image, which is a copy of what's *actually in use*. On this
60 GB machine, observed images ranged from **9.7 GB to 26.0 GB** — and that
spread is the whole lesson:

| When | Image | % of a 32 GiB swapfile |
|---|---|---|
| Test cycles shortly after a reboot | 9.7 – 12.2 GB | 28 – 36% |
| Real session, end of a working day | **26.0 GB** | **76%** |

Hibernating a freshly-booted machine tells you almost nothing. Size for a bad
day — browser, editors, containers, a VM — not for a quiet one.

To size it, check what you actually use at your *heaviest*, and leave real
headroom:

```bash
free -g                                  # "used" column, at a busy moment
cat /sys/power/image_size                # kernel's own soft target, 2/5 of RAM
```

Rule of thumb: **half your RAM** is a sensible floor, and it's what the 32 GiB
here works out to. **Swap ≥ RAM** makes it structurally unfailable, and if
you're sizing a partition you may as well — the space is otherwise idle.

In swapfile mode, confirm you have room for **`--size` + 1 GiB**, because the
old and new files deliberately exist at the same time:

```bash
df -h /
```

If `/` can't hold both, the script tells you so and points at `--partition`
rather than quietly shaving its own safety margin.

> The original 8 GB Ubuntu default swapfile **could never have held the image.**
> If you're on a stock Ubuntu install, yours is probably 8 GB too.

**What happens if you undersize it?** Not a disaster: systemd logs `Couldn't
hibernate, will try to suspend again` and falls back to plain suspend (the
`suspend-after-failed-hibernate` action in `man 8 systemd-sleep`). You keep the
session and pay the s2idle draw instead of hibernating. Worth knowing — but at
~0.44 W that's still ~20%/day, so it's a soft landing, not a safety net you'd
want to rely on over a long weekend.

### 2. Battery model — `suspend-report`

Line 6 globs upower's history file by battery model name:

```sh
BATT_HIST=$(ls -t /var/lib/upower/history-charge-FRANGWA-*.dat 2>/dev/null | head -1)
```

`FRANGWA` is this battery's model. Find yours and substitute it:

```bash
cat /sys/class/power_supply/BAT*/model_name
ls /var/lib/upower/history-charge-*.dat
```

Pick the file matching your *laptop* battery, not a Bluetooth peripheral —
upower keeps history for headphones and keyboards in the same directory. If you
get this wrong the drain figure is nonsense; everything else in the report
still works.

The script handles `charge_*` (µAh) vs `energy_*` (µWh) batteries
automatically — no change needed there.

### Optional: timings

In `10-hibernate-delay.conf`:

```ini
HibernateDelaySec=2h    # how long to stay in instant-resume s2idle first
HibernateOnACPower=no   # on AC, just stay suspended
```

At 0.44 W, 2 h costs ~1.6% of the battery before it goes to disk. Shorten it if
you'd rather trade resume speed for battery; lengthen it if you're in and out
of the machine all day.

Leaving `HibernateDelaySec` *unset* makes systemd estimate from the discharge
rate and hibernate only when the battery is nearly flat — more convenient, but
it drains most of the pack first, which is the exact outcome this repo exists
to prevent.

---

## Installation

Clone it, then work through the steps in order. **Do Part 1 first and live with
it for a day** — it's the low-risk half and it's most of the benefit.

```sh
git clone git@github.com:driegert/framework13-suspend_hibernate.git
cd framework13-suspend_hibernate
D="$PWD/framework13-suspend-scripts"
```

### Step 1 — wake-source policy (low risk, do this first)

```sh
sudo install    -m 0755 "$D/framework-wakeup-policy"         /usr/local/sbin/framework-wakeup-policy
sudo install -D -m 0644 "$D/framework-wakeup-policy.service" /etc/systemd/system/framework-wakeup-policy.service
sudo install -D -m 0755 "$D/framework-wakeup-policy.sleep"   /etc/systemd/system-sleep/framework-wakeup-policy
sudo systemctl daemon-reload
sudo systemctl enable --now framework-wakeup-policy.service
```

Verify — you should be down to 4 armed sources:

```sh
systemctl status framework-wakeup-policy.service
find /sys/devices -path '*/power/wakeup' -type f | while read -r f; do
    [ "$(cat "$f")" = "enabled" ] && echo "${f#/sys/devices/}"
done | sed 's|/power/wakeup||' | sort
```

> **Note:** from here on, **the keyboard and touchpad will not wake the
> machine.** Use the power button or open the lid. This is deliberate — the
> touchpad was one of the worst offenders. See [Troubleshooting](#troubleshooting)
> to re-arm the keyboard if you hate it.

Close the lid, walk away for a few hours, then come back and check it slept
once and slept deeply:

```sh
install -m 0755 "$D/suspend-report" ~/.local/bin/suspend-report   # edit battery model first!
suspend-report
```

Residency ≥ 95% and `times it surfaced and re-slept: 0` means Part 1 worked.
**For a lot of people this is enough** — stop here if you like.

### Step 2 — hibernation

Read the script before running it. It reformats your swap. Pick a path — see
[Part 2](#part-2--setup-hibernatesh) for the trade-off:

```sh
sudo "$D/setup-hibernate.sh"                          # swapfile on / (default)
sudo "$D/setup-hibernate.sh" --size 48                # ditto, larger
sudo "$D/setup-hibernate.sh" --partition /dev/nvme0n1p5   # dedicated partition
```

<details>
<summary><b>Making room for a swap partition (live USB)</b></summary>

You need unallocated space, and ext4 **can be grown online but never shrunk
online** — so the shrink has to happen from a live USB with the filesystem
unmounted.

**Shrink from the END of a partition, never the start.** Shrinking the right
edge relocates only the data inside the slice you're removing. Moving a
partition's *start* relocates the entire filesystem — hours of I/O, and the one
operation where a power cut genuinely destroys data. In GParted this means
dragging the right edge left and making sure **"free space *preceding*" stays
0**. If your layout would force a move, prefer the swapfile.

Before you start:

- **Back up the filesystem you're shrinking.** This is the step people skip.
- Save the partition table: `sudo sfdisk -d /dev/nvme0n1 > partition-table.bak`,
  plus copies of `/etc/fstab` and `/etc/default/grub`, onto the USB stick.
- Stay on AC, and make sure the live session won't auto-suspend.
- Use a current live ISO — an old GParted can baulk at newer ext4 features.
- `sudo e2fsck -f /dev/…` first; GParted refuses to resize a dirty filesystem.

Shrinking does **not** change the UUIDs of existing partitions, so `/etc/fstab`
keeps working untouched. Boot normally and confirm the shrunk filesystem is
intact *before* running `setup-hibernate.sh --partition` on the new space.
</details>

Then follow its printed instructions **exactly** — there is a step that is very
easy to miss:

```sh
sudo reboot

# ...after reboot: rebuild the initramfs a SECOND time.
sudo update-initramfs -u -k all
sudo lsinitrd /boot/initrd.img-$(uname -r) | grep -i hibernate-resume   # must find something

sudo reboot

# The check that matters. Must NOT be 0:0.
cat /sys/power/resume          # e.g. 259:3
cat /sys/power/resume_offset   # swapfile mode only; 0 is correct for a partition
```

**Why twice?** On this system `update-initramfs` is a **dracut** shim, not
initramfs-tools (`dpkg -S /usr/sbin/update-initramfs` → `dracut`). Dracut's
resume module excludes itself unless `/proc/cmdline` *already* contains
`resume=` — which it doesn't until after the GRUB change **and** a reboot. Miss
this and `/sys/power/resume` reads `0:0`, hibernate appears to work, and resume
silently fails.

This also means `/etc/initramfs-tools/conf.d/resume` is completely **inert** on
Ubuntu 26.04. Most guides on the internet will tell you to write it. Don't
bother.

### Step 3 — unblock Ubuntu's polkit denial

```sh
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanHibernate
```

> **Read the return value carefully.** `"na"` means hibernation is genuinely
> *unsupported* — go back to Step 2, something's wrong. `"no"` means **polkit
> denied it**, which is what this step fixes.

```sh
sudo install -D -m 0644 "$D/10-enable-hibernate.rules" /etc/polkit-1/rules.d/10-enable-hibernate.rules
sudo systemctl restart polkit
```

The rule is scoped to `local && active` sessions on purpose — matching upstream
systemd's own `allow_active=yes`, and stopping a remote desktop session from
hibernating the machine out from under itself.

Now **test it with a scratch editor open, not real work**:

```sh
systemctl hibernate
```

The machine should power off *completely*. Press power; your session should
come back. Confirm it genuinely resumed rather than cold-booted:

```sh
uptime -s                      # still the PRE-hibernate boot time = success
journalctl --list-boots | tail -3
```

A successful resume keeps the **same boot ID**, because it's the same kernel
session. A *failed* one produces a new boot ID. (Side effect: `journalctl -b -1`
now points at the boot *before* the one you were in. Looks alarming; is
actually the proof it worked.)

### Step 4 — suspend-then-hibernate

Only once `systemctl hibernate` is proven to work:

```sh
sudo install -D -m 0644 "$D/10-hibernate-delay.conf" /etc/systemd/sleep.conf.d/10-hibernate-delay.conf
sudo install -D -m 0644 "$D/10-lid-sleep.conf"       /etc/systemd/logind.conf.d/10-lid-sleep.conf
sudo reboot
```

Final state check:

```sh
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanSuspendThenHibernate     # -> "yes"
systemd-analyze cat-config systemd/sleep.conf
systemd-analyze cat-config systemd/logind.conf
```

---

## What you get, day to day

- Lid closed, undocked, on battery → s2idle for 2 h (instant resume), then hibernate
- Lid closed **with an external monitor** → stays awake (clamshell, intended)
- On AC → suspends, never hibernates
- Waking → **power button or lid only**; keyboard and touchpad won't
- Unplugging the charger no longer wakes it

---

## Portability

**Framework 13 / 16, other AMD models.** Part 1 is generic — `PNP0C0C` and
`PNP0C0D` are standard ACPI IDs, and nothing else is hardcoded. Parts 2–4 are
generic too. Only `suspend-report`'s battery model needs changing.

**Intel Framework laptops.** The wake-source and hibernation halves apply
unchanged. The s0i3 discussion is AMD-specific — Intel modern-standby machines
have equivalent counters in different places, and `amd_pmc` messages won't
appear. `suspend-report`'s residency section reads
`/sys/power/suspend_stats/last_hw_sleep`, which is generic, so it should still
work.

**If you have S3** (`cat /sys/power/mem_sleep` shows `deep`), you have much
less to gain. Part 1 is still worth doing; Parts 2–4 are optional.

**Non-Ubuntu distros.** Skip `10-enable-hibernate.rules` — it exists purely to
override `/usr/share/polkit-1/rules.d/com.ubuntu.desktop.rules`. Check whether
your `update-initramfs` is dracut or initramfs-tools before assuming the
two-rebuild dance applies. Everything else is plain systemd.

**Encrypted or exotic storage.** `setup-hibernate.sh` deliberately **refuses**
LUKS, LVM and RAID — the initramfs may not have that storage available at
resume time. It also requires ext4 with block size == page size. Hibernating
from LUKS is possible but it is a different, harder problem than this script
solves.

---

## Troubleshooting

**It wakes on its own again**
```sh
journalctl -b | grep "Triggering wakeup"   # any IRQ other than 9 = a leaked source
systemctl status framework-wakeup-policy.service
sudo /usr/local/sbin/framework-wakeup-policy
```
IRQ 9 is the shared ACPI SCI — that's the lid or the power button, and it's
expected. Any other IRQ means something got past the policy.

**Battery still drains while "asleep"**
```sh
suspend-report                              # residency well below 95% is the tell
journalctl -b | grep "deepest state"
```

**Hibernate stopped working after I touched the swapfile**

Re-run `setup-hibernate.sh`. This is the swapfile approach's one real weakness:
`resume_offset` is a *physical block offset* baked into the kernel command line.
Recreate, resize or restore the swapfile from a backup and the offset changes —
after which **hibernate still succeeds and resume silently fails, losing your
session.** Guard against it:

```sh
grep -o 'resume_offset=[0-9]*' /proc/cmdline
sudo filefrag -b4096 -v /swap.img | head -4     # first extent must match
```

**This section does not apply to `--partition`.** A swap partition is located by
UUID with no offset, so there is nothing to go stale and nothing to re-run. If
you keep hitting this, that's the argument for switching.

Also: **exclude `/swap.img` from backups** (Déjà Dup, Timeshift, rsync).

**Can't wake by typing**

Working as configured. To re-arm just the keyboard:
```sh
echo enabled | sudo tee /sys/devices/platform/i8042/serio0/power/wakeup
```
…and add an exception to `framework-wakeup-policy` to make it stick, or the
pre-sleep hook will disarm it again.

**Lid does nothing**

Two possible causes, both usually intentional: an external monitor is attached
(clamshell mode), or logind's `HoldoffTimeoutSec=30s` is in effect — it ignores
lid events for 30 s after any resume. Check with `systemd-inhibit --list`.

**WiFi takes ages after hibernate**

Expected. The MT7922 fails `pci_pm_restore` and does a full firmware reload:
~18 s, versus ~3 s from s2idle. Not a fault, but worth knowing before you walk
into a meeting.

More diagnostics — and the reasoning behind all of it — in
[framework13-suspend-hibernate.md](framework13-suspend-hibernate.md).

---

## Uninstalling

```sh
# Wake-source policy
sudo systemctl disable --now framework-wakeup-policy.service
sudo rm /etc/systemd/system/framework-wakeup-policy.service \
        /etc/systemd/system-sleep/framework-wakeup-policy \
        /usr/local/sbin/framework-wakeup-policy
sudo systemctl daemon-reload

# suspend-then-hibernate (keeping plain suspend)
sudo rm /etc/systemd/logind.conf.d/10-lid-sleep.conf \
        /etc/systemd/sleep.conf.d/10-hibernate-delay.conf
sudo systemctl restart systemd-logind

# Hibernation entirely
sudo rm /etc/polkit-1/rules.d/10-enable-hibernate.rules
sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub   # setup-hibernate.sh left this
sudo cp /etc/fstab.bak.<timestamp> /etc/fstab                 # --partition mode only
sudo update-initramfs -u -k all && sudo update-grub
```

Wake sources return to kernel defaults on the next reboot.

---

## Caveats

- **Sample size of one.** These numbers come from a single machine over a few
  days. suspend-then-hibernate has run **6 cycles, 5 of which hibernated**; the
  single failure was the very first one and was never explained. Cycles 1–5 were
  short bench tests, cycle 6 a real overnight run (2 h suspended, then 11 h 44 min
  hibernated, session restored intact).
- **A hibernate that *fails* is handled; one that never *starts* is not.** If
  systemd attempts hibernation and it fails — image won't fit, resume device
  missing — it logs `Couldn't hibernate, will try to suspend again` and
  re-suspends (`suspend-after-failed-hibernate`, documented in
  `man 8 systemd-sleep`). You land on plain s2idle, not a machine awake in your
  bag. The unexplained cycle-1 failure was different: it never logged
  `Attempting to hibernate` at all, so the loop simply exited and the machine
  stayed awake. With the lid already shut, no new lid event arrives and the only
  backstop is GNOME's 30-minute inactivity timeout. That's the failure mode to
  know about; it hasn't recurred in five subsequent cycles.
- **`/` needs room.** A 32 GB swapfile left ~22 GB free on a 95 GB root
  partition here. Keep an eye on snaps and `/var`.
- Machine-specific UUIDs in the documentation are placeholders
  (`<your-root-uuid>`); the setup script discovers the real values at runtime.

## License

MIT — see [LICENSE](LICENSE).
