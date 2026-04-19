#!/usr/bin/env bash
# lib/packages.sh — Package manager detection, installation, and validation.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

detect_package_manager() {
  local pm
  for pm in pacman apt dnf zypper; do
    if command -v "${pm}" >/dev/null 2>&1; then
      printf '%s\n' "${pm}"
      return 0
    fi
  done
  printf 'unknown\n'
}

packages_for_manager() {
  local manager="$1"
  case "${manager}" in
    pacman)
      printf '%s\n' "qemu-full virt-manager virt-install dnsmasq bridge-utils edk2-ovmf swtpm pciutils libvirt mkinitcpio xorriso jq curl file libarchive p7zip"
      ;;
    apt)
      printf '%s\n' "qemu-system-x86 qemu-utils virt-manager virtinst dnsmasq-base bridge-utils ovmf swtpm-tools pciutils libvirt-daemon-system libvirt-clients xorriso jq curl file libarchive-tools p7zip-full looking-glass-client"
      ;;
    dnf)
      printf '%s\n' "qemu-kvm qemu-img virt-manager virt-install dnsmasq bridge-utils edk2-ovmf swtpm pciutils libvirt libvirt-daemon-config-network xorriso jq curl file bsdtar p7zip looking-glass-client"
      ;;
    zypper)
      printf '%s\n' "qemu-kvm qemu-tools virt-manager virt-install dnsmasq bridge-utils ovmf swtpm pciutils libvirt xorriso jq curl file libarchive p7zip"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

package_manager_note() {
  local manager="$1"
  case "${manager}" in
    pacman)
      printf '%s\n' "AUR/yay is not required for the default toolchain."
      printf '%s\n' "Note: looking-glass-client is in the AUR and must be installed manually."
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

install_packages() {
  local manager="$1"
  shift
  case "${manager}" in
    pacman)
      run pacman -Syu --needed "$@"
      ;;
    apt)
      run apt update
      run apt install -y "$@"
      ;;
    dnf)
      run dnf install -y "$@"
      ;;
    zypper)
      run zypper --non-interactive install "$@"
      ;;
    *)
      fail "Unsupported package manager for automatic installs."
      ;;
  esac
}

check_commands_present() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

post_install_validation() {
  local manager="$1"
  local required_commands recommended_commands missing_required=() missing_recommended=()
  local required_units missing_units=() unit

  required_commands=(
    awk sed grep curl jq file lspci lsmod modprobe virsh systemctl
  )
  recommended_commands=(
    virt-install qemu-img xorriso
  )

  if [[ "${manager}" == "pacman" ]]; then
    recommended_commands+=(mkinitcpio)
  fi

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    if ! systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
      missing_units+=("${unit}")
    fi
  done < <(printf '%s\n' libvirtd.service libvirtd.socket)

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    missing_required+=("${unit}")
  done < <(check_commands_present "${required_commands[@]}" || true)

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    missing_recommended+=("${unit}")
  done < <(check_commands_present "${recommended_commands[@]}" || true)

  if (( ${#missing_units[@]} > 0 )); then
    fail "Missing expected libvirt unit files after package install: ${missing_units[*]}"
  fi
  if (( ${#missing_required[@]} > 0 )); then
    fail "Missing required commands after package install: ${missing_required[*]}"
  fi
  if (( ${#missing_recommended[@]} > 0 )); then
    warn "Still missing recommended commands after package install: ${missing_recommended[*]}"
  fi
}

preflight_dependencies() {
  local manager missing_required=() missing_recommended=() pkg_list manager_note
  local required_commands recommended_commands cmd

  required_commands=(
    awk sed grep curl jq file lspci lsmod modprobe virsh systemctl
  )
  recommended_commands=(
    virt-install qemu-img xorriso
  )
  if [[ "$(detect_package_manager)" == "pacman" ]]; then
    recommended_commands+=(mkinitcpio)
  fi

  for cmd in "${required_commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing_required+=("${cmd}")
  done
  for cmd in "${recommended_commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing_recommended+=("${cmd}")
  done

  if (( ${#missing_required[@]} == 0 && ${#missing_recommended[@]} == 0 )); then
    return 0
  fi

  manager="$(detect_package_manager)"
  pkg_list="$(packages_for_manager "${manager}")"
  manager_note="$(package_manager_note "${manager}")"

  if (( ${#missing_required[@]} > 0 )); then
    warn "Missing required commands: ${missing_required[*]}"
  fi
  if (( ${#missing_recommended[@]} > 0 )); then
    warn "Missing recommended commands: ${missing_recommended[*]}"
  fi

  if [[ -n "${pkg_list}" ]]; then
    printf 'Suggested packages for %s:\n  %s\n' "${manager}" "${pkg_list}" >&2
    [[ -n "${manager_note}" ]] && printf '%s\n' "${manager_note}" >&2
    if confirm "Install the suggested packages now?" "y"; then
      # shellcheck disable=SC2206
      local pkgs=( ${pkg_list} )
      install_packages "${manager}" "${pkgs[@]}"
      post_install_validation "${manager}"
    fi
  else
    warn "Could not determine install package names automatically."
  fi

  for cmd in "${required_commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required command after preflight: ${cmd}"
  done
  if [[ "${manager}" != "unknown" ]]; then
    post_install_validation "${manager}"
  fi
}
