# One-Click Passthrough

Portable host setup and VM lifecycle scripts for Windows GPU passthrough with libvirt.

## Included

- `passthrough-setup.sh`
- `windows`
- `windows-create`
- `windows-install`
- `windows-finalize`
- `windows-attach-gpu`
- `windows-autounattend`
- `windows-stop`
- `windows-shutdown`
- `windows-reset`
- `windows-reboot`
- `windows-status`
- `windows-next`
- `windows-destroy`

## Intended Flow

1. Run the one-time host installer:

```bash
sudo ./passthrough-setup.sh
```

2. Reboot the host, open a fresh shell, then run:

```bash
./windows
```

That one command handles the current stage:
- if the VM has not been created yet, it creates and starts the Spice install VM
- if the install VM is shut down later, it asks whether to resume install or switch to GPU passthrough
- once finalized, it starts the normal GPU passthrough VM

3. During setup, choose one Windows install profile:
- `standard+virtio`: unattended Windows install plus virtio/SPICE guest tools
- `winhance+virtio`: the same virtio path plus the full Winhance unattended payload

4. Install Windows over Spice and let guest tools finish.

5. Shut down the VM and run `./windows` again.
At any point, run `./windows-next` or `./windows-status` to see the current stage and the next expected step.

## Notes

- In `single` GPU mode, switching from Spice install to real passthrough will stop the display manager, tear down the host graphical session, unload GPU drivers, and detach the GPU from Linux.
- GPU-using apps may be killed during that handoff. Browsers, Electron apps, compositors, and anything holding `/dev/dri/*` or `/dev/nvidia*` are especially likely to die.
- CPU-only services and containers usually survive. GPU-using containers may be interrupted if they have the card open.
- When the passthrough VM shuts down, the release hook should reattach the GPU to Linux and restart the display manager automatically.
- This export intentionally excludes machine-specific ROMs, XML dumps, compose files, and personal hardware presets.
- The installer generates host-specific state under `/etc/passthrough` when you run it.
- USB passthrough is selected interactively during setup, with a safer review loop for controller or peripheral choices.
- The `winhance+virtio` profile resolves its source unattended file in this order:
  1. `WINHANCE_SOURCE_XML` if you override it
  2. `/home/<user>/Downloads/autounattend.xml` if present
  3. cached copy at `/etc/passthrough/source-cache/winhance-autounattend.xml`
  4. upstream fetch from the credited source URL below, then cached locally

## Credits

- Full Winhance unattended payload source: <https://github.com/memstechtips/UnattendedWinstall/blob/main/autounattend.xml>
