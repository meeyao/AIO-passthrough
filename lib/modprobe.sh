#!/usr/bin/env bash
# lib/modprobe.sh — Initramfs and modprobe.d/modules-load.d configuration.
# Supports mkinitcpio (Arch), dracut (Fedora/openSUSE), and
# update-initramfs (Debian/Ubuntu).
# Sourced by passthrough-setup.sh; requires lib/common.sh.

detect_initramfs_tool() {
  if command -v mkinitcpio >/dev/null 2>&1 && [[ -f /etc/mkinitcpio.conf ]]; then
    printf 'mkinitcpio\n'
  elif command -v dracut >/dev/null 2>&1; then
    printf 'dracut\n'
  elif command -v update-initramfs >/dev/null 2>&1; then
    printf 'update-initramfs\n'
  else
    printf 'unknown\n'
  fi
}

rebuild_initramfs() {
  local tool
  tool="$(detect_initramfs_tool)"
  case "${tool}" in
    mkinitcpio)
      run mkinitcpio -P
      ;;
    dracut)
      run dracut --force
      ;;
    update-initramfs)
      run update-initramfs -u -k all
      ;;
    *)
      warn "No supported initramfs tool found (mkinitcpio/dracut/update-initramfs). Rebuild manually."
      ;;
  esac
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

  # Build softdep lines to ensure vfio-pci binds before GPU drivers.
  # This prevents the GPU driver from grabbing the device at boot (dedicated mode).
  local softdeps=""
  local vendor_prefix
  for vendor_prefix in ${vfio_ids//,/ }; do
    case "${vendor_prefix%%:*}" in
      10de) softdeps+=$'softdep nouveau pre: vfio-pci\nsoftdep nvidia pre: vfio-pci\nsoftdep nvidia_drm pre: vfio-pci\n' ;;
      1002) softdeps+=$'softdep amdgpu pre: vfio-pci\nsoftdep radeon pre: vfio-pci\n' ;;
      8086) softdeps+=$'softdep i915 pre: vfio-pci\nsoftdep xe pre: vfio-pci\n' ;;
    esac
  done
  # Deduplicate softdep lines
  softdeps="$(printf '%s' "${softdeps}" | sort -u)"

  if [[ "${mode}" == "double" ]]; then
    vfio_body=$'# Managed by passthrough-setup.sh\n'
    vfio_body+="options vfio-pci ids=${vfio_ids} disable_vga=1"$'\n'
    [[ -n "${softdeps}" ]] && vfio_body+="${softdeps}"$'\n'
    modules_body=$'vfio\nvfio_pci\nvfio_iommu_type1\n'
    write_file "${vfio_file}" "${vfio_body}"
    write_file "${modules_file}" "${modules_body}"
  else
    # Single-GPU mode: vfio modules are loaded/unloaded dynamically by the libvirt hook.
    # Do NOT add softdeps (they make nvidia/amdgpu depend on vfio-pci at load time,
    # breaking normal desktop boot) and do NOT pre-load vfio via modules-load.d.
    vfio_body=$'# Managed by passthrough-setup.sh\n'
    vfio_body+='# Single-GPU mode: GPU driver is unbound/rebound at VM start/stop by libvirt hooks.'$'\n'
    vfio_body+='# No static vfio-pci binding or softdeps needed here.'$'\n'
    write_file "${vfio_file}" "${vfio_body}"
    # Remove any stale modules-load.d vfio entry from a previous double-gpu setup
    if [[ -f "${modules_file}" ]]; then
      backup_file "${modules_file}"
      if (( ! DRY_RUN )); then
        : > "${modules_file}"   # truncate to empty
      fi
    fi
  fi
}

configure_kvmfr() {
  local size_mb="${1:-32}"
  local mod_file="/etc/modprobe.d/kvmfr.conf"
  local load_file="/etc/modules-load.d/kvmfr.conf"
  local udev_file="/etc/udev/rules.d/99-kvmfr.rules"

  ui_note "Configuring KVMFR module (static_size_mb=${size_mb})..."

  write_file "${mod_file}" "options kvmfr static_size_mb=${size_mb}"
  write_file "${load_file}" "kvmfr"
  write_file "${udev_file}" 'SUBSYSTEM=="kvmfr", OWNER="root", GROUP="libvirt", MODE="0660"'

  ui_note "KVMFR module configuration written. It will be active after next reboot."
}
