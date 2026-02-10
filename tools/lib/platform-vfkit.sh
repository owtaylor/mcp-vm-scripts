#!/bin/bash

# Platform-specific implementation for macOS using vfkit (Virtualization.framework)
# Requires macOS 13+ for EFI bootloader.

VFKIT_STATE_DIR="$HOME/.local/share/mcpvm/vfkit"
VFKIT_DISKS_DIR="$VFKIT_STATE_DIR/disks"

# Get path to a VM's state file
_vfkit_state_file() {
    echo "$VFKIT_STATE_DIR/$1.state"
}

# Get path to a VM's PID file
_vfkit_pid_file() {
    echo "$VFKIT_STATE_DIR/$1.pid"
}

# Load VM state (disk path, iso path, efi_vars path, mac)
# Sets: VFKIT_DISK, VFKIT_ISO, VFKIT_EFI_VARS, VFKIT_MAC
_vfkit_load_state() {
    local vm_name="$1"
    local state_file
    state_file=$(_vfkit_state_file "$vm_name")
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi
    # shellcheck source=/dev/null
    source "$state_file"
    return 0
}

# Launch vfkit in the background with the given device paths.
# Arguments: $1=vm_name, $2=disk_path, $3=iso_path, $4=efi_vars_path, $5=mac
# Writes vfkit PID to the VM's pid file. Prints the PID to stdout for callers.
_vfkit_launch_vm() {
    local vm_name="$1"
    local disk_path="$2"
    local iso_path="$3"
    local efi_vars_path="$4"
    local mac="$5"
    local pid_file
    pid_file=$(_vfkit_pid_file "$vm_name")
    vfkit --cpus 2 --memory 4096 \
        --bootloader "efi,variable-store=$efi_vars_path,create" \
        --device "virtio-blk,path=$disk_path" \
        --device "virtio-blk,path=$iso_path" \
        --device "virtio-net,nat,mac=$mac" \
        --device virtio-rng \
        --device "virtio-serial,logFilePath=$VFKIT_STATE_DIR/$vm_name-serial.log" \
        </dev/null >> "$VFKIT_STATE_DIR/$vm_name.log" 2>&1 &
    echo $! > "$pid_file"
    cat "$pid_file"
}

# Check for required tools and macOS version
platform_check_prerequisites() {
    info "Checking prerequisites for vfkit..."

    if ! command -v vfkit &> /dev/null; then
        error "vfkit is required but not found. Install with: brew install vfkit"
    fi

    if ! command -v hdiutil &> /dev/null; then
        error "hdiutil is required but not found"
    fi

    # EFI bootloader requires macOS 13+
    local os_version
    os_version=$(sw_vers -productVersion 2>/dev/null)
    local major
    major=$(echo "$os_version" | cut -d. -f1)
    if [[ -z "$major" ]] || [[ "$major" -lt 13 ]]; then
        error "vfkit with EFI boot requires macOS 13 or later (current: $os_version)"
    fi

    mkdir -p "$VFKIT_STATE_DIR" "$VFKIT_DISKS_DIR"
}

# Validate base image exists; use raw image, converting from qcow2 if needed
# Arguments:
#   $1 - RHEL version (e.g., 9.5)
# Returns:
#   Sets BASE_IMAGE variable with path to base image (raw)
# Expects the KVM qcow2 image (official Red Hat format). Converts to raw on first use if needed.
platform_validate_base_image() {
    local version="$1"
    local image_dir="$HOME/.local/share/mcpvm"
    local raw_image="$image_dir/rhel-$version-aarch64.raw"
    local qcow2_image="$image_dir/rhel-$version-aarch64-kvm.qcow2"

    if [[ -f "$raw_image" ]]; then
        BASE_IMAGE="$raw_image"
        info "Base image found: $BASE_IMAGE"
        return 0
    fi

    if [[ ! -f "$qcow2_image" ]]; then
        error "Base image not found at $qcow2_image\n  Please download the RHEL $version KVM image from:\n  https://access.redhat.com/downloads/content/rhel\n  and place it at $qcow2_image"
    fi

    info "Converting qcow2 to raw..."
    if ! command -v qemu-img &> /dev/null; then
        error "qemu-img is required to convert qcow2 to raw. Install with: brew install qemu"
    fi
    if ! qemu-img convert -f qcow2 -O raw "$qcow2_image" "$raw_image"; then
        error "Failed to convert $qcow2_image to raw"
    fi
    BASE_IMAGE="$raw_image"
    info "Base image ready: $BASE_IMAGE"
    return 0
}

# Check if VM exists (has state file)
# Arguments:
#   $1 - VM name
platform_vm_exists() {
    local vm_name="$1"
    _vfkit_load_state "$vm_name"
}

# Check if VM already exists and error if so
# Arguments:
#   $1 - VM name
platform_check_vm_exists() {
    local vm_name="$1"

    if _vfkit_load_state "$vm_name" 2>/dev/null; then
        error "VM '$vm_name' already exists. Delete it first with: mcpvm delete $vm_name"
    fi
}

# Create VM: CoW clone of base, write state, start vfkit in background
# Arguments:
#   $1 - VM name
#   $2 - RHEL version (e.g., 9.5)
#   $3 - Base image path (raw)
#   $4 - Cloud-init ISO path
platform_create_vm() {
    local vm_name="$1"
    local version="$2"
    local base_image="$3"
    local cloudinit_iso="$4"

    local vm_disk="$VFKIT_DISKS_DIR/$vm_name.raw"
    local efi_vars="$VFKIT_STATE_DIR/$vm_name-efi-vars"
    # Fixed MAC per VM so we can look up IP in dhcpd_leases
    local mac
    mac="52:54:00:$(openssl rand -hex 3 | sed 's/\(..\)/\1:/g;s/:$//')"

    info "Creating VM disk (APFS CoW clone)..."
    if ! cp -c "$base_image" "$vm_disk" 2>/dev/null; then
        # Fallback: full copy if cp -c not supported (e.g. non-APFS)
        info "CoW clone not available, copying base image..."
        cp "$base_image" "$vm_disk"
    fi

    info "Writing VM state..."
    local state_file
    state_file=$(_vfkit_state_file "$vm_name")
    cat > "$state_file" <<EOF
VFKIT_DISK="$vm_disk"
VFKIT_ISO="$cloudinit_iso"
VFKIT_EFI_VARS="$efi_vars"
VFKIT_MAC="$mac"
EOF

    info "Starting vfkit..."
    # Run vfkit in background
    local vfkit_pid
    vfkit_pid=$(_vfkit_launch_vm "$vm_name" "$vm_disk" "$cloudinit_iso" "$efi_vars" "$mac")
    info "vfkit started (PID $vfkit_pid)"
    info "VM created successfully!"
}

# Get VM IP from macOS DHCP lease file
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

    if ! _vfkit_load_state "$vm_name"; then
        warn "No state found for VM '$vm_name'"
        echo ""
        return 1
    fi

    info "Waiting for VM to acquire IP address (checking /var/db/dhcpd_leases)..."

    # MAC in lease file may use single-digit octets (e.g. 52:54:0:11:62:fe); awk normalizes to 12 hex digits for comparison
    local mac_plain
    mac_plain=$(echo "$VFKIT_MAC" | tr -d ':' | tr '[:upper:]' '[:lower:]')
    local lease_file="/var/db/dhcpd_leases"

    while [[ $attempt -lt $max_retries ]]; do
        if [[ -r "$lease_file" ]]; then
            # Lease file is brace-delimited blocks with hw_address=1,<mac>; ip_address=x.x.x.x (order varies).
            vm_ip=""
            block=""
            while IFS= read -r line; do
                block="$block$line"$'\n'
                if [[ "$line" =~ ^[[:space:]]*\}$ ]]; then
                    hw_raw=$(echo "$block" | grep 'hw_address=' | head -1 | cut -d= -f2 | cut -d, -f2 | tr -d '; \t')
                    if [[ -n "$hw_raw" ]]; then
                        # Normalize MAC to 12 hex digits (lease may have 52:54:0:11:62:fe).
                        hw_norm=$(echo "$hw_raw" | tr ':' '\n' | while IFS= read -r o; do [[ -n "$o" ]] && printf '%02x' "0x$o"; done | tr -d '\n')
                        if [[ "$hw_norm" == "$mac_plain" ]]; then
                            vm_ip=$(echo "$block" | grep 'ip_address=' | head -1 | cut -d= -f2 | tr -d '; \t')
                            break
                        fi
                    fi
                    block=""
                fi
            done < "$lease_file"
            if [[ -n "$vm_ip" ]] && [[ "$vm_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                info "VM acquired IP address: $vm_ip"
                echo "$vm_ip"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            echo -n "." >&2
            sleep "$retry_interval"
        fi
    done
    echo "" >&2

    warn "Timeout waiting for VM to acquire IP address"
    warn "Check $lease_file or connect via serial: $VFKIT_STATE_DIR/$vm_name-serial.log"
    return 1
}

# List all VMs with mcpvm- prefix (state files)
# Returns:
#   Prints list of VM names and states to stdout
platform_list_vms() {
    local state_file pid_file pid
    for state_file in "$VFKIT_STATE_DIR"/mcpvm-*.state; do
        [[ -e "$state_file" ]] || continue
        local name
        name=$(basename "$state_file" .state)
        pid_file="$VFKIT_STATE_DIR/$name.pid"
        if [[ -f "$pid_file" ]]; then
            pid=$(cat "$pid_file" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                echo "$name running"
            else
                echo "$name stopped"
            fi
        else
            echo "$name stopped"
        fi
    done
}

# Start a VM (launch vfkit in background using saved state)
# Arguments:
#   $1 - VM name
platform_start_vm() {
    local vm_name="$1"

    if ! _vfkit_load_state "$vm_name"; then
        error "VM '$vm_name' does not exist"
    fi

    local pid_file
    pid_file=$(_vfkit_pid_file "$vm_name")
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            info "VM '$vm_name' is already running (PID $pid)"
            return 0
        fi
    fi

    info "Starting VM '$vm_name'..."
    local vfkit_pid
    vfkit_pid=$(_vfkit_launch_vm "$vm_name" "$VFKIT_DISK" "$VFKIT_ISO" "$VFKIT_EFI_VARS" "$VFKIT_MAC")
    info "VM '$vm_name' started (PID $vfkit_pid)"
}

# Stop a VM (terminate vfkit process)
# Arguments:
#   $1 - VM name
platform_stop_vm() {
    local vm_name="$1"

    if ! _vfkit_load_state "$vm_name"; then
        error "VM '$vm_name' does not exist"
    fi

    local pid_file
    pid_file=$(_vfkit_pid_file "$vm_name")
    if [[ ! -f "$pid_file" ]]; then
        info "VM '$vm_name' is already stopped"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        info "VM '$vm_name' is already stopped"
        rm -f "$pid_file"
        return 0
    fi

    info "Stopping VM '$vm_name'..."
    kill "$pid" 2>/dev/null || true
    # Wait briefly for graceful exit
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 15 ]]; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
    info "VM '$vm_name' stopped"
}

# Delete a VM and its resources
# Arguments:
#   $1 - VM name
platform_delete_vm() {
    local vm_name="$1"

    if ! _vfkit_load_state "$vm_name"; then
        error "VM '$vm_name' does not exist"
    fi

    platform_stop_vm "$vm_name"

    info "Deleting VM '$vm_name'..."

    rm -f "$VFKIT_DISK"
    rm -f "$VFKIT_EFI_VARS"
    rm -f "$(_vfkit_state_file "$vm_name")"
    rm -f "$(_vfkit_pid_file "$vm_name")"
    rm -f "$VFKIT_STATE_DIR/$vm_name-serial.log"
    rm -f "$VFKIT_STATE_DIR/$vm_name.log"

    # Cloud-init ISO is in mcpvm/disks
    local cloudinit_iso="$HOME/.local/share/mcpvm/disks/$vm_name-cloudinit.iso"
    if [[ -f "$cloudinit_iso" ]]; then
        info "Removing cloud-init ISO..."
        rm -f "$cloudinit_iso"
    fi

    info "VM '$vm_name' deleted successfully"
}

# Resolve hostname via mDNS
# Arguments:
#   $1 - hostname (e.g., myvm.local)
# Returns:
#   0 if hostname is resolvable, 1 otherwise
platform_resolve_hostname() {
    local hostname="$1"

    if dscacheutil -q host -a name "$hostname" &>/dev/null; then
        return 0
    fi
    return 1
}
