#!/usr/bin/env bash
# lib/hooks.sh — Single-GPU prepare/release hook generation and qemu dispatcher.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

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
  # KDE powerdevil silently holds the GPU I2C bus, blocking nvidia_drm unload
  # even when lsof /dev/nvidia* shows nothing. Kill it first.
  # (technique from VFIO-Nvidia-dynamic-unbind/scripts/detachgpu.sh)
  org_kde_powerdevil
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

# Signal KWin / DRM compositors to gracefully release the GPU card node before
# we yank the driver. This avoids a full DE restart on KDE Wayland in many cases.
# Technique from VFIO-Nvidia-dynamic-unbind/scripts/detachgpu.sh:
#   udevadm trigger --action=remove /dev/dri/card1
# which maps to kwin drm_backend.cpp:L190 hot-remove path.
udevadm_signal_drm_remove() {
  local sysfs_base="/sys/bus/pci/devices/\${GPU_PCI}/drm"
  local card
  [[ -d "\${sysfs_base}" ]] || return 0
  for card in "\${sysfs_base}"/card*; do
    [[ -d "\${card}" ]] || continue
    log "Sending udev remove event to DRM card: \${card}"
    udevadm trigger --action=remove "\${card}" 2>/dev/null || true
  done
  sleep 1
}

stop_user_units() {
  local uid unit
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] || return 0

  if user_bus_ready; then
    for unit in "\${USER_UNITS_TO_STOP[@]}"; do
      runuser -u "\${SESSION_USER}" -- env \\
        XDG_RUNTIME_DIR="/run/user/\${uid}" \\
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \\
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

# Fire udev remove event first so KWin can gracefully release the DRM node.
# On KDE Wayland this may avoid the need for a full display manager restart.
udevadm_signal_drm_remove

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
