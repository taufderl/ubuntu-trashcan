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

step "Enabling services"
for unit in trashcan-fand.service trashcan-wifi-seed.service; do
  [[ -f $TARGET/etc/systemd/system/$unit ]] && in_target systemctl enable "$unit"
done

step "Done"
exit 0
