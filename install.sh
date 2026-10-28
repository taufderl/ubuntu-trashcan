#!/bin/bash
# Autoinstall late-command: apply the Mac Pro 6,1 patches to the freshly
# installed system in /target. Never fails the install; problems are logged
# to /var/log/trashcan-install.log on the new system.
SRC=$(dirname "$(readlink -f "$0")")
TARGET=${TARGET:-/target}
LOG=$TARGET/var/log/trashcan-install.log
exec > >(tee -a "$LOG") 2>&1

in_target() { curtin in-target --target="$TARGET" -- "$@"; }
step() { echo "==> $*"; }
problem() { echo "!!! $*"; }

FILL_DISK=yes SWAP_SIZE=2G RESERVED_PCT=1
# shellcheck source=/dev/null
[[ -r $SRC/options ]] && . "$SRC/options"
ROOT_DEV=$(findmnt -no SOURCE "$TARGET")

# The guided LVM layout only uses part of the disk; give / the rest.
if [[ $FILL_DISK == yes ]] && lvs "$ROOT_DEV" >/dev/null 2>&1; then
  vg=$(lvs --noheadings -o vg_name "$ROOT_DEV" | tr -d ' ')
  if (( $(vgs --noheadings -o vg_free_count "$vg" | tr -d ' ') > 0 )); then
    step "Growing / into the free space of $vg"
    lvextend -r -l +100%FREE "$ROOT_DEV" || problem "lvextend failed"
  fi
fi

if [[ $(findmnt -no FSTYPE "$TARGET") == ext4 ]]; then
  step "Reserving $RESERVED_PCT% of / for root"
  tune2fs -m "$RESERVED_PCT" "$ROOT_DEV" || problem "tune2fs failed"
fi

if [[ -f $TARGET/swap.img ]]; then
  swapoff "$TARGET/swap.img" 2>/dev/null
  rm -f "$TARGET/swap.img"
  if [[ $SWAP_SIZE == 0 ]]; then
    step "Removing the swap file"
    sed -i '\#^/swap.img[[:space:]]#d' "$TARGET/etc/fstab"
  else
    step "Resizing the swap file to $SWAP_SIZE"
    { fallocate -l "$SWAP_SIZE" "$TARGET/swap.img" && chmod 600 "$TARGET/swap.img" &&
      mkswap "$TARGET/swap.img" >/dev/null; } || problem "could not recreate the swap file"
  fi
fi

step "Installing patch files"
(cd "$SRC/payload" && find . -type f) | while read -r f; do
  f=${f#./}
  install -D -o root -g root -m "$(stat -c %a "$SRC/payload/$f")" "$SRC/payload/$f" "$TARGET/$f"
done

step "Installing the Broadcom wl driver, wpasupplicant and build tools"
mkdir -p "$TARGET/var/cache/trashcan"
cp "$SRC"/debs/*.deb "$TARGET/var/cache/trashcan/"
if ! in_target sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download /var/cache/trashcan/*.deb'; then
  problem "apt could not install the bundled packages, falling back to dpkg"
  in_target sh -c 'DEBIAN_FRONTEND=noninteractive dpkg -i --skip-same-version /var/cache/trashcan/*.deb' ||
    problem "dpkg failed too"
fi
rm -rf "$TARGET/var/cache/trashcan"

# The dkms postinst builds for the installer's running kernel; make sure every
# kernel in the new system has the module, then rebuild initramfs for the blacklist.
for k in "$TARGET"/lib/modules/*; do
  in_target dkms autoinstall -k "${k##*/}" || problem "dkms build failed for ${k##*/}"
done
find "$TARGET/lib/modules" -name 'wl.ko*' | grep -q . || problem "wl.ko missing: Wi-Fi will not work"
in_target update-initramfs -u -k all || problem "update-initramfs failed"

step "Updating GRUB with the Mac Pro kernel arguments"
in_target update-grub || problem "update-grub failed"

# The installer enables DHCP on both Ethernet ports. Unplugged, they make
# systemd-networkd-wait-online stall every boot for 2 minutes.
step "Marking Ethernet ports optional"
for eth in $(in_target netplan get ethernets 2>/dev/null | sed -n 's/^\([^ #][^:]*\):$/\1/p'); do
  in_target netplan set "ethernets.$eth.optional=true" || problem "could not mark $eth optional"
done

step "Enabling services"
for unit in trashcan-fand.service trashcan-wifi-seed.service; do
  [[ -f $TARGET/etc/systemd/system/$unit ]] && in_target systemctl enable "$unit"
done

step "Done"
exit 0
