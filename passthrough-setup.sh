#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/etc/passthrough"
BACKUP_DIR="${STATE_DIR}/backups"
STATE_FILE="${STATE_DIR}/passthrough.conf"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
WINDOWS_ISO_URL="https://www.microsoft.com/en-us/software-download/windows11"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/"
DOCKUR_WINDOWS_SRC="${DOCKUR_WINDOWS_SRC:-/home/${SUDO_USER:-${USER}}/github/windows/src}"
WINHANCE_SOURCE_XML="${WINHANCE_SOURCE_XML:-/home/${SUDO_USER:-${USER}}/Downloads/autounattend.xml}"
WINHANCE_SOURCE_URL="${WINHANCE_SOURCE_URL:-https://raw.githubusercontent.com/memstechtips/UnattendedWinstall/main/autounattend.xml}"
WINHANCE_CACHE_XML="${WINHANCE_CACHE_XML:-/etc/passthrough/source-cache/winhance-autounattend.xml}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

ui_hr() {
  printf '%b\n' "${C_DIM}------------------------------------------------------------------------${C_RESET}"
}

ui_space() {
  printf '\n'
}

ui_section() {
  ui_space
  ui_hr
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}"
  ui_hr
}

ui_kv() {
  printf '  %b%-20s%b %s\n' "${C_DIM}" "$1" "${C_RESET}" "$2"
}

ui_note() {
  printf '%b%s%b\n' "${C_DIM}" "$1" "${C_RESET}"
}

ui_banner() {
  ui_hr
  printf '%bOne-Click Passthrough%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
  printf '%bInteractive Windows GPU passthrough setup%b\n' "${C_DIM}" "${C_RESET}"
  ui_hr
}

log() {
  printf '%b[%s]%b %s\n' "${C_BLUE}" "${SCRIPT_NAME}" "${C_RESET}" "$*"
}

warn() {
  printf '%b[%s] WARN:%b %s\n' "${C_YELLOW}" "${SCRIPT_NAME}" "${C_RESET}" "$*" >&2
}

fail() {
  printf '%b[%s] ERROR:%b %s\n' "${C_RED}" "${SCRIPT_NAME}" "${C_RESET}" "$*" >&2
  exit 1
}

run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
Usage: passthrough-setup.sh [--dry-run]

Interactive installer for single-GPU and dedicated VFIO passthrough.
It targets Arch-like hosts with either GRUB or systemd-boot and edits:

  - /etc/default/grub or /etc/kernel/cmdline
  - /etc/mkinitcpio.conf
  - /etc/modprobe.d/*.conf
  - /etc/libvirt/*
  - /etc/libvirt/hooks/*
  - /etc/systemd/system/passthrough-postboot.service
  - /usr/local/bin/passthrough-*

Run as root.
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run this script as root."
}

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
      printf '%s\n' "qemu-system-x86 qemu-utils virt-manager virtinst dnsmasq-base bridge-utils ovmf swtpm-tools pciutils libvirt-daemon-system libvirt-clients xorriso jq curl file libarchive-tools p7zip-full"
      ;;
    dnf)
      printf '%s\n' "qemu-kvm qemu-img virt-manager virt-install dnsmasq bridge-utils edk2-ovmf swtpm pciutils libvirt libvirt-daemon-config-network xorriso jq curl file bsdtar p7zip"
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
      run pacman -Sy --needed "$@"
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

ensure_dir() {
  [[ -d "$1" ]] || run mkdir -p "$1"
}

backup_file() {
  local file="$1"
  [[ -e "${file}" ]] || return 0
  ensure_dir "${BACKUP_DIR}"
  run cp -a "${file}" "${BACKUP_DIR}/$(basename "${file}").${TIMESTAMP}.bak"
}

write_file() {
  local path="$1"
  shift
  ensure_dir "$(dirname "${path}")"
  backup_file "${path}"
  if (( DRY_RUN )); then
    printf '[dry-run] write %s\n' "${path}"
    return 0
  fi
  printf '%s' "$1" > "${path}"
}

available_space_gb() {
  local target="${1:-/var/lib/libvirt/images}"
  df -BG "${target}" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4; exit}'
}

required_space_gb() {
  local disk_size_gb="${1:-64}"
  local iso_overhead_gb="${2:-10}"
  printf '%s\n' "$((disk_size_gb + iso_overhead_gb))"
}

check_disk_space() {
  local target="$1"
  local disk_size_gb="$2"
  local existing_disk_path="${3:-}"
  local required available
  if [[ -n "${existing_disk_path}" && -f "${existing_disk_path}" ]]; then
    required="10"
  else
    required="$(required_space_gb "${disk_size_gb}" "10")"
  fi
  available="$(available_space_gb "${target}" || true)"
  [[ -n "${available}" ]] || {
    warn "Could not determine free disk space for ${target}"
    return 0
  }
  if (( available < required )); then
    if [[ -n "${existing_disk_path}" && -f "${existing_disk_path}" ]]; then
      fail "Insufficient free space at ${target}: ${available}G available, ${required}G required (~10G install media overhead while reusing existing VM disk ${existing_disk_path})."
    fi
    fail "Insufficient free space at ${target}: ${available}G available, ${required}G required (${disk_size_gb}G VM disk + ~10G install media overhead)."
  fi
}

detect_cpu_vendor() {
  local vendor
  vendor="$(awk -F: '/vendor_id/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
  case "${vendor}" in
    GenuineIntel) printf 'intel\n' ;;
    AuthenticAMD) printf 'amd\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

normalize_windows_version() {
  local version="${1:-}"
  version="$(printf '%s' "${version}" | tr '[:upper:]' '[:lower:]')"
  version="$(printf '%s' "${version}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "${version}" ]] && version="win11x64"

  case "${version}" in
    11|11p|win11|pro11|win11p|windows11|"windows 11")
      printf 'win11x64\n'
      ;;
    11e|win11e|windows11e|"windows 11e")
      printf 'win11x64-enterprise-eval\n'
      ;;
    11i|11iot|iot11|win11i|win11-iot|win11x64-iot)
      printf 'win11x64-enterprise-iot-eval\n'
      ;;
    11l|11ltsc|ltsc11|win11l|win11-ltsc|win11x64-ltsc)
      printf 'win11x64-enterprise-ltsc-eval\n'
      ;;
    10|10p|win10|pro10|win10p|windows10|"windows 10")
      printf 'win10x64\n'
      ;;
    10e|win10e|windows10e|"windows 10e")
      printf 'win10x64-enterprise-eval\n'
      ;;
    10l|10ltsc|ltsc10|win10l|win10-ltsc|win10x64-ltsc)
      printf 'win10x64-enterprise-ltsc-eval\n'
      ;;
    2025|win2025|windows2025|"windows 2025")
      printf 'win2025-eval\n'
      ;;
    2022|win2022|windows2022|"windows 2022")
      printf 'win2022-eval\n'
      ;;
    2019|win2019|windows2019|"windows 2019")
      printf 'win2019-eval\n'
      ;;
    2016|win2016|windows2016|"windows 2016")
      printf 'win2016-eval\n'
      ;;
    *)
      printf '%s\n' "${version}"
      ;;
  esac
}

normalize_windows_language() {
  local lang="${1:-en}"
  lang="$(printf '%s' "${lang}" | tr '[:upper:]' '[:lower:]')"
  lang="${lang//_/-}"
  case "${lang}" in
    ""|en|en-us|english) printf 'en\n' ;;
    gb|en-gb|british) printf 'en-gb\n' ;;
    ar|arabic) printf 'ar\n' ;;
    de|german|deutsch) printf 'de\n' ;;
    es|spanish|espanol|español) printf 'es\n' ;;
    fr|french|francais|français) printf 'fr\n' ;;
    it|italian|italiano) printf 'it\n' ;;
    ja|jp|japanese) printf 'ja\n' ;;
    ko|kr|korean) printf 'ko\n' ;;
    nl|dutch) printf 'nl\n' ;;
    pl|polish) printf 'pl\n' ;;
    pt|pt-br|br|portuguese|portugues|português) printf 'pt-br\n' ;;
    ru|russian) printf 'ru\n' ;;
    tr|turkish) printf 'tr\n' ;;
    uk|ua|ukrainian) printf 'uk\n' ;;
    zh|cn|chinese) printf 'zh\n' ;;
    *) printf '%s\n' "${lang}" ;;
  esac
}

windows_language_name() {
  case "$1" in
    ar) printf 'Arabic\n' ;;
    de) printf 'German\n' ;;
    en-gb) printf 'English International\n' ;;
    en) printf 'English\n' ;;
    es) printf 'Spanish\n' ;;
    fr) printf 'French\n' ;;
    it) printf 'Italian\n' ;;
    ja) printf 'Japanese\n' ;;
    ko) printf 'Korean\n' ;;
    nl) printf 'Dutch\n' ;;
    pl) printf 'Polish\n' ;;
    pt-br) printf 'Brazilian Portuguese\n' ;;
    ru) printf 'Russian\n' ;;
    tr) printf 'Turkish\n' ;;
    uk) printf 'Ukrainian\n' ;;
    zh) printf 'Chinese (Simplified)\n' ;;
    *) printf 'English\n' ;;
  esac
}

windows_language_desc() {
  case "$1" in
    ar) printf 'Arabic\n' ;;
    de) printf 'German\n' ;;
    en-gb|en) printf 'English\n' ;;
    es) printf 'Spanish\n' ;;
    fr) printf 'French\n' ;;
    it) printf 'Italian\n' ;;
    ja) printf 'Japanese\n' ;;
    ko) printf 'Korean\n' ;;
    nl) printf 'Dutch\n' ;;
    pl) printf 'Polish\n' ;;
    pt-br) printf 'Portuguese\n' ;;
    ru) printf 'Russian\n' ;;
    tr) printf 'Turkish\n' ;;
    uk) printf 'Ukrainian\n' ;;
    zh) printf 'Chinese\n' ;;
    *) printf 'English\n' ;;
  esac
}

windows_language_culture() {
  case "$1" in
    ar) printf 'ar-SA\n' ;;
    de) printf 'de-DE\n' ;;
    en-gb) printf 'en-GB\n' ;;
    en) printf 'en-US\n' ;;
    es) printf 'es-ES\n' ;;
    fr) printf 'fr-FR\n' ;;
    it) printf 'it-IT\n' ;;
    ja) printf 'ja-JP\n' ;;
    ko) printf 'ko-KR\n' ;;
    nl) printf 'nl-NL\n' ;;
    pl) printf 'pl-PL\n' ;;
    pt-br) printf 'pt-BR\n' ;;
    ru) printf 'ru-RU\n' ;;
    tr) printf 'tr-TR\n' ;;
    uk) printf 'uk-UA\n' ;;
    zh) printf 'zh-CN\n' ;;
    *) printf 'en-US\n' ;;
  esac
}

prompt_windows_version() {
  local default="${1:-win11x64}"
  local options=(
    "Windows 11 Pro/Enterprise [win11x64]"
    "Windows 11 Enterprise Eval [win11x64-enterprise-eval]"
    "Windows 11 LTSC [win11x64-ltsc]"
    "Windows 10 Pro/Enterprise [win10x64]"
    "Windows 10 Enterprise Eval [win10x64-enterprise-eval]"
    "Windows Server 2022 Eval [win2022eval]"
  )
  local default_index="1"

  case "${default}" in
    win11x64-enterprise-eval) default_index="2" ;;
    win11x64-ltsc) default_index="3" ;;
    win10x64) default_index="4" ;;
    win10x64-enterprise-eval) default_index="5" ;;
    win2022eval) default_index="6" ;;
  esac

  case "$(prompt_menu_choice "Windows version" "${default_index}" "${options[@]}")" in
    *"[win11x64]") printf 'win11x64\n' ;;
    *"[win11x64-enterprise-eval]") printf 'win11x64-enterprise-eval\n' ;;
    *"[win11x64-ltsc]") printf 'win11x64-ltsc\n' ;;
    *"[win10x64]") printf 'win10x64\n' ;;
    *"[win10x64-enterprise-eval]") printf 'win10x64-enterprise-eval\n' ;;
    *"[win2022eval]") printf 'win2022eval\n' ;;
    *) fail "Unexpected Windows version selection." ;;
  esac
}

prompt_windows_language() {
  local default="${1:-en}"
  local options=(
    "English (US) [en]"
    "English (UK) [en-gb]"
    "German [de]"
    "French [fr]"
    "Japanese [ja]"
  )
  local default_index="1"

  case "${default}" in
    en-gb) default_index="2" ;;
    de) default_index="3" ;;
    fr) default_index="4" ;;
    ja) default_index="5" ;;
  esac

  case "$(prompt_menu_choice "Windows language" "${default_index}" "${options[@]}")" in
    *"[en]") printf 'en\n' ;;
    *"[en-gb]") printf 'en-gb\n' ;;
    *"[de]") printf 'de\n' ;;
    *"[fr]") printf 'fr\n' ;;
    *"[ja]") printf 'ja\n' ;;
    *) fail "Unexpected Windows language selection." ;;
  esac
}

discover_ovmf_code() {
  local candidate
  for candidate in \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/x64/OVMF_CODE.fd; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done
  return 1
}

discover_ovmf_vars() {
  local candidate
  for candidate in \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/OVMF/x64/OVMF_VARS.fd; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done
  return 1
}

discover_virtio_iso() {
  local candidate pattern
  for candidate in \
    /var/lib/libvirt/boot/virtio-win.iso \
    /var/lib/libvirt/images/virtio-win.iso; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done

  for pattern in \
    "/home/${SUDO_USER:-${USER}}/Downloads/virtio-win*.iso" \
    "/home/${SUDO_USER:-${USER}}/*.iso"; do
    for candidate in ${pattern}; do
      [[ -f "${candidate}" ]] || continue
      case "${candidate}" in
        *virtio*win*.iso|*virtio*.iso)
          printf '%s\n' "${candidate}"
          return 0
          ;;
      esac
    done
  done
  return 1
}

discover_windows_iso() {
  local candidate pattern
  for candidate in \
    /var/lib/libvirt/images/windows-install.iso \
    /var/lib/libvirt/boot/windows-install.iso; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done
  for pattern in \
    "/home/${SUDO_USER:-${USER}}/Downloads/*.iso" \
    "/home/${SUDO_USER:-${USER}}/*.iso"; do
    for candidate in ${pattern}; do
      [[ -f "${candidate}" ]] || continue
      case "${candidate}" in
        *Win11*.iso|*Windows11*.iso|*windows11*.iso|*Windows_11*.iso|*windows_11*.iso)
          printf '%s\n' "${candidate}"
          return 0
          ;;
      esac
    done
  done
  return 1
}

default_iommu_params() {
  case "$1" in
    intel) printf 'intel_iommu=on iommu=pt kvm.ignore_msrs=1\n' ;;
    amd) printf 'amd_iommu=on iommu=pt kvm.ignore_msrs=1\n' ;;
    *) printf 'iommu=pt kvm.ignore_msrs=1\n' ;;
  esac
}

prompt() {
  local message="$1"
  local default="${2:-}"
  local answer
  if [[ -n "${default}" ]]; then
    read -r -p "$(printf '%b›%b %s %b[%s]%b: ' "${C_GREEN}" "${C_RESET}" "${message}" "${C_DIM}" "${default}" "${C_RESET}")" answer
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "$(printf '%b›%b %s: ' "${C_GREEN}" "${C_RESET}" "${message}")" answer
    printf '%s\n' "${answer}"
  fi
}

prompt_menu_choice() {
  local message="$1"
  local default_index="$2"
  shift 2
  local options=("$@")
  local answer selected index

  while :; do
    index=1
    for selected in "${options[@]}"; do
      printf '  %b%2d)%b %s\n' "${C_BLUE}" "${index}" "${C_RESET}" "${selected}" >&2
      index=$((index + 1))
    done
    answer="$(prompt "${message}" "${default_index}")"
    if [[ "${answer}" =~ ^[1-9][0-9]*$ ]]; then
      selected="${options[$((answer - 1))]:-}"
      if [[ -n "${selected}" ]]; then
        printf '%s\n' "${selected}"
        return 0
      fi
    fi
    warn "Choose one of the listed options."
  done
}

prompt_secret() {
  local message="$1"
  local default="${2:-}"
  local answer
  while :; do
    if [[ -n "${default}" ]]; then
      read -r -s -p "$(printf '%b›%b %s %b[hidden, press Enter to keep current]%b: ' "${C_GREEN}" "${C_RESET}" "${message}" "${C_DIM}" "${C_RESET}")" answer
      printf '\n' >&2
      printf '%s\n' "${answer:-$default}"
      return 0
    fi
    read -r -s -p "$(printf '%b›%b %s: ' "${C_GREEN}" "${C_RESET}" "${message}")" answer
    printf '\n' >&2
    [[ -n "${answer}" ]] || {
      warn "${message} cannot be blank."
      continue
    }
    printf '%s\n' "${answer}"
    return 0
  done
}

xml_escape() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s\n' "${value}"
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local suffix='[y/N]'
  local answer
  [[ "${default}" == "y" ]] && suffix='[Y/n]'
  read -r -p "$(printf '%b?%b %s %b%s%b: ' "${C_BLUE}" "${C_RESET}" "${message}" "${C_DIM}" "${suffix}" "${C_RESET}")" answer
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

prompt_windows_iso_strategy() {
  local detected="${1:-}"
  local answer

  while :; do
    ui_section "Windows Media" >&2
    if [[ -n "${detected}" && -f "${detected}" ]]; then
      ui_note "Detected local Windows ISO: ${detected}" >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Windows ISO option" "1" \
        "Use detected ISO" \
        "Enter a different ISO path" \
        "Download Windows ISO automatically")"
      case "${answer}" in
        "Use detected ISO") printf 'detected\n'; return 0 ;;
        "Enter a different ISO path") printf 'manual\n'; return 0 ;;
        "Download Windows ISO automatically") printf 'download\n'; return 0 ;;
      esac
    else
      ui_note "No local Windows ISO was detected." >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Windows ISO option" "1" \
        "Enter a Windows ISO path" \
        "Download Windows ISO automatically")"
      case "${answer}" in
        "Enter a Windows ISO path") printf 'manual\n'; return 0 ;;
        "Download Windows ISO automatically") printf 'download\n'; return 0 ;;
      esac
    fi
    warn "Choose one of the listed Windows ISO options."
  done
}

choose_windows_iso() {
  local detected="${1:-}"
  local version_id="${2:-win11x64}"
  local language_id="${3:-en}"
  local strategy answer

  strategy="$(prompt_windows_iso_strategy "${detected}")"
  case "${strategy}" in
    detected)
      printf '%s\n' "${detected}"
      return 0
      ;;
    manual)
      prompt_iso_path "Windows ISO path" "" "${WINDOWS_ISO_URL}" "1" "${version_id}" "${language_id}"
      return 0
      ;;
    download)
      answer="/var/lib/libvirt/images/windows-install.iso"
      ui_note "Automatic download target: ${answer}" >&2
      if download_windows_iso "${answer}" "${version_id}" "${language_id}" >&2; then
        printf '%s\n' "${answer}"
        return 0
      fi
      warn "Automatic Windows ISO download failed."
      ui_note "Official download page: ${WINDOWS_ISO_URL}" >&2
      prompt_iso_path "Windows ISO path" "" "${WINDOWS_ISO_URL}" "1" "${version_id}" "${language_id}"
      return 0
      ;;
  esac

  fail "Could not determine how to obtain the Windows ISO."
}

prompt_iso_path() {
  local label="$1"
  local detected="${2:-}"
  local url="$3"
  local required="${4:-0}"
  local version_id="${5:-win11x64}"
  local language_id="${6:-en}"
  local answer

  while :; do
    if [[ -n "${detected}" && -f "${detected}" ]]; then
      answer="$(prompt "${label}" "${detected}")"
    else
      printf '%s\n' "No local ${label,,} detected." >&2
      printf '%s\n' "Official download page: ${url}" >&2
      if [[ "${required}" == "1" ]]; then
        answer="$(prompt "${label}")"
      else
        answer="$(prompt "${label} (leave blank to keep unset)")"
      fi
    fi

    if [[ -z "${answer}" ]]; then
      if [[ "${required}" == "1" ]]; then
        warn "${label} is required."
        printf '%s\n' "Official download page: ${url}" >&2
        continue
      fi
      printf '\n'
      return 0
    fi

    if [[ -f "${answer}" ]]; then
      if [[ "${label}" == *ISO* ]] && ! validate_iso_file "${answer}" "${label}" 104857600; then
        warn "Choose a valid ISO image for ${label}."
        printf '%s\n' "Official download page: ${url}" >&2
        detected=""
        continue
      fi
      ensure_libvirt_can_traverse_path "${answer}"
      printf '%s\n' "${answer}"
      return 0
    fi

    warn "${label} not found at ${answer}"
    printf '%s\n' "Official download page: ${url}" >&2
    detected=""
  done
}

file_size_bytes() {
  local path="$1"
  stat -c '%s' "${path}" 2>/dev/null || wc -c < "${path}" 2>/dev/null
}

ensure_libvirt_can_traverse_path() {
  local target_path="$1"
  local username="libvirt-qemu"
  local current_dir
  local -a dirs_to_check=()
  local dir

  [[ -e "${target_path}" ]] || return 0
  current_dir="$(dirname "${target_path}")"

  while [[ "${current_dir}" != "/" ]]; do
    dirs_to_check+=("${current_dir}")
    [[ "${current_dir}" == "/home" ]] && break
    current_dir="$(dirname "${current_dir}")"
  done

  local index
  for (( index=${#dirs_to_check[@]}-1; index>=0; index-- )); do
    dir="${dirs_to_check[$index]}"

    if command -v getfacl >/dev/null 2>&1 && getfacl "${dir}" 2>/dev/null | grep -q "user:${username}:.*x"; then
      continue
    fi

    if [[ -x "${dir}" ]]; then
      continue
    fi

    if command -v setfacl >/dev/null 2>&1; then
      if run setfacl --modify "user:${username}:x" "${dir}" 2>/dev/null; then
        ui_note "Granted ${username} traverse access to ${dir}" >&2
        continue
      fi
    fi

    if run chmod o+x "${dir}" 2>/dev/null; then
      ui_note "Granted world traverse access to ${dir}" >&2
      continue
    fi

    warn "Could not grant libvirt access to ${dir}. ${target_path} may not be readable by the VM."
    return 1
  done

  return 0
}

validate_iso_file() {
  local path="$1"
  local label="${2:-ISO}"
  local min_size_bytes="${3:-104857600}"
  local size description

  [[ -f "${path}" ]] || return 1
  size="$(file_size_bytes "${path}" || true)"
  [[ -n "${size}" && "${size}" =~ ^[0-9]+$ ]] || {
    warn "Could not determine size for ${label}: ${path}"
    return 1
  }
  if (( size < min_size_bytes )); then
    warn "${label} looks too small to be valid: ${path} (${size} bytes)."
    return 1
  fi

  if command -v file >/dev/null 2>&1; then
    description="$(file -b "${path}" 2>/dev/null || true)"
    case "${description}" in
      *ISO\ 9660*|*UDF\ filesystem*|*DOS/MBR\ boot\ sector*)
        return 0
        ;;
      *HTML*|*XML*|*ASCII\ text*|*Unicode\ text*|*JSON\ text*)
        warn "${label} is not an ISO image: ${path} (${description})"
        return 1
        ;;
    esac
  fi

  return 0
}

validate_winhance_source_xml() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  grep -q '<Extensions xmlns="urn:winhance:unattend">' "${path}" 2>/dev/null || return 1
  grep -q 'Winhancements\.ps1' "${path}" 2>/dev/null || return 1
}

resolve_winhance_source_xml() {
  local preferred="${1:-}"
  local tmp_output

  if [[ -n "${preferred}" && -f "${preferred}" ]]; then
    validate_winhance_source_xml "${preferred}" || fail "Winhance source XML is not valid: ${preferred}"
    printf '%s\n' "${preferred}"
    return 0
  fi

  if [[ -f "${WINHANCE_CACHE_XML}" ]]; then
    validate_winhance_source_xml "${WINHANCE_CACHE_XML}" || fail "Cached Winhance source XML is invalid: ${WINHANCE_CACHE_XML}"
    printf '%s\n' "${WINHANCE_CACHE_XML}"
    return 0
  fi

  need_download_cmds curl
  ensure_dir "$(dirname "${WINHANCE_CACHE_XML}")"
  tmp_output="$(mktemp "${WINHANCE_CACHE_XML}.tmp.XXXXXX")"
  if run curl -L --fail --output "${tmp_output}" "${WINHANCE_SOURCE_URL}" && validate_winhance_source_xml "${tmp_output}"; then
    mv -f "${tmp_output}" "${WINHANCE_CACHE_XML}"
    log "Cached Winhance source XML at ${WINHANCE_CACHE_XML}"
    printf '%s\n' "${WINHANCE_CACHE_XML}"
    return 0
  fi
  rm -f "${tmp_output}"
  fail "Could not obtain a valid Winhance source XML from ${WINHANCE_SOURCE_URL}"
}

prompt_number() {
  local label="$1"
  local default="$2"
  local min="${3:-1}"
  local answer

  while :; do
    answer="$(prompt "${label}" "${default}")"
    [[ "${answer}" =~ ^[0-9]+$ ]] || {
      warn "${label} must be a whole number."
      continue
    }
    (( answer >= min )) || {
      warn "${label} must be at least ${min}."
      continue
    }
    printf '%s\n' "${answer}"
    return 0
  done
}

need_download_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required download command: ${cmd}"
  done
}

windows_download_user_agent() {
  local browser_version
  browser_version="$((124 + ($(date +%s) - 1710892800) / 2419200))"
  printf 'Mozilla/5.0 (X11; Linux x86_64; rv:%s.0) Gecko/20100101 Firefox/%s.0\n' "${browser_version}" "${browser_version}"
}

windows_static_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"

  case "${language_id}" in
    en|en-gb) ;;
    *) return 1 ;;
  esac

  case "${version_id}" in
    win11x64)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
      ;;
    win11x64-enterprise-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
      ;;
    win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_CLIENT_IOT_LTSC_EVAL_x64FRE_en-us.iso"
      ;;
    win10x64)
      printf '%s\n' "https://dl.bobpony.com/windows/10/en-us_windows_10_22h2_x64.iso"
      ;;
    win10x64-enterprise-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
      ;;
    win10x64-enterprise-ltsc-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso"
      ;;
    win2025-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
      ;;
    win2022-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
      ;;
    win2019-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso"
      ;;
    win2019-hv)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/17763.557.190612-0019.rs5_release_svc_refresh_SERVERHYPERCORE_OEM_x64FRE_en-us.ISO"
      ;;
    win2016-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/F/3/C/F3C4E1E7-972A-4E22-879E-2AA1FA286A6A/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO"
      ;;
    *) return 1 ;;
  esac
}

resolve_windows_retail_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local page_url="" windows_version="" download_type="1"
  local user_agent language_name session_id page_html product_edition_id profile sku_json sku_id iso_json iso_url rc

  case "${version_id}" in
    win11x64) windows_version="11" ;;
    win10x64) windows_version="10" ;;
    *) return 1 ;;
  esac

  user_agent="$(windows_download_user_agent)"
  language_name="$(windows_language_name "${language_id}")"
  page_url="https://www.microsoft.com/en-us/software-download/windows${windows_version}"
  [[ "${version_id}" == "win10x64" ]] && page_url+="ISO"
  profile="606624d44113"
  session_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  session_id="${session_id//[![:print:]]/}"

  page_html="$(curl --silent --max-time 30 --user-agent "${user_agent}" --header "Accept:" --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "${page_url}")" || return 1
  product_edition_id="$(printf '%s' "${page_html}" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f2 | head -n1 | tr -cd '0-9' | head -c 16)"
  [[ -n "${product_edition_id}" ]] || return 1

  curl --silent --max-time 30 --output /dev/null --user-agent "${user_agent}" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- \
    "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=${session_id}" || return 1

  sku_json="$(curl --silent --max-time 30 --request GET --user-agent "${user_agent}" --referer "${page_url}" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- \
    "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=${profile}&ProductEditionId=${product_edition_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  { sku_id="$(printf '%s' "${sku_json}" | jq -r --arg LANG "${language_name}" '.Skus?[]? | select(.Language==$LANG).Id' | head -n1)"; rc=$?; } || :
  [[ -n "${sku_id}" && "${sku_id}" != "null" && "${rc}" -eq 0 ]] || return 1

  iso_json="$(curl --silent --max-time 30 --request GET --user-agent "${user_agent}" --referer "${page_url}" --header "Accept:" --max-filesize 100K --proto =https --tlsv1.2 --http1.1 -- \
    "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=${profile}&ProductEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  [[ -n "${iso_json}" ]] || return 1

  if printf '%s' "${iso_json}" | grep -q "Sentinel marked this request as rejected."; then
    warn "Microsoft blocked the automated retail download request based on your IP address."
    return 1
  fi
  if printf '%s' "${iso_json}" | grep -q "We are unable to complete your request at this time."; then
    warn "Microsoft rejected the automated retail download request at this time."
    return 1
  fi

  { iso_url="$(printf '%s' "${iso_json}" | jq -r '.ProductDownloadOptions?[]? | select(.DownloadType==1).Uri' | head -n1)"; rc=$?; } || :
  [[ -n "${iso_url}" && "${iso_url}" != "null" && "${rc}" -eq 0 ]] || return 1
  printf '%s\n' "${iso_url}"
}

resolve_windows_eval_download_url() {
  local version_id="${1:-win11x64-enterprise-eval}"
  local language_id="${2:-en}"
  local user_agent culture country url html filter links resolved

  case "${version_id}" in
    win11x64-enterprise-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise" ;;
    win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-11-iot-enterprise-ltsc-eval" ;;
    win10x64-enterprise-eval|win10x64-enterprise-ltsc-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise" ;;
    win2025-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025" ;;
    win2022-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022" ;;
    win2019-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019" ;;
    win2019-hv) url="https://www.microsoft.com/en-us/evalcenter/download-hyper-v-server-2019" ;;
    win2016-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2016" ;;
    *) return 1 ;;
  esac

  user_agent="$(windows_download_user_agent)"
  culture="$(windows_language_culture "${language_id}")"
  country="${culture#*-}"
  html="$(curl --silent --max-time 30 --user-agent "${user_agent}" --location --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "${url}")" || return 1
  [[ -n "${html}" ]] || return 1

  filter="https://go.microsoft.com/fwlink/?linkid=[0-9]\\+&clcid=0x[0-9a-z]\\+&culture=${culture,,}&country=${country,,}"
  if ! printf '%s' "${html}" | grep -io "${filter}" >/dev/null; then
    filter="https://go.microsoft.com/fwlink/p/?linkid=[0-9]\\+&clcid=0x[0-9a-z]\\+&culture=${culture,,}&country=${country,,}"
  fi
  links="$(printf '%s' "${html}" | grep -io "${filter}" || true)"
  [[ -n "${links}" ]] || return 1

  case "${version_id}" in
    win11x64-enterprise-eval|win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval|win2025-eval|win2022-eval|win2019-eval|win2019-hv|win2016-eval)
      resolved="$(printf '%s\n' "${links}" | head -n1)"
      ;;
    win10x64-enterprise-eval)
      resolved="$(printf '%s\n' "${links}" | head -n2 | tail -n1)"
      ;;
    win10x64-enterprise-ltsc-eval)
      resolved="$(printf '%s\n' "${links}" | head -n4 | tail -n1)"
      ;;
    *) return 1 ;;
  esac

  [[ -n "${resolved}" ]] || return 1
  curl --silent --max-time 30 --user-agent "${user_agent}" --location --output /dev/null --write-out "%{url_effective}" --head --fail --proto =https --tlsv1.2 --http1.1 -- "${resolved}" || return 1
}

resolve_windows_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local url=""

  url="$(windows_static_download_url "${version_id}" "${language_id}" || true)"
  if [[ -n "${url}" ]]; then
    printf '%s\n' "${url}"
    return 0
  fi

  case "${version_id}" in
    win10x64|win11x64)
      resolve_windows_retail_download_url "${version_id}" "${language_id}"
      ;;
    win11x64-enterprise-*|win10x64-enterprise-*|win2025-eval|win2022-eval|win2019-eval|win2019-hv|win2016-eval)
      resolve_windows_eval_download_url "${version_id}" "${language_id}" || windows_static_download_url "${version_id}" "${language_id}"
      ;;
    *)
      return 1
      ;;
  esac
}

dockur_windows_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local define_sh="${DOCKUR_WINDOWS_SRC}/define.sh"
  local mido_sh="${DOCKUR_WINDOWS_SRC}/mido.sh"
  local description

  [[ -f "${define_sh}" && -f "${mido_sh}" ]] || return 1
  description="Windows $(windows_language_desc "${language_id}")"

  /usr/bin/env bash -lc '
set -euo pipefail
VERSION_ID="$1"
LANGUAGE_ID="$2"
DESCRIPTION="$3"
DEFINE_SH="$4"
MIDO_SH="$5"
PLATFORM="x64"
DEBUG="N"
VERIFY="N"
SUPPORT="https://github.com/dockur/windows"
MIDO_URL=""
info() { :; }
html() { :; }
warn() { printf "%s\n" "$*" >&2; }
error() { printf "%s\n" "$*" >&2; return 1; }
source "$DEFINE_SH"
source "$MIDO_SH"
getWindows "$VERSION_ID" "$LANGUAGE_ID" "$DESCRIPTION" >/dev/null
printf "%s\n" "$MIDO_URL"
' bash "${version_id}" "${language_id}" "${description}" "${define_sh}" "${mido_sh}" 2>/dev/null
}

download_windows_iso() {
  local output_path="$1"
  local version_id="${2:-win11x64}"
  local language_id="${3:-en}"
  local iso_url tmp_output
  local -a curl_download_cmd

  need_download_cmds curl jq
  iso_url="$(dockur_windows_download_url "${version_id}" "${language_id}" || true)"
  if [[ -n "${iso_url}" ]]; then
    log "Resolved Windows ISO URL via Dockur logic: ${iso_url}"
  else
    iso_url="$(resolve_windows_download_url "${version_id}" "${language_id}" || true)"
  fi
  [[ -n "${iso_url}" ]] || {
    warn "Could not resolve a Windows ISO download URL for ${version_id} (${language_id})."
    return 1
  }
  [[ "${iso_url}" == http* ]] || {
    warn "Resolved Windows ISO URL is invalid: ${iso_url}"
    return 1
  }
  log "Resolved Windows ISO URL: ${iso_url}"

  ensure_dir "$(dirname "${output_path}")"
  tmp_output="$(mktemp "${output_path}.tmp.XXXXXX")"
  curl_download_cmd=(curl -L --fail --output "${tmp_output}")
  if [[ -t 1 ]]; then
    curl_download_cmd+=(--progress-bar)
  fi
  curl_download_cmd+=("${iso_url}")
  if run "${curl_download_cmd[@]}" && validate_iso_file "${tmp_output}" "Windows ISO" 536870912; then
    mv -f "${tmp_output}" "${output_path}"
    return 0
  fi
  rm -f "${tmp_output}"
  return 1
}

list_gpus() {
  lspci -Dnn | awk '
    /VGA compatible controller|3D controller/ {
      slot=$1
      desc=$0
      sub(/^[^ ]+ /, "", desc)
      print slot "|" desc
    }'
}

find_gpu_audio() {
  local bus_prefix="${1%.*}"
  lspci -Dnn | awk -v prefix="${bus_prefix}" '
    index($1, prefix) == 1 && /Audio device/ {
      print $1 "|" substr($0, index($0, $2))
    }'
}

list_all_gpu_functions() {
  local bus_prefix="${1%.*}"
  lspci -Dnn | awk -v prefix="${bus_prefix}" '
    index($1, prefix) == 1 {
      print $1 "|" substr($0, index($0, $2))
    }'
}

device_ids_for_bus() {
  local bus_prefix="${1%.*}"
  lspci -Dnn -n | awk -v prefix="${bus_prefix}" '
    index($1, prefix) == 1 {
      if (match($0, /\[[0-9a-f]{4}:[0-9a-f]{4}\]/)) {
        id=substr($0, RSTART + 1, RLENGTH - 2)
        ids = ids ? ids "," id : id
      }
    }
    END { print ids }'
}

render_device_menu() {
  local index=1
  while IFS='|' read -r slot desc; do
    [[ -n "${slot}" ]] || continue
    printf '%d) %s - %s\n' "${index}" "${slot}" "${desc}" >&2
    index=$((index + 1))
  done <<< "$1"
}

select_gpu() {
  local entries="$1"
  local choice selected
  render_device_menu "${entries}"
  while :; do
    choice="$(prompt "Select the GPU number to passthrough" "1")"
    [[ "${choice}" =~ ^[1-9][0-9]*$ ]] || {
      warn "Invalid GPU selection."
      continue
    }
    selected="$(printf '%s\n' "${entries}" | sed -n "${choice}p")"
    [[ -n "${selected}" ]] && break
    warn "Invalid GPU selection."
  done
  printf '%s\n' "${selected}"
}

usb_ids_file() {
  local candidate
  for candidate in /usr/share/hwdata/usb.ids /usr/share/misc/usb.ids; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done
  return 1
}

usb_vendor_name() {
  local vendor_id="${1,,}"
  local file
  file="$(usb_ids_file || true)"
  [[ -n "${file}" ]] || return 1
  awk -v vendor="${vendor_id}" '
    tolower($1) == vendor && $0 !~ /^\t/ {
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      print
      exit
    }' "${file}"
}

usb_product_name() {
  local vendor_id="${1,,}"
  local product_id="${2,,}"
  local file
  file="$(usb_ids_file || true)"
  [[ -n "${file}" ]] || return 1
  awk -v vendor="${vendor_id}" -v product="${product_id}" '
    BEGIN { in_vendor = 0 }
    $0 !~ /^\t/ {
      in_vendor = (tolower($1) == vendor)
      next
    }
    in_vendor && $0 ~ /^\t[0-9a-fA-F]{4}[[:space:]]+/ {
      line=$0
      sub(/^\t/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (tolower(parts[1]) == product) {
        sub(/^[[:space:]]*[0-9a-fA-F]{4}[[:space:]]+/, "", line)
        print line
        exit
      }
    }' "${file}"
}

usb_device_blacklisted() {
  local vendor="${1,,}"
  local product="${2,,}"
  case "${vendor}:${product}" in
    1d6b:0001|1d6b:0002|1d6b:0003|1d6b:0004)
      return 0
      ;;
  esac
  return 1
}

list_usb_controllers() {
  lspci -Dnn | awk '
    /USB controller|USB 3|xHCI|EHCI|OHCI/ {
      slot=$1
      desc=$0
      sub(/^[^ ]+ /, "", desc)
      print slot "|" desc
    }'
}

iommu_group_devices() {
  local pci="$1"
  local group_path
  group_path="$(readlink -f "/sys/bus/pci/devices/${pci}/iommu_group" 2>/dev/null || true)"
  [[ -n "${group_path}" && -d "${group_path}/devices" ]] || return 1
  find -L "${group_path}/devices" -maxdepth 1 -mindepth 1 -printf '%f\n' | sort
}

pci_group_isolated() {
  local pci="$1"
  local count
  count="$(iommu_group_devices "${pci}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "${count}" == "1" ]]
}

isolated_usb_controllers() {
  local entries="$1"
  local slot desc any
  any=0
  while IFS='|' read -r slot desc; do
    [[ -n "${slot}" ]] || continue
    if pci_group_isolated "${slot}"; then
      printf '%s|%s\n' "${slot}" "${desc}"
      any=1
    fi
  done <<< "${entries}"
  return 0
}

recommended_usb_controller() {
  local entries="$1"
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line,,}" in
      *asmedia*|*asm1143*|*renesas*)
        printf '%s\n' "${line}"
        return 0
        ;;
    esac
  done <<< "${entries}"
  printf '%s\n' "${entries}" | head -n1
}

list_usb_devices() {
  local dev vendor product manufacturer product_name busnum devnum line vendor_name product_label
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "${dev}/idVendor" && -f "${dev}/idProduct" ]] || continue
    [[ -f "${dev}/busnum" && -f "${dev}/devnum" ]] || continue
    vendor="$(<"${dev}/idVendor")"
    product="$(<"${dev}/idProduct")"
    usb_device_blacklisted "${vendor}" "${product}" && continue
    manufacturer="$(<"${dev}/manufacturer" 2>/dev/null || true)"
    product_name="$(<"${dev}/product" 2>/dev/null || true)"
    busnum="$(<"${dev}/busnum")"
    devnum="$(<"${dev}/devnum")"
    vendor_name="$(usb_vendor_name "${vendor}" || true)"
    product_label="$(usb_product_name "${vendor}" "${product}" || true)"
    [[ -z "${manufacturer}" ]] && manufacturer="${vendor_name}"
    [[ -z "${product_name}" ]] && product_name="${product_label}"
    line="${vendor}:${product}|bus $(printf '%03d' "${busnum}") device $(printf '%03d' "${devnum}") - ${manufacturer:-Unknown Vendor} ${product_name:-Unknown Product}"
    printf '%s\n' "${line}" | sed 's/[[:space:]]\+/ /g; s/ - $//'
  done | awk '!seen[$1]++'
}

render_plain_menu() {
  local entries="$1"
  local index=1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    printf '  %b%2d)%b %s\n' "${C_BLUE}" "${index}" "${C_RESET}" "${line}" >&2
    index=$((index + 1))
  done <<< "${entries}"
}

classify_usb_entry() {
  local entry="${1,,}"
  case "${entry}" in
    *keyboard* ) printf 'keyboard\n' ;;
    *mouse* ) printf 'mouse\n' ;;
    *controller*|*gamepad*|*xbox*|*dualshock*|*dualsense* ) printf 'controller\n' ;;
    *bluetooth* ) printf 'bluetooth\n' ;;
    *receiver*|*wireless* ) printf 'receiver\n' ;;
    *) printf 'other\n' ;;
  esac
}

prompt_usb_mode() {
  local default="$1"
  local answer
  local default_index="1"
  case "${default}" in
    controller) default_index="2" ;;
    devices|device) default_index="3" ;;
    evdev) default_index="4" ;;
  esac

  answer="$(prompt_menu_choice "USB passthrough mode" "${default_index}" \
    "No USB passthrough [none]" \
    "Pass through one whole USB controller [controller]" \
    "Pass through selected USB devices [devices]" \
    "Pass through input devices via evdev [evdev]")"
  case "${answer}" in
    *"[none]") printf 'none\n' ;;
    *"[controller]") printf 'controller\n' ;;
    *"[devices]") printf 'devices\n' ;;
    *"[evdev]") printf 'evdev\n' ;;
    *) fail "Unexpected USB mode selection." ;;
  esac
}

select_usb_controller() {
  local entries="$1"
  local recommended="$2"
  local recommended_index=1 choice selected index=1 line
  render_plain_menu "${entries}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == "${recommended}" ]] && recommended_index="${index}"
    index=$((index + 1))
  done <<< "${entries}"
  printf 'Recommended for beginners: %s\n' "${recommended}" >&2
  while :; do
    choice="$(prompt "Select the USB controller number to pass through" "${recommended_index}")"
    [[ "${choice}" =~ ^[1-9][0-9]*$ ]] || {
      warn "Invalid controller selection."
      continue
    }
    selected="$(printf '%s\n' "${entries}" | sed -n "${choice}p")"
    [[ -n "${selected}" ]] && {
      printf '%s\n' "${selected}"
      return 0
    }
    warn "Invalid controller selection."
  done
}

select_usb_devices() {
  local entries="$1"
  local selection action selected_lines="" item entry class
  render_plain_menu "${entries}"
  ui_note "Pick one or more USB devices. Commands: number, comma list, list, clear, done." >&2
  while :; do
    if [[ -n "${selected_lines}" ]]; then
      printf '%bCurrently selected:%b\n' "${C_BOLD}" "${C_RESET}" >&2
      printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++ { printf "  - %s\n", $0 }' >&2
    else
      printf '%bCurrently selected:%b none\n' "${C_BOLD}" "${C_RESET}" >&2
    fi
    action="$(prompt "USB devices to pass through" "done")"
    action="${action// /}"
    case "${action,,}" in
      "")
        continue
        ;;
      done)
        printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++'
        return 0
        ;;
      list)
        render_plain_menu "${entries}"
        continue
        ;;
      clear)
        selected_lines=""
        continue
        ;;
    esac
    IFS=',' read -r -a items <<< "${action}"
    for item in "${items[@]}"; do
      [[ "${item}" =~ ^[1-9][0-9]*$ ]] || {
        warn "Skipping invalid USB selection: ${item}"
        continue
      }
      entry="$(printf '%s\n' "${entries}" | sed -n "${item}p")"
      [[ -n "${entry}" ]] || {
        warn "Skipping missing USB selection: ${item}"
        continue
      }
      class="$(classify_usb_entry "${entry}")"
      case "${class}" in
        keyboard|mouse|receiver)
          warn "Selected ${class}: ${entry}"
          warn "If this is your only host input device, you may lock yourself out during VM use."
          ;;
      esac
      selected_lines="${selected_lines}${entry}"$'\n'
    done
    selected_lines="$(printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++')"
    [[ -n "${selected_lines}" ]] && selected_lines="${selected_lines}"$'\n'
  done
}

detect_bootloader() {
  if [[ -f /etc/default/grub ]]; then
    printf 'grub\n'
    return 0
  fi
  if [[ -f /etc/kernel/cmdline ]]; then
    printf 'systemd-boot\n'
    return 0
  fi
  printf 'unknown\n'
}

normalize_cmdline() {
  printf '%s\n' "$*" | awk '{$1=$1; print}'
}

extract_grub_cmdline_default() {
  local file="$1"
  local current
  current="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${file}" | head -n1 | cut -d'"' -f2)"
  current="${current#GRUB_CMDLINE_LINUX_DEFAULT=}"
  current="${current#\'}"
  current="${current%\'}"
  normalize_cmdline "${current}"
}

cmdline_add_tokens() {
  local current="$1"
  shift
  local token updated="${current}"
  for token in "$@"; do
    [[ -n "${token}" ]] || continue
    if ! printf ' %s ' "${updated}" | grep -Fq " ${token} "; then
      updated="${updated} ${token}"
    fi
  done
  normalize_cmdline "${updated}"
}

cmdline_remove_prefix() {
  local current="$1"
  local prefix="$2"
  printf '%s\n' "${current}" | awk -v prefix="${prefix}" '
    {
      out=""
      for (i = 1; i <= NF; i++) {
        if (index($i, prefix) == 1) {
          continue
        }
        out = out ? out " " $i : $i
      }
      print out
    }'
}

update_grub_cmdline() {
  local args="$1"
  local file="/etc/default/grub"
  local current updated
  backup_file "${file}"
  current="$(extract_grub_cmdline_default "${file}")"
  updated="$(cmdline_add_tokens "${current}" ${args})"
  if (( DRY_RUN )); then
    printf '[dry-run] update %s GRUB_CMDLINE_LINUX_DEFAULT -> %s\n' "${file}" "${updated}"
    return 0
  fi
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${updated}\"|" "${file}"
}

remove_grub_token_prefix() {
  local prefix="$1"
  local file="/etc/default/grub"
  local current updated
  backup_file "${file}"
  current="$(extract_grub_cmdline_default "${file}")"
  updated="$(cmdline_remove_prefix "${current}" "${prefix}")"
  if (( DRY_RUN )); then
    printf '[dry-run] remove tokens with prefix %s from %s\n' "${prefix}" "${file}"
    return 0
  fi
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${updated}\"|" "${file}"
}

update_systemd_boot_cmdline() {
  local args="$1"
  local file="/etc/kernel/cmdline"
  local current updated
  current="$(tr '\n' ' ' < "${file}")"
  updated="$(cmdline_add_tokens "${current}" ${args})"
  write_file "${file}" "${updated}"$'\n'
}

remove_systemd_boot_prefix() {
  local prefix="$1"
  local file="/etc/kernel/cmdline"
  local current updated
  current="$(tr '\n' ' ' < "${file}")"
  updated="$(cmdline_remove_prefix "${current}" "${prefix}")"
  write_file "${file}" "${updated}"$'\n'
}

configure_bootloader() {
  local mode="$1"
  local vfio_ids="$2"
  local cpu_vendor="$3"
  local bootloader iommu_args args

  bootloader="$(detect_bootloader)"
  iommu_args="$(default_iommu_params "${cpu_vendor}")"
  args="${iommu_args}"

  if [[ "${mode}" == "double" ]]; then
    args="${args} rd.driver.pre=vfio-pci vfio-pci.ids=${vfio_ids}"
  fi

  case "${bootloader}" in
    grub)
      update_grub_cmdline "${args}"
      if [[ "${mode}" == "single" ]]; then
        remove_grub_token_prefix "vfio-pci.ids="
        remove_grub_token_prefix "rd.driver.pre="
      fi
      ;;
    systemd-boot)
      update_systemd_boot_cmdline "${args}"
      if [[ "${mode}" == "single" ]]; then
        remove_systemd_boot_prefix "vfio-pci.ids="
        remove_systemd_boot_prefix "rd.driver.pre="
      fi
      ;;
    *)
      fail "Unsupported bootloader. Expected /etc/default/grub or /etc/kernel/cmdline."
      ;;
  esac

  printf '%s\n' "${bootloader}"
}

update_mkinitcpio() {
  local mode="$1"
  local file="/etc/mkinitcpio.conf"
  local modules

  [[ -f "${file}" ]] || {
    warn "Skipping mkinitcpio update because ${file} does not exist."
    return 0
  }

  modules=""
  if [[ "${mode}" == "double" ]]; then
    modules="vfio vfio_pci vfio_iommu_type1"
  fi

  backup_file "${file}"

  if (( DRY_RUN )); then
    printf '[dry-run] update %s for %s-gpu mode\n' "${file}" "${mode}"
    return 0
  fi

  if [[ "${mode}" == "double" ]]; then
    awk -v modules="${modules}" '
      BEGIN { done = 0 }
      /^MODULES=/ {
        print "MODULES=(" modules ")"
        done = 1
        next
      }
      { print }
      END {
        if (!done) {
          print "MODULES=(" modules ")"
        }
      }' "${file}" > "${file}.tmp"
  else
    awk '
      BEGIN { done = 0 }
      /^MODULES=/ {
        print "MODULES=()"
        done = 1
        next
      }
      { print }
      END {
        if (!done) {
          print "MODULES=()"
        }
      }' "${file}" > "${file}.tmp"
  fi
  mv "${file}.tmp" "${file}"
}

configure_modprobe() {
  local mode="$1"
  local vfio_ids="$2"
  local cpu_vendor="$3"
  local kvm_file="/etc/modprobe.d/kvm-${cpu_vendor}.conf"
  local vfio_file="/etc/modprobe.d/vfio-passthrough.conf"
  local modules_file="/etc/modules-load.d/vfio.conf"
  local kvm_body vfio_body modules_body

  case "${cpu_vendor}" in
    intel) kvm_body="options kvm_intel nested=1"$'\n' ;;
    amd) kvm_body="options kvm_amd nested=1"$'\n' ;;
    *) kvm_body="" ;;
  esac

  [[ -n "${kvm_body}" ]] && write_file "${kvm_file}" "${kvm_body}"

  if [[ "${mode}" == "double" ]]; then
    vfio_body=$'# Managed by passthrough-setup.sh\n'
    vfio_body+="options vfio-pci ids=${vfio_ids} disable_vga=1"$'\n'
    modules_body=$'vfio\nvfio_pci\nvfio_iommu_type1\n'
  else
    vfio_body=$'# Managed by passthrough-setup.sh\n'
    vfio_body+='# Single-GPU mode: GPU bound/unbound via libvirt hooks.'$'\n'
    modules_body=$'vfio\nvfio_pci\nvfio_iommu_type1\n'
  fi

  write_file "${vfio_file}" "${vfio_body}"
  write_file "${modules_file}" "${modules_body}"
}

configure_libvirt() {
  local user_name="$1"
  local network_conf="/etc/libvirt/network.conf"
  local libvirtd_conf="/etc/libvirt/libvirtd.conf"

  if [[ -f "${network_conf}" ]]; then
    backup_file "${network_conf}"
    if (( DRY_RUN )); then
      printf '[dry-run] ensure firewall_backend=iptables in %s\n' "${network_conf}"
    else
      if grep -qE '^[#[:space:]]*firewall_backend' "${network_conf}"; then
        sed -i -E 's|^[#[:space:]]*firewall_backend.*|firewall_backend = "iptables"|' "${network_conf}"
      else
        printf '\nfirewall_backend = "iptables"\n' >> "${network_conf}"
      fi
    fi
  fi

  if [[ -f "${libvirtd_conf}" ]]; then
    backup_file "${libvirtd_conf}"
    if (( DRY_RUN )); then
      printf '[dry-run] ensure unix_sock_group/unix_sock_rw_perms in %s\n' "${libvirtd_conf}"
    else
      if grep -qE '^[#[:space:]]*unix_sock_group' "${libvirtd_conf}"; then
        sed -i -E 's|^[#[:space:]]*unix_sock_group.*|unix_sock_group = "libvirt"|' "${libvirtd_conf}"
      else
        printf '\nunix_sock_group = "libvirt"\n' >> "${libvirtd_conf}"
      fi
      if grep -qE '^[#[:space:]]*unix_sock_rw_perms' "${libvirtd_conf}"; then
        sed -i -E 's|^[#[:space:]]*unix_sock_rw_perms.*|unix_sock_rw_perms = "0770"|' "${libvirtd_conf}"
      else
        printf 'unix_sock_rw_perms = "0770"\n' >> "${libvirtd_conf}"
      fi
    fi
  fi

  if id -nG "${user_name}" 2>/dev/null | tr ' ' '\n' | grep -qx 'libvirt'; then
    :
  else
    run usermod -aG libvirt "${user_name}"
  fi

  if id -nG "${user_name}" 2>/dev/null | tr ' ' '\n' | grep -qx 'input'; then
    :
  else
    run usermod -aG input "${user_name}"
  fi

  run systemctl enable --now libvirtd.service
  run systemctl enable --now libvirtd.socket
  run virsh net-autostart default

  # Modernize and spoof the default network (borrowed from AutoVirt)
  local network_xml="/etc/libvirt/qemu/networks/default.xml"
  if [[ -f "${network_xml}" ]]; then
    local oui="b0:4e:26"
    local random_mac="${oui}:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    backup_file "${network_xml}"
    if (( DRY_RUN )); then
      printf '[dry-run] spoof MAC and IP in %s -> %s\n' "${network_xml}" "${random_mac}"
    else
      # Change MAC and move from 192.168.122.x to 10.0.0.x
      sed -i \
        -e "s|<mac address='[0-9A-Fa-f:]\{17\}'|<mac address='${random_mac}'|g" \
        -e "s|address='192\.168\.122\.1'|address='10.0.0.1'|g" \
        -e "s|start='192\.168\.122\.2'|start='10.0.0.2'|g" \
        -e "s|end='192\.168\.122\.254'|end='10.0.0.254'|g" \
        "${network_xml}"
    fi
  fi

  if [[ "$(virsh net-info default 2>/dev/null | awk -F': *' '/^Active:/ {print tolower($2); exit}')" != "yes" ]]; then
    run virsh net-start default
  fi
  run systemctl restart libvirtd.service
}

write_state_file() {
  local mode="$1"
  local user_name="$2"
  local vm_name="$3"
  local gpu_pci="$4"
  local gpu_audio_pci="$5"
  local vfio_ids="$6"
  local bootloader="$7"
  local ovmf_code="$8"
  local ovmf_vars="$9"
  local virtio_iso="${10}"
  local windows_iso="${11}"
  local vcpus="${12}"
  local memory_mb="${13}"
  local disk_size_gb="${14}"
  local windows_version="${15}"
  local windows_language="${16}"
  local usb_mode="${17}"
  local usb_controller_pci="${18}"
  local usb_device_ids="${19}"
  local windows_test_mode="${20}"
  local winhance_payload="${21}"
  local install_profile="${22}"
  local windows_password="${23}"
  local install_stage="${24}"
  local body

  body=$(cat <<EOF
MODE="${mode}"
SESSION_USER="${user_name}"
VM_NAME="${vm_name}"
GPU_PCI="${gpu_pci}"
GPU_AUDIO_PCI="${gpu_audio_pci}"
VFIO_IDS="${vfio_ids}"
BOOTLOADER="${bootloader}"
OVMF_CODE="${ovmf_code}"
OVMF_VARS="${ovmf_vars}"
VIRTIO_ISO="${virtio_iso}"
WINDOWS_ISO="${windows_iso}"
VCPUS="${vcpus}"
MEMORY_MB="${memory_mb}"
DISK_SIZE_GB="${disk_size_gb}"
WINDOWS_VERSION="${windows_version}"
WINDOWS_LANGUAGE="${windows_language}"
USB_MODE="${usb_mode}"
USB_CONTROLLER_PCI="${usb_controller_pci}"
USB_DEVICE_IDS="${usb_device_ids}"
WINDOWS_TEST_MODE="${windows_test_mode}"
WINHANCE_PAYLOAD="${winhance_payload}"
INSTALL_PROFILE="${install_profile}"
WINDOWS_PASSWORD="${windows_password}"
INSTALL_STAGE="${install_stage}"
EOF
)
  write_file "${STATE_FILE}" "${body}"
}

create_status_script() {
  local body stage_body

  stage_body=$(cat <<'EOF'
echo "Install stage: ${INSTALL_STAGE:-unknown}"
case "${INSTALL_STAGE:-unknown}" in
  host-configured)
    echo "Next step: run './windows' from the repo directory to build the initial Spice install VM."
    ;;
  spice-install)
    echo "Next step: complete Windows install in the Spice VM, then shut it down and run './windows' again."
    ;;
  gpu-passthrough)
    echo "Next step: run './windows' from the repo directory to start the passthrough VM."
    ;;
esac
echo
EOF
)

  body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
[[ -f "${STATE_FILE}" ]] || {
  echo "No passthrough state file at ${STATE_FILE}" >&2
  exit 1
}
source "${STATE_FILE}"

echo "Mode: ${MODE}"
echo "VM: ${VM_NAME}"
echo "GPU: ${GPU_PCI}"
echo "GPU audio: ${GPU_AUDIO_PCI}"
echo "VFIO IDs: ${VFIO_IDS}"
echo "Bootloader: ${BOOTLOADER}"
echo
EOF
)
  body+="${stage_body}"
  body+=$(cat <<'EOF'
echo "Kernel cmdline:"
cat /proc/cmdline
echo
echo "GPU bindings:"
lspci -nnk -s "${GPU_PCI}" || true
echo
lspci -nnk -s "${GPU_AUDIO_PCI}" || true
echo
echo "libvirt network:"
virsh net-info default 2>/dev/null || true
echo
echo "postboot service:"
systemctl status --no-pager passthrough-postboot.service 2>/dev/null || true
echo
echo "Desktop flow:"
echo "  1. cd into the one-click-passthrough repo"
echo "  2. run ./windows"
echo "  3. if no viewer opens, open the VM in virt-manager or virt-viewer"
EOF
)

  write_file "/usr/local/bin/passthrough-status" "${body}"
  run chmod +x /usr/local/bin/passthrough-status
}

create_postboot_service() {
  local body service

  body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
REPORT_FILE="/var/log/passthrough-postboot.log"
[[ -f "${STATE_FILE}" ]] || exit 0
source "${STATE_FILE}"

{
  echo "==== $(date -Is) ===="
  echo "mode=${MODE}"
  echo "vm=${VM_NAME}"
  echo "gpu=${GPU_PCI}"
  echo "audio=${GPU_AUDIO_PCI}"
  echo
  echo "-- cmdline --"
  cat /proc/cmdline
  echo
  echo "-- iommu dmesg --"
  dmesg | grep -i iommu || true
  echo
  echo "-- kvm/vfio modules --"
  lsmod | grep -E 'kvm|vfio' || true
  echo
  echo "-- gpu binding --"
  lspci -nnk -s "${GPU_PCI}" || true
  echo
  lspci -nnk -s "${GPU_AUDIO_PCI}" || true
  echo
  echo "-- libvirt --"
  systemctl is-enabled libvirtd.service 2>/dev/null || true
  systemctl is-active libvirtd.service 2>/dev/null || true
  virsh net-info default 2>/dev/null || true
  echo
  if [[ "${MODE}" == "single" ]]; then
    echo "-- single-gpu hooks --"
    ls -l "/etc/libvirt/hooks/qemu" 2>/dev/null || true
    ls -l "/etc/libvirt/hooks/qemu.d/${VM_NAME}/prepare/begin/prepare.sh" 2>/dev/null || true
    ls -l "/etc/libvirt/hooks/qemu.d/${VM_NAME}/release/end/release.sh" 2>/dev/null || true
  else
    echo "-- dedicated mode vfio config --"
    grep -R "vfio" /etc/modprobe.d /etc/modules-load.d 2>/dev/null || true
  fi
  echo
} | tee "${REPORT_FILE}"
EOF
)

  service=$(cat <<'EOF'
[Unit]
Description=Passthrough Post-Boot Validation
After=multi-user.target libvirtd.service
Wants=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/passthrough-postboot-check

[Install]
WantedBy=multi-user.target
EOF
)

  write_file "/usr/local/libexec/passthrough-postboot-check" "${body}"
  run chmod +x /usr/local/libexec/passthrough-postboot-check
  write_file "/etc/systemd/system/passthrough-postboot.service" "${service}"
  run systemctl daemon-reload
  run systemctl enable passthrough-postboot.service
}

create_vm_helper_scripts() {
  local vm_name="$1"
  local gpu_pci="$2"
  local gpu_audio_pci="$3"
  local ovmf_code="$4"
  local ovmf_vars="$5"
  local virtio_iso="$6"
  local usb_mode="$7"
  local usb_controller_pci="$8"
  local usb_device_ids="$9"
  local windows_test_mode="${10}"
  local winhance_payload="${11}"
  local windows_password="${12}"
  local existing_disk="${13:-}"
  local create_body attach_body video_xml audio_xml unattend_xml setupcomplete_body build_unattend_body build_windows_body set_stage_body
  local controller_xml usb_attach_block id_pair vendor product usb_xml_path
  local user_name_placeholder
  local first_logon_dse_xml="" setupcomplete_dse_body="" first_logon_reboot_xml="" first_logon_debloat_xml=""
  local specialize_run_commands_xml="" unattend_extensions_xml="" winhance_extensions_xml="" winhance_source_xml=""
  local escaped_windows_password

  user_name_placeholder="${SUDO_USER:-${USER:-nick}}"
  winhance_source_xml="${WINHANCE_SOURCE_XML}"
  escaped_windows_password="$(xml_escape "${windows_password}")"

  set_stage_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
STAGE="${1:-}"
[[ -n "${STAGE}" ]] || {
  echo "usage: passthrough-set-stage <host-configured|spice-install|gpu-passthrough>" >&2
  exit 2
}
[[ -f "${STATE_FILE}" ]] || {
  echo "Missing ${STATE_FILE}" >&2
  exit 1
}

tmp="$(mktemp)"
if [[ ! -w "${STATE_FILE}" ]]; then
  echo "State file is not writable; skipping stage update to ${STAGE}" >&2
  exit 0
fi
awk -v stage="${STAGE}" '
  BEGIN { done = 0 }
  /^INSTALL_STAGE=/ {
    print "INSTALL_STAGE=\"" stage "\""
    done = 1
    next
  }
  { print }
  END {
    if (!done) {
      print "INSTALL_STAGE=\"" stage "\""
    }
  }' "${STATE_FILE}" > "${tmp}"
cat "${tmp}" > "${STATE_FILE}"
rm -f "${tmp}"
echo "Set install stage to ${STAGE}"
EOF
)

  if [[ "${windows_test_mode}" == "1" ]]; then
    first_logon_dse_xml=$(cat <<'EOF'
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Enable Windows test mode</Description>
          <CommandLine>cmd /c bcdedit /set {current} testsigning on</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>Relax driver signature enforcement</Description>
          <CommandLine>cmd /c bcdedit /set {current} nointegritychecks on</CommandLine>
        </SynchronousCommand>
EOF
)
    first_logon_reboot_xml=$(cat <<'EOF'
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>9</Order>
          <Description>Reboot into Windows test mode</Description>
          <CommandLine>shutdown.exe /r /t 5 /f /c "Rebooting once to enable Windows test mode"</CommandLine>
        </SynchronousCommand>
EOF
)
    setupcomplete_dse_body+=$'bcdedit /set {current} testsigning on >nul 2>&1\r\n'
    setupcomplete_dse_body+=$'bcdedit /set {current} nointegritychecks on >nul 2>&1\r\n'
  fi

  if [[ "${winhance_payload}" == "1" ]]; then
    winhance_source_xml="$(resolve_winhance_source_xml "${winhance_source_xml}")"
    winhance_extensions_xml="$(sed -n '/<Extensions xmlns="urn:winhance:unattend">/,/<\/Extensions>/p' "${winhance_source_xml}")"
    [[ -n "${winhance_extensions_xml}" ]] || fail "Could not extract the Winhance Extensions block from ${winhance_source_xml}."
    unattend_extensions_xml="${winhance_extensions_xml}"
    specialize_run_commands_xml=$(cat <<'EOF'
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Load full Winhance payload from unattend extensions</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Allow local account creation without online requirement</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Disable network adapters during OOBE</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Disable-NetAdapter -Confirm:\$false"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Enable .NET Framework 3.5 from Windows installation media</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -Command "foreach($d in 'C','D','E','F','G','H','I','J','K'){$src=Join-Path ($d+':') 'sources\sxs';if(Test-Path $src\*.cab){dism /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$src;break}}"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Run full Winhance payload</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\Winhance\Unattend\Scripts\Winhancements.ps1"</Path>
        </RunSynchronousCommand>
EOF
)
  else
    specialize_run_commands_xml=$(cat <<'EOF'
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Allow local account creation without online requirement</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Disable network adapters during OOBE</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Disable-NetAdapter -Confirm:\$false"</Path>
        </RunSynchronousCommand>
EOF
)
  fi

  unattend_xml=$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <DynamicUpdate>
        <Enable>false</Enable>
        <WillShowUI>OnError</WillShowUI>
      </DynamicUpdate>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Bypass TPM requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Bypass Secure Boot requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Bypass RAM requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Bypass CPU requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Allow upgrades with unsupported TPM or CPU</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>${user_name_placeholder}</FullName>
        <Organization>passthrough</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnPSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
    <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipRearm>1</SkipRearm>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
${specialize_run_commands_xml}
      </RunSynchronous>
    </component>
    <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Username>${user_name_placeholder}</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>${escaped_windows_password}</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>${user_name_placeholder}</Name>
            <Group>Administrators</Group>
            <DisplayName>${user_name_placeholder}</DisplayName>
            <Password>
              <Value>${escaped_windows_password}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <FirstLogonCommands>
${first_logon_dse_xml}
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>3</Order>
          <Description>Re-enable network adapters</Description>
          <CommandLine>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Enable-NetAdapter -Confirm:\$false"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>4</Order>
          <Description>Install virtio guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\virtio-win-guest-tools.exe start /wait "" %D:\virtio-win-guest-tools.exe /quiet /norestart</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>5</Order>
          <Description>Install SPICE guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\spice-guest-tools.exe start /wait "" %D:\spice-guest-tools.exe /S</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>6</Order>
          <Description>Hide Edge first-run experience</Description>
          <CommandLine>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HideFirstRunExperience" /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>7</Order>
          <Description>Show file extensions</Description>
          <CommandLine>reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>8</Order>
          <Description>Disable hibernation</Description>
          <CommandLine>cmd /C POWERCFG -H OFF</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>10</Order>
          <Description>Disable unsupported hardware notices</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>11</Order>
          <Description>Disable unsupported hardware notices second flag</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
${first_logon_debloat_xml}
${first_logon_reboot_xml}
      </FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
${unattend_extensions_xml}
  <cpi:offlineImage cpi:source="wim://windows/install.wim#Windows 11 Pro" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
)

  setupcomplete_body=$'@echo off\r\n'
  setupcomplete_body+=$'set "PT_SETUP_LOG=%ProgramData%\\Passthrough\\SetupComplete.log"\r\n'
  setupcomplete_body+=$'set "PT_SETUP_MARKER=%Public%\\Desktop\\Passthrough Post-Install.txt"\r\n'
  setupcomplete_body+=$'if not exist "%ProgramData%\\Passthrough" mkdir "%ProgramData%\\Passthrough" >nul 2>&1\r\n'
  setupcomplete_body+=$'echo [%date% %time%] SetupComplete.cmd started>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+="${setupcomplete_dse_body}"
  setupcomplete_body+=$'for %%D in (D E F G H I J K L M) do (\r\n'
  setupcomplete_body+=$'  if exist %%D:\\virtio-win-guest-tools.exe (\r\n'
  setupcomplete_body+=$'    echo [%date% %time%] Installing virtio guest tools from %%D:>>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+=$'    start /wait "" %%D:\\virtio-win-guest-tools.exe /quiet /norestart\r\n'
  setupcomplete_body+=$'  )\r\n'
  setupcomplete_body+=$'  if exist %%D:\\spice-guest-tools.exe (\r\n'
  setupcomplete_body+=$'    echo [%date% %time%] Installing SPICE guest tools from %%D:>>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+=$'    start /wait "" %%D:\\spice-guest-tools.exe /S\r\n'
  setupcomplete_body+=$'  )\r\n'
  setupcomplete_body+=$')\r\n'
  setupcomplete_body+=$'(\r\n'
  setupcomplete_body+=$'  echo Passthrough post-install tasks finished.\r\n'
  setupcomplete_body+=$'  echo.\r\n'
  setupcomplete_body+=$'  echo Time: %date% %time%\r\n'
  setupcomplete_body+=$'  echo Log: %PT_SETUP_LOG%\r\n'
  setupcomplete_body+=$'  echo.\r\n'
  setupcomplete_body+=$'  echo If virtio or SPICE tools were mounted, they were started from SetupComplete.cmd.\r\n'
  setupcomplete_body+=$') >"%PT_SETUP_MARKER%"\r\n'
  setupcomplete_body+=$'echo [%date% %time%] SetupComplete.cmd finished>>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+=$'exit /b 0\r\n'

  create_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "\${STATE_FILE}"

WINDOWS_ISO="\${1:-\${WINDOWS_ISO:-}}"
DISK_PATH="\${DISK_PATH:-/var/lib/libvirt/images/\${VM_NAME}.qcow2}"
DISK_SIZE_GB="\${DISK_SIZE_GB:-\${DISK_SIZE_GB:-120}}"
MEMORY_MB="\${MEMORY_MB:-\${MEMORY_MB:-16384}}"
VCPUS="\${VCPUS:-\${VCPUS:-8}}"
VIRTIO_MEDIA="\${2:-\${VIRTIO_ISO}}"
INSTALL_PROFILE="\${INSTALL_PROFILE:-standard}"
PATCHED_WINDOWS_ISO="/var/lib/libvirt/images/\${VM_NAME}-windows-install-\${INSTALL_PROFILE}.iso"

command -v virt-install >/dev/null 2>&1 || {
  echo "virt-install is required" >&2
  exit 1
}
[[ -f "${ovmf_code}" ]] || {
  echo "Missing OVMF_CODE at ${ovmf_code}" >&2
  exit 1
}
[[ -f "${ovmf_vars}" ]] || {
  echo "Missing OVMF_VARS at ${ovmf_vars}" >&2
  exit 1
}
AVAILABLE_GB="\$(df -BG "\$(dirname "\${DISK_PATH}")" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", \$4); print \$4; exit}')"
if [[ -f "\${DISK_PATH}" ]]; then
  REQUIRED_GB="10"
else
  REQUIRED_GB="\$((DISK_SIZE_GB + 10))"
fi
if [[ -n "\${AVAILABLE_GB}" ]] && (( AVAILABLE_GB < REQUIRED_GB )); then
  echo "Insufficient free space for VM creation." >&2
  echo "Available: \${AVAILABLE_GB}G" >&2
  if [[ -f "\${DISK_PATH}" ]]; then
    echo "Required: \${REQUIRED_GB}G (~10G overhead while reusing existing VM disk \${DISK_PATH})" >&2
  else
    echo "Required: \${REQUIRED_GB}G (\${DISK_SIZE_GB}G VM disk + ~10G overhead)" >&2
  fi
  exit 1
fi

if [[ ! -f "\${PATCHED_WINDOWS_ISO}" ]]; then
  echo "Missing patched Windows ISO: \${PATCHED_WINDOWS_ISO}" >&2
  echo "Re-run: sudo ./passthrough-setup.sh" >&2
  if [[ -n "\${WINDOWS_ISO}" ]]; then
    echo "Configured base Windows ISO: \${WINDOWS_ISO}" >&2
  else
    echo "Windows ISO download page: ${WINDOWS_ISO_URL}" >&2
  fi
  exit 1
fi

cmd=(
  virt-install
  --connect qemu:///system
  --name "\${VM_NAME}"
  --memory "\${MEMORY_MB}"
  --vcpus "\${VCPUS},sockets=1,dies=1,cores=\${VCPUS},threads=1"
  --cpu "host-passthrough"
  --machine q35
  --features "acpi=on,apic=on"
  --boot "loader=${ovmf_code},loader.readonly=yes,loader.type=pflash,nvram.template=${ovmf_vars}"
  --clock "offset=localtime"
  --network network=default,model=e1000e
  --graphics spice
  --video qxl
  --sound ich9
  --watchdog "itco,action=reset"
  --channel spicevmc
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb
  --osinfo detect=on,require=off
  --noautoconsole
)

if [[ -f "\${DISK_PATH}" ]]; then
  cmd+=(--disk "path=\${DISK_PATH},format=qcow2,bus=sata")
else
  cmd+=(--disk "path=\${DISK_PATH},size=\${DISK_SIZE_GB},format=qcow2,bus=sata")
fi

cmd+=(--disk "path=\${PATCHED_WINDOWS_ISO},device=cdrom")

if [[ -n "\${VIRTIO_MEDIA}" && -f "\${VIRTIO_MEDIA}" ]]; then
  cmd+=(--disk "path=\${VIRTIO_MEDIA},device=cdrom")
else
  echo "virtio ISO not found; continuing without attaching one" >&2
  echo "Download page: ${VIRTIO_ISO_URL}" >&2
fi

"\${cmd[@]}"
/usr/local/bin/passthrough-set-stage spice-install
echo "VM created for Spice install phase."
echo "A Spice viewer should open automatically."
echo "If it does not, open \${VM_NAME} in virt-manager or virt-viewer."
echo "When Windows setup is finished and the VM is shut down, run ./windows again."
EOF
)

  build_unattend_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "${STATE_FILE}"

SRC_DIR="/etc/passthrough/autounattend"
OUT_ISO="/var/lib/libvirt/images/${VM_NAME}-autounattend.iso"

[[ -f "${SRC_DIR}/Autounattend.xml" ]] || {
  echo "Missing ${SRC_DIR}/Autounattend.xml" >&2
  exit 1
}

if command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
else
  echo "Need xorriso, genisoimage, or mkisofs to build unattended ISO" >&2
  exit 1
fi

echo "Built ${OUT_ISO}"
EOF
)

  build_windows_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "${STATE_FILE}"

SRC_DIR="/etc/passthrough/autounattend"
BASE_ISO="${WINDOWS_ISO}"
PROFILE="${INSTALL_PROFILE:-standard}"
OUT_ISO="/var/lib/libvirt/images/${VM_NAME}-windows-install-${PROFILE}.iso"
SETUPCOMPLETE="${SRC_DIR}/\$OEM\$/\$\$/Setup/Scripts/SetupComplete.cmd"
WORKDIR="$(mktemp -d)"
ROOT_DIR="${WORKDIR}/root"
cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

[[ -f "${BASE_ISO}" ]] || {
  echo "Missing Windows ISO: ${BASE_ISO}" >&2
  exit 1
}
[[ -f "${SRC_DIR}/Autounattend.xml" ]] || {
  echo "Missing ${SRC_DIR}/Autounattend.xml" >&2
  exit 1
}
[[ -f "${SETUPCOMPLETE}" ]] || {
  echo "Missing ${SETUPCOMPLETE}" >&2
  exit 1
}
command -v xorriso >/dev/null 2>&1 || {
  echo "Need xorriso to build patched Windows ISO" >&2
  exit 1
}

extract_iso() {
  mkdir -p "${ROOT_DIR}"
  if command -v 7z >/dev/null 2>&1; then
    7z x -y "-o${ROOT_DIR}" "${BASE_ISO}" >/dev/null
    return 0
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -C "${ROOT_DIR}" -xf "${BASE_ISO}"
    return 0
  fi
  echo "Need 7z or bsdtar to extract the Windows ISO" >&2
  exit 1
}

extract_iso

mkdir -p "${ROOT_DIR}/sources/\$OEM\$/\$\$/Setup/Scripts"
cp "${SRC_DIR}/Autounattend.xml" "${ROOT_DIR}/Autounattend.xml"
cp "${SETUPCOMPLETE}" "${ROOT_DIR}/sources/\$OEM\$/\$\$/Setup/Scripts/SetupComplete.cmd"

[[ -f "${ROOT_DIR}/boot/etfsboot.com" ]] || {
  echo "Missing BIOS boot image in extracted Windows ISO: boot/etfsboot.com" >&2
  exit 1
}

if [[ -f "${ROOT_DIR}/efi/microsoft/boot/efisys.bin" ]]; then
  EFI_BOOT_IMAGE="efi/microsoft/boot/efisys.bin"
elif [[ -f "${ROOT_DIR}/efi/microsoft/boot/efisys_noprompt.bin" ]]; then
  EFI_BOOT_IMAGE="efi/microsoft/boot/efisys_noprompt.bin"
else
  echo "Missing EFI boot image in extracted Windows ISO" >&2
  exit 1
fi

VOLID="$(xorriso -indev "${BASE_ISO}" -pvd_info 2>/dev/null | awk -F': *' '/^Volume Id/ {print $2; exit}')"
VOLID="${VOLID:-WINAUTO}"

rm -f "${OUT_ISO}"
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -J \
  -joliet-long \
  -relaxed-filenames \
  -V "${VOLID}" \
  -o "${OUT_ISO}" \
  -b "boot/etfsboot.com" \
  -no-emul-boot \
  -boot-load-size 8 \
  -eltorito-alt-boot \
  -e "${EFI_BOOT_IMAGE}" \
  -no-emul-boot \
  "${ROOT_DIR}"

echo "Built ${OUT_ISO}"
EOF
)

  # Automatic VBIOS ROM injection if present
  local rom_path="/etc/passthrough/roms/vbios_${gpu_pci//[:.]/_}.rom"
  local rom_xml=""
  if [[ -f "${rom_path}" ]]; then
    log "Found custom VBIOS ROM at ${rom_path}. Injecting into VM config."
    rom_xml="<rom file='${rom_path}'/>"
  fi

  video_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${gpu_pci:0:4}' bus='0x${gpu_pci:5:2}' slot='0x${gpu_pci:8:2}' function='0x${gpu_pci:11:1}'/>
  </source>
  ${rom_xml}
</hostdev>
EOF
)

  audio_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${gpu_audio_pci:0:4}' bus='0x${gpu_audio_pci:5:2}' slot='0x${gpu_audio_pci:8:2}' function='0x${gpu_audio_pci:11:1}'/>
  </source>
</hostdev>
EOF
)

  controller_xml=""
  usb_attach_block=""
  if [[ "${usb_mode}" == "controller" && -n "${usb_controller_pci}" ]]; then
    controller_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${usb_controller_pci:0:4}' bus='0x${usb_controller_pci:5:2}' slot='0x${usb_controller_pci:8:2}' function='0x${usb_controller_pci:11:1}'/>
  </source>
</hostdev>
EOF
)
    usb_attach_block+=$'virsh -c qemu:///system attach-device "${VM_NAME}" /etc/passthrough/${VM_NAME}-usb-controller.xml --config\n'
  fi

  if [[ "${usb_mode}" == "evdev" ]]; then
    usb_attach_block+=$'python3 - "${xml_after}" <<\'"\'"\'PY\'"\'"\'\n'
    usb_attach_block+=$'import os\n'
    usb_attach_block+=$'import sys\n'
    usb_attach_block+=$'import xml.etree.ElementTree as ET\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'xml_path = sys.argv[1]\n'
    usb_attach_block+=$'tree = ET.parse(xml_path)\n'
    usb_attach_block+=$'root = tree.getroot()\n'
    usb_attach_block+=$'devices = root.find("devices")\n'
    usb_attach_block+=$'if devices is None:\n'
    usb_attach_block+=$'    raise SystemExit("domain XML missing <devices>")\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'seen = set()\n'
    usb_attach_block+=$'for base in ("/dev/input/by-id", "/dev/input/by-path"):\n'
    usb_attach_block+=$'    if not os.path.isdir(base):\n'
    usb_attach_block+=$'        continue\n'
    usb_attach_block+=$'    for name in sorted(os.listdir(base)):\n'
    usb_attach_block+=$'        if not (name.endswith("-event-kbd") or name.endswith("-event-mouse")):\n'
    usb_attach_block+=$'            continue\n'
    usb_attach_block+=$'        dev = os.path.join(base, name)\n'
    usb_attach_block+=$'        real = os.path.realpath(dev)\n'
    usb_attach_block+=$'        if real in seen:\n'
    usb_attach_block+=$'            continue\n'
    usb_attach_block+=$'        seen.add(real)\n'
    usb_attach_block+=$'        input_el = ET.SubElement(devices, "input", {"type": "evdev"})\n'
    usb_attach_block+=$'        attrs = {"dev": dev, "grabToggle": "shift-shift"}\n'
    usb_attach_block+=$'        if name.endswith("-event-kbd"):\n'
    usb_attach_block+=$'            attrs["grab"] = "all"\n'
    usb_attach_block+=$'            attrs["repeat"] = "on"\n'
    usb_attach_block+=$'        ET.SubElement(input_el, "source", attrs)\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'tree.write(xml_path, encoding="unicode")\n'
    usb_attach_block+=$'PY\n'
  fi

  attach_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "\${STATE_FILE}"
URI="qemu:///system"
PATCHED_WINDOWS_ISO="/var/lib/libvirt/images/\${VM_NAME}-windows-install-\${INSTALL_PROFILE:-standard}.iso"

iommu_group_devices() {
  local pci="\$1"
  local group_path
  group_path="\$(readlink -f "/sys/bus/pci/devices/\${pci}/iommu_group" 2>/dev/null || true)"
  [[ -n "\${group_path}" && -d "\${group_path}/devices" ]] || return 1
  find -L "\${group_path}/devices" -maxdepth 1 -mindepth 1 -printf '%f\n' | sort
}

pci_group_isolated() {
  local pci="\$1"
  local count
  count="\$(iommu_group_devices "\${pci}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "\${count}" == "1" ]]
}

state="\$(virsh -c "\${URI}" domstate "\${VM_NAME}" 2>/dev/null || true)"
if [[ "\${state}" == "running" ]]; then
  echo "Shut down \${VM_NAME} before finalizing GPU passthrough." >&2
  exit 1
fi

if [[ "\${USB_MODE:-none}" == "controller" && -n "\${USB_CONTROLLER_PCI:-}" ]]; then
  if ! pci_group_isolated "\${USB_CONTROLLER_PCI}"; then
    echo "Refusing to passthrough USB controller \${USB_CONTROLLER_PCI}: its IOMMU group is not isolated." >&2
    echo "Use USB device passthrough instead, or choose a controller in a standalone group." >&2
    echo "Group contents:" >&2
    iommu_group_devices "\${USB_CONTROLLER_PCI}" | while read -r dev; do
      lspci -nns "\${dev}" >&2 || true
    done
    exit 1
  fi
fi

xml_before="\$(mktemp)"
xml_after="\$(mktemp)"
trap 'rm -f "\${xml_before}" "\${xml_after}"' EXIT

virsh -c "\${URI}" dumpxml "\${VM_NAME}" > "\${xml_before}"
cp "\${xml_before}" "/etc/passthrough/\${VM_NAME}-before-gpu-passthrough.xml"
cp "\${xml_before}" "\${xml_after}"

python3 - "\${xml_after}" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()

vm_name = root.findtext("name") or "windows"
vcpus = root.findtext("vcpu") or "4"

def remove_all(parent, tag):
    for child in list(parent.findall(tag)):
        parent.remove(child)

devices = root.find("devices")
if devices is not None:
    for child in list(devices):
        if child.tag == "disk" and child.get("device") == "cdrom":
            devices.remove(child)
        elif child.tag == "hostdev":
            devices.remove(child)
        elif child.tag == "graphics" and child.get("type") == "spice":
            devices.remove(child)
        elif child.tag == "video":
            devices.remove(child)
        elif child.tag == "channel" and child.get("type") == "spicevmc":
            devices.remove(child)
        elif child.tag == "redirdev":
            devices.remove(child)
        elif child.tag == "audio" and child.get("type") == "spice":
            devices.remove(child)
        elif child.tag == "sound":
            devices.remove(child)
        elif child.tag == "input" and child.get("type") == "tablet":
            devices.remove(child)

features = root.find("features")
if features is not None:
    root.remove(features)
features = ET.Element("features")
ET.SubElement(features, "acpi")
ET.SubElement(features, "apic")
hyperv = ET.SubElement(features, "hyperv", {"mode": "custom"})
for name, state in (
    ("relaxed", "on"),
    ("vapic", "on"),
    ("spinlocks", "on"),
    ("vpindex", "on"),
    ("runtime", "on"),
    ("synic", "on"),
    ("stimer", "on"),
    ("frequencies", "on"),
    ("tlbflush", "off"),
    ("ipi", "off"),
    ("avic", "on"),
):
    ET.SubElement(hyperv, name, {"state": state})
ET.SubElement(features, "vmport", {"state": "off"})
root.insert(2, features)

cpu = root.find("cpu")
if cpu is not None:
    root.remove(cpu)
cpu = ET.Element("cpu", {"mode": "host-passthrough", "check": "none", "migratable": "on"})
ET.SubElement(cpu, "topology", {
    "sockets": "1",
    "dies": "1",
    "clusters": "1",
    "cores": vcpus.strip(),
    "threads": "1",
})
ET.SubElement(cpu, "cache", {"mode": "passthrough"})
insert_after = root.find("features")
insert_idx = list(root).index(insert_after) + 1 if insert_after is not None else 3
root.insert(insert_idx, cpu)

clock = root.find("clock")
if clock is not None:
    root.remove(clock)
clock = ET.Element("clock", {"offset": "localtime"})
ET.SubElement(clock, "timer", {"name": "hpet", "present": "yes"})
ET.SubElement(clock, "timer", {"name": "hypervclock", "present": "yes"})
insert_after = root.find("cpu")
insert_idx = list(root).index(insert_after) + 1 if insert_after is not None else 4
root.insert(insert_idx, clock)

tree.write(xml_path, encoding="unicode")
PY

virsh -c "\${URI}" define "\${xml_after}" >/dev/null
virsh -c "\${URI}" attach-device "\${VM_NAME}" /etc/passthrough/\${VM_NAME}-gpu-video.xml --config
virsh -c "\${URI}" attach-device "\${VM_NAME}" /etc/passthrough/\${VM_NAME}-gpu-audio.xml --config
${usb_attach_block}
virsh -c "\${URI}" define "\${xml_after}" >/dev/null

if [[ "\${EUID}" -eq 0 ]]; then
  /usr/local/bin/passthrough-set-stage gpu-passthrough || true
elif command -v sudo >/dev/null 2>&1; then
  sudo /usr/local/bin/passthrough-set-stage gpu-passthrough || true
else
  echo "State file is not writable; skipping stage update to gpu-passthrough" >&2
fi
echo "Attached GPU${usb_mode:+ and USB} devices to \${VM_NAME} config."
echo "Rewrote \${VM_NAME} into passthrough mode (no Spice/QXL, install media removed, Hyper-V/CPU clock blocks applied)."
echo "Next step: run ./windows from the repo directory to start the finalized passthrough VM."
EOF
)

  write_file "/etc/passthrough/autounattend/Autounattend.xml" "${unattend_xml}"
  write_file '/etc/passthrough/autounattend/$OEM$/$$/Setup/Scripts/SetupComplete.cmd' "${setupcomplete_body}"
  write_file "/etc/passthrough/${vm_name}-gpu-video.xml" "${video_xml}"
  write_file "/etc/passthrough/${vm_name}-gpu-audio.xml" "${audio_xml}"
  if [[ -n "${controller_xml}" ]]; then
    write_file "/etc/passthrough/${vm_name}-usb-controller.xml" "${controller_xml}"
  fi
  write_file "/usr/local/bin/passthrough-build-autounattend" "${build_unattend_body}"
  write_file "/usr/local/bin/passthrough-build-windows-iso" "${build_windows_body}"
  write_file "/usr/local/bin/passthrough-set-stage" "${set_stage_body}"
  write_file "/usr/local/bin/passthrough-create-vm" "${create_body}"
  write_file "/usr/local/bin/passthrough-attach-gpu" "${attach_body}"
  run chmod +x /usr/local/bin/passthrough-build-autounattend
  run chmod +x /usr/local/bin/passthrough-build-windows-iso
  run chmod +x /usr/local/bin/passthrough-set-stage
  run chmod +x /usr/local/bin/passthrough-create-vm
  run chmod +x /usr/local/bin/passthrough-attach-gpu
  run /usr/local/bin/passthrough-build-autounattend
  if [[ -f "${existing_disk}" ]]; then
    ui_note "Skipping Windows ISO generation: existing VM disk will be reused"
  else
    run /usr/local/bin/passthrough-build-windows-iso
  fi
}

create_single_gpu_hooks() {
  local vm_name="$1"
  local session_user="$2"
  local video_pci="$3"
  local audio_pci="$4"
  local video_node audio_node prepare release dispatcher

  video_node="pci_${video_pci//[:.]/_}"
  audio_node="pci_${audio_pci//[:.]/_}"

  prepare=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

GPU_VIDEO_NODE="${video_node}"
GPU_AUDIO_NODE="${audio_node}"
GPU_PCI="${video_pci}"
GPU_AUDIO_PCI="${audio_pci}"
WAIT_SECONDS=15
STATE_DIR="/run/passthrough"
SESSION_USER="${session_user}"
SYSTEM_UNITS_TO_STOP=(
  display-manager.service
  nvidia-persistenced.service
  nvidia-powerd.service
)
USER_UNITS_TO_STOP=(
  graphical-session.target
  wayland-session.target
  niri.service
)
USER_PROCESSES_TO_KILL=(
  Xorg
  Xwayland
  sway
  Hyprland
  kwin_wayland
  gnome-shell
  plasma_session
  niri
  quickshell
  qs
)

nvidia_device_minor_for_pci() {
  local info_file="/proc/driver/nvidia/gpus/\${GPU_PCI}/information"
  [[ -f "\${info_file}" ]] || return 0
  awk -F': *' '/Device Minor/ {print \$2; exit}' "\${info_file}" 2>/dev/null || true
}

gpu_device_paths() {
  local sysfs_base="/sys/bus/pci/devices/\${GPU_PCI}"
  local drm_dir entry devnode minor
  [[ -d "\${sysfs_base}" ]] || return 0

  drm_dir="\${sysfs_base}/drm"
  if [[ -d "\${drm_dir}" ]]; then
    for entry in "\${drm_dir}"/card* "\${drm_dir}"/renderD*; do
      [[ -e "\${entry}" ]] || continue
      devnode="/dev/\$(basename "\${entry}")"
      [[ -e "\${devnode}" ]] && printf '%s\n' "\${devnode}"
    done
  fi

  minor="\$(nvidia_device_minor_for_pci)"
  if [[ "\${minor}" =~ ^[0-9]+$ ]] && [[ -e "/dev/nvidia\${minor}" ]]; then
    printf '%s\n' "/dev/nvidia\${minor}"
  fi
}

log() {
  logger -t qemu-single-gpu-prepare -- "\$*"
  echo "[qemu-single-gpu-prepare] \$*" >&2
}

fail() {
  log "ERROR: \$*"
  exit 1
}

state_file_for() {
  local suffix="\$1"
  printf '%s/%s.%s\n' "\${STATE_DIR}" "\${GPU_VIDEO_NODE}" "\${suffix}"
}

user_uid() {
  id -u "\${SESSION_USER}" 2>/dev/null || true
}

user_bus_ready() {
  local uid
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] && [[ -S "/run/user/\${uid}/bus" ]]
}

get_active_display_manager() {
  local dm
  dm=\$(systemctl list-units --type=service --state=running | grep -E "gdm|sddm|lightdm|lxdm|ly|greetd" | awk '{print \$1}' | head -n1)
  echo "\${dm:-display-manager.service}"
}

stop_system_units() {
  local dm
  dm="\$(get_active_display_manager)"
  log "Stopping display manager: \${dm}"
  systemctl stop "\${dm}" 2>/dev/null || true
  systemctl stop nvidia-persistenced.service nvidia-powerd.service 2>/dev/null || true
}

stop_user_units() {
  local uid unit
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] || return 0

  if user_bus_ready; then
    for unit in "\${USER_UNITS_TO_STOP[@]}"; do
      runuser -u "\${SESSION_USER}" -- env \
        XDG_RUNTIME_DIR="/run/user/\${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \
        systemctl --user stop "\${unit}" 2>/dev/null || true
    done
  fi
}

kill_user_processes() {
  local proc
  for proc in "\${USER_PROCESSES_TO_KILL[@]}"; do
    pkill -u "\${SESSION_USER}" -TERM -x "\${proc}" 2>/dev/null || true
  done
  sleep 1
  for proc in "\${USER_PROCESSES_TO_KILL[@]}"; do
    pkill -u "\${SESSION_USER}" -KILL -x "\${proc}" 2>/dev/null || true
  done
}

gpu_user_pids() {
  local -a devices=()
  local pid
  mapfile -t devices < <(gpu_device_paths)
  [[ "\${#devices[@]}" -gt 0 ]] || return 0
  for pid in \$(fuser "\${devices[@]}" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u); do
    [[ "\${pid}" =~ ^[0-9]+$ ]] || continue
    if ps -o user= -p "\${pid}" 2>/dev/null | awk '{print \$1}' | grep -qx "\${SESSION_USER}"; then
      printf '%s\n' "\${pid}"
    fi
  done
}

report_gpu_users() {
  local pid user comm
  for pid in \$(gpu_user_pids); do
    user="\$(ps -o user= -p "\${pid}" 2>/dev/null | awk '{print \$1}' || true)"
    comm="\$(ps -o comm= -p "\${pid}" 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
    log "GPU user pid=\${pid} user=\${user:-unknown} cmd=\${comm:-unknown}"
  done
}

nuke_gpu_users() {
  local pids pid_csv count=0
  mkdir -p "\${STATE_DIR}"
  pids="\$(gpu_user_pids)"
  if [[ -n "\${pids}" ]]; then
    pid_csv="\$(printf '%s\n' "\${pids}" | paste -sd, -)"
    ps -p "\${pid_csv}" -o comm= > "\$(state_file_for killed_names)"
    log "Recording GPU users: \$(tr '\n' ' ' < "\$(state_file_for killed_names)")"
  fi

  while (( count < 5 )); do
    pids="\$(gpu_user_pids)"
    if [[ -z "\${pids}" ]]; then
      return 0
    fi
    echo "\${pids}" | xargs -r kill -9 2>/dev/null || true
    sleep 1
    ((count++))
  done
  return 1
}

wait_for_module_gone() {
  local module="\$1"
  local deadline=\$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! lsmod | awk '{print \$1}' | grep -qx "\${module}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

driver_in_use() {
  local pci="\$1"
  lspci -nnk -s "\${pci}" | awk -F': ' '/Kernel driver in use/ {print \$2; exit}'
}

already_detached_to_vfio() {
  [[ "\$(driver_in_use "\${GPU_PCI}")" == "vfio-pci" ]] && [[ "\$(driver_in_use "\${GPU_AUDIO_PCI}")" == "vfio-pci" ]]
}

unload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia_drm nvidia_modeset nvidia_uvm nvidia
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

reload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

save_release_state() {
  local driver
  driver="\$(driver_in_use "\${GPU_PCI}")"
  mkdir -p "\${STATE_DIR}"
  printf '%s\n' "\${driver}" > "\$(state_file_for driver)"
  reload_modules_for_driver "\${driver}" > "\$(state_file_for modules)" || true
  printf '%s\n' "\$(get_active_display_manager)" > "\$(state_file_for display-manager)"
}

unload_gpu_drivers() {
  local driver module
  local -a modules=()
  driver="\$(driver_in_use "\${GPU_PCI}")"
  mapfile -t modules < <(unload_modules_for_driver "\${driver}")
  [[ "\${#modules[@]}" -gt 0 ]] || return 0
  log "Unloading selected GPU driver stack for \${GPU_PCI}: \${modules[*]}"
  modprobe -r "\${modules[@]}" 2>/dev/null || true
  for module in "\${modules[@]}"; do
    if lsmod | grep -q "^\${module}"; then
      modprobe -r "\${module}" 2>/dev/null || true
      wait_for_module_gone "\${module}" || fail "\${module} is still loaded after attempted unload"
    fi
  done
}

reattach_to_host_and_fail() {
  virsh nodedev-reattach "\${GPU_AUDIO_NODE}" >/dev/null 2>&1 || true
  virsh nodedev-reattach "\${GPU_VIDEO_NODE}" >/dev/null 2>&1 || true
  fail "\$*"
}

wait_for_vfio_bind() {
  local deadline=\$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "\$(driver_in_use "\${GPU_PCI}")" == "vfio-pci" ]] && [[ "\$(driver_in_use "\${GPU_AUDIO_PCI}")" == "vfio-pci" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

log "Starting single-GPU prepare hook for \${GPU_PCI}"

if already_detached_to_vfio; then
  log "GPU is already bound to vfio-pci"
  exit 0
fi

stop_system_units
stop_user_units
kill_user_processes
sleep 1

nuke_gpu_users || {
  report_gpu_users
  fail "Selected GPU device nodes are still busy; refusing to unload the GPU driver"
}

for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 0 > "\${vt}/bind" || true
done

if [[ -e /sys/bus/platform/drivers/efi-framebuffer/unbind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind || true
fi

save_release_state
unload_gpu_drivers

modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1

virsh nodedev-detach "\${GPU_AUDIO_NODE}" || true
virsh nodedev-detach "\${GPU_VIDEO_NODE}" || true

command -v udevadm >/dev/null 2>&1 && udevadm settle || true
wait_for_vfio_bind || reattach_to_host_and_fail "GPU functions did not bind to vfio-pci"
EOF
)

  release=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

GPU_VIDEO_NODE="${video_node}"
GPU_AUDIO_NODE="${audio_node}"
STATE_DIR="/run/passthrough"

log() {
  logger -t qemu-single-gpu-release -- "\$*"
  echo "[qemu-single-gpu-release] \$*" >&2
}

state_file_for() {
  local suffix="\$1"
  printf '%s/%s.%s\n' "\${STATE_DIR}" "\${GPU_VIDEO_NODE}" "\${suffix}"
}

reload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

reload_gpu_drivers() {
  local module
  local -a modules=()

  if [[ -f "\$(state_file_for modules)" ]]; then
    mapfile -t modules < "\$(state_file_for modules)"
  fi

  if [[ "\${#modules[@]}" -eq 0 ]] && [[ -f "\$(state_file_for driver)" ]]; then
    mapfile -t modules < <(reload_modules_for_driver "\$(cat "\$(state_file_for driver)")")
  fi

  if [[ "\${#modules[@]}" -eq 0 ]]; then
    modules=(nvidia nvidia_modeset nvidia_uvm nvidia_drm amdgpu radeon nouveau xe i915)
  fi

  log "Reloading host GPU driver stack: \${modules[*]}"
  for module in "\${modules[@]}"; do
    modprobe "\${module}" || true
  done
}

virsh nodedev-reattach "\${GPU_AUDIO_NODE}" || true
virsh nodedev-reattach "\${GPU_VIDEO_NODE}" || true

modprobe -r vfio_pci vfio_iommu_type1 vfio || true

reload_gpu_drivers
sleep 1

for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 1 > "\${vt}/bind" || true
done

if [[ -e /sys/bus/platform/drivers/efi-framebuffer/bind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind || true
fi

log "Restarting NVIDIA services..."
systemctl start nvidia-persistenced.service 2>/dev/null || true
systemctl start nvidia-powerd.service 2>/dev/null || true

log "Restarting display manager..."
if [[ -f "\$(state_file_for display-manager)" ]]; then
  dm_unit="\$(cat "\$(state_file_for display-manager)")"
else
  dm_unit="display-manager.service"
fi
systemctl restart "\${dm_unit}" 2>/dev/null || systemctl start "\${dm_unit}" 2>/dev/null || true
EOF
)

  dispatcher=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${vm_name}"
HOOK_DIR="/etc/libvirt/hooks"
STATE_FILE="/etc/passthrough/passthrough.conf"

guest="\${1:-}"
operation="\${2:-}"
suboperation="\${3:-}"

if [[ "\${guest}" != "\${VM_NAME}" ]]; then
  exit 0
fi

if [[ -f "\${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "\${STATE_FILE}"
fi

if [[ "\${INSTALL_STAGE:-host-configured}" != "gpu-passthrough" ]]; then
  exit 0
fi

case "\${operation}/\${suboperation}" in
  prepare/begin)
    exec "\${HOOK_DIR}/qemu.d/\${VM_NAME}/prepare/begin/prepare.sh"
    ;;
  release/end|stopped/end)
    exec "\${HOOK_DIR}/qemu.d/\${VM_NAME}/release/end/release.sh"
    ;;
esac
EOF
)

  write_file "/etc/libvirt/hooks/qemu" "${dispatcher}"
  run chmod +x /etc/libvirt/hooks/qemu
  write_file "/etc/libvirt/hooks/qemu.d/${vm_name}/prepare/begin/prepare.sh" "${prepare}"
  write_file "/etc/libvirt/hooks/qemu.d/${vm_name}/release/end/release.sh" "${release}"
  run chmod +x "/etc/libvirt/hooks/qemu.d/${vm_name}/prepare/begin/prepare.sh"
  run chmod +x "/etc/libvirt/hooks/qemu.d/${vm_name}/release/end/release.sh"
}

clear_single_gpu_hooks() {
  local vm_name="$1"
  local hook_dir="/etc/libvirt/hooks/qemu.d/${vm_name}"
  local noop_hook

  if [[ -e /etc/libvirt/hooks/qemu ]]; then
    backup_file /etc/libvirt/hooks/qemu
  fi
  if [[ -d "${hook_dir}" ]]; then
    ensure_dir "${BACKUP_DIR}"
    run cp -a "${hook_dir}" "${BACKUP_DIR}/$(basename "${hook_dir}").${TIMESTAMP}.bak"
    run rm -rf "${hook_dir}"
  fi

  noop_hook=$'#!/usr/bin/env bash\nexit 0\n'
  write_file "/etc/libvirt/hooks/qemu" "${noop_hook}"
  run chmod +x /etc/libvirt/hooks/qemu
}

rebuild_bootloader() {
  local cmd=() output_path tmp_log
  case "$1" in
    grub)
      tmp_log="$(mktemp)"
      if [[ -d /boot/grub ]]; then
        cmd=(grub-mkconfig -o /boot/grub/grub.cfg)
        output_path="/boot/grub/grub.cfg"
      elif [[ -d /boot/grub2 ]]; then
        cmd=(grub2-mkconfig -o /boot/grub2/grub.cfg)
        output_path="/boot/grub2/grub.cfg"
      else
        warn "GRUB detected but grub.cfg path was not obvious. Rebuild it manually."
        rm -f "${tmp_log}"
        return 1
      fi
      if (( DRY_RUN )); then
        printf '[dry-run] %s\n' "${cmd[*]}"
        rm -f "${tmp_log}"
        return 0
      fi
      if "${cmd[@]}" > >(tee "${tmp_log}") 2> >(tee -a "${tmp_log}" >&2); then
        rm -f "${tmp_log}"
        return 0
      fi
      warn "GRUB rebuild failed. The passthrough config files were written, but ${output_path} was not regenerated."
      warn "This usually means there is a syntax error in /etc/default/grub or in one of the scripts under /etc/grub.d."
      warn "Check the failing line reported above and inspect /boot/grub/grub.cfg.new if GRUB created it."
      rm -f "${tmp_log}"
      return 1
      ;;
    systemd-boot)
      if command -v kernel-install >/dev/null 2>&1; then
        run kernel-install add "$(uname -r)" "/usr/lib/modules/$(uname -r)/vmlinuz" || true
      fi
      if command -v bootctl >/dev/null 2>&1; then
        run bootctl update || true
      fi
      ;;
  esac
}

show_iommu_group() {
  local pci="$1"
  local dev_path group
  dev_path="/sys/bus/pci/devices/${pci}"
  [[ -e "${dev_path}" ]] || return 0
  group="$(basename "$(readlink -f "${dev_path}/iommu_group" 2>/dev/null || true)")"
  [[ -n "${group}" ]] || return 0
  printf 'IOMMU group %s:\n' "${group}"
  find "/sys/kernel/iommu_groups/${group}/devices" -maxdepth 1 -mindepth 1 -type l | sort | while read -r node; do
    lspci -nns "${node##*/}"
  done
}

list_candidate_passthrough_domains() {
  local requested_vm="$1"
  printf '%s\n' \
    "${requested_vm}" \
    "${requested_vm}-spice" \
    "windows" \
    "windows-spice" \
    "win11" \
    "win11-spice" | awk 'NF && !seen[$0]++'
}

existing_passthrough_domains() {
  local requested_vm="$1"
  local existing_all
  existing_all="$(virsh -c qemu:///system list --all --name 2>/dev/null || true)"
  [[ -n "${existing_all}" ]] || return 0
  list_candidate_passthrough_domains "${requested_vm}" | while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    printf '%s\n' "${existing_all}" | grep -Fxq "${candidate}" && printf '%s\n' "${candidate}"
  done
}

cleanup_passthrough_domain_assets() {
  local domain_name="$1"
  local path
  for path in \
    "/var/lib/libvirt/images/${domain_name}.qcow2" \
    "/var/lib/libvirt/images/${domain_name}-autounattend.iso" \
    "/var/lib/libvirt/images/${domain_name}-windows-install-standard.iso" \
    "/var/lib/libvirt/images/${domain_name}-windows-install-winhance.iso" \
    "/var/lib/libvirt/images/${domain_name}-windows-install.iso"; do
    [[ -e "${path}" ]] || continue
    if (( DRY_RUN )); then
      printf '[dry-run] remove %s\n' "${path}"
    else
      printf 'Removing generated VM asset: %s\n' "${path}"
      rm -f "${path}"
    fi
  done
}

cleanup_existing_passthrough_vms() {
  local requested_vm="$1"
  local domains=() domain state

  while IFS= read -r domain; do
    [[ -n "${domain}" ]] || continue
    domains+=("${domain}")
  done < <(existing_passthrough_domains "${requested_vm}")

  (( ${#domains[@]} > 0 )) || return 0

  ui_section "Fresh Install Cleanup"
  ui_note "Detected old passthrough VM definitions and generated images:" >&2
  for domain in "${domains[@]}"; do
    printf '  %b-%b %s\n' "${C_YELLOW}" "${C_RESET}" "${domain}" >&2
  done
  if ! confirm "Fresh install cleanup: remove these old passthrough VMs and generated images?" "n"; then
    return 0
  fi

  for domain in "${domains[@]}"; do
    state="$(virsh -c qemu:///system domstate "${domain}" 2>/dev/null || true)"
    if [[ "${state}" == "running" || "${state}" == "paused" || "${state}" == "in shutdown" ]]; then
      run virsh -c qemu:///system destroy "${domain}" || true
    fi
    run virsh -c qemu:///system undefine "${domain}" --nvram || true
    cleanup_passthrough_domain_assets "${domain}"
  done
}

main() {
  local mode cpu_vendor gpu_entries gpu_choice gpu_pci gpu_desc gpu_audio gpu_audio_pci
  local vfio_ids user_name vm_name bootloader ovmf_code ovmf_vars virtio_iso windows_iso
  local vcpus memory_mb disk_size_gb windows_version windows_language windows_test_mode windows_password
  local usb_mode usb_controller_entries usb_controller_choice usb_controller_pci usb_device_entries usb_device_ids isolated_usb_entries
  local winhance_payload install_profile existing_disk_path bootloader_rebuild_ok="1"

  if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  elif [[ -n "${1:-}" ]]; then
    usage
    exit 2
  fi

  require_root
  preflight_dependencies
  ui_banner

  cpu_vendor="$(detect_cpu_vendor)"
  ovmf_code="$(discover_ovmf_code || true)"
  ovmf_vars="$(discover_ovmf_vars || true)"
  virtio_iso="$(discover_virtio_iso || true)"
  windows_iso="$(discover_windows_iso || true)"
  windows_version="win11x64"
  windows_language="en"
  windows_test_mode="0"
  windows_password="Passw0rd!"
  winhance_payload="0"
  install_profile="standard"
  usb_mode="none"
  usb_controller_pci=""
  usb_device_ids=""
  gpu_entries="$(list_gpus)"
  [[ -n "${gpu_entries}" ]] || fail "No discrete GPUs were detected with lspci."

  ui_section "Host Detection"
  log "Detected CPU vendor: ${cpu_vendor}"
  [[ -n "${ovmf_code}" ]] && log "Detected OVMF code: ${ovmf_code}" || warn "No OVMF_CODE file detected."
  [[ -n "${virtio_iso}" ]] && log "Detected virtio ISO: ${virtio_iso}" || warn "No virtio ISO detected."
  [[ -n "${windows_iso}" ]] && log "Detected Windows ISO: ${windows_iso}" || warn "No Windows ISO detected."
  ui_section "GPU Selection"
  printf '%bDetected GPUs:%b\n' "${C_BOLD}" "${C_RESET}"
  gpu_choice="$(select_gpu "${gpu_entries}")"
  gpu_pci="${gpu_choice%%|*}"
  gpu_desc="${gpu_choice#*|}"

  gpu_audio="$(find_gpu_audio "${gpu_pci}" | head -n1 || true)"
  if [[ -z "${gpu_audio}" ]]; then
    warn "No audio function was detected on ${gpu_pci}. Using only the video function."
    gpu_audio_pci="${gpu_pci%.*}.1"
  else
    gpu_audio_pci="${gpu_audio%%|*}"
  fi

  ui_space
  printf '%bSelected GPU:%b %s - %s\n' "${C_BOLD}" "${C_RESET}" "${gpu_pci}" "${gpu_desc}"
  printf '%bRelated functions:%b\n' "${C_BOLD}" "${C_RESET}"
  list_all_gpu_functions "${gpu_pci}" | while IFS='|' read -r slot desc; do
    printf '  - %s %s\n' "${slot}" "${desc}"
  done
  ui_space
  show_iommu_group "${gpu_pci}" || true
  ui_space

  ui_section "VM Configuration"
  case "$(prompt_menu_choice "Choose passthrough mode" "1" \
    "Single-GPU — host shares GPU, VM temporarily takes it [single]" \
    "Dedicated — GPU permanently passed through, host uses other GPU [double]")" in
    *"[single]") mode="single" ;;
    *"[double]") mode="double" ;;
    *) fail "Unexpected passthrough mode selection." ;;
  esac

  if [[ "${mode}" == "single" ]]; then
    warn "Single-GPU mode will tear down the host graphical session when the VM starts."
    warn "Browsers, Electron apps, game launchers, containers, and anything using the selected GPU may be stopped or killed."
    warn "If you have an iGPU or another host GPU available, dedicated mode is the safer default."
  fi

  user_name="$(prompt "Host username that should be added to libvirt" "${SUDO_USER:-${USER}}")"
  vm_name="$(prompt "Libvirt VM name for hook wiring" "windows")"
  cleanup_existing_passthrough_vms "${vm_name}"
  existing_disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"
  if [[ -f "${existing_disk_path}" ]]; then
    ui_note "Existing VM disk detected and will be reused: ${existing_disk_path}"
    ui_note "Skipping Windows version/language prompts (existing disk will be reused)"
  else
    windows_version="$(prompt_windows_version "${windows_version}")"
    windows_language="$(prompt_windows_language "${windows_language}")"
    windows_password="$(prompt_secret "Windows VM password" "${windows_password}")"
    if confirm "Enable Windows test mode and relaxed driver signature enforcement?" "n"; then
      windows_test_mode="1"
    fi
    if confirm "Use the full Winhance+virtio install profile instead of standard+virtio?" "n"; then
      winhance_payload="1"
      install_profile="winhance"
    fi
  fi
  vcpus="$(prompt_number "VM vCPU count" "8" "1")"
  memory_mb="$(prompt_number "VM memory in MB" "16384" "1024")"
  disk_size_gb="$(prompt_number "VM disk size in GB" "120" "32")"
  check_disk_space "/var/lib/libvirt/images" "${disk_size_gb}" "${existing_disk_path}"
  usb_controller_entries="$(list_usb_controllers || true)"
  isolated_usb_entries="$(isolated_usb_controllers "${usb_controller_entries}" || true)"
  if [[ -n "${usb_controller_entries}" ]]; then
    if [[ -z "${isolated_usb_entries}" ]]; then
      warn "No USB controllers are in an isolated IOMMU group. Controller passthrough is unsafe on this host."
      warn "Falling back to per-device USB passthrough or none."
      usb_mode="$(prompt_usb_mode "devices")"
    else
      usb_mode="$(prompt_usb_mode "controller")"
    fi
    case "${usb_mode}" in
      controller)
        usb_controller_choice="$(select_usb_controller "${isolated_usb_entries}" "$(recommended_usb_controller "${isolated_usb_entries}")")"
        usb_controller_pci="${usb_controller_choice%%|*}"
        ;;
      devices)
        usb_device_entries="$(list_usb_devices || true)"
        if [[ -n "${usb_device_entries}" ]]; then
          usb_device_ids="$(select_usb_devices "${usb_device_entries}" | cut -d'|' -f1)"
        else
          warn "No USB devices detected from sysfs. Falling back to no USB passthrough."
          usb_mode="none"
        fi
        ;;
    esac
  else
    warn "No separate USB controllers detected. USB passthrough wizard skipped."
  fi
  if [[ -f "${existing_disk_path}" ]]; then
    ui_note "Skipping Windows/virtio ISO prompts (existing disk will be reused)"
  else
    windows_iso="$(choose_windows_iso "${windows_iso}" "${windows_version}" "${windows_language}")"
    virtio_iso="$(prompt_iso_path "virtio ISO path" "${virtio_iso}" "${VIRTIO_ISO_URL}")"
  fi
  vfio_ids="$(device_ids_for_bus "${gpu_pci}")"
  [[ -n "${vfio_ids}" ]] || fail "Could not derive PCI IDs for ${gpu_pci}"

  ui_section "Plan Review"
  if [[ "${mode}" == "single" ]]; then
    ui_kv "Mode" "single-GPU (host shares GPU)"
  else
    ui_kv "Mode" "dedicated (GPU permanently passed through)"
  fi
  ui_kv "GPU bus" "${gpu_pci%.*}"
  ui_kv "VFIO IDs" "${vfio_ids}"
  ui_kv "User" "${user_name}"
  ui_kv "VM name" "${vm_name}"
  if [[ -f "${existing_disk_path}" ]]; then
    ui_kv "Existing disk" "${existing_disk_path}"
  else
    ui_kv "Windows version" "${windows_version}"
    ui_kv "Windows language" "${windows_language}"
    ui_kv "Windows password" "[hidden]"
    ui_kv "Windows test mode" "$([[ "${windows_test_mode}" == "1" ]] && printf 'enabled' || printf 'disabled')"
    ui_kv "Install profile" "${install_profile}+virtio"
    ui_kv "Windows ISO" "${windows_iso:-unset}"
    ui_kv "virtio ISO" "${virtio_iso:-unset}"
  fi
  ui_kv "vCPUs" "${vcpus}"
  ui_kv "Memory" "${memory_mb} MB"
  ui_kv "Disk" "${disk_size_gb} GB"
  ui_kv "USB mode" "${usb_mode}"
  if [[ -n "${usb_controller_pci}" ]]; then
    ui_kv "USB controller" "${usb_controller_pci}"
  fi
  if [[ -n "${usb_device_ids}" ]]; then
    ui_kv "USB devices" "$(printf '%s' "${usb_device_ids}" | paste -sd',' -)"
  fi
  ui_kv "Backups" "${BACKUP_DIR}"

  confirm "Proceed with these changes?" "y" || exit 0

  ui_section "Applying Changes"
  bootloader="$(configure_bootloader "${mode}" "${vfio_ids}" "${cpu_vendor}")"
  update_mkinitcpio "${mode}"
  configure_modprobe "${mode}" "${vfio_ids}" "${cpu_vendor}"
  configure_libvirt "${user_name}"
  write_state_file "${mode}" "${user_name}" "${vm_name}" "${gpu_pci}" "${gpu_audio_pci}" "${vfio_ids}" "${bootloader}" "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" "${windows_iso}" "${vcpus}" "${memory_mb}" "${disk_size_gb}" "${windows_version}" "${windows_language}" "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}" "${windows_test_mode}" "${winhance_payload}" "${install_profile}" "${windows_password}" "host-configured"
  create_status_script
  create_postboot_service
  create_vm_helper_scripts "${vm_name}" "${gpu_pci}" "${gpu_audio_pci}" "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}" "${windows_test_mode}" "${winhance_payload}" "${windows_password}" "${existing_disk_path}"

  if [[ "${mode}" == "single" ]]; then
    create_single_gpu_hooks "${vm_name}" "${user_name}" "${gpu_pci}" "${gpu_audio_pci}"
  else
    clear_single_gpu_hooks "${vm_name}"
  fi

  rebuild_bootloader "${bootloader}" || bootloader_rebuild_ok="0"
  if [[ -f /etc/mkinitcpio.conf ]]; then
    run mkinitcpio -P
  fi

  if confirm "Enable auto-recovery watchdog service (recovers host on VM crash)?" "y"; then
    run cp "${PWD}/passthrough-watchdog.service" /etc/systemd/system/
    run systemctl daemon-reload
    run systemctl enable --now passthrough-watchdog
    ui_kv "Watchdog service" "enabled"
  fi

  ui_section "Completed"
  ui_kv "Reboot required" "yes"
  ui_kv "Mode configured" "${mode}-GPU passthrough"
  ui_kv "Backups stored in" "${BACKUP_DIR}"
  ui_kv "Status helper" "/usr/local/bin/passthrough-status"
  ui_kv "VM create helper" "/usr/local/bin/passthrough-create-vm"
  ui_kv "GPU attach helper" "/usr/local/bin/passthrough-attach-gpu"
  if [[ "${bootloader_rebuild_ok}" != "1" ]]; then
    ui_kv "Bootloader rebuild" "failed; fix GRUB syntax and rerun grub-mkconfig"
  fi

  ui_section "After Reboot"
  printf '  %b1.%b passthrough-status\n' "${C_BLUE}" "${C_RESET}"
  printf '  %b2.%b systemctl status passthrough-postboot.service\n' "${C_BLUE}" "${C_RESET}"
  printf '  %b3.%b cat /var/log/passthrough-postboot.log\n' "${C_BLUE}" "${C_RESET}"

  ui_section "Simple Flow"
  printf '  %b1.%b Run %b./windows%b\n' "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
  printf '     %bThis creates and starts the first Spice install VM.%b\n' "${C_DIM}" "${C_RESET}"
  printf '  %b2.%b A Spice viewer should open automatically.\n' "${C_BLUE}" "${C_RESET}"
  printf '     %bIf it does not, open the VM in virt-manager or virt-viewer.%b\n' "${C_DIM}" "${C_RESET}"
  printf '  %b3.%b Install Windows in the VM.\n' "${C_BLUE}" "${C_RESET}"
  printf '  %b4.%b When the VM is shut down, run %b./windows%b again.\n' "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
  printf '     %bIt will ask whether to resume the install VM or switch to GPU passthrough.%b\n' "${C_DIM}" "${C_RESET}"
  printf '  %b5.%b After that, keep using %b./windows%b as the normal start command.\n' "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
  if [[ "${mode}" == "single" ]]; then
    ui_space
    printf '%bSingle-GPU Warning%b\n' "${C_BOLD}${C_YELLOW}" "${C_RESET}"
    printf '  %b-%b Switching to real passthrough will stop the display manager and tear down the host graphical session.\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b-%b Browsers, Electron apps, compositors, and anything using /dev/dri/* or /dev/nvidia* may be killed.\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b-%b CPU-only services usually survive. GPU-using containers may be interrupted if they hold the card open.\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b-%b When the VM shuts down, the release hook should reattach the GPU and restart the display manager automatically.\n' "${C_YELLOW}" "${C_RESET}"
  fi
  if [[ -z "${windows_iso}" ]]; then
    ui_space
    ui_note "Windows ISO download page: ${WINDOWS_ISO_URL}"
  fi
  if [[ -z "${virtio_iso}" ]]; then
    ui_note "virtio ISO download page: ${VIRTIO_ISO_URL}"
  fi
}

main "${1:-}"
