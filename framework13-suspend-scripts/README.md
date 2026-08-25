# framework13-suspend-scripts

Source copies of everything installed on **tinkertoy** for suspend/hibernate.
Full explanation lives in `../framework13-suspend-hibernate.md`.

`framework-wakeup-policy*`, `10-hibernate-delay.conf` and `10-lid-sleep.conf`
were copied back from the live system, so they are the real running versions.
`setup-hibernate.sh` and `10-enable-hibernate.rules` are faithful reproductions
(the polkit directory is mode 0700, so the installed copy can't be read back
without root — diff them if you want to be sure).

| File | Installs to |
|---|---|
| `framework-wakeup-policy` | `/usr/local/sbin/framework-wakeup-policy` (0755) |
| `framework-wakeup-policy.service` | `/etc/systemd/system/` (0644) |
| `framework-wakeup-policy.sleep` | `/etc/systemd/system-sleep/framework-wakeup-policy` (0755) |
| `10-enable-hibernate.rules` | `/etc/polkit-1/rules.d/` (0644) |
| `10-hibernate-delay.conf` | `/etc/systemd/sleep.conf.d/` (0644) |
| `10-lid-sleep.conf` | `/etc/systemd/logind.conf.d/` (0644) |
| `10-hibernate-reserve.conf` | `/etc/UPower/UPower.conf.d/` (0644) |
| `stale-kernel-lid-guard` | `/usr/local/sbin/` (0755) |
| `stale-kernel-lid-guard.service` | `/etc/systemd/system/` (0644) |
| `zzz-stale-kernel-lid-guard` | `/etc/kernel/postinst.d/` (0755) |
| `suspend-report` | `~/.local/bin/` (0755) |
| `crash-evidence-setup.sh` | run once with sudo; not installed. Edits `/etc/default/grub` + `/etc/default/kdump-tools`. |
| `kdump-noresume.sh` | **superseded** by the above; kept for reference |
| `setup-hibernate.sh` | run once with sudo; not installed |

## Reinstall from scratch

```sh
cd framework13-suspend-scripts     # from the repo root
D=$PWD

# 1. wake-source policy
sudo install -m 0755 "$D/framework-wakeup-policy"          /usr/local/sbin/framework-wakeup-policy
sudo install -D -m 0644 "$D/framework-wakeup-policy.service" /etc/systemd/system/framework-wakeup-policy.service
sudo install -D -m 0755 "$D/framework-wakeup-policy.sleep" /etc/systemd/system-sleep/framework-wakeup-policy
sudo systemctl daemon-reload
sudo systemctl enable --now framework-wakeup-policy.service

# 2. hibernation (reboot + second initramfs rebuild required -- read the script's output)
sudo "$D/setup-hibernate.sh"

# 3. unblock Ubuntu's polkit denial
sudo install -D -m 0644 "$D/10-enable-hibernate.rules" /etc/polkit-1/rules.d/10-enable-hibernate.rules
sudo systemctl restart polkit

# 4. suspend-then-hibernate  (only after `systemctl hibernate` is proven to work)
sudo install -D -m 0644 "$D/10-hibernate-delay.conf" /etc/systemd/sleep.conf.d/10-hibernate-delay.conf
sudo install -D -m 0644 "$D/10-lid-sleep.conf"       /etc/systemd/logind.conf.d/10-lid-sleep.conf
sudo reboot

# 5. raise the emergency-hibernate battery floor from 2% to 7%
#    (filename must match ^[0-9][0-9]-[a-zA-Z0-9_-]*\.conf$ or it is silently ignored)
sudo install -D -m 0644 "$D/10-hibernate-reserve.conf" /etc/UPower/UPower.conf.d/10-hibernate-reserve.conf
sudo systemctl restart upower

# 6. stale-kernel lid guard -- stops a lid close from hibernating into an
#    image the next boot cannot restore (see Part 7 of the write-up)
sudo install -m 0755 "$D/stale-kernel-lid-guard"            /usr/local/sbin/stale-kernel-lid-guard
sudo install -D -m 0644 "$D/stale-kernel-lid-guard.service" /etc/systemd/system/stale-kernel-lid-guard.service
sudo install -D -m 0755 "$D/zzz-stale-kernel-lid-guard"     /etc/kernel/postinst.d/zzz-stale-kernel-lid-guard
sudo systemctl daemon-reload
sudo systemctl enable --now stale-kernel-lid-guard.service
sudo /usr/local/sbin/stale-kernel-lid-guard --self-test    # must print PASS

# 7. make a panic leave evidence: pstore-before-kexec ordering, plus keeping the
#    capture kernel away from the drivers that have twice panicked it (Part 8)
sudo "$D/crash-evidence-setup.sh"    # idempotent; verifies everything it changes

# 8. health check
install -m 0755 "$D/suspend-report" ~/.local/bin/suspend-report
suspend-report
```

## The ones that bite

**Re-run `setup-hibernate.sh` if `/swap.img` is ever recreated, resized, or
restored from a backup.** The physical offset changes; a stale `resume_offset`
means hibernate succeeds and resume silently fails, losing the session.

This applies to **swapfile mode only** — `--partition` has no offset, which is
the main reason to prefer it. Note that a *stale offset* is not the only way to
get a silently lost session: an image write that doesn't complete leaves the
same `PM: Image not found (code -22)` on the next boot, because swsusp writes
the header signature last. See "A lost session, diagnosed" in
`../framework13-suspend-hibernate.md`.

**Reboot after a kernel upgrade before you close the lid.** A hibernation image
is stamped with the kernel that wrote it and no other kernel will restore it,
while GRUB boots the newest installed kernel — so between `apt` landing a kernel
and your next reboot, hibernating loses the session. `stale-kernel-lid-guard`
now makes that safe by forcing plain suspend in that window, but it is only
installed if you ran step 6 above. Check with:

```sh
stale-kernel-lid-guard --status
```

See "The kernel-upgrade trap" in `../framework13-suspend-hibernate.md`.

**Check `/var/lib/systemd/pstore/`, never `/sys/fs/pstore`.** The latter is
root-only; `ls` prints *permission denied* and nothing else, which reads exactly
like "no crash records". The archived copies with reassembled `dmesg.txt` files
are what you want. And a record whose kernel uptime is *seconds* was written by
the kdump capture kernel, not by the kernel you care about.

**`crash_kexec_post_notifiers` must be `Y`.** With kdump armed, `panic()` jumps
to the capture kernel before `kmsg_dump()` runs, so pstore records nothing —
enabling kdump is a net loss until this is set.

```sh
cat /sys/module/kernel/parameters/crash_kexec_post_notifiers
```

**`KDUMP_CMDLINE_APPEND` replaces the packaged default — it does not extend it.**
Setting it to just `"noresume"` silently drops
`systemd.unit=kdump-tools-dump.service` and kdump stops capturing entirely, while
`kdump-config status` still reports *ready to kdump*. `crash-evidence-setup.sh` repeats
all five defaults and then checks each one survived. Verify against the built
command line, never the config file:

```sh
grep noresume /var/crash/kexec_cmd
```

`/etc/default/kdump-tools` is a packaged conffile, so a `kdump-tools` upgrade may
offer to replace it — re-check after one. Note that crash capture here has
**never yet produced a vmcore**: the capture kernel panicked on its own device
probing on both 2026-08-24 (`snd_pci_ps`) and 2026-08-25 (`iwlwifi`). The
blacklist targets exactly those; a third driver may still be waiting. Proving it
means `echo c | sudo tee /proc/sysrq-trigger`, which hard-crashes the machine,
then checking **both** `/var/crash` and `/var/lib/systemd/pstore/`.

See "A panic during hibernation, and no vmcore" in
`../framework13-suspend-hibernate.md`.
