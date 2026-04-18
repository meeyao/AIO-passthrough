# One-Click Passthrough

This repo sets up a Linux host for Windows GPU passthrough, builds an unattended Windows installer, and gives you one main command to drive the VM lifecycle:

```bash
./windows
```

It is still a guided setup, not a true zero-input one-click tool.

## What You Do

1. Run the host setup:

```bash
sudo ./passthrough-setup.sh
```

2. Reboot when the script tells you to.

3. Come back to this folder and run:

```bash
./windows
```

4. Install Windows in the Spice window.

5. Shut the VM down and run `./windows` again.

6. Confirm the switch to GPU passthrough when asked.

After that, keep using `./windows` as the normal start command.

During setup, the script also asks for the Windows local account password that will be used by the unattended install.
If it finds old passthrough VM definitions like `windows`, `windows-spice`, `win11`, or `<your-vm-name>-spice`, it can offer a fresh-install cleanup prompt to remove those stale definitions and generated images.

## What `./windows` Does

- First run: creates and starts the Windows install VM
- During install phase: reopens or resumes the Spice VM
- After install is complete: asks whether to switch to GPU passthrough
- After finalize: starts the passthrough VM normally

If you want a hint, run:

```bash
./windows-next
```

If you want more details, run:

```bash
./windows-status
```

## Install Profiles

During setup, you choose one of these:

- `standard+virtio`
  Unattended Windows install plus virtio/SPICE guest tools
- `winhance+virtio`
  The same virtio path plus the full Winhance unattended payload

## What to Expect

- A Spice viewer should open automatically during the install phase.
- If it does not, open the VM with `virt-manager` or `virt-viewer`.
- In `single` GPU mode, switching to real passthrough will stop the display manager, tear down the host graphical session, unload GPU drivers, and detach the GPU from Linux.
- The setup script now warns aggressively before `single` GPU mode proceeds, because that handoff is disruptive by design.
- Browsers, Electron apps, compositors, and anything actively using `/dev/dri/*` or `/dev/nvidia*` may be killed during that handoff.
- CPU-only services usually survive. GPU-using containers may not.
- When the passthrough VM shuts down, the release hook should reattach the GPU to Linux and restart the display manager automatically.
- If you point setup at ISOs in a user-owned path like `~/Downloads`, it will try to grant libvirt the minimum directory traversal access needed to read them.

## Fresh Installs

The setup script can detect `pacman`, `apt`, `dnf`, or `zypper`, suggest the needed package bundle, and offer to install it.

That means it can help bootstrap a fresh Arch or Ubuntu host, but it is still best treated as a tested beta, not a guaranteed works-on-every-PC release.

## Winhance Source

The `winhance+virtio` profile resolves its source unattended file in this order:

1. `WINHANCE_SOURCE_XML` if you override it
2. `/home/<user>/Downloads/autounattend.xml` if present
3. cached copy at `/etc/passthrough/source-cache/winhance-autounattend.xml`
4. upstream fetch from the credited source below, then cached locally

## Credits

- Full Winhance unattended payload source: <https://github.com/memstechtips/UnattendedWinstall/blob/main/autounattend.xml>
