#!/bin/bash
# Enable hibernation on tinkertoy (Framework 13 AMD, Ubuntu 26.04).
#
# Two paths, because there are two ways to hold a hibernation image:
#
#   --file       (default) a swapfile on the root filesystem.
#                Needs no repartitioning, but the kernel cmdline carries a
#                resume_offset -- a PHYSICAL BLOCK OFFSET that is invalidated
#                if the file is ever recreated, resized or restored from a
#                backup. When that happens hibernate SUCCEEDS and resume
#                SILENTLY FAILS, losing the session. RE-RUN THIS SCRIPT if you
#                ever touch the swapfile.
#
#   --partition  a dedicated swap partition.
#                Needs unallocated space (usually a live-USB shrink of an
#                existing filesystem), but resume is located purely by UUID.
#                There is no offset, so there is nothing to drift and nothing
#                to re-run. If you have the space, this is the durable choice.
#
# Both paths end the same way: resume= on the kernel cmdline, a rebuilt
# initramfs, and the two-reboot dracut dance described at the end.
#
# Why the swapfile goes on / and not /home, despite /home having far more room:
#   systemd-logind runs with ProtectHome=yes, so it cannot stat() a swapfile
#   under /home and may refuse hibernation entirely. See systemd issue #15354.
#   (This constraint does not apply to --partition: a partition is not under
#   /home, so it sidesteps the problem completely.)
#
# Ordering is deliberate in both modes: the new swap is fully established
# BEFORE the old one is torn down, so a failure at any point leaves a bootable
# machine with working swap.

set -euo pipefail

MODE=file
SWAP_DEV=
SWAPFILE=/swap.img
TMPSWAP=/swap.img.new
SWAP_GB=32
GRUB_CFG=/etc/default/grub
ASSUME_YES=0
FORCE=0

usage() {
    cat <<'EOF'
Usage:
  setup-hibernate.sh [--file] [--size GB]      Swapfile on / (default)
  setup-hibernate.sh --partition /dev/sdXN     Dedicated swap partition
  setup-hibernate.sh --help

Options:
  --file              Swapfile mode (default). Rebuilds SWAPFILE at --size.
  --size GB           Swapfile size in GiB (default 32). Swapfile mode only.
  --partition DEV     Swap partition mode. DEV is ERASED with mkswap.
  --yes               Skip the interactive confirmation (partition mode).
  --force             Allow --partition to erase a device that currently holds
                      a filesystem. Refused without this.
  --help              This text.

Sizing: swap does not need to equal RAM -- it needs to hold the image of what
is actually in use. But images from a freshly-booted machine are badly
unrepresentative; size for a heavy day. Swap >= RAM makes it unfailable.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --file)      MODE=file ;;
        --partition) MODE=part; SWAP_DEV="${2:-}"; shift ;;
        --size)      SWAP_GB="${2:-}"; shift ;;
        --yes)       ASSUME_YES=1 ;;
        --force)     FORCE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

STAGE=start
trap 'rc=$?; if [ $rc -ne 0 ]; then
        echo; echo "FAILED during stage: $STAGE (exit $rc)"
        echo "Active swap right now:"; swapon --show || echo "  NONE"
        echo "If no swap is listed, run: swapon --all   (or reboot)"
      fi' EXIT

MEM_BYTES=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo)

# RESUME_UUID / RESUME_OFFSET are what the two modes must produce between them.
RESUME_UUID=
RESUME_OFFSET=

# ============================================================================
# MODE: swap partition
# ============================================================================
if [ "$MODE" = part ]; then

STAGE="validating $SWAP_DEV"
[ -n "$SWAP_DEV" ]  || die "--partition needs a device, e.g. /dev/nvme0n1p5"
[ -b "$SWAP_DEV" ]  || die "$SWAP_DEV is not a block device"

# Refuse whole disks outright -- the single most destructive typo available.
DEV_TYPE=$(lsblk -dno TYPE "$SWAP_DEV" | head -1 | tr -d ' ')
[ "$DEV_TYPE" = "part" ] \
    || die "$SWAP_DEV is type '$DEV_TYPE', not a partition -- refusing"

# Refuse anything currently mounted, or backing a filesystem we care about.
if findmnt -rno TARGET --source "$SWAP_DEV" >/dev/null 2>&1; then
    die "$SWAP_DEV is mounted at $(findmnt -rno TARGET --source "$SWAP_DEV" | tr '\n' ' ')-- refusing"
fi
for m in / /home /boot /boot/efi; do
    src=$(findmnt -no SOURCE --target "$m" 2>/dev/null || true)
    [ "$src" = "$SWAP_DEV" ] && die "$SWAP_DEV currently backs $m -- refusing"
done

# Refuse to destroy a filesystem without an explicit --force.
EXIST_TYPE=$(blkid -o value -s TYPE "$SWAP_DEV" 2>/dev/null || true)
case "${EXIST_TYPE:-}" in
    ""|swap) ;;
    *) [ "$FORCE" -eq 1 ] \
         || die "$SWAP_DEV holds a '$EXIST_TYPE' filesystem. Refusing without --force." ;;
esac

DEV_BYTES=$(blockdev --getsize64 "$SWAP_DEV")
say "swap partition: $SWAP_DEV"
echo "  size:       $(numfmt --to=iec "$DEV_BYTES")  ($DEV_BYTES bytes)"
echo "  RAM:        $(numfmt --to=iec "$MEM_BYTES")"
echo "  current:    ${EXIST_TYPE:-empty}"
echo "  fstab:      a UUID= swap entry will be added; existing swap entries commented out"
if [ "$DEV_BYTES" -lt "$MEM_BYTES" ]; then
    echo
    echo "  NOTE: this partition is smaller than RAM. That is usually fine --"
    echo "  images are far smaller than RAM in practice -- but it is not a"
    echo "  guarantee. If hibernation ever cannot fit, systemd logs"
    echo "  \"Couldn't hibernate, will try to suspend again\" and falls back to"
    echo "  suspend rather than staying awake."
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    echo "  mkswap will ERASE $SWAP_DEV."
    printf '  Type YES to continue: '
    read -r ans
    [ "$ans" = "YES" ] || die "aborted at confirmation"
fi

STAGE="mkswap $SWAP_DEV"
say "formatting $SWAP_DEV as swap"
mkswap "$SWAP_DEV" >/dev/null
udevadm settle 2>/dev/null || sleep 1
RESUME_UUID=$(blkid -o value -s UUID "$SWAP_DEV")
[ -n "$RESUME_UUID" ] || die "could not read the new swap UUID from $SWAP_DEV"
echo "  UUID: $RESUME_UUID"

# Activate the NEW swap before disturbing the old, same as the file path.
STAGE="activating $SWAP_DEV"
swapon "$SWAP_DEV" || die "swapon $SWAP_DEV failed"

STAGE="editing /etc/fstab"
say "updating /etc/fstab"
FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
cp -a /etc/fstab "$FSTAB_BAK"
awk -v u="$RESUME_UUID" '
    /^[[:space:]]*#/ { print; next }
    NF >= 3 && $3 == "swap" { print "# disabled by setup-hibernate.sh: " $0; next }
    { print }
    END { printf "UUID=%s none swap sw 0 0\n", u }
' "$FSTAB_BAK" > /etc/fstab.new
mv /etc/fstab.new /etc/fstab
echo "  backup: $FSTAB_BAK"
grep -nE 'swap' /etc/fstab || true

# Deactivate the old swapfile, but deliberately DO NOT delete it. If resume
# from the new partition somehow fails, it is still there to fall back on.
if swapon --show=NAME --noheadings | grep -qxF "$SWAPFILE"; then
    STAGE="deactivating $SWAPFILE"
    swapoff "$SWAPFILE" && echo "  deactivated $SWAPFILE (file left on disk on purpose)"
fi

# ============================================================================
# MODE: swapfile
# ============================================================================
else

STAGE=preconditions
case "${SWAP_GB:-}" in
    ''|*[!0-9]*) die "--size must be a whole number of GiB" ;;
esac
[ "$SWAP_GB" -gt 0 ] || die "--size must be greater than zero"

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
if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
    echo "ERROR: need ~${NEED_MB} MB free on $FS_MNT, have ${AVAIL_MB} MB" >&2
    echo >&2
    echo "The old and new swapfiles exist at the same time, on purpose, so a" >&2
    echo "failure cannot leave you without swap. If $FS_MNT cannot hold both," >&2
    echo "a swap PARTITION is the better answer than shaving the safety margin:" >&2
    echo "  sudo $0 --partition /dev/..." >&2
    exit 1
fi

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

echo "swapfile:   $SWAPFILE  ->  ${SWAP_GB} GiB"
echo "  filesystem: $FS_DEV  $FS_TYPE  at $FS_MNT  ($DEV_TYPE)"
echo "  UUID:       $FS_UUID"
echo "  blocksize:  $BLKSIZE == pagesize $PAGESIZE  OK"
echo "  free:       ${AVAIL_MB} MB (need ${NEED_MB} MB)"
echo "  RAM:        $(numfmt --to=iec "$MEM_BYTES")"
echo "  fstab:      unchanged (path is the same)"

# ---- 1. build the replacement BEFORE touching the old one ------------------

STAGE="creating $TMPSWAP"
say "creating $TMPSWAP at ${SWAP_GB} GiB (old swap still active)"
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

RESUME_UUID="$FS_UUID"
RESUME_OFFSET="$OFFSET"

fi
# ============================================================================
# COMMON: kernel cmdline, initramfs, grub
# ============================================================================

echo "  resume=UUID=$RESUME_UUID"
[ -n "$RESUME_OFFSET" ] && echo "  resume_offset=$RESUME_OFFSET"

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
# Strips BOTH resume= and resume_offset=. Partition mode deliberately does not
# put an offset back: a stale resume_offset left over from a previous swapfile
# would point at blocks the swapfile no longer owns.
CLEAN=$(echo "$CUR" | sed -E 's/(^| )resume(_offset)?=[^ ]*//g; s/  +/ /g; s/^ | $//g')
if [ -n "$RESUME_OFFSET" ]; then
    NEW=$(echo "$CLEAN resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET" | sed -E 's/^ | $//g')
else
    NEW=$(echo "$CLEAN resume=UUID=$RESUME_UUID" | sed -E 's/^ | $//g')
fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" "$GRUB_CFG"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"
grep -q "resume=UUID=$RESUME_UUID" "$GRUB_CFG" || die "cmdline edit did not take; restore $GRUB_BAK"
if [ -z "$RESUME_OFFSET" ]; then
    grep -q 'resume_offset=' "$GRUB_CFG" \
        && die "a stale resume_offset survived the edit; restore $GRUB_BAK and fix by hand"
fi

# NOTE: update-initramfs on this system is a DRACUT shim, so
# /etc/initramfs-tools/conf.d/resume is INERT and deliberately not written.
# dracut's 74resume module reads resume= from the kernel cmdline instead --
# which is why the initramfs must be rebuilt again AFTER the first reboot.

STAGE="update-initramfs"
say "regenerating initramfs"
update-initramfs -u -k all || die "update-initramfs failed -- restore $GRUB_BAK and do not reboot"

STAGE="update-grub"
say "regenerating grub"
update-grub || die "update-grub failed -- restore $GRUB_BAK and do not reboot"

STAGE=done
say "done"

if [ "$MODE" = part ]; then
    SWAP_SUMMARY="$SWAP_DEV  ($(numfmt --to=iec "$(blockdev --getsize64 "$SWAP_DEV")"))"
    RESUME_SUMMARY="UUID=$RESUME_UUID   (no offset -- nothing to drift)"
else
    SWAP_SUMMARY="$(swapon --show=SIZE --noheadings | head -1) at $SWAPFILE"
    RESUME_SUMMARY="UUID=$RESUME_UUID  offset=$RESUME_OFFSET"
fi

cat <<EOF

  swap:        $SWAP_SUMMARY
  / free:      $(df -h --output=avail / | tail -1 | tr -d ' ')
  resume:      $RESUME_SUMMARY
  grub backup: $GRUB_BAK

NEXT STEPS (in order -- the second one is easy to miss):

  1. sudo reboot

  2. sudo update-initramfs -u -k all
     Dracut only includes its resume module once /proc/cmdline already contains
     resume=, which it did not when this script ran. Verify:
       sudo lsinitrd /boot/initrd.img-\$(uname -r) | grep -i hibernate-resume

  3. sudo reboot   (again)

  4. cat /sys/power/resume        # MUST be a real device number, not 0:0
     busctl call org.freedesktop.login1 /org/freedesktop/login1 \\
         org.freedesktop.login1.Manager CanHibernate

     "no" = polkit denial -> install 10-enable-hibernate.rules
     "na" = genuinely unsupported

  5. Test with a SCRATCH editor open, not real work:
       systemctl hibernate
     Machine should power off COMPLETELY, and pressing power should restore the
     session. Confirm with: journalctl --list-boots | tail -2
     A successful resume keeps the SAME boot ID.
EOF

if [ "$MODE" = part ]; then
cat <<EOF

  6. ONLY after step 5 has succeeded, reclaim the old swapfile:
       sudo rm -f $SWAPFILE
     It was left in place on purpose as a fallback. Its fstab entry is already
     commented out; /etc/fstab.bak.* has the original.

To undo:
    sudo cp $GRUB_BAK $GRUB_CFG
    sudo cp /etc/fstab.bak.<timestamp> /etc/fstab
    sudo update-initramfs -u -k all && sudo update-grub
EOF
else
cat <<EOF

  RE-RUN THIS SCRIPT if $SWAPFILE is ever recreated, resized, or restored from
  a backup. The physical offset changes, and a stale resume_offset means
  hibernate SUCCEEDS and resume SILENTLY FAILS. A swap partition
  (--partition) has no offset and does not have this failure mode.

To undo:
    sudo cp $GRUB_BAK $GRUB_CFG
    sudo update-initramfs -u -k all && sudo update-grub
EOF
fi
