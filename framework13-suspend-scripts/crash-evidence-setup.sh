#!/bin/bash
# Make a kernel panic leave evidence on tinkertoy.
#
# Two independent changes, either of which alone is useful:
#
# 1. crash_kexec_post_notifiers=1 on the MAIN kernel cmdline.
#    With kdump armed, panic() jumps to the capture kernel BEFORE running
#    kmsg_dump(), so pstore never records the real panic. Proven here: on
#    2026-08-24 the capture kernel found /sys/fs/pstore EMPTY after the
#    hibernation panic, then wrote its OWN panic there minutes later. This flag
#    flips the order -- kmsg_dump() (and therefore efi_pstore) runs first, so
#    the panic dmesg survives whether or not the capture kernel makes it.
#
# 2. module_blacklist=... on the CAPTURE kernel cmdline.
#    The capture kernel needs nvme + ext4 and nothing else, but it re-probes
#    everything and has died twice doing so:
#      2026-08-24  acp63_irq_handler+0x44 [snd_pci_ps]  NULL deref at [10.29s]
#                  (reached via irqpoll's try_one_irq/note_interrupt polling)
#      2026-08-25  iwlwifi microcode error -> RIP: 0x0 -> Fatal exception [32.12s]
#    Blacklisting audio/wifi/gpu/thunderbolt removes both handlers.
#
# See "Part 8" in framework13-suspend-hibernate.md.
set -euo pipefail

STAMP=$(date +%Y%m%d%H%M%S)
GRUB=/etc/default/grub
KDUMP=/etc/default/kdump-tools
FLAG="crash_kexec_post_notifiers=1"
BLACKLIST="module_blacklist=snd_pci_ps,snd_pci_acp6x,snd_pci_acp5x,snd_pci_acp3x,snd_rn_pci_acp3x,snd_acp_pci,snd_acp_config,snd_acp_legacy_common,iwlwifi,amdgpu,thunderbolt"
KDUMP_BASE="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 irqpoll usbcore.nousb noresume"

echo "=============================================================="
echo "1/4  $FLAG -> $GRUB"
echo "=============================================================="
if grep -q "crash_kexec_post_notifiers" "$GRUB"; then
    echo "  already present, leaving alone:"
    grep -n crash_kexec_post_notifiers "$GRUB" | sed 's/^/    /'
else
    cp -a "$GRUB" "$GRUB.bak.$STAMP"
    echo "  backup: $GRUB.bak.$STAMP"
    python3 - "$GRUB" "$FLAG" <<'PY'
import sys, re
path, flag = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"$', s, re.M)
if not m:
    sys.exit("could not find GRUB_CMDLINE_LINUX_DEFAULT")
new = (m.group(1) + " " + flag).strip()
s = s[:m.start(1)] + new + s[m.end(1):]
open(path, 'w').write(s)
print("    now: " + new)
PY
fi

echo
echo "=============================================================="
echo "2/4  module blacklist -> $KDUMP"
echo "=============================================================="
if grep -q '^KDUMP_CMDLINE_APPEND=.*module_blacklist' "$KDUMP"; then
    echo "  already present, leaving alone."
else
    cp -a "$KDUMP" "$KDUMP.bak-$STAMP"
    echo "  backup: $KDUMP.bak-$STAMP"
    python3 - "$KDUMP" "$KDUMP_BASE $BLACKLIST" <<'PY'
import sys, re
path, want = sys.argv[1], sys.argv[2]
s = open(path).read()
line = 'KDUMP_CMDLINE_APPEND="%s"' % want
if re.search(r'^KDUMP_CMDLINE_APPEND=.*$', s, re.M):
    s = re.sub(r'^KDUMP_CMDLINE_APPEND=.*$', line, s, count=1, flags=re.M)
else:
    sys.exit("no active KDUMP_CMDLINE_APPEND to replace")
open(path, 'w').write(s)
PY
    grep -n '^KDUMP_CMDLINE_APPEND=' "$KDUMP" | fold -w 100 | sed 's/^/    /'
fi

echo
echo "=============================================================="
echo "3/4  arm it NOW (no reboot needed for the pstore ordering)"
echo "=============================================================="
echo Y > /sys/module/kernel/parameters/crash_kexec_post_notifiers
echo "  /sys/module/kernel/parameters/crash_kexec_post_notifiers = $(cat /sys/module/kernel/parameters/crash_kexec_post_notifiers)"

echo
echo "=============================================================="
echo "4/4  regenerate grub + reload kdump, then verify"
echo "=============================================================="
update-grub 2>&1 | sed 's/^/    /'
kdump-config unload >/dev/null 2>&1 || true
kdump-config load  2>&1 | sed 's/^/    /'

echo
echo "--- VERIFY ---"
fail=0
grep -q "$FLAG" /boot/grub/grub.cfg \
    && echo "PASS  grub.cfg carries $FLAG" \
    || { echo "FAIL  $FLAG missing from grub.cfg"; fail=1; }
[ "$(cat /sys/module/kernel/parameters/crash_kexec_post_notifiers)" = "Y" ] \
    && echo "PASS  runtime toggle armed (Y) -- active for THIS boot already" \
    || { echo "FAIL  runtime toggle not armed"; fail=1; }
grep -q 'module_blacklist=' /var/crash/kexec_cmd \
    && echo "PASS  capture cmdline carries module_blacklist" \
    || { echo "FAIL  module_blacklist missing from kexec_cmd"; fail=1; }
for opt in reset_devices "systemd.unit=kdump-tools-dump.service" nr_cpus=1 irqpoll usbcore.nousb noresume; do
    grep -q -- "$opt" /var/crash/kexec_cmd \
        && echo "PASS  capture cmdline retains $opt" \
        || { echo "FAIL  capture cmdline LOST $opt"; fail=1; }
done
kdump-config status 2>&1 | sed 's/^/      /'
echo
echo "--- capture cmdline now ---"
tr ' ' '\n' < /var/crash/kexec_cmd | grep -E 'blacklist|noresume|irqpoll|nr_cpus|reset_devices|usbcore|systemd.unit' | sed 's/^/      /'
echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOMETHING FAILED -- backups are $GRUB.bak.$STAMP and $KDUMP.bak-$STAMP"; exit 1; }
echo
echo "The pstore ordering fix is ACTIVE NOW (runtime toggle)."
echo "The blacklist applies to the already-reloaded capture kernel, also now."
echo "The GRUB line only matters for surviving a reboot."
