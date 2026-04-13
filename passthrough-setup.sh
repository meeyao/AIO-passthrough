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

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "${SCRIPT_NAME}" "$*" >&2
}

fail() {
  printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$*" >&2
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

Interactive installer for single-GPU and double-GPU VFIO passthrough.
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
      printf '%s\n' "qemu-full virt-manager virt-install dnsmasq bridge-utils edk2-ovmf swtpm pciutils libvirt mkinitcpio xorriso"
      ;;
    apt)
      printf '%s\n' "qemu-system-x86 qemu-utils virt-manager virtinst dnsmasq-base bridge-utils ovmf swtpm-tools pciutils libvirt-daemon-system libvirt-clients xorriso"
      ;;
    dnf)
      printf '%s\n' "qemu-kvm qemu-img virt-manager virt-install dnsmasq bridge-utils edk2-ovmf swtpm pciutils libvirt libvirt-daemon-config-network xorriso"
      ;;
    zypper)
      printf '%s\n' "qemu-kvm qemu-tools virt-manager virt-install dnsmasq bridge-utils ovmf swtpm pciutils libvirt xorriso"
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

preflight_dependencies() {
  local manager missing_required=() missing_recommended=() pkg_list
  local required_commands recommended_commands cmd

  required_commands=(
    awk sed grep lspci lsmod modprobe virsh systemctl
  )
  recommended_commands=(
    mkinitcpio virt-install qemu-img xorriso
  )

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

  if (( ${#missing_required[@]} > 0 )); then
    warn "Missing required commands: ${missing_required[*]}"
  fi
  if (( ${#missing_recommended[@]} > 0 )); then
    warn "Missing recommended commands: ${missing_recommended[*]}"
  fi

  if [[ -n "${pkg_list}" ]]; then
    printf 'Suggested packages for %s:\n  %s\n' "${manager}" "${pkg_list}" >&2
    if confirm "Install the suggested packages now?" "y"; then
      # shellcheck disable=SC2206
      local pkgs=( ${pkg_list} )
      install_packages "${manager}" "${pkgs[@]}"
    fi
  else
    warn "Could not determine install package names automatically."
  fi

  for cmd in "${required_commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required command after preflight: ${cmd}"
  done
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

prompt_windows_version() {
  local default="${1:-win11x64}"
  local answer normalized
  while :; do
    answer="$(prompt "Windows version (examples: 11, 11e, 11ltsc, 10, 10e, 2022)" "${default}")"
    normalized="$(normalize_windows_version "${answer}")"
    [[ -n "${normalized}" ]] || {
      warn "Invalid Windows version."
      continue
    }
    printf '%s\n' "${normalized}"
    return 0
  done
}

prompt_windows_language() {
  local default="${1:-en}"
  local answer normalized
  while :; do
    answer="$(prompt "Windows language (examples: en, en-gb, de, fr, ja)" "${default}")"
    normalized="$(normalize_windows_language "${answer}")"
    [[ -n "${normalized}" ]] || {
      warn "Invalid Windows language."
      continue
    }
    printf '%s\n' "${normalized}"
    return 0
  done
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
    read -r -p "${message} [${default}]: " answer
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "${message}: " answer
    printf '%s\n' "${answer}"
  fi
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local suffix='[y/N]'
  local answer
  [[ "${default}" == "y" ]] && suffix='[Y/n]'
  read -r -p "${message} ${suffix}: " answer
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
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
        if [[ "${label}" == "Windows ISO path" ]] && confirm "Try automatic Windows ISO download to /var/lib/libvirt/images/windows-install.iso?" "n"; then
          answer="/var/lib/libvirt/images/windows-install.iso"
          if download_windows_iso "${answer}" "${version_id}" "${language_id}"; then
            printf '%s\n' "${answer}"
            return 0
          fi
          warn "Automatic Windows ISO download failed."
          printf '%s\n' "Official download page: ${url}" >&2
        fi
        continue
      fi
      printf '\n'
      return 0
    fi

    if [[ -f "${answer}" ]]; then
      printf '%s\n' "${answer}"
      return 0
    fi

    warn "${label} not found at ${answer}"
    printf '%s\n' "Official download page: ${url}" >&2
    detected=""
  done
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

download_windows_iso() {
  local output_path="$1"
  local version_id="${2:-win11x64}"
  local language_id="${3:-en}"
  local page_url page_html product_edition_id session_id sku_json sku_id iso_json iso_url user_agent language_name

  need_download_cmds curl jq

  user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
  language_name="$(windows_language_name "${language_id}")"

  case "${version_id}" in
    win11x64) page_url="https://www.microsoft.com/en-us/software-download/windows11" ;;
    win10x64) page_url="https://www.microsoft.com/en-us/software-download/windows10ISO" ;;
    *)
      warn "Automatic download is only implemented for Windows 10/11 retail media right now."
      return 1
      ;;
  esac

  page_html="$(curl -fsSL -A "${user_agent}" "${page_url}")" || return 1
  product_edition_id="$(printf '%s' "${page_html}" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f2 | head -n1)"
  [[ -n "${product_edition_id}" ]] || return 1

  session_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  curl -fsSL -A "${user_agent}" "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=${session_id}" >/dev/null || return 1

  sku_json="$(curl -fsSL -A "${user_agent}" \
    --referer "${page_url}" \
    "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=606624d44113&ProductEditionId=${product_edition_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  sku_id="$(printf '%s' "${sku_json}" | jq -r --arg LANG "${language_name}" '.Skus[] | select(.Language==$LANG).Id' | head -n1)"
  [[ -n "${sku_id}" && "${sku_id}" != "null" ]] || return 1

  iso_json="$(curl -fsSL -A "${user_agent}" \
    --referer "${page_url}" \
    "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=606624d44113&ProductEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  iso_url="$(printf '%s' "${iso_json}" | jq -r '.ProductDownloadOptions[] | select(.DownloadType==1).Uri' | head -n1)"
  [[ -n "${iso_url}" && "${iso_url}" != "null" ]] || return 1

  ensure_dir "$(dirname "${output_path}")"
  run curl -L --fail --output "${output_path}" "${iso_url}"
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
    choice="$(prompt "Select the GPU number to passthrough")"
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

list_usb_controllers() {
  lspci -Dnn | awk '
    /USB controller|USB 3|xHCI|EHCI|OHCI/ {
      slot=$1
      desc=$0
      sub(/^[^ ]+ /, "", desc)
      print slot "|" desc
    }'
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
  local dev vendor product manufacturer product_name busnum devnum line
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "${dev}/idVendor" && -f "${dev}/idProduct" ]] || continue
    [[ -f "${dev}/busnum" && -f "${dev}/devnum" ]] || continue
    vendor="$(<"${dev}/idVendor")"
    product="$(<"${dev}/idProduct")"
    manufacturer="$(<"${dev}/manufacturer" 2>/dev/null || true)"
    product_name="$(<"${dev}/product" 2>/dev/null || true)"
    busnum="$(<"${dev}/busnum")"
    devnum="$(<"${dev}/devnum")"
    line="${vendor}:${product}|bus $(printf '%03d' "${busnum}") device $(printf '%03d' "${devnum}") - ${manufacturer} ${product_name}"
    printf '%s\n' "${line}" | sed 's/[[:space:]]\+/ /g; s/ - $//'
  done | awk '!seen[$1]++'
}

render_plain_menu() {
  local entries="$1"
  local index=1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    printf '%d) %s\n' "${index}" "${line}" >&2
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
  while :; do
    answer="$(prompt "USB passthrough mode (none/controller/devices)" "${default}")"
    case "${answer}" in
      none|controller|devices) printf '%s\n' "${answer}"; return 0 ;;
      *) warn "Enter one of: none, controller, devices." ;;
    esac
  done
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
  local selection selected_lines="" idx item entry class
  render_plain_menu "${entries}"
  printf 'Select USB device numbers separated by commas. Blank means none.\n' >&2
  selection="$(prompt "USB devices to pass through")"
  [[ -z "${selection}" ]] && return 0
  selection="${selection// /}"
  IFS=',' read -r -a items <<< "${selection}"
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
  printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++'
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
  current="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${file}" | head -n1 | cut -d'"' -f2)"
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
  current="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${file}" | head -n1 | cut -d'"' -f2)"
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
    vfio_body+='# Single-GPU mode uses dynamic bind/unbind via libvirt hooks.'$'\n'
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

  run systemctl enable --now libvirtd.service
  run systemctl enable --now libvirtd.socket
  run virsh net-autostart default
  run virsh net-start default || true
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
  local install_stage="${20}"
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
    echo "Next step: run 'windows create' to build the initial Spice install VM."
    ;;
  spice-install)
    echo "Next step: complete Windows install and guest tools in the Spice VM, then shut it down and run 'windows finalize'."
    ;;
  gpu-passthrough)
    echo "Next step: start the VM normally with 'windows start'."
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
    echo "-- double-gpu vfio config --"
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
  local create_body attach_body video_xml audio_xml unattend_xml setupcomplete_body build_unattend_body set_stage_body
  local controller_xml usb_attach_block id_pair vendor product usb_xml_path
  local user_name_placeholder

  user_name_placeholder="${SUDO_USER:-${USER:-nick}}"

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
          <Value>Passw0rd!</Value>
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
              <Value>Passw0rd!</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Re-enable network adapters</Description>
          <CommandLine>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Enable-NetAdapter -Confirm:\$false"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>Install virtio guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\virtio-win-guest-tools.exe start /wait "" %D:\virtio-win-guest-tools.exe /quiet /norestart</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>3</Order>
          <Description>Install SPICE guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\spice-guest-tools.exe start /wait "" %D:\spice-guest-tools.exe /S</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>4</Order>
          <Description>Hide Edge first-run experience</Description>
          <CommandLine>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HideFirstRunExperience" /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>5</Order>
          <Description>Show file extensions</Description>
          <CommandLine>reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>6</Order>
          <Description>Disable hibernation</Description>
          <CommandLine>cmd /C POWERCFG -H OFF</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>7</Order>
          <Description>Disable unsupported hardware notices</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>8</Order>
          <Description>Disable unsupported hardware notices second flag</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <cpi:offlineImage cpi:source="wim://windows/install.wim#Windows 11 Pro" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
)

  setupcomplete_body=$'@echo off\r\n'
  setupcomplete_body+=$'for %%D in (D E F G H I J K L M) do (\r\n'
  setupcomplete_body+=$'  if exist %%D:\\virtio-win-guest-tools.exe start /wait "" %%D:\\virtio-win-guest-tools.exe /quiet /norestart\r\n'
  setupcomplete_body+=$'  if exist %%D:\\spice-guest-tools.exe start /wait "" %%D:\\spice-guest-tools.exe /S\r\n'
  setupcomplete_body+=$')\r\n'
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
UNATTEND_ISO="/etc/passthrough/\${VM_NAME}-autounattend.iso"

[[ -n "\${WINDOWS_ISO}" ]] || {
  echo "usage: passthrough-create-vm [/path/to/windows.iso] [/path/to/virtio.iso]" >&2
  echo "Windows ISO download page: ${WINDOWS_ISO_URL}" >&2
  exit 2
}

command -v virt-install >/dev/null 2>&1 || {
  echo "virt-install is required" >&2
  exit 1
}
command -v qemu-img >/dev/null 2>&1 || {
  echo "qemu-img is required" >&2
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
[[ -f "\${WINDOWS_ISO}" ]] || {
  echo "Windows ISO not found: \${WINDOWS_ISO}" >&2
  echo "Download page: ${WINDOWS_ISO_URL}" >&2
  exit 1
}

if [[ ! -f "\${UNATTEND_ISO}" ]]; then
  /usr/local/bin/passthrough-build-autounattend
fi

if [[ ! -f "\${DISK_PATH}" ]]; then
  qemu-img create -f qcow2 "\${DISK_PATH}" "\${DISK_SIZE_GB}G"
fi

cmd=(
  virt-install
  --connect qemu:///system
  --name "\${VM_NAME}"
  --memory "\${MEMORY_MB}"
  --vcpus "\${VCPUS}"
  --cpu host-passthrough
  --machine q35
  --boot "loader=${ovmf_code},loader.readonly=yes,loader.type=pflash,nvram.template=${ovmf_vars}"
  --disk "path=\${DISK_PATH},format=qcow2,bus=sata"
  --disk "path=\${WINDOWS_ISO},device=cdrom"
  --network network=default,model=e1000e
  --graphics spice
  --video qxl
  --sound ich9
  --channel spicevmc
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb
  --osinfo detect=on,require=off
  --noautoconsole
)

if [[ -n "\${VIRTIO_MEDIA}" && -f "\${VIRTIO_MEDIA}" ]]; then
  cmd+=(--disk "path=\${VIRTIO_MEDIA},device=cdrom")
else
  echo "virtio ISO not found; continuing without attaching one" >&2
  echo "Download page: ${VIRTIO_ISO_URL}" >&2
fi

if [[ -f "\${UNATTEND_ISO}" ]]; then
  cmd+=(--disk "path=\${UNATTEND_ISO},device=cdrom")
fi

"\${cmd[@]}"
/usr/local/bin/passthrough-set-stage spice-install
echo "VM created for Spice install phase."
echo "Finish Windows install, let guest tools run, then shut the VM down and run: windows finalize"
EOF
)

  build_unattend_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "${STATE_FILE}"

SRC_DIR="/etc/passthrough/autounattend"
OUT_ISO="/etc/passthrough/${VM_NAME}-autounattend.iso"

[[ -f "${SRC_DIR}/Autounattend.xml" ]] || {
  echo "Missing ${SRC_DIR}/Autounattend.xml" >&2
  exit 1
}

if command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}" >/dev/null 2>&1
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

  video_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${gpu_pci:0:4}' bus='0x${gpu_pci:5:2}' slot='0x${gpu_pci:8:2}' function='0x${gpu_pci:11:1}'/>
  </source>
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
    usb_attach_block+=$'virsh attach-device "${VM_NAME}" /etc/passthrough/${VM_NAME}-usb-controller.xml --config\n'
  fi

  if [[ "${usb_mode}" == "devices" && -n "${usb_device_ids}" ]]; then
    while IFS= read -r id_pair; do
      [[ -n "${id_pair}" ]] || continue
      vendor="${id_pair%%:*}"
      product="${id_pair##*:}"
      usb_xml_path="/etc/passthrough/${vm_name}-usb-${vendor}-${product}.xml"
      write_file "${usb_xml_path}" "$(cat <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${vendor}'/>
    <product id='0x${product}'/>
  </source>
</hostdev>
EOF
)"
      usb_attach_block+="virsh attach-device \"\${VM_NAME}\" ${usb_xml_path} --config"$'\n'
    done <<< "${usb_device_ids}"
  fi

  attach_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "\${STATE_FILE}"

state="\$(virsh domstate "\${VM_NAME}" 2>/dev/null || true)"
if [[ "\${state}" == "running" ]]; then
  echo "Shut down \${VM_NAME} before finalizing GPU passthrough." >&2
  exit 1
fi

virsh dumpxml "\${VM_NAME}" >/dev/null
virsh attach-device "\${VM_NAME}" /etc/passthrough/\${VM_NAME}-gpu-video.xml --config
virsh attach-device "\${VM_NAME}" /etc/passthrough/\${VM_NAME}-gpu-audio.xml --config
${usb_attach_block}/usr/local/bin/passthrough-set-stage gpu-passthrough
echo "Attached GPU${usb_mode:+ and USB} devices to \${VM_NAME} config."
echo "Next step: start the finalized passthrough VM with 'windows start'."
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
  write_file "/usr/local/bin/passthrough-set-stage" "${set_stage_body}"
  write_file "/usr/local/bin/passthrough-create-vm" "${create_body}"
  write_file "/usr/local/bin/passthrough-attach-gpu" "${attach_body}"
  run chmod +x /usr/local/bin/passthrough-build-autounattend
  run chmod +x /usr/local/bin/passthrough-set-stage
  run chmod +x /usr/local/bin/passthrough-create-vm
  run chmod +x /usr/local/bin/passthrough-attach-gpu
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
SESSION_USER="${session_user}"
SYSTEM_UNITS_TO_STOP=(
  display-manager.service
)
USER_UNITS_TO_STOP=(
  graphical-session.target
  wayland-session.target
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
)

log() {
  logger -t qemu-single-gpu-prepare -- "\$*"
  echo "[qemu-single-gpu-prepare] \$*" >&2
}

fail() {
  log "ERROR: \$*"
  exit 1
}

user_uid() {
  id -u "\${SESSION_USER}" 2>/dev/null || true
}

user_bus_ready() {
  local uid
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] && [[ -S "/run/user/\${uid}/bus" ]]
}

stop_system_units() {
  local unit
  for unit in "\${SYSTEM_UNITS_TO_STOP[@]}"; do
    systemctl stop "\${unit}" 2>/dev/null || true
  done
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
  lsof -t /dev/dri/* /dev/nvidia* 2>/dev/null | sort -u
}

wait_for_no_gpu_users() {
  local deadline=\$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! gpu_user_pids | grep -q .; then
      return 0
    fi
    sleep 1
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

stop_system_units
stop_user_units
kill_user_processes
sleep 1

for dev in /dev/dri/card* /dev/nvidia*; do
  [[ -e "\${dev}" ]] || continue
  fuser -k -TERM "\${dev}" 2>/dev/null || true
done
sleep 1

if gpu_user_pids | grep -q .; then
  gpu_user_pids | xargs -r kill -KILL 2>/dev/null || true
fi

wait_for_no_gpu_users || fail "GPU device nodes are still busy"

for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 0 > "\${vt}/bind" || true
done

if [[ -e /sys/bus/platform/drivers/efi-framebuffer/unbind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind || true
fi

modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia amdgpu radeon nouveau || true
wait_for_module_gone "nvidia" || true
wait_for_module_gone "amdgpu" || true

modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1

virsh nodedev-detach "\${GPU_AUDIO_NODE}" || true
virsh nodedev-detach "\${GPU_VIDEO_NODE}" || true

[[ "\$(driver_in_use "\${GPU_PCI}")" == "vfio-pci" ]] || fail "GPU video function did not bind to vfio-pci"
[[ "\$(driver_in_use "\${GPU_AUDIO_PCI}")" == "vfio-pci" ]] || fail "GPU audio function did not bind to vfio-pci"
EOF
)

  release=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

GPU_VIDEO_NODE="${video_node}"
GPU_AUDIO_NODE="${audio_node}"

log() {
  logger -t qemu-single-gpu-release -- "\$*"
  echo "[qemu-single-gpu-release] \$*" >&2
}

virsh nodedev-reattach "\${GPU_AUDIO_NODE}" || true
virsh nodedev-reattach "\${GPU_VIDEO_NODE}" || true

modprobe -r vfio_pci vfio_iommu_type1 vfio || true

modprobe nvidia || true
modprobe nvidia_modeset || true
modprobe nvidia_uvm || true
modprobe nvidia_drm || true
modprobe amdgpu || true
modprobe radeon || true
modprobe nouveau || true

for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 1 > "\${vt}/bind" || true
done

if [[ -e /sys/bus/platform/drivers/efi-framebuffer/bind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind || true
fi

systemctl start display-manager.service 2>/dev/null || true
EOF
)

  dispatcher=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${vm_name}"
HOOK_DIR="/etc/libvirt/hooks"

guest="\${1:-}"
operation="\${2:-}"
suboperation="\${3:-}"

if [[ "\${guest}" != "\${VM_NAME}" ]]; then
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
  case "$1" in
    grub)
      if [[ -d /boot/grub ]]; then
        run grub-mkconfig -o /boot/grub/grub.cfg
      elif [[ -d /boot/grub2 ]]; then
        run grub2-mkconfig -o /boot/grub2/grub.cfg
      else
        warn "GRUB detected but grub.cfg path was not obvious. Rebuild it manually."
      fi
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

main() {
  local mode cpu_vendor gpu_entries gpu_choice gpu_pci gpu_desc gpu_audio gpu_audio_pci
  local vfio_ids user_name vm_name bootloader ovmf_code ovmf_vars virtio_iso windows_iso
  local vcpus memory_mb disk_size_gb windows_version windows_language
  local usb_mode usb_controller_entries usb_controller_choice usb_controller_pci usb_device_entries usb_device_ids

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

  cpu_vendor="$(detect_cpu_vendor)"
  ovmf_code="$(discover_ovmf_code || true)"
  ovmf_vars="$(discover_ovmf_vars || true)"
  virtio_iso="$(discover_virtio_iso || true)"
  windows_iso="$(discover_windows_iso || true)"
  windows_version="win11x64"
  windows_language="en"
  usb_mode="none"
  usb_controller_pci=""
  usb_device_ids=""
  gpu_entries="$(list_gpus)"
  [[ -n "${gpu_entries}" ]] || fail "No discrete GPUs were detected with lspci."

  log "Detected CPU vendor: ${cpu_vendor}"
  [[ -n "${ovmf_code}" ]] && log "Detected OVMF code: ${ovmf_code}" || warn "No OVMF_CODE file detected."
  [[ -n "${virtio_iso}" ]] && log "Detected virtio ISO: ${virtio_iso}" || warn "No virtio ISO detected."
  [[ -n "${windows_iso}" ]] && log "Detected Windows ISO: ${windows_iso}" || warn "No Windows ISO detected."
  printf '\nDetected GPUs:\n'
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

  printf '\nSelected GPU: %s - %s\n' "${gpu_pci}" "${gpu_desc}"
  printf 'Related functions:\n'
  list_all_gpu_functions "${gpu_pci}" | while IFS='|' read -r slot desc; do
    printf '  - %s %s\n' "${slot}" "${desc}"
  done
  printf '\n'
  show_iommu_group "${gpu_pci}" || true
  printf '\n'

  while :; do
    mode="$(prompt "Choose passthrough mode (single/double)" "single")"
    case "${mode}" in
      single|double) break ;;
      *) warn "Enter either single or double." ;;
    esac
  done

  user_name="$(prompt "Host username that should be added to libvirt" "${SUDO_USER:-${USER}}")"
  vm_name="$(prompt "Libvirt VM name for hook wiring" "windows")"
  windows_version="$(prompt_windows_version "${windows_version}")"
  windows_language="$(prompt_windows_language "${windows_language}")"
  vcpus="$(prompt_number "VM vCPU count" "8" "1")"
  memory_mb="$(prompt_number "VM memory in MB" "16384" "1024")"
  disk_size_gb="$(prompt_number "VM disk size in GB" "120" "32")"
  usb_controller_entries="$(list_usb_controllers || true)"
  if [[ -n "${usb_controller_entries}" ]]; then
    usb_mode="$(prompt_usb_mode "controller")"
    case "${usb_mode}" in
      controller)
        usb_controller_choice="$(select_usb_controller "${usb_controller_entries}" "$(recommended_usb_controller "${usb_controller_entries}")")"
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
  windows_iso="$(prompt_iso_path "Windows ISO path" "${windows_iso}" "${WINDOWS_ISO_URL}" "1" "${windows_version}" "${windows_language}")"
  virtio_iso="$(prompt_iso_path "virtio ISO path" "${virtio_iso}" "${VIRTIO_ISO_URL}")"
  vfio_ids="$(device_ids_for_bus "${gpu_pci}")"
  [[ -n "${vfio_ids}" ]] || fail "Could not derive PCI IDs for ${gpu_pci}"

  printf '\nPlanned changes:\n'
  printf '  - Mode: %s-GPU passthrough\n' "${mode}"
  printf '  - GPU bus: %s\n' "${gpu_pci%.*}"
  printf '  - VFIO IDs: %s\n' "${vfio_ids}"
  printf '  - User: %s\n' "${user_name}"
  printf '  - VM name: %s\n' "${vm_name}"
  printf '  - Windows version: %s\n' "${windows_version}"
  printf '  - Windows language: %s\n' "${windows_language}"
  printf '  - vCPUs: %s\n' "${vcpus}"
  printf '  - Memory: %s MB\n' "${memory_mb}"
  printf '  - Disk: %s GB\n' "${disk_size_gb}"
  printf '  - USB passthrough mode: %s\n' "${usb_mode}"
  if [[ -n "${usb_controller_pci}" ]]; then
    printf '  - USB controller: %s\n' "${usb_controller_pci}"
  fi
  if [[ -n "${usb_device_ids}" ]]; then
    printf '  - USB devices: %s\n' "$(printf '%s' "${usb_device_ids}" | paste -sd',' -)"
  fi
  printf '  - Windows ISO: %s\n' "${windows_iso:-unset}"
  printf '  - virtio ISO: %s\n' "${virtio_iso:-unset}"
  printf '  - Backups: %s\n\n' "${BACKUP_DIR}"

  confirm "Proceed with these changes?" "y" || exit 0

  bootloader="$(configure_bootloader "${mode}" "${vfio_ids}" "${cpu_vendor}")"
  update_mkinitcpio "${mode}"
  configure_modprobe "${mode}" "${vfio_ids}" "${cpu_vendor}"
  configure_libvirt "${user_name}"
  write_state_file "${mode}" "${user_name}" "${vm_name}" "${gpu_pci}" "${gpu_audio_pci}" "${vfio_ids}" "${bootloader}" "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" "${windows_iso}" "${vcpus}" "${memory_mb}" "${disk_size_gb}" "${windows_version}" "${windows_language}" "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}" "host-configured"
  create_status_script
  create_postboot_service
  create_vm_helper_scripts "${vm_name}" "${gpu_pci}" "${gpu_audio_pci}" "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}"

  if [[ "${mode}" == "single" ]]; then
    create_single_gpu_hooks "${vm_name}" "${user_name}" "${gpu_pci}" "${gpu_audio_pci}"
  else
    clear_single_gpu_hooks "${vm_name}"
  fi

  rebuild_bootloader "${bootloader}"
  if [[ -f /etc/mkinitcpio.conf ]]; then
    run mkinitcpio -P
  fi

  printf '\nCompleted.\n'
  printf '  - Reboot required: yes\n'
  printf '  - Mode configured: %s-GPU passthrough\n' "${mode}"
  printf '  - Backups stored in: %s\n' "${BACKUP_DIR}"
  printf '  - Status helper: /usr/local/bin/passthrough-status\n'
  printf '  - VM create helper: /usr/local/bin/passthrough-create-vm\n'
  printf '  - GPU attach helper: /usr/local/bin/passthrough-attach-gpu\n'
  printf '\nAfter reboot, verify with:\n'
  printf '  passthrough-status\n'
  printf '  systemctl status passthrough-postboot.service\n'
  printf '  cat /var/log/passthrough-postboot.log\n'
  printf '\nVM lifecycle:\n'
  printf '  passthrough-create-vm [%s] [%s]\n' "${windows_iso:-/path/to/windows.iso}" "${virtio_iso:-/path/to/virtio-win.iso}"
  printf '  windows start   # Spice install phase\n'
  printf '  windows shutdown\n'
  printf '  windows finalize\n'
  printf '  windows start   # GPU passthrough phase\n'
  if [[ -z "${windows_iso}" ]]; then
    printf '\nWindows ISO download page: %s\n' "${WINDOWS_ISO_URL}"
  fi
  if [[ -z "${virtio_iso}" ]]; then
    printf 'virtio ISO download page: %s\n' "${VIRTIO_ISO_URL}"
  fi
}

main "${1:-}"
