# AIO-passthrough

> A robust, modular, cross-distro automated GPU passthrough setup for Linux KVM/QEMU — with anticheat concealment, Sunshine/Moonlight streaming, and a full Windows VM lifecycle manager.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Distros: Arch · Debian · Fedora](https://img.shields.io/badge/distros-Arch%20%C2%B7%20Debian%20%C2%B7%20Fedora-informational)
![GPUs: NVIDIA · AMD · Intel](https://img.shields.io/badge/GPU-NVIDIA%20%C2%B7%20AMD%20%C2%B7%20Intel-green)

---

## What it does

`passthrough-setup.sh` detects your hardware, configures VFIO, rebuilds your initramfs, patches your bootloader, creates a libvirt VM, generates a patched Windows ISO with unattended install — and installs `windows-vm` as a global shell command to manage the entire VM lifecycle from anywhere.

After a single reboot you run `windows-vm` and follow a guided two-phase install:

1. **Spice phase** — Windows installs via emulated QXL/Spice graphics so you can see the setup
2. **Passthrough phase** — run `windows-vm attach-gpu` (or just `windows-vm` again when prompted) and the VM is rewritten: Spice stripped, real GPU attached, anticheat flags injected, concealment active

---

## Features

### Hardware & Distro Support
- **GPU topologies**: single-GPU (iGPU + dGPU share), dual-GPU (dedicated passthrough GPU), multi-dGPU
- **Bootloaders**: GRUB, systemd-boot, Limine
- **Initramfs**: mkinitcpio (Arch), dracut (Fedora), update-initramfs (Debian/Ubuntu)
- **Distros**: Arch Linux, Debian, Ubuntu, Fedora, Nobara (via `/etc/os-release` detection)
- **Privilege escalation**: `sudo`, `doas`, `pkexec` — whichever is available

### Anticheat / KVM Concealment
Applied automatically to every passthrough VM XML rewrite:

| Flag | Effect |
|---|---|
| `kvm.hidden=on` | Hides `KVMKVMKVM` CPUID signature |
| `vendor_id` spoof | Random 12-char seed — prevents CPUID 0x40000000 detection |
| `hypervisor` CPUID bit disabled | Clears bit 31 of ECX in CPUID leaf 1 |
| `pmu=off` | Battleye/EAC probe Performance Monitoring Unit |
| `vmport=off` | Disables VMware I/O port backdoor (port 0x5658) |
| `msrs.unknown=fault` | Unknown MSR reads inject `#GP` instead of returning 0 |
| `ssbd` / `amd-ssbd` / `virt-ssbd` disabled | Removes KVM-specific CPUID flags |
| `kvmclock=no` | Hides KVM paravirtual clock source |
| `<smbios mode="host"/>` | VM reports real host motherboard serials via WMI |
| `memballoon=none` | Removes virtio RAM balloon (kills GPU perf and is detectable) |
| S3/S4 ACPI sleep states enabled | Bare-metal systems always expose these |
| Native TSC timer | `tsc` mode `native` for accurate VM timing |
| `topoext` (AMD only) | Correct SMT topology exposure to Windows scheduler |

### Windows ISO Automation
- Auto-downloads the latest Windows 11 ISO via the [Dockur/windows](https://github.com/dockur/windows) mirror (bypasses Microsoft's browser-gated download wall)
- Injects `Autounattend.xml`: local account, no Microsoft login, timezone UTC, partitioning, TPM/SecureBoot bypass
- `SetupComplete.cmd` runs at first login to install virtio/SPICE guest tools
- Optional **Winhance** debloat profile (downloads from [memstechtips](https://github.com/memstechtips/WIMUtil))
- Optional **Windows Test Mode** + relaxed Driver Signature Enforcement (DSE off) for custom drivers

### Sunshine / Moonlight Headless Streaming
- Toggle during setup to **auto-install Sunshine** inside the VM at first boot
- Installs **VB-Cable** virtual audio driver for headless audio capture (technique from [Parsec-Cloud-Preparation-Tool](https://github.com/K-Gibson/Parsec-Cloud-Preparation-Tool))
- Opens required firewall ports (TCP 47984/47989/47990/48010, UDP 47998-48000/48002/48010)
- `windows-vm stream` starts the VM headlessly and prints your host IP + Sunshine web UI URL
- Works with any Moonlight client — phone, Steam Deck, another PC, TV

### Single-GPU Hook Quality
- `udevadm trigger --action=remove` sent to DRM card node **before** stopping the display manager — allows KDE Wayland to gracefully release the GPU without a full DE restart (from [VFIO-Nvidia-dynamic-unbind](https://github.com/Bensikrac/VFIO-Nvidia-dynamic-unbind))
- `org_kde_powerdevil` killed before `rmmod nvidia` — prevents invisible I2C bus hold that makes `nvidia_drm` refuse to unload even with clean `lsof`
- Dispatcher checks `INSTALL_STAGE` — hooks are a no-op during Spice install phase
- Full state restoration on VM shutdown: DM restarted, drivers reloaded, VT consoles re-bound

---

## Requirements

**Packages** (auto-installed by the setup script):

| Category | Packages |
|---|---|
| KVM/QEMU | `qemu-full` / `qemu-kvm`, `libvirt`, `virt-install` |
| OVMF | `edk2-ovmf` / `ovmf` |
| Viewing | `virt-manager`, `virt-viewer` |
| ISO tools | `xorriso`, `7zip` / `p7zip` |
| Utilities | `curl`, `jq` |

**Kernel requirements:**
- IOMMU enabled (`intel_iommu=on` or `amd_iommu=on`) — the setup script adds this
- `vfio`, `vfio-pci`, `vfio_iommu_type1` modules
- Dirty-TLB fix for single-GPU (kernel ≥ 5.14)

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/meeyao/one-click-passthrough
cd one-click-passthrough

# 2. Run setup (requires root)
sudo ./passthrough-setup.sh

# 3. Reboot
sudo reboot

# 4. Start Windows — from anywhere after reboot
windows-vm
```

The setup wizard asks:
- Which GPU to pass through (auto-detected with IOMMU group isolation check)
- USB mode: evdev, controller passthrough, or none
- Windows version / language / password
- Windows Test Mode (DSE off) — for custom/unsigned drivers
- Winhance debloat — optional
- Sunshine/Moonlight streaming — installs Sunshine + VB-Cable at first Windows boot
- vCPU count, memory, disk size

---

## VM Lifecycle — `windows-vm`

Installed globally at `/usr/local/bin/windows-vm` (symlink to `./windows` in the repo).

```
windows-vm                  Smart start — detects stage, does the right thing
windows-vm start            Same as above
windows-vm stream           Headless start for Sunshine/Moonlight streaming
windows-vm sunshine         Print Sunshine connection instructions
windows-vm attach-gpu       Finalize: rewrite XML for GPU passthrough
windows-vm stop             ACPI shutdown
windows-vm destroy          Force-kill
windows-vm reset            Hard reset
windows-vm reboot           Guest reboot
windows-vm status           Show install stage + VM state
windows-vm next             Print what the next step is
windows-vm xml              Dump libvirt domain XML
```

### Install stages

| Stage | Meaning | Next action |
|---|---|---|
| `host-configured` | Setup done, VM not yet created | `windows-vm` (creates VM) |
| `spice-install` | VM exists, Windows installing via Spice | `windows-vm attach-gpu` when ready |
| `gpu-passthrough` | Fully configured for GPU passthrough | `windows-vm` (starts directly) |

---

## Modular Architecture

```
passthrough-setup.sh        Thin orchestrator — sources lib/, runs stages
lib/
  common.sh                 UI, logging, privilege escalation, write helpers
  detect.sh                 Distro, CPU, GPU, bootloader, IOMMU detection
  packages.sh               Multi-distro package management
  bootloader.sh             GRUB / systemd-boot / Limine cmdline + rebuild
  modprobe.sh               vfio.conf, softdep, initramfs rebuild
  libvirt.sh                libvirtd daemon + network configuration
  usb.sh                    USB controller / evdev device passthrough
  iso.sh                    Windows ISO resolution, Dockur mirror, patching
  windows.sh                Winhance / unattend.xml / SetupComplete.cmd
  state.sh                  State file, status script, postboot service, uninstall
  hooks.sh                  Single-GPU libvirt hook generation (prepare/release)
  vm.sh                     passthrough-create-vm, passthrough-attach-gpu helpers
windows                     VM lifecycle manager (installed as windows-vm)
```

All file modifications are backed up to `/etc/passthrough/backups/` before changes.

---

## Uninstall

```bash
sudo ./passthrough-setup.sh --uninstall
```

Removes: hooks, helper scripts, modprobe/modules configs, bootloader VFIO tokens, rebuilds initramfs. Preserves VM disks and the state file at `/etc/passthrough/`.

---

## Dry Run

```bash
sudo ./passthrough-setup.sh --dry-run
```

Prints every file write and command that would be executed without touching the system.

---

## Verified Configurations

The following hardware and software combinations have been tested and are confirmed **stable**:

### Desktop Enthusiast (Stable Build)
- **OS**: CachyOS (Arch-based)
- **Kernel**: 6.18.22-1-cachyos-lts
- **GPU**: NVIDIA RTX 3070 (GA104)
- **CPU**: AMD Ryzen
- **VM Configuration**:
  - **Memory**: 4096 MB (Stable minimum)
  - **vCPUs**: 4 (Stable default)
  - **Disk**: 32 GB (Thin provisioned)
  - **USB**: `evdev` (Highly stable for keyboard/mouse)
  - **Windows**: 11 Pro (24H2)
  - **Profiles**: Winhance + Virtio + Test Mode (DSE Off)

> [!TIP]
> If you encounter black screens or boot loops during the Spice installation phase, try backing down to **4 vCPUs** and **4096 MB RAM** temporarily. You can always increase these values in the XML after the Windows install is complete.

---

## Troubleshooting

**Post-boot validation:**
```bash
passthrough-status
cat /var/log/passthrough-postboot.log
systemctl status passthrough-postboot.service
```

**GPU still bound to host driver after reboot:**
```bash
lspci -nnk -s <GPU_PCI>   # should show "Kernel driver in use: vfio-pci"
cat /proc/cmdline          # should contain vfio-pci.ids=...
```

**Single-GPU: desktop doesn't come back after VM shutdown:**
```bash
systemctl status display-manager.service
journalctl -u display-manager.service -n 50
```

**Anticheat still detecting VM:**
- Check `windows-vm xml | grep -A5 features` — confirm `kvm hidden`, `pmu`, `vmport`, `vendor_id` are present
- EAC may require a cold boot of the VM (not a reset) after XML changes
- For FACEIT/Vanguard: additional SMBIOS spoofing (`windows-spoof-smbios.py`) may be needed

---

## Credits & Inspiration

| Project | What we borrowed |
|---|---|
| [AutoVirt](https://github.com/Scrut1ny/AutoVirt) | Anticheat flag patterns, `fmtr::box_text` UI style, softdep pattern |
| [VFIO-Nvidia-dynamic-unbind](https://github.com/Bensikrac/VFIO-Nvidia-dynamic-unbind) | `udevadm trigger --action=remove` KDE trick, powerdevil kill |
| [single-gpu-passthrough wiki](https://gitlab.com/risingprismtv/single-gpu-passthrough/-/wikis/home) | `vendor_id` spoof, `smbios mode=host`, `topoext` AMD fix |
| [Parsec-Cloud-Preparation-Tool](https://github.com/parsec-cloud/Parsec-Cloud-Preparation-Tool) | VB-Cable silent install pattern for headless audio |
| [dockur/windows](https://github.com/dockur/windows) | Windows ISO download mirror bypassing Microsoft's browser gate |

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).

This project is free software: you can redistribute it and/or modify it under the terms of the GPL v3. Commercial redistribution is prohibited.
