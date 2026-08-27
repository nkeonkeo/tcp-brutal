#!/usr/bin/env bash
#
# install_dkms.sh - tcp-bbrx dkms module install script
# Try `install_dkms.sh --help` for usage.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2023 Aperture Internet Laboratory
#

set -e


###
# SCRIPT CONFIGURATION
###

# Command line arguments of this script
SCRIPT_ARGS=("$@")

# Initial URL & command of one-click script (for usage & logging)
# TODO: change the link to real
SCRIPT_INITIATOR_URL="https://tcp.hy2.sh"
SCRIPT_INITIATOR_COMMAND="bash <(curl -fsSL $SCRIPT_INITIATOR_URL)"

# URL of GitHub
REPO_URL="https://github.com/nkeonkeo/tcp-brutal"

# curl command line flags.
# To using a proxy, please specify ALL_PROXY in the environ variable, such like:
# export ALL_PROXY=socks5h://192.0.2.1:1080
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

DKMS_MODULE_NAME="tcp-bbrx"
KERNEL_MODULE_NAME="tcp_bbrx"


###
# AUTO DETECTED GLOBAL VARIABLE
###

# Package manager
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"


###
# COMMAND REPLACEMENT & UTILITIES
###

has_command() {
  local _command=$1

  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "/tmp/bbrxinst.XXXXXXXXXX"
}

tput() {
  if [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && has_command tput; then
    command tput "$@" 2>/dev/null || true
  fi
}

tred="$(tput setaf 1)"
tgreen="$(tput setaf 2)"
tyellow="$(tput setaf 3)"
tblue="$(tput setaf 4)"
taoi="$(tput setaf 6)"
tbold="$(tput bold)"
treset="$(tput sgr0)"

is_run_from_fd() {
  has_prefix "$0" "/dev/" || has_prefix "$0" "/proc/"
}

script_name() {
  local _keep_dirname="$1"

  if is_run_from_fd; then
    echo "$SCRIPT_INITIATOR_COMMAND"
    return
  fi

  if ! has_prefix "$0" "." && [[ -z "$_keep_dirname" ]]; then
    basename "$0"
    return
  fi
  echo "$0"
}

note() {
  local _msg="$1"

  echo -e "$(script_name): ${tbold}note: $_msg${treset}"
}

warning() {
  local _msg="$1"

  echo -e "$(script_name): ${tyellow}warning: $_msg${treset}"
}

error() {
  local _msg="$1"

  echo -e "$(script_name): ${tred}error: $_msg${treset}"
}

has_prefix() {
    local _s="$1"
    local _prefix="$2"

    if [[ -z "$_prefix" ]]; then
        return 0
    fi

    if [[ -z "$_s" ]]; then
        return 1
    fi

    [[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

show_argument_error_and_exit() {
  local _error_msg="$1"

  error "$_error_msg"
  echo "Try \"$(script_name) --help\" for usage." >&2
  exit 22
}

exec_sudo() {
  # exec sudo with configurable environ preserved.
  local _saved_ifs="$IFS"
  IFS=$'\n'
  local _preserved_env=(
    $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
    $(env | grep "^FORCE_\w*=" || true)
  )
  IFS="$_saved_ifs"

  exec sudo env \
    "${_preserved_env[@]}" \
    "$@"
}

detect_package_manager() {
  if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then
    return 0
  fi

  if has_command apt; then
    apt update
    PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
    return 0
  fi

  if has_command dnf; then
    PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
    return 0
  fi

  if has_command yum; then
    PACKAGE_MANAGEMENT_INSTALL='yum -y install'
    return 0
  fi

  if has_command zypper; then
    PACKAGE_MANAGEMENT_INSTALL='zypper install -y'
    return 0
  fi

  if has_command pacman; then
    PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
    return 0
  fi

  return 1
}

install_software() {
  local _package_name="$1"

  if ! detect_package_manager; then
    error "Supported package manager is not detected, please install the following package manually:"
    echo
    echo -e "\t* $_package_name"
    echo
    exit 65
  fi

  echo "Installing missing dependence '$_package_name' with '$PACKAGE_MANAGEMENT_INSTALL' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
    echo "ok"
  else
    error "Cannot install '$_package_name' with detected package manager, please install it manually."
    exit 65
  fi
}

apt_package_has_candidate() {
  local _package_name="$1"
  local _candidate

  _candidate="$(apt-cache policy "$_package_name" 2>/dev/null \
    | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
  [[ -n "$_candidate" && "$_candidate" != "(none)" ]]
}

apt_kernel_metapackages() {
  local _kernel_ver="$1"

  case "$_kernel_ver" in
    *-cloud-amd64)
      echo "linux-image-cloud-amd64 linux-headers-cloud-amd64"
      ;;
    *-rt-amd64)
      echo "linux-image-rt-amd64 linux-headers-rt-amd64"
      ;;
    *-amd64)
      echo "linux-image-amd64 linux-headers-amd64"
      ;;
    *-cloud-arm64)
      echo "linux-image-cloud-arm64 linux-headers-cloud-arm64"
      ;;
    *-rt-arm64)
      echo "linux-image-rt-arm64 linux-headers-rt-arm64"
      ;;
    *-arm64)
      echo "linux-image-arm64 linux-headers-arm64"
      ;;
    *)
      return 1
      ;;
  esac
}

latest_kernel_with_headers() {
  local _module_dir
  local _latest=""

  for _module_dir in /lib/modules/*; do
    [[ -d "$_module_dir/build" ]] || continue
    if [[ -z "$_latest" ]] \
        || [[ "$(printf '%s\n%s\n' "$_latest" "${_module_dir##*/}" | sort -V | tail -n 1)" != "$_latest" ]]; then
      _latest="${_module_dir##*/}"
    fi
  done
  echo "$_latest"
}

install_linux_headers() {
  local _kernel_ver="$(uname -r)"

  echo "Try to install linux-headers for $_kernel_ver ... "

  if has_command pacman; then
    local _kernel_img="/lib/modules/$_kernel_ver/vmlinuz"
    if [[ ! -f "$_kernel_img" ]]; then
      error "Kernel image does not exist."
      note "If you are using a kernel installed by pacman, this usually caused by system upgrading without reboot."
      note "Please reboot your server and try again."
      return 2
    fi
    local _kernel_pkg=$(pacman -Qoq "$_kernel_img")
    if [[ -z "$_kernel_pkg" ]]; then
      error "Failed to detect kernel package."
      warning "It seems like you are NOT using a kernel that installed by pacman."
      return 2
    fi
    install_software "$_kernel_pkg-headers"
  elif has_command apt; then
    local _exact_headers="linux-headers-$_kernel_ver"
    local _metapackages _kernel_meta _headers_meta _next_kernel

    if ! detect_package_manager; then
      error "Supported package manager is not detected, please install $_exact_headers manually."
      return 65
    fi

    if apt_package_has_candidate "$_exact_headers"; then
      install_software "$_exact_headers"
      return 0
    fi

    warning "The configured APT repositories do not provide $_exact_headers."
    warning "The running kernel is likely obsolete or came from a repository that is no longer configured."

    if ! _metapackages="$(apt_kernel_metapackages "$_kernel_ver")"; then
      error "Cannot determine Debian/Ubuntu kernel metapackages for $_kernel_ver."
      note "Install matching headers manually, or install a supported kernel and reboot into it."
      return 65
    fi
    read -r _kernel_meta _headers_meta <<< "$_metapackages"

    if ! apt_package_has_candidate "$_kernel_meta" \
        || ! apt_package_has_candidate "$_headers_meta"; then
      error "APT has no candidate for $_kernel_meta and/or $_headers_meta."
      note "Check your Debian/Ubuntu APT sources, then install matching kernel headers manually."
      return 65
    fi

    note "Installing the current kernel flavor via metapackages: $_kernel_meta $_headers_meta"
    if ! $PACKAGE_MANAGEMENT_INSTALL "$_kernel_meta" "$_headers_meta"; then
      error "Cannot install Debian/Ubuntu kernel metapackages."
      return 65
    fi

    if is_linux_headers_installed; then
      return 0
    fi

    _next_kernel="$(latest_kernel_with_headers)"
    error "Headers for the running kernel $_kernel_ver are unavailable."
    if [[ -n "$_next_kernel" && "$_next_kernel" != "$_kernel_ver" ]]; then
      note "Kernel $_next_kernel and its headers are installed."
      note "Reboot into $_next_kernel, then rerun: $(script_name 1) install -f"
    else
      note "Reboot into the newly installed kernel, then rerun: $(script_name 1) install -f"
    fi
    return 2
  elif has_command dnf || has_command yum; then
    install_software "kernel-devel-$_kernel_ver"
  else
    # unsupported
    error "Automatically linux headers installing is currently not supported on this distribution."
    return 1
  fi
}

rerun_with_sudo() {
  if ! has_command sudo; then
    return 13
  fi

  local _target_script

  if is_run_from_fd; then
    local _tmp_script="$(mktemp)"
    chmod +x "$_tmp_script"

    if has_command curl; then
      curl -o "$_tmp_script" "$SCRIPT_INITIATOR_URL"
    elif has_command wget; then
      wget -O "$_tmp_script" "$SCRIPT_INITIATOR_URL"
    else
      return 127
    fi

    _target_script="$_tmp_script"
  else
    _target_script="$0"
  fi

  note "Re-running this script with sudo."
  exec_sudo "$_target_script" "${SCRIPT_ARGS[@]}"
}

check_permission() {
  if [[ "$UID" -eq '0' ]]; then
    return
  fi

  note "The user running this script is not root."

  if ! rerun_with_sudo; then
    error "Please manually switch to root and run this script again."
    echo
    echo -e "\t${tred}sudo -H bash${treset}"
    echo -e "\t${tred}$(script_name "1")${treset}"
    echo
    exit 13
  fi
}

check_environment_operating_system() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    return
  fi

  error "This script only supports Linux."
  exit 95
}

check_environment_curl() {
  if has_command curl; then
    return
  fi

  install_software curl
}

check_environment_grep() {
  if has_command grep; then
    return
  fi

  install_software grep
}

check_environment_dkms() {
  if has_command dkms; then
    return
  fi

  install_software dkms
}

is_linux_headers_installed() {
  test -d "/lib/modules/$(uname -r)/build"
}

is_archlinux() {
  test -f "/etc/arch-release"
}


check_linux_headers() {
  echo -n "Checking linux-headers ... "
  if is_linux_headers_installed; then
    echo "ok"
  else
    echo "not installed"
    if ! install_linux_headers; then
      warning "Kernel headers is missing for current running kernel."
      warning "The DKMS kernel module will not be compiled."
      return 2
    fi
  fi
}

check_environment() {
  check_environment_operating_system
  check_environment_curl
  check_environment_grep
  check_environment_dkms
  check_linux_headers
}

vercmp_segment() {
  local _lhs="$1"
  local _rhs="$2"

  if [[ "x$_lhs" == "x$_rhs" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs" ]]; then
    echo -1
    return
  fi
  if [[ -z "$_rhs" ]]; then
    echo 1
    return
  fi

  local _lhs_num="${_lhs//[A-Za-z]*/}"
  local _rhs_num="${_rhs//[A-Za-z]*/}"

  if [[ "x$_lhs_num" == "x$_rhs_num" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs_num" ]]; then
    echo -1
    return
  fi
  if [[ -z "$_rhs_num" ]]; then
    echo 1
    return
  fi
  local _numcmp=$(($_lhs_num - $_rhs_num))
  if [[ "$_numcmp" -ne 0 ]]; then
    echo "$_numcmp"
    return
  fi

  local _lhs_suffix="${_lhs#"$_lhs_num"}"
  local _rhs_suffix="${_rhs#"$_rhs_num"}"

  if [[ "x$_lhs_suffix" == "x$_rhs_suffix" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs_suffix" ]]; then
    echo 1
    return
  fi
  if [[ -z "$_rhs_suffix" ]]; then
    echo -1
    return
  fi
  if [[ "$_lhs_suffix" < "$_rhs_suffix" ]]; then
    echo -1
    return
  fi
  echo 1
}

vercmp() {
  local _lhs=${1#v}
  local _rhs=${2#v}

  while [[ -n "$_lhs" && -n "$_rhs" ]]; do
    local _clhs="${_lhs/.*/}"
    local _crhs="${_rhs/.*/}"

    local _segcmp="$(vercmp_segment "$_clhs" "$_crhs")"
    if [[ "$_segcmp" -ne 0 ]]; then
      echo "$_segcmp"
      return
    fi

    _lhs="${_lhs#"$_clhs"}"
    _lhs="${_lhs#.}"
    _rhs="${_rhs#"$_crhs"}"
    _rhs="${_rhs#.}"
  done

  if [[ "x$_lhs" == "x$_rhs" ]]; then
    echo 0
    return
  fi

  if [[ -z "$_lhs" ]]; then
    echo -1
    return
  fi

  if [[ -z "$_rhs" ]]; then
    echo 1
    return
  fi

  return
}


###
# ARGUMENTS PARSER
###

show_usage_and_exit() {
  echo
  echo -e "\t${tbold}$(script_name)${treset} - tcp-bbrx dkms install script"
  echo
  echo -e "Usage:"
  echo
  echo -e "${tbold}Install tcp-bbrx${treset}"
  echo -e "\t$(script_name) [install] [ -f | -l <file> | --version <version> ]"
  echo -e "Options:"
  echo -e "\t-f, --force\tForce re-install latest or specified version even if it has been installed."
  echo -e "\t-l, --local <file>\tInstall specified DKMS tarball instead of download it."
  echo -e "\t--version <version>\tInstall specified version instead of the latest."
  echo
  echo -e "${tbold}Uninstall tcp-bbrx${treset}"
  echo -e "\t$(script_name) uninstall"
  echo
  echo -e "${tbold}Check for the status & update${treset}"
  echo -e "\t$(script_name) check"
  echo
  echo -e "${tbold}Reload / Unload tcp-bbrx kernel module${treset}"
  echo -e "\t$(script_name) [re]load"
  echo -e "\t$(script_name) unload"
  echo
  echo -e "${tbold}Show this help${treset}"
  echo -e "\t$(script_name) help"
  exit 0
}

check_show_usage_and_exit() {
  case "$1" in
    "help")
      show_usage_and_exit
      ;;
  esac

  # if '-h' or '--help' appear in arguments in any position,
  # display help and exit
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--help' | '-h')
        show_usage_and_exit
        ;;
    esac
    shift
  done
}


###
# DKMS
###

dkms_get_installed_versions() {
  local _module="$1"

  local _dkms_moddir="/var/lib/dkms/$_module"

  if [[ ! -d "$_dkms_moddir" ]]; then
    return
  fi

  for file in $(command ls "$_dkms_moddir/"); do
    if [[ -L "$_dkms_moddir/$file" ]]; then
      # ignore kernel-* symlinks
      continue
    fi
    echo "v$file"
  done
}

dkms_remove_modules() {
  local _module="$1"
  local _keep_latest="$2"

  local _versions_to_remove=($(dkms_get_installed_versions "$_module"))
  if [[ -n "$_keep_latest" ]]; then
    local _latest=""
    local _new_versions_to_remove
    _new_versions_to_remove=()
    for version in "${_versions_to_remove[@]}"; do
      local _vercmp="$(vercmp "$version" "$_latest")"
      if [[ "$_vercmp" -gt 0 ]]; then
        if [[ -n "$_latest" ]]; then
          _new_versions_to_remove+=("$_latest")
        fi
        _latest="$version"
      else
        _new_versions_to_remove+=("$version")
      fi
    done
    _versions_to_remove=("${_new_versions_to_remove[@]}")
  fi

  for version in "${_versions_to_remove[@]}"; do
    local _dkms_version="${version#v}"

    echo -n "Removing DKMS module $_module/$_dkms_version ... "
    if dkms remove "$_module/$_dkms_version" --all > /dev/null; then
      echo "ok"
    else
      # suppress dkms remove failed, shall not to be a problem
      continue
    fi
    echo -n "Cleaning DKMS module source /usr/src/$_module-$_dkms_version ... "
    if rm -rf "/usr/src/$_module-$_dkms_version"; then
      echo "ok"
    else
      # also suppress this
      continue
    fi
  done
}

dkms_ldtarball() {
  local _tarball="$1"

  # dkms variables
  local PACKAGE_NAME PACKAGE_VERSION MAKE CLEAN
  local BUILT_MODULE_NAME DEST_MODULE_LOCATION AUTOINSTALL

  local _extractdir="$(mktemp -d)"
  tar xf "$_tarball" -C "$_extractdir"
  source "$_extractdir/dkms_source_tree/dkms.conf"

  if [[ -z "$PACKAGE_NAME" || -z "$PACKAGE_VERSION" ]]; then
    error "Malformed DKMS tarball, PACKAGE_NAME or PACKAGE_VERSION is missing."
    exit 22
  fi

  rm -rf "/usr/src/$PACKAGE_NAME-$PACKAGE_VERSION"
  mkdir -p "/usr/src/$PACKAGE_NAME-$PACKAGE_VERSION"
  cp -a "$_extractdir/dkms_source_tree/." "/usr/src/$PACKAGE_NAME-$PACKAGE_VERSION/"
  rm -rf "$_extractdir"

  dkms add "$PACKAGE_NAME/$PACKAGE_VERSION"
}

dkms_install_tarball() {
  local _tarball="$1"

  echo "Installing DKMS module from tarball file $_tarball ... "
  if ! dkms_ldtarball "$_tarball"; then
    error "Failed to install DKMS tarball, please check above output or try to uninstall first."
    return 1
  fi
}


###
# Kernel modules
###

kmod_is_loaded() {
  local _module="$1"

  lsmod | grep -qP '\b'"$_module"'\b'
}

kmod_find_installed() {
  local _module="$1"
  local _kver

  _kver="$(uname -r)"
  find "/lib/modules/$_kver" \
    \( -name "${_module}.ko" \
    -o -name "${_module}.ko.xz" \
    -o -name "${_module}.ko.zst" \
    -o -name "${_module}.ko.gz" \) \
    -print -quit 2>/dev/null
}

dkms_show_build_hint() {
  local _module="$1"
  local _log

  error "DKMS may have failed to build $_module for kernel $(uname -r)."
  for _log in /var/lib/dkms/"$_module"/*/build/make.log; do
    if [[ -f "$_log" ]]; then
      note "Last build log: $_log"
      note "Tail:"
      tail -n 20 "$_log" | sed 's/^/\t/' >&2
      return
    fi
  done
  note "Try: dkms status; dkms install $_module/<version> -k $(uname -r)"
}

kmod_supports_congestion_control() {
  local _congestion_control="$1"
  local _available

  _available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  [[ " $_available " == *" $_congestion_control "* ]]
}

kmod_validate_installed() {
  local _module="$1"
  local _ko _vermagic

  _ko="$(kmod_find_installed "$_module")"
  if [[ -z "$_ko" ]]; then
    return 1
  fi

  _vermagic="$(modinfo -F vermagic "$_ko" 2>/dev/null || true)"
  if [[ -z "$_vermagic" || "${_vermagic%% *}" != "$(uname -r)" ]]; then
    error "Module $_ko does not match the running kernel $(uname -r)."
    [[ -n "$_vermagic" ]] && note "Module vermagic: $_vermagic"
    return 1
  fi
}

kmod_load_if_unloaded() {
  local _module="$1"
  local _ko _err

  if ! kmod_validate_installed "$_module"; then
    dkms_show_build_hint "$DKMS_MODULE_NAME"
    error "No valid ${_module}.ko was built for $(uname -r)."
    return 1
  fi

  if ! kmod_is_loaded "$_module"; then
    _ko="$(kmod_find_installed "$_module")"
    echo -n "Loading kernel module $_module ... "
    _err="$(mktemp)"
    if modprobe "$_module" 2>"$_err"; then
      echo "ok"
      rm -f "$_err"
    else
      error "Failed to load kernel module $_module."
      if [[ -s "$_err" ]]; then
        note "modprobe: $(tr '\n' ' ' < "$_err")"
      fi
      rm -f "$_err"
      if has_command dmesg; then
        note "Recent kernel messages:"
        dmesg 2>/dev/null | tail -n 8 | sed 's/^/\t/' >&2 || true
      fi
      return 1
    fi
  fi

  if ! kmod_is_loaded "$_module"; then
    error "Module $_module is not present in lsmod after modprobe."
    return 1
  fi
  if ! kmod_supports_congestion_control bbrx; then
    error "Module $_module loaded, but bbrx is absent from net.ipv4.tcp_available_congestion_control."
    return 1
  fi
}

KMOD_RESTORE_CONGESTION_CONTROL=""

kmod_release_default_congestion_control() {
  local _module="$1"
  local _current _fallback

  _current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  [[ "$_module" == "$KERNEL_MODULE_NAME" && "$_current" == "bbrx" ]] || return 0

  for _fallback in cubic reno; do
    if kmod_supports_congestion_control "$_fallback"; then
      note "Temporarily switching the default congestion control from bbrx to $_fallback for module reload."
      if sysctl -q -w "net.ipv4.tcp_congestion_control=$_fallback"; then
        KMOD_RESTORE_CONGESTION_CONTROL="bbrx"
        return 0
      fi
    fi
  done

  error "Cannot select a fallback congestion control before unloading $_module."
  return 1
}

kmod_restore_default_congestion_control() {
  if [[ -z "$KMOD_RESTORE_CONGESTION_CONTROL" ]]; then
    return 0
  fi

  if ! kmod_supports_congestion_control "$KMOD_RESTORE_CONGESTION_CONTROL"; then
    error "Cannot restore unavailable congestion control $KMOD_RESTORE_CONGESTION_CONTROL."
    return 1
  fi
  if ! sysctl -q -w "net.ipv4.tcp_congestion_control=$KMOD_RESTORE_CONGESTION_CONTROL"; then
    error "Cannot restore congestion control $KMOD_RESTORE_CONGESTION_CONTROL."
    return 1
  fi
  note "Restored the default congestion control to $KMOD_RESTORE_CONGESTION_CONTROL."
  KMOD_RESTORE_CONGESTION_CONTROL=""
}

kmod_unload_if_loaded() {
  local _module="$1"

  if kmod_is_loaded "$_module"; then
    if ! kmod_release_default_congestion_control "$_module"; then
      return 1
    fi

    echo -n "Unloading kernel module $_module ... "
    if rmmod "$_module"; then
      echo "ok"
    else
      error "Failed to unload kernel module, kernel module might be occupied by active sockets or another process."
      error "Stop services using bbrx, or reboot the server to activate the updated module."
      kmod_restore_default_congestion_control || true
      return 1
    fi
  fi
}

kmod_setup_autoload() {
  local _module="$1"

  echo -n "Enabling auto load kernel module $_module on system boot ... "
  if echo "$_module" > "/etc/modules-load.d/$_module.conf"; then
    echo "ok"
  else
    warning "Failed to enable auto load $_module on system boot."
  fi
}

kmod_unsetup_autoload() {
  local _module="$1"

  echo -n "Disabling auto load kernel module $_module on system boot ... "
  if rm -f "/etc/modules-load.d/$_module.conf"; then
    echo "ok"
  else
    warning "Failed to disable auto load $_module on system boot."
  fi
}

###
# API
###

# Print "owner/repo" for https://github.com/<owner>/<repo>(.git|/)
github_owner_repo_from_url() {
  local _u="${REPO_URL%.git}"
  _u="${_u%/}"
  if [[ "$_u" =~ github\.com/([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

get_latest_version() {
  if [[ -n "$VERSION" ]]; then
    echo "$VERSION"
    return
  fi

  local _repo_path
  if ! _repo_path="$(github_owner_repo_from_url)"; then
    error "REPO_URL is not a supported GitHub repository URL: $REPO_URL"
    exit 11
  fi

  local _tmpfile
  _tmpfile=$(mktemp)
  local _api="https://api.github.com/repos/${_repo_path}/releases/latest"
  if ! curl -sS "$_api" \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: tcp-bbrx-install-dkms-script' \
      -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    error "Failed to fetch the latest release from GitHub (${_api}), please check your network and try again."
    exit 11
  fi

  local _latest_version
  _latest_version=$(grep -oP '"tag_name"\s*:\s*"\K[^"]+' "$_tmpfile" | head -1)
  rm -f "$_tmpfile"

  if [[ -z "$_latest_version" ]]; then
    error "Failed to parse tag_name from GitHub API response (no releases or unexpected JSON)."
    exit 11
  fi

  echo "$_latest_version"
}

download_dkms_tarball() {
  local _version="$1"
  local _destination="$2"

  local _download_url="$REPO_URL/releases/download/$_version/tcp-bbrx.dkms.tar.gz"
  echo "Downloading DKMS tarball: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "Download failed, please check your network and try again."
    return 11
  fi
  return 0
}


###
# ENTRY
###

perform_install() {
  local _local_file=""
  local _user_provided_local_file=""
  local _version=""
  local _install_needed=""

  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--force' | '-f')
        _install_needed="1"
        ;;
      '--local' | '-l')
        shift
        if [[ "x$1" == "x--" ]]; then
          shift
          _local_file="$1"
        elif has_prefix "$1" "-"; then
          _local_file=""
        else
          _local_file="$1"
        fi
        if [[ -z "$_local_file" ]]; then
          show_argument_error_and_exit "Please specify the local dkms.tar file to install for option '-l' or '--local'."
        fi
        _install_needed="1"
        _user_provided_local_file="1"
        ;;
      '--version')
        shift
        if [[ "x$1" == "x--" ]]; then
          shift
          _version="$1"
        elif has_prefix "$1" "-"; then
          _version=""
        else
          _version="$1"
        fi
        if [[ -z "$_version" ]]; then
          show_argument_error_and_exit "Please specify the version for option '--version'."
        fi
        ;;
      *)
        show_argument_error_and_exit "Unrecognized option '$1' for subcommand 'install'."
        ;;
    esac
    shift
  done

  if [[ -n "$_local_file" && -n "$_version" ]]; then
    show_argument_error_and_exit "'--version' and '--local' cannot be used together."
  fi

  # check installed version
  echo "Cleaning old installations ... "
  dkms_remove_modules "$DKMS_MODULE_NAME" "1"

  echo -n "Checking installed version ... "
  local _installed_version="$(dkms_get_installed_versions "$DKMS_MODULE_NAME" | head -1)"
  if [[ -n "$_installed_version" ]]; then
    echo "$_installed_version"
  else
    echo "not installed"
  fi

  if [[ -z "$_local_file" && -z "$_version" ]]; then
    echo -n "Checking latest version ... "
    local _latest_version=$(get_latest_version)
    if [[ -n "$_latest_version" ]]; then
      echo "$_latest_version"
      _version="$_latest_version"
    fi
  fi

  if [[ -z "$_local_file" && -n "$_version" ]]; then
    local _vercmp="$(vercmp "$_installed_version" "$_version")"
    if [[ "$_vercmp" -lt "0" ]]; then
      _install_needed="1"
    fi
    if [[ -n "$_install_needed" ]]; then
      local _download_destination="$(mktemp).tar.gz"
      download_dkms_tarball "$_version" "$_download_destination"
      _local_file="$_download_destination"
    fi
  fi

  if [[ -n "$_install_needed" ]]; then
    # remove all installed version as DKMS not allowed to overwrite a installed module
    dkms_remove_modules "$DKMS_MODULE_NAME" ""
    dkms_install_tarball "$_local_file"
  fi

  if [[ -z "$_user_provided_local_file" && -n "$_local_file" ]]; then
    # clean auto downloaded tarball
    rm -f "$_local_file"
  fi

  echo "Rebuilding DKMS modules as needed ... "
  if ! dkms autoinstall -k "$(uname -r)"; then
    dkms_show_build_hint "$DKMS_MODULE_NAME"
    error "DKMS failed to build modules for $(uname -r)."
    exit 2
  fi

  if ! kmod_validate_installed "$KERNEL_MODULE_NAME"; then
    dkms_show_build_hint "$DKMS_MODULE_NAME"
    error "tcp-bbrx DKMS package is present but a valid ${KERNEL_MODULE_NAME}.ko was not built for $(uname -r)."
    error "Install linux-headers-$(uname -r), then run: dkms install $DKMS_MODULE_NAME/<version> -k $(uname -r)"
    exit 2
  fi

  kmod_setup_autoload "$KERNEL_MODULE_NAME"

  if [[ -z "$_install_needed" ]]; then
    if ! kmod_load_if_unloaded "$KERNEL_MODULE_NAME"; then
      error "tcp-bbrx is installed but failed validation or loading."
      exit 2
    fi

    echo "${tbold}There is nothing to do today.${treset}"
    exit 0
  fi

  if ! kmod_unload_if_loaded "$KERNEL_MODULE_NAME"; then
    warning "tcp-bbrx is successfully update, but occupied by other process, please reboot your server to active the latest change."
    exit 0
  fi

  if ! kmod_load_if_unloaded "$KERNEL_MODULE_NAME"; then
    error "tcp-bbrx is successfully installed, but failed to load, this might cause by mismatched linux-headers."
    error "If you update your system recently, reboot the system might solve this."
    exit 2
  fi
  if ! kmod_restore_default_congestion_control; then
    exit 2
  fi

  if [[ -z "$_version" ]]; then
    _version="$(dkms_get_installed_versions "$DKMS_MODULE_NAME" | head -1)"
  fi

  echo
  echo -e "${tbold}Congratulation! tcp-bbrx $_version has been successfully installed and loaded on your server.${treset}"
}

perform_uninstall() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      *)
        show_argument_error_and_exit "Unrecognized option '$1' for subcommand 'uninstall'."
        ;;
    esac
    shift
  done

  kmod_unsetup_autoload "$KERNEL_MODULE_NAME"

  dkms_remove_modules "$DKMS_MODULE_NAME" ""

  if ! kmod_unload_if_loaded "$KERNEL_MODULE_NAME"; then
    warning "tcp-bbrx is successfully uninstall from your server, but failed to unload from the kernel."
    warning "Please reboot your system to unload it from the kernel."
    exit 0
  fi

  echo
  echo -e "${tbold}Congratulation! tcp-bbrx has been successfully uninstalled and unloaded."
}

perform_check() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      *)
        show_argument_error_and_exit "Unrecognized option '$1' for subcommand 'check'."
        ;;
    esac
    shift
  done

  echo -n "Checking kernel module ... "
  if kmod_is_loaded "$KERNEL_MODULE_NAME"; then
    echo "loaded"
  else
    echo "not loaded"
  fi

  echo -n "Checking installed version ... "
  local _installed_versions=($(dkms_get_installed_versions "$DKMS_MODULE_NAME"))
  if [[ "${#_installed_versions[@]}" -eq "0" ]]; then
    echo "not installed"
  elif [[ "${#_installed_versions[@]}" -eq "1" ]]; then
    echo "${_installed_versions[0]}"
  else
    echo "multiple version installed"
    for version in "${_installed_versions[@]}"; do
      echo -e "\tFound $version"
    done
  fi

  echo -n "Checking latest version ... "
  local _latest_version=$(get_latest_version)
  if [[ -n "$_latest_version" ]]; then
    echo "$_latest_version"
  fi
}

perform_reload() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      *)
        show_argument_error_and_exit "Unrecognized option '$1' for subcommand 'reload'."
        ;;
    esac
    shift
  done

  kmod_unload_if_loaded "$KERNEL_MODULE_NAME"
  kmod_load_if_unloaded "$KERNEL_MODULE_NAME"
  kmod_restore_default_congestion_control
}

perform_unload() {
  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      *)
        show_argument_error_and_exit "Unrecognized option '$1' for subcommand 'unload'."
        ;;
    esac
    shift
  done

  kmod_unload_if_loaded "$KERNEL_MODULE_NAME"
}

main() {
  check_show_usage_and_exit "$@"

  check_permission
  check_environment

  case "$1" in
    "install")
      shift
      perform_install "$@"
      ;;
    "uninstall" | "remove")
      shift
      perform_uninstall "$@"
      ;;
    "check" | "status")
      shift
      perform_check "$@"
      ;;
    "load" | "reload")
      shift
      perform_reload "$@"
      ;;
    "unload")
      shift
      perform_unload "$@"
      ;;
    *)
      # default action
      perform_install "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

# vim:set ft=bash ts=2 sw=2 sts=2 et:
