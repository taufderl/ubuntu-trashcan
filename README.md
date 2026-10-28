# ubuntu-trashcan

Builds an Ubuntu Server installer ISO that just works on the 2013 Mac Pro
(MacPro6,1, the "trashcan") with FirePro D300 GPUs.

It patches a stock `live-server-amd64` ISO. The installer itself is unchanged
and fully interactive. When it finishes, it also:

- **Wi-Fi:** installs Broadcom's `wl` driver for the BCM4360 offline (DKMS,
  so it is rebuilt on kernel updates), plus `wpasupplicant` and `iw`, and
  blacklists `b43`/`bcma`/`ssb`/`brcmsmac`.
- **Wi-Fi seed (optional):** joins your network on first boot via netplan.
- **GPU:** runs the D300s (Southern Islands) on `amdgpu` instead of `radeon`
  (`radeon.si_support=0 amdgpu.si_support=1`) for proper power management.
- **Thermal:** `trashcan-fand` raises the SMC fan floor from CPU *and* GPU
  temperatures, since the SMC alone lets the GPUs overheat under Linux.
  Tune it in `/etc/trashcan/fand.conf`.

## Build

On a Linux x86_64 machine (WSL2 works, but keep `--workdir` off `/mnt/c`):

```bash
sudo apt install xorriso curl
cp wifi-seed.conf.example wifi-seed.conf   # optional, then edit it
sudo ./build-iso.sh --wifi-seed wifi-seed.conf
sudo ./write-usb.sh ubuntu-26.04*-macpro61.iso /dev/sdX
```

The second step can also be done on another machine with any raw image
writer (Rufus in DD mode, Etcher), or in one go with `build-iso.sh --write /dev/sdX`.

With no `--iso`, it downloads the latest Ubuntu 26.04 LTS server ISO and checks
it against the official checksums. Run `./build-iso.sh --help` for all options
(`--gpu radeon`, `--no-thermal`, `--wifi-ssid`, and more).

Boot the Mac Pro holding **Option**, then pick **EFI Boot**. The installer logs
the patch step to `/var/log/trashcan-install.log`.
