#!/bin/bash

# Cloud-init ISO generation for both Linux and macOS

# Create cloud-init ISO
# Arguments:
#   $1 - VM name (used as hostname)
#   $2 - Username to create
#   $3 - SSH public key content
#   $4 - Red Hat organization ID
#   $5 - Red Hat activation key
#   $6 - Output ISO path
create_cloudinit_iso() {
    local vm_name="$1"
    local username="$2"
    local ssh_key="$3"
    local org_id="$4"
    local activation_key="$5"
    local output_iso="$6"

    # Create temporary directory for cloud-init files
    local temp_dir=$(mktemp -d)

    # Create meta-data file
    cat > "$temp_dir/meta-data" <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF

    # Create user-data file
    cat > "$temp_dir/user-data" <<'EOFUSERDATA'
#cloud-config
hostname: __HOSTNAME__
fqdn: __HOSTNAME__.local

rh_subscription:
  activation-key: __ACTIVATION_KEY__
  org: "__ORG_ID__"

users:
  - name: __USERNAME__
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - __SSH_KEY__

packages:
  - avahi

runcmd:
  # Enable and start avahi for mDNS
  - systemctl enable avahi-daemon
  - systemctl start avahi-daemon
  # Disable cloud-init to prevent it from running on subsequent boots
  - systemctl disable cloud-init.service cloud-config.service cloud-final.service cloud-init-local.service
  - touch /etc/cloud/cloud-init.disabled
  # Trigger SELinux relabel on next boot
  - touch /.autorelabel
EOFUSERDATA

    # Set sed in-place flag based on platform
    local sed_inplace
    if [[ "$PLATFORM" == "Darwin" ]]; then
        sed_inplace=(-i '')  # macOS (BSD sed) requires empty string
    else
        sed_inplace=(-i)     # Linux (GNU sed)
    fi

    # Replace placeholders in user-data
    sed "${sed_inplace[@]}" "s|__HOSTNAME__|$vm_name|g" "$temp_dir/user-data"
    sed "${sed_inplace[@]}" "s|__ORG_ID__|$org_id|g" "$temp_dir/user-data"
    sed "${sed_inplace[@]}" "s|__ACTIVATION_KEY__|$activation_key|g" "$temp_dir/user-data"
    sed "${sed_inplace[@]}" "s|__USERNAME__|$username|g" "$temp_dir/user-data"
    sed "${sed_inplace[@]}" "s|__SSH_KEY__|$ssh_key|g" "$temp_dir/user-data"

    case "$PLATFORM" in
        Linux)
            # Use xorriso on Linux
            if ! command -v xorriso &> /dev/null; then
                rm -rf "$temp_dir"
                error "xorriso is required but not installed. Install with: sudo dnf install xorriso"
            fi

            xorriso -as mkisofs -output "$output_iso" -volid cidata -joliet -rock "$temp_dir" &>/dev/null
            ;;
        Darwin)
            # Use hdiutil on macOS
            hdiutil makehybrid -o "$output_iso" -iso -joliet -default-volume-name cidata "$temp_dir" &>/dev/null
            ;;
        *)
            rm -rf "$temp_dir"
            error "Unsupported platform for ISO creation: $PLATFORM"
            ;;
    esac

    # Clean up temporary directory
    rm -rf "$temp_dir"

    if [[ ! -f "$output_iso" ]]; then
        error "Failed to create cloud-init ISO at $output_iso"
    fi

    info "Created cloud-init ISO: $output_iso"
}

# Cleanup cloud-init ISO
# Arguments:
#   $1 - ISO path to remove
cleanup_cloudinit_iso() {
    local iso_path="$1"
    if [[ -f "$iso_path" ]]; then
        rm -f "$iso_path"
        info "Cleaned up cloud-init ISO"
    fi
}
