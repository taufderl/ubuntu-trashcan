#!/usr/bin/env bash
# build-iso.sh - turn a stock Ubuntu Server ISO into a Mac Pro 6,1 ("trashcan")
# installer: offline Broadcom wl Wi-Fi driver, amdgpu for the FirePro D300s,
# CPU+GPU aware fan control and an optional seeded Wi-Fi network.
#
# The stock installer is kept fully interactive. A small autoinstall.yaml only
# adds a late-command that runs /cdrom/trashcan/install.sh against /target.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RELEASE=26.04
ISO=""
OUT=""
WORK="$HERE/work"
GPU=amdgpu
THERMAL=yes
KEEP_WORK=no
WRITE_DEV=""
WIFI_SEED=""
WIFI_SSID="" WIFI_PSK="" WIFI_HIDDEN=no WIFI_COUNTRY=""
CLI_SSID="" CLI_PSK="" CLI_HIDDEN="" CLI_COUNTRY=""

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33mwarn:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 [options]

  --release VER       Ubuntu Server release to download (default: $RELEASE)
  --iso PATH          use a local live-server ISO instead of downloading
  --output PATH       output ISO (default: <iso name>-macpro61.iso next to this script)
  --workdir DIR       scratch space on a Linux filesystem (default: ./work)
  --gpu amdgpu|radeon kernel driver for the FirePro D300s (default: amdgpu)
  --no-thermal        skip the fan-control daemon
  --wifi-seed FILE    Wi-Fi to join after install (see wifi-seed.conf.example)
  --wifi-ssid SSID    same, on the command line (overrides the seed file)
  --wifi-psk PSK      WPA2/WPA3-personal passphrase (omit for open networks)
  --wifi-hidden       the network does not broadcast its SSID
  --wifi-country CC   regulatory domain, e.g. DE or US
  --write /dev/sdX    write the finished ISO to this USB stick (asks first)
  --keep-work         keep the work directory afterwards
EOF
}

while (($#)); do
  case $1 in
    --release)      RELEASE=$2; shift ;;
    --iso)          ISO=$(readlink -f "$2"); shift ;;
    --output)       OUT=$2; shift ;;
    --workdir)      WORK=$2; shift ;;
    --gpu)          GPU=$2; shift ;;
    --no-thermal)   THERMAL=no ;;
    --wifi-seed)    WIFI_SEED=$2; shift ;;
    --wifi-ssid)    CLI_SSID=$2; shift ;;
    --wifi-psk)     CLI_PSK=$2; shift ;;
    --wifi-hidden)  CLI_HIDDEN=yes ;;
    --wifi-country) CLI_COUNTRY=$2; shift ;;
    --write)        WRITE_DEV=$2; shift ;;
    --keep-work)    KEEP_WORK=yes ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# --- checks -----------------------------------------------------------------

# Only 26.04 and newer: older releases ship a different Wi-Fi driver package.
supported() { [[ $1 =~ ^([0-9]{2})\.([0-9]{2}) ]] && (( 10#${BASH_REMATCH[1]}${BASH_REMATCH[2]} >= 2604 )); }

[[ $RELEASE =~ ^[0-9]{2}\.(04|10)(\.[0-9]+)?$ ]] ||
  die "Ubuntu releases are YY.04 or YY.10; there is no '$RELEASE' (try 26.04)"
supported "$RELEASE" || die "only Ubuntu 26.04 or newer is supported"
[[ $GPU == amdgpu || $GPU == radeon ]] || die "--gpu must be amdgpu or radeon"
(( EUID == 0 )) || die "run as root (mounts, chroot): sudo $0 $*"
[[ $(uname -m) == x86_64 ]] || die "needs an x86_64 host (the build chroot runs amd64 binaries)"
for tool in xorriso curl sha256sum md5sum chroot mount findmnt lsblk; do
  command -v "$tool" >/dev/null || die "missing '$tool' (Debian/Ubuntu: apt install xorriso curl)"
done
grep -qw squashfs /proc/filesystems || modprobe squashfs 2>/dev/null ||
  die "kernel has no squashfs support"

mkdir -p "$WORK"
WORK=$(readlink -f "$WORK")
case $(stat -f -c %T "$WORK") in
  v9fs|9p|fuseblk|ntfs*|vfat|msdos|exfat)
    die "$WORK is on a Windows/FAT filesystem; pass --workdir on a Linux filesystem" ;;
esac
(( $(df --output=avail -B1G "$WORK" | tail -1) >= 8 )) || warn "less than 8 GB free in $WORK"

# --- Wi-Fi seed --------------------------------------------------------------

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

load_wifi_seed() {
  local line key val n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1)); line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]] || die "$1:$n: expected KEY=VALUE"
    key=${BASH_REMATCH[1]}
    val=$(trim "${BASH_REMATCH[2]}")
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
    case $key in
      WIFI_SSID)    WIFI_SSID=$val ;;
      WIFI_PSK)     WIFI_PSK=$val ;;
      WIFI_HIDDEN)  WIFI_HIDDEN=$val ;;
      WIFI_COUNTRY) WIFI_COUNTRY=$val ;;
      *) warn "$1:$n: ignoring unknown key $key" ;;
    esac
  done < "$1"
}

[[ -n $WIFI_SEED ]] && { [[ -r $WIFI_SEED ]] || die "cannot read $WIFI_SEED"; load_wifi_seed "$WIFI_SEED"; }
[[ -n $CLI_SSID ]]    && WIFI_SSID=$CLI_SSID
[[ -n $CLI_PSK ]]     && WIFI_PSK=$CLI_PSK
[[ -n $CLI_HIDDEN ]]  && WIFI_HIDDEN=$CLI_HIDDEN
[[ -n $CLI_COUNTRY ]] && WIFI_COUNTRY=$CLI_COUNTRY

if [[ -n $WIFI_SSID ]]; then
  (( ${#WIFI_SSID} <= 32 )) || die "SSID longer than 32 bytes"
  [[ $WIFI_SSID != *[[:cntrl:]]* ]] || die "SSID contains control characters"
  if [[ -n $WIFI_PSK ]]; then
    [[ $WIFI_PSK =~ ^[[:print:]]{8,63}$ || $WIFI_PSK =~ ^[0-9a-fA-F]{64}$ ]] ||
      die "WIFI_PSK must be 8-63 printable characters or 64 hex digits"
  fi
  [[ -z $WIFI_COUNTRY || $WIFI_COUNTRY =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be two capital letters"
  case ${WIFI_HIDDEN,,} in yes|true|1) WIFI_HIDDEN=yes ;; *) WIFI_HIDDEN=no ;; esac
elif [[ -n $WIFI_PSK ]]; then
  die "a Wi-Fi passphrase was given without an SSID"
fi

# --- mounts and cleanup ------------------------------------------------------

MOUNTS=()
mnt() { mount "$@"; MOUNTS+=("${*: -1}"); }

unmount_to() {
  local m
  while (( ${#MOUNTS[@]} > $1 )); do
    m=${MOUNTS[-1]}
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || warn "could not unmount $m"
    unset 'MOUNTS[-1]'
  done
}

cleanup() {
  unmount_to 0
  [[ $KEEP_WORK == yes ]] && return
  if findmnt -rno TARGET | grep -q "^$WORK/"; then
    warn "something is still mounted under $WORK; not deleting it"
  else
    rm -rf --one-file-system "$WORK"
  fi
}
trap cleanup EXIT
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

# --- 1. get the ISO ------------------------------------------------------------

fetch_iso() {
  local base="https://releases.ubuntu.com/$RELEASE" sums name want
  log "Looking up the current $RELEASE live-server ISO"
  sums=$(curl -fsSL "$base/SHA256SUMS") || die "cannot fetch $base/SHA256SUMS"
  name=$(awk '{f=$2; sub(/^\*/, "", f)} f ~ /live-server-amd64\.iso$/ {n=f} END {print n}' <<<"$sums")
  [[ -n $name ]] || die "no live-server-amd64 ISO listed at $base"
  want=$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f)} f == n {print $1}' <<<"$sums")

  mkdir -p "$HERE/cache"
  ISO="$HERE/cache/$name"
  if [[ ! -f $ISO ]]; then
    log "Downloading $name"
    curl -fL --continue-at - -o "$ISO.part" "$base/$name"
    mv "$ISO.part" "$ISO"
  fi
  log "Verifying $name"
  echo "$want  $ISO" | sha256sum -c --quiet - || { rm -f "$ISO"; die "checksum mismatch; deleted, run again"; }
}

[[ -n $ISO ]] || fetch_iso
[[ -f $ISO ]] || die "no such ISO: $ISO"
[[ -n $OUT ]] || OUT="$HERE/$(basename "${ISO%.iso}")-macpro61.iso"
OUT=$(readlink -f "$OUT")
[[ $OUT != "$ISO" ]] || die "output would overwrite the input ISO"

W=$(mktemp -d "$WORK/build.XXXXXX")
ISOMNT=$W/iso STAGE=$W/stage
mkdir -p "$ISOMNT" "$STAGE/trashcan/debs"
mnt -o loop,ro "$ISO" "$ISOMNT"
[[ -f $ISOMNT/casper/install-sources.yaml ]] ||
  die "$(basename "$ISO") does not look like a layered Ubuntu live-server ISO"

# --- 2. inspect it -------------------------------------------------------------

BASE_LAYER=$ISOMNT/casper/ubuntu-server-minimal.squashfs
[[ -f $BASE_LAYER ]] || die "casper/ubuntu-server-minimal.squashfs not found on the ISO"

# The base layer is what every install starts from, kernel included.
LOWER=$W/layer
mkdir -p "$LOWER"
mnt -t squashfs -o loop,ro "$BASE_LAYER" "$LOWER"
KVER=$(ls "$LOWER/usr/lib/modules" | sort -V | tail -1)
[[ -n $KVER ]] || die "no kernel found in $(basename "$BASE_LAYER")"
SNAPSHOT=$(grep -oE '\(([0-9]{8})' "$ISOMNT/.disk/info" 2>/dev/null | tr -d '(' || true)
log "ISO: $(cat "$ISOMNT/.disk/info" 2>/dev/null || basename "$ISO")"
supported "$(grep -oE '[0-9]{2}\.[0-9]{2}' "$ISOMNT/.disk/info" | head -1)" ||
  die "$(basename "$ISO") is older than Ubuntu 26.04 (or not an Ubuntu ISO)"
log "Kernel: $KVER"

# --- 3. fetch the extra packages in a throwaway chroot ---------------------------

# The chroot is the minimal server layer, i.e. what the smallest install starts
# from, so apt downloads every package the target could be missing.
fetch_debs() {
  local depth=${#MOUNTS[@]} root="$W/root" codename
  mkdir -p "$root" "$W/upper" "$W/ovl-work"
  mnt -t overlay overlay -o "lowerdir=$LOWER,upperdir=$W/upper,workdir=$W/ovl-work" "$root"
  for d in dev dev/pts proc sys; do mnt --bind "/$d" "$root/$d"; done

  rm -f "$root/etc/resolv.conf"
  cp -L /etc/resolv.conf "$root/etc/resolv.conf"
  codename=$(. "$root/etc/os-release" && echo "$VERSION_CODENAME")
  rm -f "$root"/etc/apt/sources.list.d/* "$root/etc/apt/sources.list"
  cat > "$root/etc/apt/sources.list.d/build.sources" <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: $codename $codename-updates $codename-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  local apt_opts=()
  has_pkg() { chroot "$root" apt-cache "${apt_opts[@]}" show --no-all-versions "$1" >/dev/null 2>&1; }
  chroot "$root" apt-get -q update
  if ! has_pkg "linux-headers-$KVER"; then
    [[ -n $SNAPSHOT ]] || die "linux-headers-$KVER is not in the archive (and the ISO date is unknown)"
    # Point-release kernels drop out of -updates; the snapshot archive keeps them.
    warn "linux-headers-$KVER is gone from the archive; using the snapshot from $SNAPSHOT"
    apt_opts=(-o "APT::Snapshot=${SNAPSHOT}T235959Z")
    chroot "$root" apt-get -q "${apt_opts[@]}" update
    has_pkg "linux-headers-$KVER" || die "linux-headers-$KVER is not downloadable; cannot ship the Wi-Fi driver"
  fi
  local pkgs=(broadcom-sta-dkms dkms build-essential "linux-headers-$KVER" wpasupplicant iw)
  log "Downloading ${pkgs[*]} (+ dependencies) for $codename"
  chroot "$root" apt-get -qy "${apt_opts[@]}" --download-only install "${pkgs[@]}"
  cp "$root"/var/cache/apt/archives/*.deb "$STAGE/trashcan/debs/"
  log "Staged $(ls "$STAGE/trashcan/debs" | wc -l) packages ($(du -sh "$STAGE/trashcan/debs" | cut -f1))"
  unmount_to "$depth"
}
fetch_debs

# --- 4. stage the target patches -------------------------------------------------

KARGS=()
[[ $GPU == amdgpu ]] && KARGS+=(radeon.si_support=0 amdgpu.si_support=1)
KARGS+=(modprobe.blacklist=b43,b43legacy,bcma,ssb,brcmsmac)

PAYLOAD=$STAGE/trashcan/payload
mkdir -p "$PAYLOAD"
cp -r "$HERE/payload/wifi/." "$PAYLOAD/"
[[ $THERMAL == yes ]] && cp -r "$HERE/payload/thermal/." "$PAYLOAD/"
install -m755 "$HERE/install.sh" "$STAGE/trashcan/install.sh"

mkdir -p "$PAYLOAD/etc/default/grub.d"
cat > "$PAYLOAD/etc/default/grub.d/90-trashcan.cfg" <<EOF
# ubuntu-trashcan: Mac Pro 6,1 kernel arguments
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT ${KARGS[*]}"
EOF

yaml_quote() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

if [[ -n $WIFI_SSID ]]; then
  log "Seeding Wi-Fi network '$WIFI_SSID'"
  # @IFACE@ is filled in on first boot by trashcan-wifi-seed, once wl is loaded
  # and the real interface name is known.
  mkdir -p "$PAYLOAD/etc/trashcan"
  {
    echo "network:"
    echo "  version: 2"
    echo "  wifis:"
    echo "    @IFACE@:"
    echo "      optional: true"
    echo "      dhcp4: true"
    echo "      dhcp6: true"
    [[ -n $WIFI_COUNTRY ]] && echo "      regulatory-domain: $WIFI_COUNTRY"
    echo "      access-points:"
    if [[ -z $WIFI_PSK && $WIFI_HIDDEN == no ]]; then
      echo "        $(yaml_quote "$WIFI_SSID"): {}"
    else
      echo "        $(yaml_quote "$WIFI_SSID"):"
      [[ -n $WIFI_PSK ]] && echo "          password: $(yaml_quote "$WIFI_PSK")"
      [[ $WIFI_HIDDEN == yes ]] && echo "          hidden: true"
    fi
  } > "$PAYLOAD/etc/trashcan/wifi-netplan.yaml.in"
  chmod 600 "$PAYLOAD/etc/trashcan/wifi-netplan.yaml.in"
fi

cat > "$PAYLOAD/etc/trashcan/build-info" <<EOF
source_iso=$(basename "$ISO")
kernel=$KVER
gpu=$GPU
thermal=$THERMAL
wifi_seed=$([[ -n $WIFI_SSID ]] && echo yes || echo no)
built=$(date -u +%FT%TZ)
EOF

# Every section stays interactive; this only hooks in the late-command.
cat > "$STAGE/autoinstall.yaml" <<'EOF'
autoinstall:
  version: 1
  interactive-sections:
    - "*"
  late-commands:
    - bash /cdrom/trashcan/install.sh
EOF

# --- 5. boot menu ----------------------------------------------------------------

mkdir -p "$STAGE/boot/grub"
for cfg in boot/grub/grub.cfg boot/grub/loopback.cfg; do
  [[ -f $ISOMNT/$cfg ]] || continue
  sed -E -e "s#(/casper/[^[:space:]]*vmlinuz[^[:space:]]*)#\1 ${KARGS[*]}#" \
         -e 's#(Try or Install Ubuntu Server)#\1 (Mac Pro 6,1)#' \
         "$ISOMNT/$cfg" > "$STAGE/$cfg"
done

# md5sum.txt backs the "check disc for defects" boot entry.
( cd "$STAGE" && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum ) > "$W/new.md5"
awk 'NR == FNR {seen[$2] = 1; print; next} !($2 in seen)' "$W/new.md5" "$ISOMNT/md5sum.txt" |
  sort -k2 > "$STAGE/md5sum.txt"

# --- 6. write the ISO --------------------------------------------------------------

log "Writing $OUT"
rm -f "$OUT"
xorriso -indev "$ISO" -outdev "$OUT" \
  -map "$STAGE" / \
  -boot_image any replay \
  -compliance no_emul_toc \
  -padding included
unmount_to 0
[[ -n ${SUDO_USER:-} ]] && { chown "$SUDO_USER:" "$OUT" 2>/dev/null || true; }
log "Done: $OUT"

# --- 7. optionally flash it ----------------------------------------------------------

[[ -n $WRITE_DEV ]] && "$HERE/write-usb.sh" "$OUT" "$WRITE_DEV"
exit 0
