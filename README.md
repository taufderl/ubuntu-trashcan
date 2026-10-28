# ubuntu-trashcan

Builds an Ubuntu Server installer ISO that works out of the box on the 2013
Mac Pro (MacPro6,1, the "trashcan") with AMD FirePro D300 GPUs.

It takes the stock Ubuntu Server ISO (26.04 LTS or newer) and adds the Mac Pro
fixes. The installer itself is unchanged and fully interactive. At the end it
also applies the following to the new system:

| Area | What it does |
| --- | --- |
| **Wi-Fi** | Installs Broadcom's `wl` driver for the BCM4360 (`broadcom-sta-dkms`) offline from the ISO, plus `wpasupplicant` and `iw`. DKMS rebuilds the driver on kernel updates. Blocks `b43`/`bcma`/`ssb`/`brcmsmac` so they can't grab the card. |
| **Wi-Fi seed** | Optional: joins your network on first boot via netplan. |
| **GPU** | Runs the D300s (Southern Islands) on `amdgpu` instead of `radeon` (`radeon.si_support=0 amdgpu.si_support=1`) for proper power management. |
| **Thermal** | `trashcan-fand` raises the fan's minimum speed based on CPU *and* GPU temperatures. The Mac's own fan controller (SMC) alone lets the GPUs overheat under Linux. It stays in charge and can still spin the fan faster; the original minimum is restored when the service stops. |
| **Disk** | Grows `/` into the free space Ubuntu's guided LVM layout leaves unused, reserves 1% instead of 5% of ext4 for root, and makes the swap file 2 GB instead of 8 GB (`--no-fill-disk`, `--reserved-pct`, `--swap-size`). |
| **Network** | Marks the Ethernet ports optional, so boot doesn't wait 2 minutes for unplugged cables. |

## Build

You need a Linux x86_64 machine, root, `xorriso`, `curl` and about 8 GB of free
space. WSL2 works, as long as the work directory isn't under `/mnt/c`.

```bash
sudo apt install xorriso curl
```

Optionally, create a Wi-Fi seed file and fill in your network:

```bash
cp wifi-seed.conf.example wifi-seed.conf
```

Then build:

```bash
sudo ./build-iso.sh --wifi-seed wifi-seed.conf
```

Without `--iso`, it downloads the latest Ubuntu 26.04 server ISO and checks it
against Ubuntu's official checksums. The result is
`<iso-name>-macpro61.iso`. Run `./build-iso.sh --help` for every option,
including `--output`, `--gpu radeon`, `--no-thermal`, `--swap-size` and `--wifi-ssid`.

> [!WARNING]
> A seeded ISO contains your Wi-Fi passphrase in plain text. Don't share it.
> `wifi-seed.conf` and `*.iso` are git-ignored.

## Write the USB stick

On Linux:

```bash
sudo ./write-usb.sh ubuntu-26.04*-macpro61.iso /dev/sdX
```

On Windows, use [Rufus](https://rufus.ie) and choose **DD Image mode** when it
asks. Don't use Ventoy.

## Install

1. Plug in the stick, Ethernet if you have it, and a wired keyboard.
2. Hold **Option** (Alt) while powering on, then pick **EFI Boot**.
3. The screen stays black for about 2 minutes. The boot menu is there but
   invisible on the Mac, and it starts the Mac Pro entry on its own.
4. Install as usual. Wi-Fi only works on the installed system, so use Ethernet
   or continue without a network. Enable OpenSSH.

After the first boot, the patch log is at `/var/log/trashcan-install.log`. Fan
settings are in `/etc/trashcan/fand.conf`.

## Getting macOS back

Hold **Option + Command + R** at startup for Internet Recovery, which installs
macOS 12 Monterey. For a reliable fallback, make a Monterey installer stick
with `createinstallmedia` before wiping macOS.

## Licence

[MIT](LICENCE.md)
