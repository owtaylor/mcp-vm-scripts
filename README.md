# RHEL VM Setup Scripts

Cross-platform scripts for automated RHEL virtual machine creation and configuration. Supports both Linux (libvirt/KVM) and macOS (UTM).

## Features

- **Cross-platform**: Automatically detects and uses the appropriate virtualization platform
  - Linux: libvirt/KVM
  - macOS: UTM (QEMU backend)
- **Automated Setup**: Creates fully configured VMs with:
  - Red Hat subscription registration
  - User account creation with SSH key authentication
  - mDNS/Avahi for easy network access via `<hostname>.local`
  - Automatic SSH known_hosts configuration
- **Cloud-init Based**: Uses cloud-init for VM provisioning, ensuring cross-platform compatibility
- **Efficient Storage**: Uses QCOW2 backing files to minimize disk usage

## Prerequisites

### Linux (libvirt/KVM)
- `virsh`, `virt-install`, `qemu-img`, `xorriso`
- libvirtd running with user permissions: `virsh -c qemu:///system list`
- RHEL KVM image (x86_64) downloaded to `~/.local/share/rhelmcp/rhel-X.Y-x86_64-kvm.qcow2`

### macOS (UTM)
- UTM.app installed at `/Applications/UTM.app` ([Download](https://mac.getutm.app/))
- `osascript`, `hdiutil` (built-in to macOS)
- Optional: `qemu-img` (install via `brew install qemu` for backing file support)
- RHEL ARM64 image downloaded to `~/.local/share/rhelmcp/rhel-X.Y-aarch64.qcow2`

### Both Platforms
- SSH key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` (ed25519 preferred)
- Configuration file at `~/.config/rhelmcp/config.env` (see Configuration section)

## Configuration

Create `~/.config/rhelmcp/config.env` with your Red Hat subscription details:

```bash
# Get these from: https://console.redhat.com/insights/connector/activation-keys
REDHAT_ORG_ID=1234567
REDHAT_ACTIVATION_KEY=myuser-rhelmcp
```

## Usage

```bash
./tools/setup-vm.sh --version=<RHEL-MAJOR>.<RHEL-MINOR> <NAME>
```

**Example:**
```bash
./tools/setup-vm.sh --version=9.5 test-vm
```

This will:
1. Validate prerequisites for your platform (Linux or macOS)
2. Check that the base RHEL image exists
3. Create a cloud-init ISO with:
   - VM hostname configuration (`<NAME>.local`)
   - Red Hat subscription registration
   - User account (current user) with sudo access
   - SSH authorized key
   - Avahi/mDNS setup
4. Create the VM using platform-specific tools:
   - **Linux**: Creates VM disk with backing file, uses `virt-install`
   - **macOS**: Creates VM disk, registers with UTM via AppleScript
5. Wait for VM to boot and acquire an IP address
6. Configure SSH known_hosts for immediate passwordless access
7. Display connection instructions

## Connecting to VMs

After creation, connect via:
```bash
ssh <username>@<NAME>.local
```

Where `<username>` is your current system username.

## Managing VMs

### Linux (libvirt)
```bash
# View console
virsh -c qemu:///system console <NAME>

# Shutdown
virsh -c qemu:///system shutdown <NAME>

# Start
virsh -c qemu:///system start <NAME>

# Delete VM and storage
virsh -c qemu:///system undefine --remove-all-storage <NAME>
```

### macOS (UTM)
Use UTM.app for graphical management:
- Start/stop VMs
- Access console
- Delete VMs

## Architecture

### File Structure
- `tools/setup-vm.sh` - Main entry point with platform detection
- `tools/lib/common.sh` - Common utilities (logging, validation, SSH)
- `tools/lib/cloudinit.sh` - Cloud-init ISO generation (cross-platform)
- `tools/lib/platform-libvirt.sh` - Linux/libvirt implementation
- `tools/lib/platform-utm.sh` - macOS/UTM implementation
- `tools/get-vm-ip-utm.scpt` - AppleScript helper for UTM IP lookup
- `tools/run-vm-utm.scpt` - AppleScript helper for UTM VM creation

### Design Principles
- Platform abstraction through function naming convention (`platform_*`)
- Cloud-init for provisioning (avoids platform-specific guest modification)
- Shared network configuration for easy host access
- mDNS/Avahi for DNS-less hostname resolution

## Downloading RHEL Images

Download RHEL KVM Guest Images from:
https://access.redhat.com/downloads/content/rhel

- **Linux**: Download x86_64 KVM image
- **macOS**: Download ARM64 (aarch64) image

Place downloaded images at:
- **Linux**: `~/.local/share/rhelmcp/rhel-X.Y-x86_64-kvm.qcow2`
- **macOS**: `~/.local/share/rhelmcp/rhel-X.Y-aarch64.qcow2`
