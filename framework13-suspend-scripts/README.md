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
| `suspend-report` | `~/.local/bin/` (0755) |
| `setup-hibernate.sh` | run once with sudo; not installed |

## Reinstall from scratch

```sh
D=~/Documents/framework13-suspend-scripts

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

# 5. health check
install -m 0755 "$D/suspend-report" ~/.local/bin/suspend-report
suspend-report
```

## The one that bites

**Re-run `setup-hibernate.sh` if `/swap.img` is ever recreated, resized, or
restored from a backup.** The physical offset changes; a stale `resume_offset`
means hibernate succeeds and resume silently fails, losing the session.
