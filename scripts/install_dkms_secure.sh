#!/usr/bin/env bash
#
# install_dkms_secure.sh - tcp-bbrx DKMS install for Debian 13 / Ubuntu 26+
#
# Adds Secure Boot MOK setup and DKMS module signing on top of install_dkms.sh.
# Try `install_dkms_secure.sh --help` for usage.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2023 Aperture Internet Laboratory
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=install_dkms.sh
source "$SCRIPT_DIR/install_dkms.sh"

SCRIPT_INITIATOR_URL="https://tcp.hy2.sh/install_dkms_secure.sh"
SCRIPT_INITIATOR_COMMAND="bash <(curl -fsSL $SCRIPT_INITIATOR_URL)"

MOK_KEY="/var/lib/dkms/mok.key"
MOK_CERT="/var/lib/dkms/mok.pub"
DKMS_SIGNING_CONF="/etc/dkms/framework.conf.d/signing.conf"

is_target_distro() {
  if [[ ! -f /etc/os-release ]]; then
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    debian)
      if [[ "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] && [[ "${VERSION_ID%%.*}" -ge 13 ]]; then
        return 0
      fi
      [[ "${VERSION_CODENAME:-}" == "trixie" ]] && return 0
      ;;
    ubuntu)
      if [[ "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] && [[ "${VERSION_ID%%.*}" -ge 26 ]]; then
        return 0
      fi
      ;;
  esac

  return 1
}

is_secure_boot_enabled() {
  if ! has_command mokutil; then
    return 1
  fi

  mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

ensure_mokutil() {
  if has_command mokutil; then
    return 0
  fi

  install_software mokutil
}

ensure_dkms_mok_keys() {
  if [[ -f "$MOK_KEY" && -f "$MOK_CERT" ]]; then
    return 0
  fi

  note "Generating DKMS MOK signing key pair at $MOK_KEY ..."
  install -d -m 755 /var/lib/dkms
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "$MOK_KEY" -outform DER \
    -out "$MOK_CERT" -nodes -days 36500 \
    -subj "/CN=DKMS module signing key/"
  chmod 600 "$MOK_KEY"
  chmod 644 "$MOK_CERT"
}

ensure_dkms_signing_conf() {
  install -d -m 755 /etc/dkms/framework.conf.d

  if [[ -f "$DKMS_SIGNING_CONF" ]] \
      && grep -qF "$MOK_KEY" "$DKMS_SIGNING_CONF" 2>/dev/null \
      && grep -qF "$MOK_CERT" "$DKMS_SIGNING_CONF" 2>/dev/null; then
    return 0
  fi

  note "Writing DKMS signing config to $DKMS_SIGNING_CONF ..."
  cat > "$DKMS_SIGNING_CONF" <<EOF
# Managed by install_dkms_secure.sh (Debian 13 / Ubuntu 26+ Secure Boot)
mok_signing_key="$MOK_KEY"
mok_certificate="$MOK_CERT"
EOF
}

is_mok_enrolled() {
  if ! has_command mokutil; then
    return 1
  fi

  mokutil --list-enrolled 2>/dev/null | grep -qF "CN=DKMS module signing key"
}

kmod_is_signed() {
  local _module="$1"
  local _ko _signer

  _ko="$(kmod_find_installed "$_module")"
  if [[ -z "$_ko" ]]; then
    return 1
  fi

  _signer="$(modinfo "$_ko" 2>/dev/null | grep -m1 '^signer:' | cut -d: -f2- | sed 's/^[[:space:]]*//')"
  [[ -n "$_signer" && "$_signer" != "~" ]]
}

secure_boot_hint() {
  note "Secure Boot is enabled but the module could not be loaded."
  note "1) Enroll MOK: sudo mokutil --import $MOK_CERT"
  note "2) Reboot and complete enrollment in MOK Manager"
  note "3) Rebuild: sudo $(script_name 1) install -f"
  note "Or run: sudo $(script_name 1) --enroll-mok"
}

setup_secure_boot() {
  if ! is_secure_boot_enabled; then
    note "Secure Boot is disabled; DKMS signing setup skipped."
    return 0
  fi

  note "Secure Boot is enabled; configuring DKMS module signing ..."
  ensure_mokutil
  ensure_dkms_mok_keys
  ensure_dkms_signing_conf

  if is_mok_enrolled; then
    note "MOK certificate is enrolled in UEFI."
    return 0
  fi

  warning "MOK certificate is not enrolled in UEFI yet."
  note "Modules will be signed at build time but cannot load until MOK is enrolled."
  note "Run: sudo $(script_name 1) --enroll-mok"
}

enroll_mok_key() {
  ensure_mokutil
  ensure_dkms_mok_keys

  if is_mok_enrolled; then
    note "MOK certificate is already enrolled."
    return 0
  fi

  echo -n "Importing MOK certificate into firmware ... "
  if mokutil --import "$MOK_CERT"; then
    echo "ok"
  else
    error "Failed to import MOK certificate."
    return 1
  fi

  note "Reboot the system and enroll the key in MOK Manager."
  note "Then rebuild signed modules: sudo $(script_name 1) install -f"
}

check_environment() {
  check_environment_operating_system

  if ! is_target_distro; then
    warning "This script targets Debian 13 (trixie) and Ubuntu 26+."
    warning "Secure Boot signing may still work on other releases; continuing."
  fi

  check_environment_curl
  check_environment_grep
  check_environment_dkms
  check_linux_headers
  setup_secure_boot
}

kmod_load_if_unloaded() {
  local _module="$1"

  if ! kmod_is_loaded "$_module"; then
    if is_secure_boot_enabled && ! is_mok_enrolled; then
      warning "Secure Boot is on and MOK is not enrolled; module load will likely fail."
    fi
  fi

  if ! kmod_is_loaded "$_module"; then
    local _ko _err

    _ko="$(kmod_find_installed "$_module")"
    if [[ -z "$_ko" ]]; then
      dkms_show_build_hint "$DKMS_MODULE_NAME"
      error "No ${_module}.ko found under /lib/modules/$(uname -r)/ — module was not built."
      return 1
    fi

    if is_secure_boot_enabled && ! kmod_is_signed "$_module"; then
      warning "Module exists but appears unsigned; rebuilding with DKMS signing ..."
      if dkms autoinstall; then
        _ko="$(kmod_find_installed "$_module")"
      fi
    fi

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
      if is_secure_boot_enabled; then
        secure_boot_hint
      fi
      return 1
    fi
  fi
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

  echo -n "Checking Secure Boot ... "
  if is_secure_boot_enabled; then
    echo "enabled"
  else
    echo "disabled"
  fi

  echo -n "Checking MOK enrollment ... "
  if is_mok_enrolled; then
    echo "enrolled"
  else
    echo "not enrolled"
  fi

  echo -n "Checking module signature ... "
  if kmod_is_signed "$KERNEL_MODULE_NAME"; then
    modinfo "$(kmod_find_installed "$KERNEL_MODULE_NAME")" 2>/dev/null \
      | grep -m1 '^signer:' | sed 's/^signer:[[:space:]]*/signer: /'
  else
    echo "unsigned or not installed"
  fi

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
  local _latest_version
  _latest_version=$(get_latest_version)
  if [[ -n "$_latest_version" ]]; then
    echo "$_latest_version"
  fi
}

show_usage_and_exit() {
  echo
  echo -e "\t${tbold}$(script_name)${treset} - tcp-bbrx DKMS install (Debian 13 / Ubuntu 26+ Secure Boot)"
  echo
  echo -e "Usage:"
  echo
  echo -e "${tbold}Install tcp-bbrx${treset}"
  echo -e "\t$(script_name) [install] [ -f | -l <file> | --version <version> ]"
  echo -e "Options:"
  echo -e "\t-f, --force\tForce re-install latest or specified version even if it has been installed."
  echo -e "\t-l, --local <file>\tInstall specified DKMS tarball instead of download it."
  echo -e "\t--version <version>\tInstall specified version instead of the latest."
  echo -e "\t--enroll-mok\tImport the DKMS MOK certificate (reboot required to finish enrollment)."
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

main_secure() {
  local _enroll_mok=""
  local _args=()

  while [[ "$#" -gt '0' ]]; do
    case "$1" in
      '--enroll-mok')
        _enroll_mok="1"
        ;;
      *)
        _args+=("$1")
        ;;
    esac
    shift
  done

  if [[ -n "$_enroll_mok" ]]; then
    check_permission
    check_environment_operating_system
    ensure_mokutil
    enroll_mok_key
    exit $?
  fi

  main "${_args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_secure "$@"
fi

# vim:set ft=bash ts=2 sw=2 sts=2 et:
