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
- `windows-destroy`

## Intended Flow

1. Run the one-time host installer:

```bash
sudo ./passthrough-setup.sh
```

2. Create the initial install VM:

```bash
./windows create
./windows start
```

3. Install Windows over Spice and let guest tools finish.

4. Shut down the VM and finalize passthrough:

```bash
./windows shutdown
./windows finalize
./windows start
```

After `finalize`, normal `windows start` launches the GPU passthrough VM.

## Notes

- This export intentionally excludes machine-specific ROMs, XML dumps, compose files, and personal hardware presets.
- The installer generates host-specific state under `/etc/passthrough` when you run it.
- USB passthrough is selected interactively during setup.
