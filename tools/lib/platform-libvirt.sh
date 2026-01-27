#!/bin/bash

# Platform-specific implementation for Linux using libvirt/KVM

# Check for required tools and libvirtd connection
platform_check_prerequisites() {
    info "Checking prerequisites for libvirt/KVM..."

    # Check for required tools
    for tool in virsh virt-install qemu-img xorriso; do
        if ! command -v $tool &> /dev/null; then
            error "$tool is required but not installed"
        fi
    done

    # Check libvirtd connection
    info "Checking libvirtd connection..."
    if ! virsh -c qemu:///system list &> /dev/null; then
        error "Cannot connect to libvirtd. Please ensure libvirtd is running and you have permission to connect.\n  Try: virsh -c qemu:///system list"
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
    BASE_IMAGE="$image_dir/rhel-$version-x86_64-kvm.qcow2"

    if [[ ! -f "$BASE_IMAGE" ]]; then
        error "Base image not found at $BASE_IMAGE\n  Please download the RHEL $version KVM image from:\n  https://access.redhat.com/downloads/content/rhel\n  and place it at $BASE_IMAGE"
    fi

    info "Base image found: $BASE_IMAGE"
}

# Check if VM exists (returns 0 if exists, 1 if not)
# Arguments:
#   $1 - VM name
platform_vm_exists() {
    local vm_name="$1"
    virsh -c qemu:///system dominfo "$vm_name" &> /dev/null
}

# Check if VM already exists and error if so
# Arguments:
#   $1 - VM name
platform_check_vm_exists() {
    local vm_name="$1"

    if platform_vm_exists "$vm_name"; then
        error "VM '$vm_name' already exists. Please delete it first with: virsh -c qemu:///system undefine --remove-all-storage $vm_name"
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
    local vm_disk_dir="$HOME/.local/share/libvirt/images"
    mkdir -p "$vm_disk_dir"
    local vm_disk="$vm_disk_dir/$vm_name.qcow2"

    info "Creating VM disk with backing file..."
    qemu-img create -f qcow2 -F qcow2 -b "$base_image" "$vm_disk" 16G

    # Determine OS variant for virt-install
    local os_variant=""
    local rhel_major="${version%%.*}"

    if command -v osinfo-query &> /dev/null; then
        # Get list of available OS variants
        local available_variants=$(osinfo-query os --fields short-id | tail -n +3 | awk '{print $2}')

        # Try exact version match (e.g., rhel9.3)
        if echo "$available_variants" | grep -q "^rhel${version}$"; then
            os_variant="rhel${version}"
        # Try major version unknown (e.g., rhel9-unknown)
        elif echo "$available_variants" | grep -q "^rhel${rhel_major}-unknown$"; then
            os_variant="rhel${rhel_major}-unknown"
        # Fall back to rhel-unknown
        elif echo "$available_variants" | grep -q "^rhel-unknown$"; then
            os_variant="rhel-unknown"
        fi
    fi

    # If osinfo-query not available or no match found, use rhel-unknown
    if [[ -z "$os_variant" ]]; then
        os_variant="rhel-unknown"
        warn "Using OS variant: $os_variant (rhel${version} not found in osinfo database)"
    else
        info "Using OS variant: $os_variant"
    fi

    info "Creating VM definition..."
    virt-install \
        --connect qemu:///system \
        --name "$vm_name" \
        --memory 4096 \
        --vcpus 2 \
        --disk path="$vm_disk",format=qcow2 \
        --disk path="$cloudinit_iso",device=cdrom \
        --network network=default \
        --os-variant "$os_variant" \
        --import \
        --noautoconsole

    info "VM created successfully!"
    info "Starting VM..."
    virsh -c qemu:///system start "$vm_name" 2>/dev/null || true
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

    # Wait for VM to get an IP address from libvirt DHCP
    while [[ $attempt -lt $max_retries ]]; do
        # Try to get IP from libvirt (lease source is most reliable)
        vm_ip=$(virsh -c qemu:///system domifaddr "$vm_name" --source lease 2>/dev/null | \
                awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')

        if [[ -n "$vm_ip" ]]; then
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
    info "  virsh -c qemu:///system console $vm_name  # Connect to console"
    info "  virsh -c qemu:///system shutdown $vm_name  # Shutdown VM"
    info "  virsh -c qemu:///system start $vm_name     # Start VM"
    info "  virsh -c qemu:///system undefine --remove-all-storage $vm_name  # Delete VM"
}
