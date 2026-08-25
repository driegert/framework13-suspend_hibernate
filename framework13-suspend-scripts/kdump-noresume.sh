#!/bin/bash
# Add `noresume` to the kdump capture kernel's command line.
#
# SUPERSEDED by crash-evidence-setup.sh, which sets this AND the two changes that
# actually matter. `noresume` is correct and harmless but was NOT what was
# breaking crash capture -- a deliberate sysrq crash on 2026-08-25 reproduced the
# failure with noresume in place. Kept for reference; run the other script.
#
# Why: kdump-config builds the capture cmdline from /proc/cmdline, stripping only
# crashkernel/hugepages/hugepagesz/abm (kdump-config:732). `resume=UUID=...` is
# therefore inherited, so on a hibernation-configured machine the crash-capture
# kernel is aimed at the swap device -- and if the panic happened DURING
# hibernation, at a half-written image. On tinkertoy (2026-08-24) it ran
# systemd-hibernate-resume against that image and cleared the HibernateLocation
# EFI variable instead of ever reaching kdump-tools-dump.service, so no vmcore
# was produced. `noresume` is honoured both by the kernel (software_resume()
# bails early) and by systemd-hibernate-resume-generator, regardless of the
# order of arguments on the line.
#
# See "Part 8 -- A panic during hibernation, and no vmcore" in
# ../framework13-suspend-hibernate.md.
#
# Idempotent: refuses to run if KDUMP_CMDLINE_APPEND is already set.
# Verifies against /var/crash/kexec_cmd, which is the only thing that matters.
#
# NOTE: KDUMP_CMDLINE_APPEND REPLACES the built-in default (kdump-config:60),
# so all five default options are repeated verbatim below.
set -euo pipefail

CONF=/etc/default/kdump-tools
WANT='KDUMP_CMDLINE_APPEND="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 irqpoll usbcore.nousb noresume"'

if grep -q '^KDUMP_CMDLINE_APPEND=' "$CONF"; then
    echo "!! $CONF already sets KDUMP_CMDLINE_APPEND -- not touching it:"
    grep -n '^KDUMP_CMDLINE_APPEND=' "$CONF"
    exit 1
fi

BACKUP="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BACKUP"
echo "backup: $BACKUP"

# Insert the active setting right after the commented-out reference line.
awk -v want="$WANT" '
  { print }
  /^#KDUMP_CMDLINE_APPEND=/ && !done {
      print ""
      print "# Added 2026-08-24 after an unexplained kernel panic during hibernation"
      print "# produced no vmcore: the capture kernel inherited resume=UUID=... and walked"
      print "# the hibernation-resume path instead of running kdump-tools-dump.service."
      print "# This variable REPLACES the default above, so the defaults are repeated here."
      print want
      done = 1
  }
' "$CONF" > "$CONF.new"

mv "$CONF.new" "$CONF"
chmod --reference="$BACKUP" "$CONF"

echo "--- new setting:"
grep -n '^KDUMP_CMDLINE_APPEND=' "$CONF"

echo "--- reloading kdump (unload + load):"
kdump-config unload || true
kdump-config load

echo "--- resulting kexec_cmd:"
cat /var/crash/kexec_cmd
echo
if grep -q 'noresume' /var/crash/kexec_cmd; then
    echo "PASS: noresume present in capture cmdline"
else
    echo "FAIL: noresume NOT present -- restore with: cp -a $BACKUP $CONF"
    exit 1
fi
for opt in reset_devices "systemd.unit=kdump-tools-dump.service" nr_cpus=1 irqpoll usbcore.nousb; do
    grep -q -- "$opt" /var/crash/kexec_cmd \
        && echo "PASS: $opt retained" \
        || { echo "FAIL: $opt LOST -- restore with: cp -a $BACKUP $CONF"; exit 1; }
done
echo
echo "kdump loaded:"; kdump-config status || true
