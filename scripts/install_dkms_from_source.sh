#!/usr/bin/env bash
# Install tcp-bbrx from this repository through DKMS.
# Intended for Debian/Ubuntu hosts; run as root.

set -Eeuo pipefail

readonly MODULE_NAME="tcp-bbrx"
readonly KERNEL_MODULE="tcp_bbrx"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

PACKAGE_VERSION="${PACKAGE_VERSION:-}"
KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
ENABLE_BBRX=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install_dkms_from_source.sh [OPTIONS]

Build, install, and load tcp-bbrx from the current repository using DKMS.

Options:
  --version VERSION  DKMS package version (default: derive from git)
  --kernel RELEASE   Build for this kernel (default: uname -r)
  --enable           Set net.ipv4.tcp_congestion_control=bbrx now
  -h, --help         Show this help

Environment:
  PACKAGE_VERSION and KERNEL_RELEASE provide the same values as the options.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --version)
      (($# >= 2)) || die "--version requires a value"
      PACKAGE_VERSION="$2"
      shift 2
      ;;
    --kernel)
      (($# >= 2)) || die "--kernel requires a value"
      KERNEL_RELEASE="$2"
      shift 2
      ;;
    --enable)
      ENABLE_BBRX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

((EUID == 0)) || die "run this script as root (sudo $0)"

for file in Makefile tcp_bbrx.c bbrx-compat.h; do
  [[ -f "$REPO_ROOT/$file" ]] || die "missing repository file: $REPO_ROOT/$file"
done

if [[ -z "$PACKAGE_VERSION" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" describe --tags >/dev/null 2>&1; then
    PACKAGE_VERSION="$(git -C "$REPO_ROOT" describe --tags \
      | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g')"
  else
    die "cannot derive a version; pass --version VERSION"
  fi
fi
[[ "$PACKAGE_VERSION" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || die "invalid version: $PACKAGE_VERSION"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    dkms build-essential kmod "linux-headers-$KERNEL_RELEASE"
else
  for command_name in dkms make gcc modprobe depmod; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "missing command '$command_name'; install DKMS and the compiler toolchain"
  done
fi

readonly KERNEL_BUILD="/lib/modules/$KERNEL_RELEASE/build"
[[ -d "$KERNEL_BUILD" ]] \
  || die "missing matching headers: install linux-headers-$KERNEL_RELEASE"

readonly SOURCE_DIR="/usr/src/$MODULE_NAME-$PACKAGE_VERSION"
printf 'Installing %s/%s for kernel %s\n' \
  "$MODULE_NAME" "$PACKAGE_VERSION" "$KERNEL_RELEASE"

# Remove the same registered version first so reruns are deterministic.
if dkms status -m "$MODULE_NAME" -v "$PACKAGE_VERSION" 2>/dev/null | grep -q .; then
  dkms remove "$MODULE_NAME/$PACKAGE_VERSION" --all || true
fi
rm -rf -- "$SOURCE_DIR"
install -d -m 0755 -- "$SOURCE_DIR"
install -m 0644 -- \
  "$REPO_ROOT/Makefile" \
  "$REPO_ROOT/tcp_bbrx.c" \
  "$REPO_ROOT/bbrx-compat.h" \
  "$SOURCE_DIR/"

cat > "$SOURCE_DIR/dkms.conf" <<EOF
PACKAGE_NAME="$MODULE_NAME"
PACKAGE_VERSION="$PACKAGE_VERSION"
MAKE[0]="make KERNEL_DIR=\${kernel_source_dir} all"
CLEAN="make KERNEL_DIR=\${kernel_source_dir} clean"
BUILT_MODULE_NAME[0]="$KERNEL_MODULE"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
EOF

dkms add "$MODULE_NAME/$PACKAGE_VERSION"
if ! dkms install "$MODULE_NAME/$PACKAGE_VERSION" -k "$KERNEL_RELEASE"; then
  log="/var/lib/dkms/$MODULE_NAME/$PACKAGE_VERSION/build/make.log"
  [[ -f "$log" ]] && printf 'DKMS build log: %s\n' "$log" >&2
  exit 2
fi

# A module built for a non-running kernel cannot be loaded yet.
if [[ "$KERNEL_RELEASE" != "$(uname -r)" ]]; then
  printf 'Installed for %s; reboot into that kernel before loading it.\n' "$KERNEL_RELEASE"
  dkms status -m "$MODULE_NAME" -v "$PACKAGE_VERSION"
  exit 0
fi

modprobe "$KERNEL_MODULE"
install -d -m 0755 /etc/modules-load.d
printf '%s\n' "$KERNEL_MODULE" > /etc/modules-load.d/tcp-bbrx.conf

available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
[[ " $available " == *" bbrx "* ]] \
  || die "module loaded, but bbrx is absent from available congestion controls"

if ((ENABLE_BBRX)); then
  sysctl -w net.ipv4.tcp_congestion_control=bbrx
fi

printf '\nDKMS status:\n'
dkms status -m "$MODULE_NAME" -v "$PACKAGE_VERSION"
printf 'Loaded module:\n'
lsmod | awk -v module="$KERNEL_MODULE" 'NR == 1 || $1 == module'
printf 'Available congestion controls: %s\n' "$available"
printf 'Current congestion control: %s\n' \
  "$(sysctl -n net.ipv4.tcp_congestion_control)"
