#!/bin/bash

set -e

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
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Wait for SSH to be available and add host keys to known_hosts
# Uses virsh domifaddr to get authoritative IP, then scans that IP
# Arguments:
#   $1 - VM name for virsh
#   $2 - hostname to write to known_hosts (e.g., myvm.local)
#   $3 - max retry attempts (default: 30)
#   $4 - retry interval in seconds (default: 2)
wait_for_ssh_and_add_known_host() {
    local vm_name="$1"
    local hostname="$2"
    local max_retries="${3:-30}"
    local retry_interval="${4:-2}"
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
            break
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            echo -n "."
            sleep "$retry_interval"
        fi
    done
    echo ""

    if [[ -z "$vm_ip" ]]; then
        warn "Timeout waiting for VM to acquire IP address"
        warn "You will see a host key verification prompt on first connection"
        return 1
    fi

    # Now wait for SSH to be available on that IP
    info "Waiting for SSH to be available on $vm_ip..."
    attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        if ssh-keyscan -T 3 "$vm_ip" 2>/dev/null | grep -q "ssh-"; then
            info "SSH is available"
            break
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            echo -n "."
            sleep "$retry_interval"
        fi
    done
    echo ""

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

# Parse arguments
VERSION=""
VM_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --version=*)
            VERSION="${1#*=}"
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            if [[ -z "$VM_NAME" ]]; then
                VM_NAME="$1"
            else
                error "Unknown argument: $1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]] || [[ -z "$VM_NAME" ]]; then
    error "Usage: $0 --version=<RHEL-MAJOR>.<RHEL-MINOR> <NAME>"
fi

# Validate version format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    error "Version must be in format X.Y (e.g., 9.3)"
fi

# Validate VM name doesn't contain periods (used as hostname component)
if [[ "$VM_NAME" == *.* ]]; then
    error "VM name cannot contain periods (.) as it is used as a hostname component"
fi

info "Setting up VM: $VM_NAME with RHEL $VERSION"

# Check for required tools
for tool in virsh virt-install virt-customize; do
    if ! command -v $tool &> /dev/null; then
        error "$tool is required but not installed"
    fi
done

# Check libvirtd connection
info "Checking libvirtd connection..."
if ! virsh -c qemu:///system list &> /dev/null; then
    error "Cannot connect to libvirtd. Please ensure libvirtd is running and you have permission to connect.\n  Try: virsh -c qemu:///system list"
fi

# Load configuration
CONFIG_FILE="$HOME/.config/rhelmcp/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found at $CONFIG_FILE"
fi

source "$CONFIG_FILE"

# Validate required config variables
if [[ -z "$REDHAT_ORG_ID" ]] || [[ -z "$REDHAT_ACTIVATION_KEY" ]]; then
    error "REDHAT_ORG_ID and REDHAT_ACTIVATION_KEY must be set in $CONFIG_FILE"
fi

# Check for base image
IMAGE_DIR="$HOME/.local/share/rhelmcp"
BASE_IMAGE="$IMAGE_DIR/rhel-$VERSION-x86_64-kvm.qcow2"

if [[ ! -f "$BASE_IMAGE" ]]; then
    error "Base image not found at $BASE_IMAGE\n  Please download the RHEL $VERSION KVM image from:\n  https://access.redhat.com/downloads/content/rhel\n  and place it at $BASE_IMAGE"
fi

info "Base image found: $BASE_IMAGE"

# Check if VM already exists
if virsh -c qemu:///system dominfo "$VM_NAME" &> /dev/null; then
    error "VM '$VM_NAME' already exists. Please delete it first with: virsh -c qemu:///system undefine --remove-all-storage $VM_NAME"
fi

# Create VM disk directory
VM_DISK_DIR="$HOME/.local/share/libvirt/images"
mkdir -p "$VM_DISK_DIR"
VM_DISK="$VM_DISK_DIR/$VM_NAME.qcow2"

info "Creating VM disk with backing file..."
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DISK" 16G

# Get current user info
CURRENT_USER="$USER"
SSH_PUBKEY="$HOME/.ssh/id_rsa.pub"

if [[ ! -f "$SSH_PUBKEY" ]]; then
    error "SSH public key not found at $SSH_PUBKEY"
fi

SSH_KEY_CONTENT=$(cat "$SSH_PUBKEY")

info "Customizing VM image..."

# Create a temporary script for registration and user setup
CUSTOMIZE_SCRIPT=$(cat <<'EOFSCRIPT'
#!/bin/bash
set -e

# Set hostname (can't use hostnamectl in virt-customize since systemd isn't running)
echo "__HOSTNAME__" > /etc/hostname

# Register the system
subscription-manager register --org=__ORG_ID__ --activationkey=__ACTIVATION_KEY__

# Wait for registration to complete
subscription-manager status

# Create user
useradd -m -G wheel -s /bin/bash __USERNAME__

# Install and enable avahi
dnf install -y avahi
systemctl enable avahi-daemon

# Setup SSH
mkdir -p /home/__USERNAME__/.ssh
chmod 700 /home/__USERNAME__/.ssh
echo "__SSH_KEY__" > /home/__USERNAME__/.ssh/authorized_keys
chmod 600 /home/__USERNAME__/.ssh/authorized_keys
chown -R __USERNAME__:__USERNAME__ /home/__USERNAME__/.ssh

# Setup passwordless sudo
echo "__USERNAME__ ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/__USERNAME__
chmod 0440 /etc/sudoers.d/__USERNAME__

echo "password1" | passwd --stdin __USERNAME__
EOFSCRIPT
)

# Replace placeholders
CUSTOMIZE_SCRIPT="${CUSTOMIZE_SCRIPT//__HOSTNAME__/$VM_NAME}"
CUSTOMIZE_SCRIPT="${CUSTOMIZE_SCRIPT//__ORG_ID__/$REDHAT_ORG_ID}"
CUSTOMIZE_SCRIPT="${CUSTOMIZE_SCRIPT//__ACTIVATION_KEY__/$REDHAT_ACTIVATION_KEY}"
CUSTOMIZE_SCRIPT="${CUSTOMIZE_SCRIPT//__USERNAME__/$CURRENT_USER}"
CUSTOMIZE_SCRIPT="${CUSTOMIZE_SCRIPT//__SSH_KEY__/$SSH_KEY_CONTENT}"

# Create temporary script file
TEMP_SCRIPT=$(mktemp)
echo "$CUSTOMIZE_SCRIPT" > "$TEMP_SCRIPT"
chmod +x "$TEMP_SCRIPT"

# Run virt-customize
virt-customize -a "$VM_DISK" \
    --run "$TEMP_SCRIPT" \
    --selinux-relabel

rm "$TEMP_SCRIPT"

# Determine OS variant for virt-install
# Try rhel<major>.<minor> first, then rhel<major>-unknown, then rhel-unknown
OS_VARIANT=""
RHEL_MAJOR="${VERSION%%.*}"

if command -v osinfo-query &> /dev/null; then
    # Get list of available OS variants
    AVAILABLE_VARIANTS=$(osinfo-query os --fields short-id | tail -n +3 | awk '{print $2}')

    # Try exact version match (e.g., rhel9.3)
    if echo "$AVAILABLE_VARIANTS" | grep -q "^rhel${VERSION}$"; then
        OS_VARIANT="rhel${VERSION}"
    # Try major version unknown (e.g., rhel9-unknown)
    elif echo "$AVAILABLE_VARIANTS" | grep -q "^rhel${RHEL_MAJOR}-unknown$"; then
        OS_VARIANT="rhel${RHEL_MAJOR}-unknown"
    # Fall back to rhel-unknown
    elif echo "$AVAILABLE_VARIANTS" | grep -q "^rhel-unknown$"; then
        OS_VARIANT="rhel-unknown"
    fi
fi

# If osinfo-query not available or no match found, use rhel-unknown
if [[ -z "$OS_VARIANT" ]]; then
    OS_VARIANT="rhel-unknown"
    warn "Using OS variant: $OS_VARIANT (rhel${VERSION} not found in osinfo database)"
else
    info "Using OS variant: $OS_VARIANT"
fi

info "Creating VM definition..."
virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory 4096 \
    --vcpus 2 \
    --disk path="$VM_DISK",format=qcow2 \
    --network network=default \
    --os-variant "$OS_VARIANT" \
    --import \
    --noautoconsole

info "VM created successfully!"
info "Starting VM..."
virsh -c qemu:///system start "$VM_NAME" 2>/dev/null || true

# Wait for VM to boot and add SSH host keys to known_hosts
VM_HOSTNAME="$VM_NAME.local"
if wait_for_ssh_and_add_known_host "$VM_NAME" "$VM_HOSTNAME" 30 2; then
    info "SSH host keys configured - you can connect immediately"
else
    warn "Could not automatically configure SSH host keys"
fi

info ""
info "VM '$VM_NAME' is ready!"
info "You can connect with: ssh $CURRENT_USER@$VM_NAME.local"
info ""
info "Useful commands:"
info "  virsh -c qemu:///system console $VM_NAME  # Connect to console"
info "  virsh -c qemu:///system shutdown $VM_NAME  # Shutdown VM"
info "  virsh -c qemu:///system start $VM_NAME     # Start VM"
info "  virsh -c qemu:///system undefine --remove-all-storage $VM_NAME  # Delete VM"
