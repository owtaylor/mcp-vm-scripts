#!/bin/bash

# Platform-specific implementation for macOS using UTM

# Check for required tools and UTM installation
platform_check_prerequisites() {
    info "Checking prerequisites for UTM..."

    # Check for osascript (should always be available on macOS)
    if ! command -v osascript &> /dev/null; then
        error "osascript is required but not found"
    fi

    # Check for hdiutil (should always be available on macOS)
    if ! command -v hdiutil &> /dev/null; then
        error "hdiutil is required but not found"
    fi

    # Check for UTM application
    if [[ ! -d "/Applications/UTM.app" ]]; then
        error "UTM.app is required but not found at /Applications/UTM.app\n  Please install UTM from: https://mac.getutm.app/"
    fi

    # Check for qemu-img (needed for disk operations)
    if ! command -v qemu-img &> /dev/null; then
        warn "qemu-img not found. Will copy base image instead of using backing file."
        warn "Install qemu with: brew install qemu"
    fi
}

# Validate base image exists
# Arguments:
#   $1 - RHEL version (e.g., 9.5)
# Returns:
#   Sets BASE_IMAGE variable with path to base image
platform_validate_base_image() {
    local version="$1"
    local image_dir="$HOME/.local/share/rhelmcp"
    BASE_IMAGE="$image_dir/rhel-$version-aarch64-kvm.qcow2"

    if [[ ! -f "$BASE_IMAGE" ]]; then
        error "Base image not found at $BASE_IMAGE\n  Please download the RHEL $version ARM64 image from:\n  https://access.redhat.com/downloads/content/rhel\n  and place it at $BASE_IMAGE"
    fi

    info "Base image found: $BASE_IMAGE"
}

# Check if VM already exists
# Arguments:
#   $1 - VM name
platform_check_vm_exists() {
    local vm_name="$1"

    # Query UTM via AppleScript to check if VM exists
    local result=$(osascript -e "tell application \"UTM\" to get name of every virtual machine" 2>/dev/null)

    if [[ "$result" == *"$vm_name"* ]]; then
        error "VM '$vm_name' already exists in UTM. Please delete it first from UTM.app"
    fi
}

# Create VM
# Arguments:
#   $1 - VM name
#   $2 - RHEL version (e.g., 9.5)
#   $3 - Base image path
#   $4 - Cloud-init ISO path
platform_create_vm() {
    local vm_name="$1"
    local version="$2"
    local base_image="$3"
    local cloudinit_iso="$4"

    # Create VM disk directory
    local vm_disk_dir="$HOME/.local/share/rhelmcp/disks"
    mkdir -p "$vm_disk_dir"
    local vm_disk="$vm_disk_dir/$vm_name.qcow2"

    # Create VM disk (use backing file if qemu-img available, otherwise copy)
    if command -v qemu-img &> /dev/null; then
        info "Creating VM disk with backing file..."
        qemu-img create -f qcow2 -F qcow2 -b "$base_image" "$vm_disk" 16G
    else
        info "Creating VM disk by copying base image..."
        cp "$base_image" "$vm_disk"
        # Resize the copied image
        if command -v qemu-img &> /dev/null; then
            qemu-img resize "$vm_disk" 16G
        fi
    fi

    # Get script directory to find the AppleScript helper
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    info "Creating VM in UTM..."
    local result=$(osascript "$script_dir/run-vm-utm.scpt" "$vm_name" "$vm_disk" "$cloudinit_iso" 2>&1)

    if [[ "$result" == Error:* ]]; then
        error "Failed to create VM: $result"
    fi

    info "VM created successfully!"
    info "$result"
}

# Get VM IP address
# Arguments:
#   $1 - VM name
#   $2 - max retry attempts (default: 30)
#   $3 - retry interval in seconds (default: 2)
# Returns:
#   Prints VM IP address to stdout
platform_get_vm_ip() {
    local vm_name="$1"
    local max_retries="${2:-30}"
    local retry_interval="${3:-2}"
    local attempt=0
    local vm_ip=""

    info "Waiting for VM to acquire IP address..."

    # Get script directory to find the AppleScript helper
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # Wait for VM to get an IP address
    while [[ $attempt -lt $max_retries ]]; do
        vm_ip=$(osascript "$script_dir/get-vm-ip-utm.scpt" "$vm_name" 2>/dev/null)

        # Check if we got an IP and it's not an error message
        if [[ -n "$vm_ip" ]] && [[ "$vm_ip" != Error:* ]] && [[ "$vm_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            info "VM acquired IP address: $vm_ip"
            echo "$vm_ip"
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            echo -n "." >&2
            sleep "$retry_interval"
        fi
    done
    echo "" >&2

    warn "Timeout waiting for VM to acquire IP address"
    warn "You may need to check the VM in UTM.app to see its network status"
    return 1
}

# Display platform-specific management commands
# Arguments:
#   $1 - VM name
#   $2 - Username
platform_display_management_commands() {
    local vm_name="$1"
    local username="$2"

    info ""
    info "VM '$vm_name' is ready!"
    info "You can connect with: ssh $username@$vm_name.local"
    info ""
    info "Useful commands:"
    info "  Open UTM.app to manage the VM graphically"
    info "  To start/stop: Use UTM.app interface"
    info "  To delete: Remove the VM from UTM.app"
}
