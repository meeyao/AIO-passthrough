#!/usr/bin/env bash
# passthrough-setup.sh — One-Click Passthrough installer.
#
# Interactively configures a Linux host for Windows GPU passthrough via QEMU/KVM.
# Supports single-GPU mode (host temporarily yields the GPU) and dedicated mode
# (host has an iGPU or second GPU for display, dGPU is permanently passed through).
#
# Targets Arch (mkinitcpio/GRUB/systemd-boot), Debian/Ubuntu (update-initramfs),
# and Fedora/openSUSE (dracut). Bootloader config covers GRUB and systemd-boot.
#
# Usage:
#   sudo ./passthrough-setup.sh            # interactive install
#   sudo ./passthrough-setup.sh --dry-run  # preview changes, write nothing
#   sudo ./passthrough-setup.sh --uninstall # undo host changes
#
# Files written to the host:
#   /etc/passthrough/passthrough.conf
#   /etc/passthrough/backups/
#   /etc/passthrough/autounattend/
#   /etc/libvirt/hooks/qemu
#   /etc/libvirt/hooks/qemu.d/<vm>/prepare/begin/prepare.sh
#   /etc/libvirt/hooks/qemu.d/<vm>/release/end/release.sh
#   /etc/modprobe.d/vfio-passthrough.conf
#   /etc/modules-load.d/vfio.conf
#   /usr/local/bin/passthrough-{status,create-vm,attach-gpu,set-stage,...}
#   /usr/local/libexec/passthrough-postboot-check
#   /etc/systemd/system/passthrough-postboot.service
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Source library modules
# ---------------------------------------------------------------------------
for _lib in \
  common detect packages bootloader modprobe libvirt iso windows state hooks vm usb; do
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/${_lib}.sh"
done
unset _lib

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: passthrough-setup.sh [--dry-run | --uninstall | --regen-scripts [--skip-iso]]

Options:
  --dry-run       Preview all changes without writing anything to disk.
  --uninstall     Undo host-level changes made by a previous install.
  --regen-scripts Re-generate helper scripts and hooks from the existing
                  config (/etc/passthrough/passthrough.conf) without running
                  the full interactive setup wizard. Use this after pulling
                  source fixes to apply them without reinstalling everything.
  --skip-iso      When combined with --regen-scripts, skip rebuilding the
                  Windows / autounattend ISOs (useful after code-only changes).
  --help          Show this help text.

What this script does:
  - Detects your CPU, GPU topology, bootloader, and installed firmware.
  - Configures IOMMU kernel parameters (GRUB or systemd-boot).
  - Sets up modprobe / initramfs for VFIO modules.
  - Patches libvirt networking and enables required services.
  - Generates libvirt hooks for single-GPU or dedicated-GPU passthrough.
  - Builds a patched Windows ISO with unattended install and Winhance debloat.
  - Installs helper scripts under /usr/local/bin/passthrough-*.

After running, reboot and use ./windows from this repo to manage the VM.
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
regen_scripts() {
  require_root
  local conf="/etc/passthrough/passthrough.conf"
  [[ -f "${conf}" ]] || { echo "No config found at ${conf} — run setup first." >&2; exit 1; }
  # shellcheck source=/dev/null
  source "${conf}"

  local existing_disk="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  local existing_disk_path=""
  [[ -f "${existing_disk}" ]] && existing_disk_path="${existing_disk}"

  ui_banner
  ui_section "Regenerating helper scripts from existing config"
  ui_kv "Config"      "${conf}"
  ui_kv "VM name"     "${VM_NAME}"
  ui_kv "GPU"         "${GPU_PCI}"
  ui_kv "Mode"        "${MODE}"
  ui_kv "USB mode"    "${USB_MODE:-none}"
  ui_kv "Skip ISO"    "$([[ "${SKIP_ISO:-0}" == '1' ]] && echo 'yes' || echo 'no')"

  create_vm_helper_scripts \
    "${VM_NAME}" "${GPU_PCI}" "${GPU_AUDIO_PCI}" \
    "${OVMF_CODE}" "${OVMF_VARS}" "${VIRTIO_ISO:-}" \
    "${USB_MODE:-none}" "${USB_CONTROLLER_PCI:-}" "${USB_DEVICE_IDS:-}" \
    "${WINDOWS_TEST_MODE:-0}" "${WINHANCE_PAYLOAD:-0}" "${WINDOWS_PASSWORD:-Passw0rd!}" \
    "${SUNSHINE_PAYLOAD:-0}" "${LOOKING_GLASS:-0}" "${existing_disk_path}"

  if [[ "${MODE}" == "single" ]]; then
    create_single_gpu_hooks "${VM_NAME}" "${SESSION_USER}" "${GPU_PCI}" "${GPU_AUDIO_PCI}"
  else
    clear_single_gpu_hooks "${VM_NAME}"
  fi

  if [[ -f "${SCRIPT_DIR}/windows" ]]; then
    run ln -sf "${SCRIPT_DIR}/windows" /usr/local/bin/windows-vm
    run chmod +x /usr/local/bin/windows-vm
    ui_kv "Global command" "windows-vm (→ ${SCRIPT_DIR}/windows)"
  fi

  ui_section "Done"
  echo "Helper scripts and hooks regenerated from existing config."
  echo "No reboot required."
}

main() {
  # Parse flags — allow --regen-scripts and --skip-iso in any order
  local do_regen=0
  for arg in "$@"; do
    case "${arg}" in
      --help|-h)       usage; exit 0 ;;
      --dry-run)       DRY_RUN=1 ;;
      --skip-iso)      SKIP_ISO=1 ;;
      --uninstall)     uninstall_passthrough; exit 0 ;;
      --regen-scripts) do_regen=1 ;;
      "")             ;;
      *) usage; exit 2 ;;
    esac
  done
  if (( do_regen )); then
    regen_scripts
    exit 0
  fi

  require_root
  preflight_dependencies
  ui_banner

  # ─── Detection ────────────────────────────────────────────────────────────
  ui_section "Host Detection"

  local cpu_vendor topology igpu_slot igpu_slot_only
  local ovmf_code ovmf_vars virtio_iso windows_iso
  local gpu_entries gpu_choice gpu_pci gpu_desc gpu_audio gpu_audio_pci vfio_ids

  cpu_vendor="$(detect_cpu_vendor)"
  ovmf_code="$(discover_ovmf_code || true)"
  ovmf_vars="$(discover_ovmf_vars || true)"
  virtio_iso="$(discover_virtio_iso || true)"
  windows_iso="$(discover_windows_iso || true)"
  topology="$(detect_gpu_topology)"
  igpu_slot_only="$(detect_igpu 2>/dev/null | cut -d'|' -f1 || true)"

  log "CPU vendor   : ${cpu_vendor}"
  log "GPU topology : ${topology}"
  [[ -n "${ovmf_code}" ]] && log "OVMF code    : ${ovmf_code}" || warn "No OVMF_CODE found — install edk2-ovmf."
  [[ -n "${ovmf_vars}" ]] && log "OVMF vars    : ${ovmf_vars}" || warn "No OVMF_VARS found."
  [[ -n "${virtio_iso}" ]] && log "virtio ISO   : ${virtio_iso}" || warn "No virtio ISO found."
  [[ -n "${windows_iso}" ]] && log "Windows ISO  : ${windows_iso}" || warn "No Windows ISO found."

  [[ -n "${ovmf_code}" && -n "${ovmf_vars}" ]] || fail "OVMF firmware files are required. Install edk2-ovmf (Arch) or ovmf (apt/dnf)."

  gpu_entries="$(list_gpus)"
  [[ -n "${gpu_entries}" ]] || fail "No GPUs detected with lspci."

  # ─── GPU Selection ────────────────────────────────────────────────────────
  ui_section "GPU Selection"
  printf '%bDetected GPUs:%b\n' "${C_BOLD}" "${C_RESET}"
  gpu_choice="$(select_gpu "${gpu_entries}" "${topology}" "${igpu_slot_only}")"
  gpu_pci="${gpu_choice%%|*}"
  gpu_desc="${gpu_choice#*|}"

  gpu_audio="$(find_gpu_audio "${gpu_pci}" | head -n1 || true)"
  if [[ -z "${gpu_audio}" ]]; then
    warn "No audio function detected on ${gpu_pci}. Assuming .1 suffix."
    gpu_audio_pci="${gpu_pci%.*}.1"
  else
    gpu_audio_pci="${gpu_audio%%|*}"
  fi

  ui_space
  printf '%bSelected GPU:%b %s — %s\n' "${C_BOLD}" "${C_RESET}" "${gpu_pci}" "${gpu_desc}"
  printf '%bRelated PCI functions:%b\n' "${C_BOLD}" "${C_RESET}"
  list_all_gpu_functions "${gpu_pci}" | while IFS='|' read -r slot desc; do
    printf '  - %s %s\n' "${slot}" "${desc}"
  done
  ui_space
  show_iommu_group "${gpu_pci}" || true
  ui_space

  # ─── Passthrough mode ─────────────────────────────────────────────────────
  ui_section "VM Configuration"

  local mode
  local default_mode_idx="1"
  # If we detected an iGPU+dGPU layout, default to dedicated mode
  if [[ "${topology}" == "igpu+dgpu" || "${topology}" == "multi-dgpu" ]]; then
    default_mode_idx="2"
  fi

  case "$(prompt_menu_choice "Choose passthrough mode" "${default_mode_idx}" \
    "Single-GPU — host shares GPU, VM temporarily takes it [single]" \
    "Dedicated  — GPU permanently passed through, host uses other GPU [double]")" in
    *"[single]") mode="single" ;;
    *"[double]") mode="double" ;;
    *) fail "Unexpected passthrough mode selection." ;;
  esac

  if [[ "${mode}" == "single" ]]; then
    if [[ "${topology}" == "igpu+dgpu" || "${topology}" == "multi-dgpu" ]]; then
      ui_note "Note: you have multiple GPUs — dedicated mode is safer and keeps your desktop alive."
    fi
    warn "Single-GPU mode tears down the host graphical session when the VM starts."
    warn "Browsers, Electron apps, game launchers, and anything using the GPU may be killed."
  fi

  # ─── VM basic params ──────────────────────────────────────────────────────
  local user_name vm_name
  user_name="$(prompt "Host username to add to libvirt/input groups" "${SUDO_USER:-${USER}}")"
  vm_name="$(prompt "libvirt VM name" "windows")"

  cleanup_existing_passthrough_vms "${vm_name}"

  local existing_disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"
  local windows_version="win11x64"
  local windows_language="en"
  local windows_password="Passw0rd!"
  local windows_test_mode="0"
  local winhance_payload="0"
  local sunshine_payload="0"
  local install_profile="standard"

  if [[ -f "${existing_disk_path}" ]]; then
    ui_note "Existing VM disk found and will be reused: ${existing_disk_path}"
    ui_note "Skipping Windows version/language/password prompts."
  else
    windows_version="$(prompt_windows_version "${windows_version}")"
    windows_language="$(prompt_windows_language "${windows_language}")"
    windows_password="$(prompt_secret "Windows VM password" "${windows_password}")"
    if confirm "Enable Windows test mode + relaxed driver signature enforcement (DSE off)?" "n"; then
      windows_test_mode="1"
    fi
    if confirm "Apply Winhance debloat profile (downloads autounattend from memstechtips)?" "n"; then
      winhance_payload="1"
      install_profile="winhance"
    fi
    if confirm "Auto-install Sunshine inside the VM for headless Moonlight streaming?" "n"; then
      sunshine_payload="1"
    fi
    local lg_default="n"
    is_laptop && lg_default="y"
    if confirm "Install Looking Glass (shared-memory display for laptops/headless)?" "${lg_default}"; then
      looking_glass="1"
    else
      looking_glass="0"
    fi
  fi

  local vcpus memory_mb disk_size_gb
  vcpus="$(prompt_number "VM vCPU count" "4" "1")"
  memory_mb="$(prompt_number "VM memory in MB" "4096" "1024")"
  disk_size_gb="$(prompt_number "VM disk size in GB" "32" "32")"
  check_disk_space "/var/lib/libvirt/images" "${disk_size_gb}" "${existing_disk_path}"

  # ─── USB passthrough ──────────────────────────────────────────────────────
  local usb_mode="none" usb_controller_pci="" usb_device_ids=""
  local usb_controller_entries isolated_usb_entries usb_controller_choice usb_device_entries

  usb_controller_entries="$(list_usb_controllers || true)"
  isolated_usb_entries="$(isolated_usb_controllers "${usb_controller_entries}" || true)"

  if [[ -n "${usb_controller_entries}" ]]; then
    if [[ -z "${isolated_usb_entries}" ]]; then
      warn "No USB controllers are in an isolated IOMMU group. Controller passthrough is unsafe."
      warn "Falling back to per-device USB passthrough, evdev, or none."
      usb_mode="$(prompt_usb_mode "evdev")"
    else
      usb_mode="$(prompt_usb_mode "controller")"
    fi
    case "${usb_mode}" in
      controller)
        usb_controller_choice="$(select_usb_controller \
          "${isolated_usb_entries}" \
          "$(recommended_usb_controller "${isolated_usb_entries}")")"
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
    usb_mode="$(prompt_usb_mode "evdev")"
  fi

  # ─── ISO selection ────────────────────────────────────────────────────────
  if [[ -f "${existing_disk_path}" ]]; then
    ui_note "Skipping Windows/virtio ISO prompts (existing disk will be reused)."
  else
    windows_iso="$(choose_windows_iso "${windows_iso}" "${windows_version}" "${windows_language}")"
    virtio_iso="$(choose_virtio_iso "${virtio_iso}")"
  fi

  vfio_ids="$(device_ids_for_bus "${gpu_pci}")"
  [[ -n "${vfio_ids}" ]] || fail "Could not derive PCI device IDs for ${gpu_pci}."

  # ─── Plan review ──────────────────────────────────────────────────────────
  ui_section "Plan Review"
  ui_kv "Mode"             "${mode}-GPU passthrough"
  ui_kv "GPU"             "${gpu_pci} — ${gpu_desc}"
  ui_kv "GPU audio"       "${gpu_audio_pci}"
  ui_kv "VFIO IDs"        "${vfio_ids}"
  ui_kv "CPU vendor"      "${cpu_vendor}"
  ui_kv "User"            "${user_name}"
  ui_kv "VM name"         "${vm_name}"
  if [[ -f "${existing_disk_path}" ]]; then
    ui_kv "Existing disk"  "${existing_disk_path}"
  else
    ui_kv "Windows ver."   "${windows_version}"
    ui_kv "Language"       "${windows_language}"
    ui_kv "Password"       "[hidden]"
    ui_kv "Test mode"      "$([[ "${windows_test_mode}" == "1" ]] && printf 'enabled' || printf 'disabled')"
    ui_kv "Sunshine/VB-Cable" "$([[ "${sunshine_payload}" == "1" ]] && printf 'enabled (installs on first boot)' || printf 'disabled')"
    ui_kv "Looking Glass"  "$([[ "${looking_glass}" == "1" ]] && printf 'enabled' || printf 'disabled')"
    ui_kv "Install profile" "${install_profile}+virtio"
    ui_kv "Windows ISO"    "${windows_iso:-unset}"
    ui_kv "virtio ISO"     "${virtio_iso:-unset}"
  fi
  ui_kv "vCPUs"           "${vcpus}"
  ui_kv "Memory"          "${memory_mb} MB"
  ui_kv "Disk"            "${disk_size_gb} GB"
  ui_kv "USB mode"        "${usb_mode}"
  [[ -n "${usb_controller_pci}" ]] && ui_kv "USB controller" "${usb_controller_pci}"
  [[ -n "${usb_device_ids}" ]]  && ui_kv "USB devices"    "$(printf '%s' "${usb_device_ids}" | paste -sd',' -)"
  ui_kv "Backups"         "${BACKUP_DIR}"
  ui_kv "OVMF code"       "${ovmf_code}"
  ui_kv "OVMF vars"       "${ovmf_vars}"

  if is_laptop; then
    echo
    ui_warn "Laptop hardware detected!"
    echo "  - If you do NOT have a Mux Switch: you must use Looking Glass or Sunshine."
    echo "  - The internal laptop screen will remain black otherwise."
    echo "  - Many laptop HDMI/DP ports are wired to the iGPU and will also remain black."
  fi

  echo
  confirm "Proceed with these changes?" "y" || exit 0

  # ─── Apply ────────────────────────────────────────────────────────────────
  ui_section "Applying Changes"

  local bootloader bootloader_rebuild_ok="1"
  bootloader="$(configure_bootloader "${mode}" "${vfio_ids}" "${cpu_vendor}")"
  update_mkinitcpio "${mode}"
  configure_modprobe "${mode}" "${vfio_ids}" "${cpu_vendor}"
  configure_libvirt "${user_name}"

  write_state_file \
    "${mode}" "${user_name}" "${vm_name}" \
    "${gpu_pci}" "${gpu_audio_pci}" "${vfio_ids}" "${bootloader}" \
    "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" "${windows_iso}" \
    "${vcpus}" "${memory_mb}" "${disk_size_gb}" \
    "${windows_version}" "${windows_language}" \
    "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}" \
    "${windows_test_mode}" "${winhance_payload}" "${install_profile}" \
    "${windows_password}" "${sunshine_payload}" "${looking_glass}" "host-configured"

  create_status_script
  create_postboot_service
  create_vm_helper_scripts \
    "${vm_name}" "${gpu_pci}" "${gpu_audio_pci}" \
    "${ovmf_code}" "${ovmf_vars}" "${virtio_iso}" \
    "${usb_mode}" "${usb_controller_pci}" "${usb_device_ids}" \
    "${windows_test_mode}" "${winhance_payload}" "${windows_password}" \
    "${sunshine_payload}" "${looking_glass}" "${existing_disk_path}"

  if [[ "${mode}" == "single" ]]; then
    create_single_gpu_hooks "${vm_name}" "${user_name}" "${gpu_pci}" "${gpu_audio_pci}"
  else
    clear_single_gpu_hooks "${vm_name}"
  fi

  rebuild_bootloader "${bootloader}" || bootloader_rebuild_ok="0"
  rebuild_initramfs

  if confirm "Enable auto-recovery watchdog service?" "y"; then
    run cp "${SCRIPT_DIR}/passthrough-watchdog.service" /etc/systemd/system/
    run cp "${SCRIPT_DIR}/tools/windows-watchdog" /usr/local/bin/passthrough-watchdog
    run chmod +x /usr/local/bin/passthrough-watchdog
    run cp "${SCRIPT_DIR}/tools/windows-reset-host" /usr/local/bin/passthrough-reset-host
    run chmod +x /usr/local/bin/passthrough-reset-host
    run systemctl daemon-reload
    run systemctl enable --now passthrough-watchdog
    ui_kv "Watchdog" "enabled"
  fi

  if [[ "${looking_glass}" == "1" ]]; then
    ui_section "Looking Glass Setup"
    echo "Creating /dev/shm/looking-glass permission rule..."
    printf 'f /dev/shm/looking-glass 0666 root root -\n' | run_maybe_sudo tee /etc/tmpfiles.d/10-looking-glass.conf >/dev/null
    run_maybe_sudo systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf
    ui_kv "Looking Glass SHM" "initialized (0666)"
  fi

  # ─── Install windows-vm global command ───────────────────────────────────
  if [[ -f "${SCRIPT_DIR}/windows" ]]; then
    run ln -sf "${SCRIPT_DIR}/windows" /usr/local/bin/windows-vm
    run chmod +x /usr/local/bin/windows-vm
    ui_kv "Global command" "windows-vm (→ ${SCRIPT_DIR}/windows)"
  fi

  # ─── Summary ──────────────────────────────────────────────────────────────
  ui_section "Done"
  ui_kv "Reboot required"   "yes"
  ui_kv "Mode configured"   "${mode}-GPU passthrough"
  ui_kv "Backups stored in" "${BACKUP_DIR}"
  ui_kv "Status helper"     "/usr/local/bin/passthrough-status"
  [[ "${bootloader_rebuild_ok}" != "1" ]] && \
    ui_kv "Bootloader rebuild" "FAILED — fix GRUB syntax and rerun grub-mkconfig"

  ui_section "After Reboot"
  printf '  %b1.%b passthrough-status\n' "${C_BLUE}" "${C_RESET}"
  printf '  %b2.%b systemctl status passthrough-postboot.service\n' "${C_BLUE}" "${C_RESET}"
  printf '  %b3.%b cat /var/log/passthrough-postboot.log\n' "${C_BLUE}" "${C_RESET}"

  ui_section "Then Start Windows"
  printf '  %bwindows-vm%b  — from anywhere in your shell\n' "${C_BOLD}" "${C_RESET}"
  printf '  %b./windows%b   — from the repo directory\n' "${C_BOLD}" "${C_RESET}"
  printf '\n'
  printf '  %bwindows-vm start%b     smart start: install → Spice → GPU passthrough\n' "${C_DIM}" "${C_RESET}"
  printf '  %bwindows-vm stop%b      ACPI shutdown\n' "${C_DIM}" "${C_RESET}"
  printf '  %bwindows-vm attach-gpu%b finalize passthrough (after Spice install)\n' "${C_DIM}" "${C_RESET}"
  printf '  %bwindows-vm status%b    check VM stage and state\n' "${C_DIM}" "${C_RESET}"

  if [[ "${mode}" == "single" ]]; then

    ui_space
    printf '%bSingle-GPU Warning%b\n' "${C_BOLD}${C_YELLOW}" "${C_RESET}"
    printf '  Switching to GPU passthrough mode will kill your desktop session.\n'
    printf '  Desktop restores automatically when the VM shuts down.\n'
  fi
  if [[ -z "${windows_iso:-}" ]]; then
    ui_space
    ui_note "Windows ISO download: ${WINDOWS_ISO_URL}"
    ui_note "Or clone https://github.com/dockur/windows and set DOCKUR_WINDOWS_SRC."
  fi
  if [[ -z "${virtio_iso:-}" ]]; then
    ui_note "virtio ISO download: ${VIRTIO_ISO_URL}"
  fi
}

export SKIP_ISO="${SKIP_ISO:-0}"
main "$@"
