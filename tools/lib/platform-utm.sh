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

    # Note: qemu-img is NOT required for UTM
    # UTM handles disk copying internally when creating VMs
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

# Check if VM exists (returns 0 if exists, 1 if not)
# Arguments:
#   $1 - VM name
platform_vm_exists() {
    local vm_name="$1"

    # Query UTM via AppleScript to check if VM exists
    local result=$(osascript -e "tell application \"UTM\" to get name of every virtual machine" 2>/dev/null)

    [[ "$result" == *"$vm_name"* ]]
}

# Check if VM already exists and error if so
# Arguments:
#   $1 - VM name
platform_check_vm_exists() {
    local vm_name="$1"

    if platform_vm_exists "$vm_name"; then
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

    # UTM will copy the base image into its VM bundle automatically
    info "UTM will copy base image into VM bundle..."
    local vm_disk="$base_image"

    # Get script directory to find the AppleScript helper
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    info "Creating VM in UTM..."
    local result
    if ! result=$(osascript "$script_dir/lib/applescript/run-vm-utm.scpt" "$vm_name" "$vm_disk" "$cloudinit_iso" 2>&1); then
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
        vm_ip=$(osascript "$script_dir/lib/applescript/get-vm-ip-utm.scpt" "$vm_name" 2>/dev/null)

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
