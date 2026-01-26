#!/bin/bash

# Common utilities for VM setup scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}$1${NC}" >&2
}

# Get the directory where the script is located
# Returns absolute path to tools/ directory
get_script_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
}

# Wait for SSH to be available and add host keys to known_hosts
# Arguments:
#   $1 - VM IP address (authoritative source from platform)
#   $2 - hostname to write to known_hosts (e.g., myvm.local)
#   $3 - max retry attempts (default: 30)
#   $4 - retry interval in seconds (default: 2)
wait_for_ssh_and_add_known_host() {
    local vm_ip="$1"
    local hostname="$2"
    local max_retries="${3:-30}"
    local retry_interval="${4:-2}"
    local attempt=0

    if [[ -z "$vm_ip" ]]; then
        warn "No VM IP provided, cannot configure SSH host keys"
        warn "You will see a host key verification prompt on first connection"
        return 1
    fi

    # Wait for SSH to be available on that IP
    info "Waiting for SSH to be available on $vm_ip..."
    attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        if ssh-keyscan -T 3 "$vm_ip" 2>/dev/null | grep -q "ssh-"; then
            info "SSH is available"
            break
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            echo -n "." >&2
            sleep "$retry_interval"
        fi
    done
    echo "" >&2

    if [[ $attempt -eq $max_retries ]]; then
        warn "Timeout waiting for SSH on $vm_ip"
        warn "You will see a host key verification prompt on first connection"
        return 1
    fi

    # Retrieve and add host keys
    info "Retrieving SSH host keys from $vm_ip..."
    local known_hosts_file="$HOME/.ssh/known_hosts"

    # Ensure .ssh directory exists with proper permissions
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Create known_hosts if it doesn't exist
    touch "$known_hosts_file"
    chmod 600 "$known_hosts_file"

    # Remove any existing entries for this hostname
    if grep -q "$hostname" "$known_hosts_file" 2>/dev/null; then
        info "Removing existing entries for $hostname..."
        ssh-keygen -R "$hostname" &>/dev/null || true
    fi

    # Scan the IP but write the hostname to known_hosts
    local temp_keys=$(mktemp)
    if ssh-keyscan -T 5 "$vm_ip" > "$temp_keys" 2>/dev/null; then
        # Replace IP with hostname in the scanned keys
        sed "s/^$vm_ip/$hostname/" "$temp_keys" | grep -v "^#" | grep -v "^$" >> "$known_hosts_file"
        local key_count=$(grep -v "^#" "$temp_keys" | grep -v "^$" | wc -l)
        info "Added $key_count SSH host key(s) for $hostname to $known_hosts_file"
        rm -f "$temp_keys"
        return 0
    else
        warn "Failed to retrieve SSH host keys from $vm_ip"
        rm -f "$temp_keys"
        return 1
    fi
}

# Validate version format (X.Y)
validate_version_format() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        error "Version must be in format X.Y (e.g., 9.3)"
    fi
}

# Validate VM name doesn't contain periods
validate_vm_name() {
    local vm_name="$1"
    if [[ "$vm_name" == *.* ]]; then
        error "VM name cannot contain periods (.) as it is used as a hostname component"
    fi
}

# Load configuration from ~/.config/rhelmcp/config.env
# Sets REDHAT_ORG_ID and REDHAT_ACTIVATION_KEY
load_config() {
    local config_file="$HOME/.config/rhelmcp/config.env"
    if [[ ! -f "$config_file" ]]; then
        error "Configuration file not found at $config_file"
    fi

    source "$config_file"

    # Validate required config variables
    if [[ -z "$REDHAT_ORG_ID" ]] || [[ -z "$REDHAT_ACTIVATION_KEY" ]]; then
        error "REDHAT_ORG_ID and REDHAT_ACTIVATION_KEY must be set in $config_file"
    fi
}

# Get current user's SSH public key path and content
# Prefers id_ed25519.pub, falls back to id_rsa.pub
# Sets SSH_PUBKEY and SSH_KEY_CONTENT variables
get_ssh_key() {
    # Check for Ed25519 key first (modern, preferred)
    if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub"
    # Fall back to RSA key
    elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
        SSH_PUBKEY="$HOME/.ssh/id_rsa.pub"
    else
        error "No SSH public key found. Expected ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub"
    fi

    SSH_KEY_CONTENT=$(cat "$SSH_PUBKEY")
}

# Get platform-specific cloud-init ISO path
# Arguments:
#   $1 - VM name
# Returns:
#   Prints cloud-init ISO path to stdout
get_cloudinit_iso_path() {
    local vm_name="$1"

    case "$PLATFORM" in
        Linux)
            echo "$HOME/.local/share/libvirt/images/$vm_name-cloudinit.iso"
            ;;
        Darwin)
            echo "$HOME/.local/share/rhelmcp/disks/$vm_name-cloudinit.iso"
            ;;
        *)
            error "Unsupported platform: $PLATFORM"
            ;;
    esac
}
