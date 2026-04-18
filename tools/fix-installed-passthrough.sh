#!/usr/bin/env bash
set -euo pipefail

attach_path="/usr/local/bin/passthrough-attach-gpu"
prepare_path="/etc/libvirt/hooks/qemu.d/windows/prepare/begin/prepare.sh"

python3 - "$attach_path" "$prepare_path" <<'PY'
import re
import sys
from pathlib import Path

attach_path = Path(sys.argv[1])
prepare_path = Path(sys.argv[2])

attach = attach_path.read_text()
old_evdev = "\n".join([
    'cat <<EOF >> /etc/libvirt/qemu/${VM_NAME}.xml',
    'shopt -s nullglob',
    'for dev in /dev/input/by-id/*-event-{kbd,mouse}; do',
    '  extra_attrs=""',
    '  [[ "$dev" == *"-event-kbd" ]] && extra_attrs=\' grab="all" repeat="on"\'',
    '  printf \'    <input type="evdev">\\n      <source dev="%s" grabToggle="shift-shift"%s/>\\n    </input>\\n\' "$dev" "$extra_attrs"',
    'done',
    'EOF',
    '',
])
new_evdev = "\n".join([
    'python3 - "${xml_after}" <<\'PYXML\'',
    'import os',
    'import sys',
    'import xml.etree.ElementTree as ET',
    '',
    'xml_path = sys.argv[1]',
    'tree = ET.parse(xml_path)',
    'root = tree.getroot()',
    'devices = root.find("devices")',
    'if devices is None:',
    '    raise SystemExit("domain XML missing <devices>")',
    '',
    'seen = set()',
    'for base in ("/dev/input/by-id", "/dev/input/by-path"):',
    '    if not os.path.isdir(base):',
    '        continue',
    '    for name in sorted(os.listdir(base)):',
    '        if not (name.endswith("-event-kbd") or name.endswith("-event-mouse")):',
    '            continue',
    '        dev = os.path.join(base, name)',
    '        real = os.path.realpath(dev)',
    '        if real in seen:',
    '            continue',
    '        seen.add(real)',
    '        input_el = ET.SubElement(devices, "input", {"type": "evdev"})',
    '        attrs = {"dev": dev, "grabToggle": "shift-shift"}',
    '        if name.endswith("-event-kbd"):',
    '            attrs["grab"] = "all"',
    '            attrs["repeat"] = "on"',
    '        ET.SubElement(input_el, "source", attrs)',
    '',
    'tree.write(xml_path, encoding="unicode")',
    'PYXML',
    '',
])
if old_evdev in attach:
    attach = attach.replace(old_evdev, new_evdev)

attach = attach.replace(
    'virsh -c "${URI}" attach-device "${VM_NAME}" /etc/passthrough/${VM_NAME}-gpu-audio.xml --config\n',
    'virsh -c "${URI}" attach-device "${VM_NAME}" /etc/passthrough/${VM_NAME}-gpu-audio.xml --config\n'
    'virsh -c "${URI}" define "${xml_after}" >/dev/null\n',
    1,
)

attach_path.write_text(attach)
attach_path.chmod(0o755)

prepare = prepare_path.read_text()
if "gpu_device_paths()" not in prepare:
    helper = """
nvidia_device_minor_for_pci() {
  local info_file="/proc/driver/nvidia/gpus/${GPU_PCI}/information"
  [[ -f "${info_file}" ]] || return 0
  awk -F': *' '/Device Minor/ {print $2; exit}' "${info_file}" 2>/dev/null || true
}

gpu_device_paths() {
  local sysfs_base="/sys/bus/pci/devices/${GPU_PCI}"
  local drm_dir entry devnode minor
  [[ -d "${sysfs_base}" ]] || return 0

  drm_dir="${sysfs_base}/drm"
  if [[ -d "${drm_dir}" ]]; then
    for entry in "${drm_dir}"/card* "${drm_dir}"/renderD*; do
      [[ -e "${entry}" ]] || continue
      devnode="/dev/$(basename "${entry}")"
      [[ -e "${devnode}" ]] && printf '%s\\n' "${devnode}"
    done
  fi

  minor="$(nvidia_device_minor_for_pci)"
  if [[ "${minor}" =~ ^[0-9]+$ ]] && [[ -e "/dev/nvidia${minor}" ]]; then
    printf '%s\\n' "/dev/nvidia${minor}"
  fi
}

"""
    marker = """GPU_DRIVERS_TO_RELOAD=(
  xe
  i915
  nvidia
  nvidia_modeset
  nvidia_uvm
  nvidia_drm
  amdgpu
  radeon
  nouveau
)

"""
    prepare = prepare.replace(marker, marker + helper, 1)
    prepare = prepare.replace(
        """gpu_user_pids() {
  local pid
  for pid in $(fuser /dev/nvidia* /dev/dri/* 2>/dev/null | tr ' ' '\\n' | sed '/^$/d' | sort -u); do
""",
        """gpu_user_pids() {
  local -a devices=()
  local pid
  mapfile -t devices < <(gpu_device_paths)
  [[ "${#devices[@]}" -gt 0 ]] || return 0
  log "Tracking GPU device nodes: ${devices[*]}"
  for pid in $(fuser "${devices[@]}" 2>/dev/null | tr ' ' '\\n' | sed '/^$/d' | sort -u); do
""",
        1,
    )
    prepare = prepare.replace(
        """nuke_gpu_users() {
  local pids
  local pid_csv
  local count=0
  mkdir -p /run/passthrough
""",
        """nuke_gpu_users() {
  local pids
  local pid_csv
  local -a devices=()
  local count=0
  mkdir -p /run/passthrough
  mapfile -t devices < <(gpu_device_paths)
""",
        1,
    )
    prepare = prepare.replace(
        '      fuser -k -9 /dev/nvidia* /dev/dri/* 2>/dev/null || true\n',
        '      [[ "${#devices[@]}" -gt 0 ]] && fuser -k -9 "${devices[@]}" 2>/dev/null || true\n',
        1,
    )

prepare = prepare.replace(
    'nuke_gpu_users || log "Warning: Could not kill all processes using the GPU"\n',
    'nuke_gpu_users || fail "Selected GPU device nodes are still busy; refusing to unload the GPU driver"\n',
    1,
)

prepare = prepare.replace(
    """kill_user_processes() {
  local proc
  for proc in "${USER_PROCESSES_TO_KILL[@]}"; do
    pkill -u "${SESSION_USER}" -x "${proc}" 2>/dev/null || true
  done
}
""",
    """kill_user_processes() {
  local proc
  for proc in "${USER_PROCESSES_TO_KILL[@]}"; do
    pkill -u "${SESSION_USER}" -TERM -x "${proc}" 2>/dev/null || true
  done
  sleep 1
  for proc in "${USER_PROCESSES_TO_KILL[@]}"; do
    pkill -u "${SESSION_USER}" -KILL -x "${proc}" 2>/dev/null || true
  done
}
""",
    1,
)

prepare_path.write_text(prepare)
prepare_path.chmod(0o755)
PY

bash -n "$attach_path"
bash -n "$prepare_path"
echo "installed passthrough helpers repaired"
