# One-Click Passthrough

Easily run Windows on Arch Linux with GPU Passthrough.

## Verified Hardware
This setup has been tested on:
- **GPU**: NVIDIA GeForce RTX 3070
- **CPU**: AMD Ryzen 7 3700X

*Note: This project is a work-in-progress. Additional testing for systems using Integrated GPUs (iGPUs) is needed.*

---

## Quick Setup Guide

1.  **Prepare your system**: Run the setup script to install dependencies and configure your host.
    ```bash
    sudo ./passthrough-setup.sh
    ```
2.  **Reboot** your machine.
3.  **Launch the Installer**: Run the management script to start the Windows installation VM.
    ```bash
    ./windows
    ```
    *A window will appear where you can install Windows as you normally would.*

4.  **Finalize**: Once Windows is installed and you have shut down the VM, run `./windows` again. It will ask if you want to switch to high-performance GPU passthrough mode.

## How to Manage Your VM

After the initial setup, you only need one command:

### `./windows`
This is your "one-click" command. It automatically detects what you are doing:
- **First run**: Sets up and starts the Windows installer.
- **Mid-install**: Opens the installer if it's already running.
- **Post-install**: Asks to switch to GPU Passthrough.
- **Daily use**: Boots your GPU-accelerated Windows VM.

### Other Useful Commands
If you need specific tasks, you can still use the underlying tools:
- `./windows-status`: See what state the VM is in.
- `./windows-next`: Get a tip on what to do next.
- `./windows-stop`: Safely shut down the VM.

*All management scripts are located in the `tools/` folder if you need to access them directly.*
