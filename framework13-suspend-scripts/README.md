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

# 7. health check
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
