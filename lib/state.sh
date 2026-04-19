#!/usr/bin/env bash
# lib/state.sh — State file management, stage tracking, and cleanup/uninstall.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

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
  local sunshine_payload="${24:-0}"
  local looking_glass="${25:-0}"
  local install_stage="${26}"
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
  SUNSHINE_PAYLOAD="${sunshine_payload}"
  LOOKING_GLASS="${looking_glass}"
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
  body+=$'\n'
  body+="${stage_body}"
  body+=$'\n'
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

# ---------------------------------------------------------------------------
# Domain cleanup helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall_passthrough() {
  local vm_name bootloader
  require_root

  if [[ ! -f "${STATE_FILE}" ]]; then
    fail "No state file at ${STATE_FILE}. Nothing to uninstall."
  fi

  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  vm_name="${VM_NAME:-windows}"
  bootloader="${BOOTLOADER:-grub}"

  ui_section "Uninstalling Passthrough"

  # Remove single-GPU hooks
  if [[ -e /etc/libvirt/hooks/qemu ]]; then
    backup_file /etc/libvirt/hooks/qemu
    rm -f /etc/libvirt/hooks/qemu
  fi
  if [[ -d "/etc/libvirt/hooks/qemu.d/${vm_name}" ]]; then
    rm -rf "/etc/libvirt/hooks/qemu.d/${vm_name}"
  fi

  # Remove installed helper scripts
  local helper
  for helper in \
    /usr/local/bin/passthrough-status \
    /usr/local/bin/passthrough-create-vm \
    /usr/local/bin/passthrough-attach-gpu \
    /usr/local/bin/passthrough-set-stage \
    /usr/local/bin/passthrough-build-autounattend \
    /usr/local/bin/passthrough-build-windows-iso \
    /usr/local/bin/windows-vm \
    /usr/local/libexec/passthrough-postboot-check; do
    [[ -f "${helper}" ]] && rm -f "${helper}"
  done

  # Disable services
  systemctl disable --now passthrough-postboot.service 2>/dev/null || true
  systemctl disable --now passthrough-watchdog 2>/dev/null || true
  rm -f /etc/systemd/system/passthrough-postboot.service
  rm -f /etc/systemd/system/passthrough-watchdog.service
  systemctl daemon-reload

  # Remove modprobe/modules configs
  rm -f /etc/modprobe.d/vfio-passthrough.conf
  rm -f /etc/modules-load.d/vfio.conf

  # Clean bootloader VFIO tokens
  case "${bootloader}" in
    grub)
      remove_grub_token_prefix "vfio-pci.ids="
      remove_grub_token_prefix "rd.driver.pre="
      rebuild_bootloader grub || true
      ;;
    systemd-boot)
      remove_systemd_boot_prefix "vfio-pci.ids="
      remove_systemd_boot_prefix "rd.driver.pre="
      rebuild_bootloader systemd-boot || true
      ;;
  esac

  # Rebuild initramfs
  if [[ -f /etc/mkinitcpio.conf ]]; then
    update_mkinitcpio "single"
    mkinitcpio -P
  fi

  log "Uninstall complete. A reboot is recommended."
  log "The state file and backups remain at ${STATE_DIR}/ for reference."
  log "VM disks in /var/lib/libvirt/images/ were NOT removed."
}
