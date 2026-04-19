#!/usr/bin/env bash
# lib/detect.sh — Hardware and OS detection: distro, CPU, bootloader, GPU, IOMMU, OVMF, ISOs.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

# ---------------------------------------------------------------------------
# Distro detection (from /etc/os-release, fallback to package manager)
# ---------------------------------------------------------------------------
detect_distro() {
  local id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID,,}"
  fi
  case "${id}" in
    arch|manjaro|endeavouros|arcolinux|garuda|artix)
      printf 'arch\n' ;;
    debian|ubuntu|linuxmint|pop|elementary|zorin|mx|kali|pureos|neon|deepin)
      printf 'debian\n' ;;
    fedora|centos|rhel|rocky|alma|oracle)
      printf 'fedora\n' ;;
    opensuse-*|sles)
      printf 'opensuse\n' ;;
    *)
      # Fallback: detect by package manager
      if command -v pacman >/dev/null 2>&1; then
        printf 'arch\n'
      elif command -v apt >/dev/null 2>&1; then
        printf 'debian\n'
      elif command -v dnf >/dev/null 2>&1; then
        printf 'fedora\n'
      elif command -v zypper >/dev/null 2>&1; then
        printf 'opensuse\n'
      else
        printf 'unknown\n'
      fi
      ;;
  esac
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

detect_bootloader() {
  # Check Limine first — it may coexist with GRUB stubs on some distros
  if [[ -f /etc/default/limine ]]; then
    printf 'limine\n'
    return 0
  fi
  if [[ -f /etc/default/grub ]]; then
    printf 'grub\n'
    return 0
  fi
  # systemd-boot uses /etc/kernel/cmdline (kernel-install) or loader entries
  local sdboot_dirs=(/boot/loader/entries /boot/efi/loader/entries /efi/loader/entries)
  local d
  for d in "${sdboot_dirs[@]}"; do
    if [[ -d "${d}" ]]; then
      printf 'systemd-boot\n'
      return 0
    fi
  done
  if [[ -f /etc/kernel/cmdline ]]; then
    printf 'systemd-boot\n'
    return 0
  fi
  printf 'unknown\n'
}

default_iommu_params() {
  case "$1" in
    intel) printf 'intel_iommu=on iommu=pt kvm.ignore_msrs=1\n' ;;
    amd) printf 'amd_iommu=on iommu=pt kvm.ignore_msrs=1\n' ;;
    *) printf 'iommu=pt kvm.ignore_msrs=1\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# GPU detection
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# iGPU / dGPU topology detection (Phase 3)
# ---------------------------------------------------------------------------
detect_igpu() {
  # Returns the PCI slot of an integrated GPU if one exists.
  # Integrated GPUs are typically on bus 00, slot 02 (Intel) or have
  # AMD Renoir/Cezanne/Phoenix APU in the description.
  local slot desc
  while IFS='|' read -r slot desc; do
    [[ -n "${slot}" ]] || continue
    # Intel iGPUs are always at 00:02.0
    if [[ "${slot}" == *":00:02.0" ]]; then
      printf '%s|%s\n' "${slot}" "${desc}"
      return 0
    fi
    # AMD APU iGPUs — look for known APU identifiers in the description
    case "${desc,,}" in
      *renoir*|*cezanne*|*barcelo*|*rembrandt*|*phoenix*|*raphael*|*"radeon graphics"*|*"radeon vega"*)
        # Confirm it's on a low bus number (integrated, not discrete)
        local bus_num
        bus_num="$(printf '%s' "${slot}" | grep -oP ':\K[0-9a-f]{2}(?=:)' | head -1)"
        if [[ "${bus_num}" == "00" || "${bus_num}" == "01" || "${bus_num}" == "05" || "${bus_num}" == "06" ]]; then
          printf '%s|%s\n' "${slot}" "${desc}"
          return 0
        fi
        ;;
    esac
  done <<< "$(list_gpus)"
  return 1
}

# Detect if the system is a laptop
is_laptop() {
  if [[ -d /sys/class/power_supply/BAT0 ]] || [[ -d /sys/class/power_supply/BAT1 ]]; then
    return 0
  fi
  # Fallback to chassis type check
  if command -v dmidecode >/dev/null 2>&1; then
    local chassis
    chassis=$(run_maybe_sudo dmidecode -s chassis-type 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    [[ "${chassis}" == "laptop" || "${chassis}" == "notebook" || "${chassis}" == "portable" ]] && return 0
  fi
  return 1
}

detect_gpu_topology() {
  # Returns: single-gpu | igpu+dgpu | multi-dgpu
  local gpu_count igpu
  gpu_count="$(list_gpus | wc -l)"
  igpu="$(detect_igpu 2>/dev/null || true)"

  if (( gpu_count <= 1 )); then
    printf 'single-gpu\n'
  elif [[ -n "${igpu}" ]]; then
    printf 'igpu+dgpu\n'
  else
    printf 'multi-dgpu\n'
  fi
}

# ---------------------------------------------------------------------------
# IOMMU group helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# GPU selection UI
# ---------------------------------------------------------------------------
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
  local topology="${2:-unknown}"
  local igpu_slot="${3:-}"
  local choice selected

  # Annotate GPUs with role hints
  if [[ -n "${igpu_slot}" ]]; then
    while IFS='|' read -r slot desc; do
      [[ -n "${slot}" ]] || continue
      if [[ "${slot}" == "${igpu_slot}" ]]; then
        printf '%s - %s %b[integrated — host display]%b\n' "${slot}" "${desc}" "${C_DIM}" "${C_RESET}" >&2
      else
        printf '%s - %s %b[discrete — passthrough candidate]%b\n' "${slot}" "${desc}" "${C_GREEN}" "${C_RESET}" >&2
      fi
    done <<< "${entries}"
  else
    render_device_menu "${entries}"
  fi

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

# ---------------------------------------------------------------------------
# OVMF / ISO discovery
# ---------------------------------------------------------------------------
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
