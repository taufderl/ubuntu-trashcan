#!/usr/bin/env bash
# write-usb.sh - write an ISO built by build-iso.sh to a USB stick.
set -Eeuo pipefail

die() { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

(($# == 2)) || { echo "Usage: sudo $0 IMAGE.iso /dev/sdX" >&2; exit 1; }
iso=$1 dev=$2

[[ -f $iso ]] || die "no such ISO: $iso"
(( EUID == 0 )) || die "run as root: sudo $0 $*"
[[ -b $dev ]] || die "$dev is not a block device"
[[ $(lsblk -dno TYPE "$dev") == disk ]] || die "$dev is not a whole disk"
lsblk -nro MOUNTPOINT "$dev" | grep -q . && die "$dev has mounted partitions; unmount them first"
(( $(stat -c %s "$iso") <= $(lsblk -bdno SIZE "$dev") )) || die "$dev is smaller than the ISO"

lsblk -o NAME,SIZE,MODEL,TRAN "$dev"
read -r -p "Type $dev to ERASE it and write $(basename "$iso"): " answer
[[ $answer == "$dev" ]] || die "aborted"

dd if="$iso" of="$dev" bs=4M conv=fsync oflag=direct status=progress
sync
printf '\e[1;34m==>\e[0m %s\n' "USB stick ready: boot the Mac Pro holding Option (Alt) and pick 'EFI Boot'"
