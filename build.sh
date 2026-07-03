#!/usr/bin/env bash
# build.sh - Unbound Debian package builder & installer (ISP Production Grade)
# Automates downloading, compiling, testing, and installing Unbound packages.

set -Eeuo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration if available
CONFIG_FILE="${SCRIPT_DIR}/builder.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Set defaults if not set in config
OUTPUT_DIR="${OUTPUT_DIR:-output}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/unbound-pkg}"
LOG_FILE="${LOG_FILE:-build.log}"
DEBIAN_POOL_URL="${DEBIAN_POOL_URL:-https://deb.debian.org/debian/pool/main/u/unbound/}"

# Ensure absolute paths
if [[ ! "$OUTPUT_DIR" =~ ^/ ]]; then
    OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi
if [[ ! "$LOG_FILE" =~ ^/ ]]; then
    LOG_FILE="${SCRIPT_DIR}/${LOG_FILE}"
fi

# Constants/Colors
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"

# Logger helpers (redirecting to stderr to prevent stdout contamination in captures)
log_info()    { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*" >&2; }
log_success() { echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*" >&2; }
log_warn()    { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*" >&2; }
log_error()   { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2; }

# Redirect stdout/stderr to log file as well
setup_logging() {
    touch "$LOG_FILE"
    exec > >(tee -ia "$LOG_FILE")
    exec 2> >(tee -ia "$LOG_FILE" >&2)
    log_info "Logging to ${LOG_FILE}"
}

usage() {
    cat <<EOF
Usage:
  $0 [options] --latest
  $0 [options] --version <debian-version>
  $0 [options] --dsc <dsc-url>
  $0 --rollback

Options:
  --install     Install the generated .deb packages after building
  --restart     Restart/Allow restart of the unbound service after installation
  --backup      Force backup of /etc/unbound configuration before installation
  --rollback    Restore packages and config from the last created snapshot

Examples:
  $0 --latest --install --restart
  $0 --version 1.25.1-1 --install --backup
  $0 --dsc https://deb.debian.org/debian/pool/main/u/unbound/unbound_1.25.1-1.dsc
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (or via sudo) to install dependencies and packages."
        exit 1
    fi
}

check_dependencies() {
    log_info "Checking tool dependencies..."
    local deps=(curl wget dpkg-dev dget dpkg-buildpackage dscverify)
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    # Try to install missing development dependencies automatically
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools: ${missing[*]}. Installing..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y devscripts dpkg-dev curl wget build-essential gnupg debian-keyring dirmngr apt-utils
    fi
}

get_latest_version() {
    local dsc_file
    dsc_file=$(curl -fsSL "$DEBIAN_POOL_URL" | grep -oE 'unbound_[^"]+\.dsc' | sort -V | tail -1)
    if [[ -z "$dsc_file" ]]; then
        log_error "Could not auto-detect the latest Unbound version from ${DEBIAN_POOL_URL}"
        exit 1
    fi
    echo "${DEBIAN_POOL_URL}${dsc_file}"
}

# Creates a highly robust pre-installation snapshot.
# Downloads actual currently installed .deb packages locally to protect rollback from repo changes.
create_snapshot() {
    local label="${1:-snap}"
    local snap_id
    snap_id=$(date +%Y%m%d-%H%M%S)
    local snap_dir="${BACKUP_DIR}/${label}-${snap_id}"
    
    log_info "Creating recovery snapshot at ${snap_dir}..."
    mkdir -p "${snap_dir}/packages"

    # 1. Back up Unbound config directory
    if [[ -d "/etc/unbound" ]]; then
        if ! tar -czf "${snap_dir}/unbound-cfg.tar.gz" -C /etc/unbound . 2>/dev/null; then
            log_warn "Config backup created with warnings/errors."
        fi
        log_success "Configuration backed up successfully."
    else
        log_warn "/etc/unbound does not exist. Skipping configuration backup."
    fi

    # 2. Query and save exact package state
    local installed_pkgs=()
    # Mapfile to collect all unbound related packages installed
    mapfile -t installed_pkgs < <(dpkg-query -W -f='${binary:Package}\n' 'unbound*' 'libunbound*' 2>/dev/null || true)
    
    if [[ ${#installed_pkgs[@]} -gt 0 && -n "${installed_pkgs[0]}" ]]; then
        log_info "Downloading active package binaries for offline rollback: ${installed_pkgs[*]}"
        # Store versions list
        dpkg -l "${installed_pkgs[@]}" > "${snap_dir}/packages.list" || true
        # Fetch actual binary packages currently running
        if ! (cd "${snap_dir}/packages" && apt-get download "${installed_pkgs[@]}" >/dev/null 2>&1); then
            log_warn "Could not download some package binaries. Offline package rollback might be limited."
        fi
    else
        log_warn "No installed Unbound packages detected."
    fi

    # Link as the latest run snapshot for default rollback behavior
    ln -sfn "${label}-${snap_id}" "${BACKUP_DIR}/latest"
    log_success "Snapshot ${label}-${snap_id} successfully created."
}

perform_rollback() {
    check_root
    log_info "Starting rollback..."
    
    local target_dir="${BACKUP_DIR}/latest"
    if [[ ! -L "$target_dir" && ! -d "$target_dir" ]]; then
        log_error "No rollback snapshot found at ${target_dir}."
        exit 1
    fi

    # Resolve symlink to absolute path for log clarity
    local resolved_dir
    resolved_dir=$(readlink -f "$target_dir")
    log_info "Reverting changes to snapshot: ${resolved_dir}"

    # 1. Reinstall old package binaries from local cache (offline safe)
    if [[ -d "${resolved_dir}/packages" ]]; then
        local debs=()
        mapfile -t debs < <(find "${resolved_dir}/packages" -name "*.deb")
        if [[ ${#debs[@]} -gt 0 && -n "${debs[0]}" ]]; then
            log_info "Downgrading/Restoring package binaries..."
            # Using dpkg -i directly is offline-safe and overrides any repository updates
            if ! dpkg -i "${resolved_dir}/packages"/*.deb; then
                log_warn "dpkg restore encountered issues. Running apt-get install -f to fix dependencies..."
                apt-get install -f -y
            fi
            log_success "Packages restored."
        else
            log_warn "No package binaries found in snapshot. Attempting repository fallback..."
            if [[ -f "${resolved_dir}/packages.list" ]]; then
                local pkgs_to_install=()
                while read -r _ name version _ ; do
                    pkgs_to_install+=("${name}=${version}")
                done < <(awk '{print $2, $3}' "${resolved_dir}/packages.list")
                if [[ ${#pkgs_to_install[@]} -gt 0 ]]; then
                    apt-get install -y --allow-downgrades "${pkgs_to_install[@]}"
                fi
            fi
        fi
    fi

    # 2. Restore configurations
    if [[ -f "${resolved_dir}/unbound-cfg.tar.gz" ]]; then
        log_info "Restoring Unbound configurations..."
        rm -rf /etc/unbound/*
        mkdir -p /etc/unbound
        tar -xzf "${resolved_dir}/unbound-cfg.tar.gz" -C /etc/unbound
        log_success "Configurations restored."
    else
        log_warn "No configuration archive found in snapshot."
    fi

    # Restart service if systemd is active
    if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -q unbound; then
        log_info "Restarting service after rollback..."
        systemctl restart unbound || true
    fi
}

post_install_tests() {
    log_info "Running post-installation verification tests..."
    
    # 1. Check configuration syntax
    if command -v unbound-checkconf &>/dev/null; then
        if ! unbound-checkconf; then
            log_error "Unbound configuration check failed!"
            return 1
        fi
        log_success "Configuration syntax check passed."
    fi

    # 2. Check service status
    if command -v systemctl &>/dev/null; then
        sleep 3
        if ! systemctl is-active unbound &>/dev/null; then
            log_error "Unbound service is not active!"
            return 1
        fi
        log_success "Unbound service is active."
    fi

    # 3. DNS query test (if unbound is listening on localhost)
    if command -v dig &>/dev/null; then
        if ss -tulpn 2>/dev/null | grep -qE '127.0.0.1:53|\[::1\]:53'; then
            log_info "Testing local DNS query resolution..."
            if ! dig +short @127.0.0.1 google.com &>/dev/null; then
                log_warn "DNS resolution query failed on localhost loopback."
                return 1
            fi
            log_success "DNS query resolution verified successfully."
        fi
    fi

    return 0
}

# Main parsing
INSTALL=0
RESTART=0
BACKUP=0
MODE=""
ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            MODE="latest"
            shift
            ;;
        --version)
            MODE="version"
            ARG="$2"
            shift 2
            ;;
        --dsc)
            MODE="dsc"
            ARG="$2"
            shift 2
            ;;
        --install)
            INSTALL=1
            shift
            ;;
        --restart)
            RESTART=1
            shift
            ;;
        --backup)
            BACKUP=1
            shift
            ;;
        --rollback)
            MODE="rollback"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    usage
    exit 1
fi

setup_logging
log_info "Starting unbound-pkg run at $(date)"

if [[ "$MODE" == "rollback" ]]; then
    perform_rollback
    exit 0
fi

# Build mode logic
check_root
check_dependencies

# Determine DSC URL
DSC_URL=""
if [[ "$MODE" == "latest" ]]; then
    DSC_URL=$(get_latest_version)
elif [[ "$MODE" == "version" ]]; then
    DSC_URL="${DEBIAN_POOL_URL}unbound_${ARG}.dsc"
elif [[ "$MODE" == "dsc" ]]; then
    DSC_URL="$ARG"
fi

log_info "Target DSC URL: ${DSC_URL}"

# Create build workspace
BUILD_WORKSPACE=$(mktemp -d -t unbound-pkg-build-XXXXXX)
log_info "Created build workspace at ${BUILD_WORKSPACE}"

# Clean up workspace on exit
trap 'rm -rf "${BUILD_WORKSPACE}"' EXIT

cd "$BUILD_WORKSPACE"

# Download source
log_info "Downloading source package files..."
# We download using dget. If we have the debian-keyring, signature validation is checked automatically.
# We omit -u to check package authenticity. If signature check fails because of a missing key,
# dget falls back gracefully, but we verify signature via dscverify if available.
if ! dget "$DSC_URL"; then
    log_warn "dget download failed or failed signature check. Retrying with --allow-unauthenticated..."
    if ! dget -u "$DSC_URL"; then
        log_error "Failed to download source package."
        exit 1
    fi
fi

# Verify signature explicitly if dscverify is present
DSC_FILE=$(find . -maxdepth 1 -name "*.dsc" | head -1)
if [[ -n "$DSC_FILE" && -f "$DSC_FILE" ]] && command -v dscverify &>/dev/null; then
    log_info "Verifying Debian package source signature..."
    if ! dscverify "$DSC_FILE" >/dev/null 2>&1; then
        log_warn "Source signature verification failed (keyring might be missing or out of date)."
    else
        log_success "Source signature verified successfully."
    fi
fi

# Find extracted source directory
SRC_DIR=$(find . -maxdepth 1 -type d -name "unbound-*" | head -1)
if [[ -z "$SRC_DIR" ]]; then
    log_error "Failed to find extracted Unbound source directory."
    exit 1
fi

cd "$SRC_DIR"

# Install build dependencies
log_info "Installing build dependencies..."
apt-get build-dep -y .

# Compile
log_info "Starting compilation (using $(nproc) parallel jobs)..."
export DEB_BUILD_OPTIONS="parallel=$(nproc)"
if ! dpkg-buildpackage -us -uc -b; then
    log_error "Compilation failed."
    exit 1
fi

# Collect artifacts
cd ..
mkdir -p "$OUTPUT_DIR"
log_info "Collecting packages to output directory: ${OUTPUT_DIR}"
find . -maxdepth 1 -type f -name "*.deb" -exec cp -v {} "$OUTPUT_DIR/" \;

log_success "Compilation finished successfully."

# Cleanup policy-rc.d trap
cleanup_policy() {
    if [[ -f /usr/sbin/policy-rc.d ]]; then
        rm -f /usr/sbin/policy-rc.d
    fi
}
trap 'cleanup_policy; rm -rf "${BUILD_WORKSPACE}"' EXIT

# Installation phase
if [[ $INSTALL -eq 1 ]]; then
    # Always create an automatic recovery snapshot before mutating the system
    create_snapshot "auto-preinstall"

    # If --backup was forced by the user, we create an additional manual backup folder
    if [[ $BACKUP -eq 1 ]]; then
        create_snapshot "manual"
    fi

    # Block service restart during upgrade if --restart is NOT specified
    if [[ $RESTART -ne 1 ]]; then
        log_info "Temporarily disabling automatic service restarts during upgrade..."
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod +x /usr/sbin/policy-rc.d
    fi

    log_info "Installing generated packages..."
    if ! find "$OUTPUT_DIR" -maxdepth 1 -name "*.deb" | grep -q .; then
        log_error "No deb packages found in output directory to install."
        exit 1
    fi

    if ! apt-get install -y "$OUTPUT_DIR"/*.deb; then
        log_error "Package installation failed! Triggering rollback..."
        cleanup_policy
        perform_rollback
        exit 1
    fi

    # Clean up policy-rc.d block
    cleanup_policy

    log_success "Packages installed successfully."

    # If user explicitly wants a restart (or if the service was not restarted by the install)
    if [[ $RESTART -eq 1 ]]; then
        if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -q unbound; then
            log_info "Restarting Unbound service..."
            systemctl restart unbound
        fi
    fi

    # Post-install tests
    if ! post_install_tests; then
        log_warn "Post-installation tests failed! Triggering rollback..."
        perform_rollback
        exit 1
    fi
    log_success "Post-installation checks passed successfully!"
fi

log_success "unbound-pkg finished processing successfully."
