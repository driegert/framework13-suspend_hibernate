#!/bin/bash
# Enable hibernation on tinkertoy (Framework 13 AMD, Ubuntu 26.04).
#
# RE-RUN THIS if the swapfile is ever recreated, resized, or restored from a
# backup -- the physical offset changes, and a stale resume_offset means
# hibernate SUCCEEDS and resume SILENTLY FAILS, losing the session.
#
# Grows /swap.img to 32 GB on the ROOT partition and configures resume. The
# path is unchanged, so /etc/fstab is NOT touched.
#
# Why root and not /home, despite /home having far more space:
#   systemd-logind runs with ProtectHome=yes, so it cannot stat() a swapfile
#   under /home and may refuse hibernation entirely. See systemd issue #15354.
#
# Ordering is deliberate: the new swapfile is fully built BEFORE the old one is
# torn down, so a failure at any point leaves a bootable machine with working
# swap. The window with no swap is a single rm+mv.
#
# Reboot required afterwards: resume= is only read at boot. Then rebuild the
# initramfs AGAIN (dracut's resume module is only included once /proc/cmdline
# already contains resume=), and verify /sys/power/resume reads 259:3 not 0:0.

set -euo pipefail

SWAPFILE=/swap.img
TMPSWAP=/swap.img.new
SWAP_GB=32
GRUB_CFG=/etc/default/grub

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

STAGE=start
trap 'rc=$?; [ $rc -ne 0 ] && { echo; echo "FAILED during stage: $STAGE (exit $rc)"; echo "Active swap right now:"; swapon --show || echo "  NONE"; echo "If no swap is listed, run: swapon $SWAPFILE   (or reboot)"; }' EXIT

# ---- preconditions ---------------------------------------------------------

STAGE=preconditions
SWAPDIR=$(dirname "$SWAPFILE")
FS_DEV=$(findmnt -no SOURCE --target "$SWAPDIR")
FS_UUID=$(findmnt -no UUID   --target "$SWAPDIR")
FS_TYPE=$(findmnt -no FSTYPE --target "$SWAPDIR")
FS_MNT=$(findmnt -no TARGET  --target "$SWAPDIR")
PAGESIZE=$(getconf PAGESIZE)

[ "$FS_TYPE" = "ext4" ] || die "$FS_MNT is $FS_TYPE, not ext4 -- offsets differ"
[ -n "$FS_UUID" ]       || die "could not determine UUID of $FS_MNT"

# Stacked storage (LVM/LUKS/RAID) may not be available to the initramfs at
# resume time. Plain partitions only.
DEV_TYPE=$(lsblk -no TYPE "$FS_DEV" | head -1 | tr -d ' ')
case "$DEV_TYPE" in
    part|disk) ;;
    *) die "$FS_DEV is type '$DEV_TYPE', not a plain partition -- resume may not find it" ;;
esac

BLKSIZE=$(tune2fs -l "$FS_DEV" | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')
[ "$BLKSIZE" = "$PAGESIZE" ] || die "ext4 block size ($BLKSIZE) != page size ($PAGESIZE); resume_offset would be wrong"

# Both files exist simultaneously, so we need the FULL new size free.
AVAIL_MB=$(df --output=avail -BM "$SWAPDIR" | tail -1 | tr -dc '0-9')
NEED_MB=$(( SWAP_GB * 1024 + 1024 ))
[ "$AVAIL_MB" -ge "$NEED_MB" ] || die "need ~${NEED_MB} MB free on $FS_MNT, have ${AVAIL_MB} MB"

# Refuse to destroy anything we cannot prove is a swapfile.
if [ -e "$SWAPFILE" ]; then
    if ! swapon --show=NAME --noheadings | grep -qxF "$SWAPFILE"; then
        case "$(file -b "$SWAPFILE" 2>/dev/null)" in
            *swap*) ;;
            *) die "$SWAPFILE exists but is neither active swap nor a swap file -- refusing to delete it" ;;
        esac
    fi
fi
[ -e "$TMPSWAP" ] && die "$TMPSWAP already exists -- remove it by hand first"

echo "swapfile:   $SWAPFILE  ->  ${SWAP_GB} GB"
echo "  filesystem: $FS_DEV  $FS_TYPE  at $FS_MNT  ($DEV_TYPE)"
echo "  UUID:       $FS_UUID"
echo "  blocksize:  $BLKSIZE == pagesize $PAGESIZE  OK"
echo "  free:       ${AVAIL_MB} MB (need ${NEED_MB} MB)"
echo "  fstab:      unchanged (path is the same)"

# ---- 1. build the replacement BEFORE touching the old one ------------------

STAGE="creating $TMPSWAP"
say "creating $TMPSWAP at ${SWAP_GB} GB (old swap still active)"
# dd, not fallocate: fully written extents, no unwritten-extent ambiguity.
dd if=/dev/zero of="$TMPSWAP" bs=1M count=$((SWAP_GB * 1024)) status=progress
chmod 600 "$TMPSWAP"
chown root:root "$TMPSWAP"
mkswap "$TMPSWAP" >/dev/null
sync

# ---- 2. swap over ----------------------------------------------------------

STAGE="switching swap"
say "switching to the new swapfile"
if swapon --show=NAME --noheadings | grep -qxF "$SWAPFILE"; then
    swapoff "$SWAPFILE" || die "swapoff $SWAPFILE failed -- refusing to continue"
fi
rm -f "$SWAPFILE"
mv "$TMPSWAP" "$SWAPFILE"     # same fs: inode and extents unchanged
swapon "$SWAPFILE" || die "swapon $SWAPFILE failed"
sync
swapon --show

# ---- 3. offset, computed on the FINAL file at its FINAL path ---------------

STAGE="computing resume_offset"
say "computing resume_offset"
# -b4096 pins the reporting unit to the page size.
OFFSET=$(filefrag -b4096 -v "$SWAPFILE" | awk '/^[[:space:]]*0:/{print $4; exit}' | tr -cd '0-9')
case "${OFFSET:-}" in
    ''|*[!0-9]*) die "could not parse swapfile offset from filefrag" ;;
esac
[ "$OFFSET" -gt 0 ] || die "implausible offset '$OFFSET'"
echo "  resume=UUID=$FS_UUID"
echo "  resume_offset=$OFFSET"

# ---- 4. kernel cmdline -----------------------------------------------------

STAGE="editing $GRUB_CFG"
say "updating $GRUB_CFG"
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"$' "$GRUB_CFG" \
    || die "GRUB_CMDLINE_LINUX_DEFAULT is not a simple double-quoted assignment; edit by hand"
[ "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG")" -eq 1 ] \
    || die "expected exactly one GRUB_CMDLINE_LINUX_DEFAULT assignment"

GRUB_BAK="${GRUB_CFG}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$GRUB_CFG" "$GRUB_BAK"
CUR=$(awk -F'"' '/^GRUB_CMDLINE_LINUX_DEFAULT=/{print $2}' "$GRUB_CFG")
case "$CUR" in
    *['\\&|']*) die "existing cmdline contains characters unsafe for this edit: $CUR" ;;
esac
CLEAN=$(echo "$CUR" | sed -E 's/(^| )resume(_offset)?=[^ ]*//g; s/  +/ /g; s/^ | $//g')
NEW=$(echo "$CLEAN resume=UUID=$FS_UUID resume_offset=$OFFSET" | sed -E 's/^ | $//g')
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" "$GRUB_CFG"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"
grep -q "resume_offset=$OFFSET" "$GRUB_CFG" || die "cmdline edit did not take; restore $GRUB_BAK"

# NOTE: update-initramfs on this system is a DRACUT shim, so
# /etc/initramfs-tools/conf.d/resume is INERT and deliberately not written.
# dracut's 74resume module reads resume= from the kernel cmdline instead --
# which is why the initramfs must be rebuilt again AFTER the first reboot.

# ---- 5. regenerate ---------------------------------------------------------

STAGE="update-initramfs"
say "regenerating initramfs"
update-initramfs -u -k all || die "update-initramfs failed -- restore $GRUB_BAK and do not reboot"

STAGE="update-grub"
say "regenerating grub"
update-grub || die "update-grub failed -- restore $GRUB_BAK and do not reboot"

STAGE=done
say "done"
cat <<EOF

  swap:        $(swapon --show=SIZE --noheadings | head -1) at $SWAPFILE
  / free:      $(df -h --output=avail / | tail -1 | tr -d ' ')
  resume:      UUID=$FS_UUID  offset=$OFFSET
  grub backup: $GRUB_BAK

NEXT STEPS (in order -- the second one is easy to miss):

  1. sudo reboot

  2. sudo update-initramfs -u -k all
     Dracut only includes its resume module once /proc/cmdline already contains
     resume=, which it did not when this script ran. Verify:
       sudo lsinitrd /boot/initrd.img-\$(uname -r) | grep -i hibernate-resume

  3. sudo reboot   (again)

  4. cat /sys/power/resume        # MUST read 259:3, not 0:0
     busctl call org.freedesktop.login1 /org/freedesktop/login1 \\
         org.freedesktop.login1.Manager CanHibernate

     "no" = polkit denial -> install 10-enable-hibernate.rules
     "na" = genuinely unsupported

  5. Test with a SCRATCH editor open, not real work:
       systemctl hibernate
     Machine should power off COMPLETELY, and pressing power should restore the
     session. Confirm with: journalctl --list-boots | tail -2
     A successful resume keeps the SAME boot ID.

To undo:
    sudo cp $GRUB_BAK $GRUB_CFG
    sudo update-initramfs -u -k all && sudo update-grub
EOF
