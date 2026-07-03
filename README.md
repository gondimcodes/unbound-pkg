# unbound-pkg

`unbound-pkg` is a lightweight utility designed to download, compile, test, install, and manage custom Unbound Debian packages directly from official Debian source repositories.

It allows you to compile the latest Unbound release from Debian unstable or a specific release, preserving all native Debian system integrations (systemd, AppArmor, configuration paths) while avoiding common patch collision issues.

## Project Structure

```text
unbound-pkg/
├── build.sh         # Main automation script
├── builder.conf     # Configuration options (output directory, backup paths, etc.)
└── README.md        # This documentation file
```

## Setup & Configuration

You can customize the script's defaults by editing `builder.conf`:

*   `OUTPUT_DIR`: The directory where the compiled `.deb` packages will be placed (default: `output/`).
*   `BACKUP_DIR`: The directory where rollback package lists and configuration backups will be saved (default: `/var/backups/unbound-pkg`).
*   `LOG_FILE`: The build logging output file (default: `build.log`).
*   `DEBIAN_POOL_URL`: The official Debian pool archive URL used to locate Unbound package files.

## Usage

Run the script as `root` or using `sudo`.

### Build options

1.  **Build the latest version from Debian Unstable**:
    ```bash
    sudo ./build.sh --latest
    ```

2.  **Build a specific version** (e.g. `1.25.1-1`):
    ```bash
    sudo ./build.sh --version 1.25.1-1
    ```

3.  **Build from a specific DSC URL**:
    ```bash
    sudo ./build.sh --dsc https://deb.debian.org/debian/pool/main/u/unbound/unbound_1.25.1-1.dsc
    ```

### Post-Build Actions

*   **`--install`**: Installs the compiled `.deb` packages on the system after a successful compilation.
*   **`--backup`**: Backs up current `/etc/unbound` configuration and active unbound package versions to `$BACKUP_DIR` before starting the installation.
*   **`--restart`**: Restarts the Unbound system service (`systemctl restart unbound`) after installation is complete.

**Example: Build, backup, install, and restart service**:
```bash
sudo ./build.sh --latest --install --backup --restart
```

### Rollback / Recovery

If an installation or configuration check fails, or if you want to manually revert to the last working setup, run:
```bash
sudo ./build.sh --rollback
```

This will automatically:
1. Re-install the previously recorded Unbound/libunbound package versions.
2. Restore configuration files in `/etc/unbound/` from the last saved backup.
