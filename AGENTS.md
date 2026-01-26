# Agent Context: RHEL VM Setup Scripts

This document provides essential context for agents working on this codebase.

## Project Purpose

This is a cross-platform VM automation tool for creating Red Hat Enterprise Linux (RHEL) test VMs. It's designed for MCP (Model Context Protocol) testing but is generally useful for anyone needing automated RHEL VM provisioning.

## Architecture Overview

### Cross-Platform Design

The codebase uses **platform abstraction** to support both Linux and macOS:

1. **Main Entry Point**: `tools/setup-vm.sh`
   - Detects platform via `uname -s` (Linux/Darwin)
   - Sources the appropriate platform implementation
   - Orchestrates the VM creation workflow

2. **Platform Implementations**:
   - `tools/lib/platform-libvirt.sh` - Linux (KVM/libvirt/virsh)
   - `tools/lib/platform-utm.sh` - macOS (UTM via AppleScript)

3. **Shared Libraries**:
   - `tools/lib/common.sh` - Platform-agnostic utilities
   - `tools/lib/cloudinit.sh` - Cloud-init ISO generation

### Key Abstraction Pattern

All platform-specific functions use the `platform_*` naming convention:
- `platform_check_prerequisites()` - Verify required tools
- `platform_validate_base_image()` - Check base image exists
- `platform_check_vm_exists()` - Prevent duplicate VMs
- `platform_create_vm()` - Create and start VM
- `platform_get_vm_ip()` - Retrieve VM IP address
- `platform_display_management_commands()` - Show usage help

This allows the main script to call platform functions without knowing the implementation details.

## Important Technical Decisions

### Cloud-init vs virt-customize

**The project uses cloud-init for VM provisioning** (as of recent refactoring). Previous versions used virt-customize, but this was macOS-incompatible.

Cloud-init approach:
1. Generate an ISO with `meta-data` and `user-data` files
2. Attach ISO as a removable drive during VM creation
3. RHEL cloud images auto-detect and execute cloud-init on first boot
4. ISO performs: user creation, SSH setup, subscription registration, mDNS setup

**Why this matters**: When modifying VM configuration, edit `tools/lib/cloudinit.sh:create_cloudinit_iso()`, not platform-specific files.

### ISO Generation Tools

- **Linux**: Uses `xorriso` (replaced older `genisoimage`)
- **macOS**: Uses `hdiutil` (native tool)

Both create ISO9660 images with Joliet extensions and volume label `cidata` (cloud-init convention).

### Architecture Differences

- **Linux**: x86_64 VMs using libvirt/KVM
- **macOS**: aarch64 (ARM64) VMs using UTM/QEMU

Base images must match the platform architecture.

## File Locations & Conventions

### User Configuration
- **Config**: `~/.config/rhelmcp/config.env` (Red Hat subscription credentials)
- **SSH Key**: `~/.ssh/id_rsa.pub` (required, no alternatives supported currently)

### VM Storage
- **Base Images**: `~/.local/share/rhelmcp/rhel-X.Y-{x86_64-kvm,aarch64}.qcow2`
- **Linux VM Disks**: `~/.local/share/libvirt/images/<name>.qcow2`
- **macOS VM Disks**: `~/.local/share/rhelmcp/disks/<name>.qcow2`

### QCOW2 Backing Files
VMs use QCOW2 backing files pointing to base images for storage efficiency. The `qemu-img create -b` command creates a copy-on-write overlay.

## Network Configuration

### mDNS/Avahi Setup
VMs are configured to be accessible at `<name>.local` via:
1. Cloud-init sets hostname and FQDN
2. Avahi package installed and enabled
3. Hostname resolves without DNS

### Platform Networking
- **Linux**: Uses libvirt's `default` network (NAT with DHCP)
- **macOS**: Uses UTM's `shared` network mode (vmnet-shared)

Both provide DHCP and NAT for outbound connectivity.

## AppleScript Integration (macOS Only)

Two AppleScript helpers enable UTM automation:

1. **run-vm-utm.scpt**: Creates and starts VMs
   - Uses UTM's AppleScript API
   - Configures: memory (4GB), drives (QCOW2 + ISO), networking
   - Backend: QEMU with virtio drivers

2. **get-vm-ip-utm.scpt**: Retrieves IP addresses
   - Queries UTM's network interface configuration
   - Returns IPv4 address or empty string

**Limitation**: UTM's AppleScript API has limited IP address visibility. The script tries to read from VM configuration, but may not always get the IP immediately.

## SSH Host Key Management

The `wait_for_ssh_and_add_known_host()` function in `common.sh`:
1. Waits for SSH to be available on VM IP
2. Scans host keys via `ssh-keyscan`
3. Writes keys to `~/.ssh/known_hosts` using the **hostname** (not IP)
   - Example: Keys from `192.168.122.100` written as `test-vm.local ssh-rsa ...`
4. This allows immediate passwordless SSH via `ssh user@test-vm.local`

## Common Tasks

### Adding New Cloud-init Configuration
Edit `tools/lib/cloudinit.sh:create_cloudinit_iso()`:
- Modify `user-data` heredoc
- Use placeholder variables (e.g., `__HOSTNAME__`)
- Replace placeholders with `sed` before ISO creation

### Supporting a New Platform
1. Create `tools/lib/platform-<name>.sh`
2. Implement all `platform_*` functions
3. Add platform detection case in `tools/setup-vm.sh`
4. Update ISO generation in `cloudinit.sh` if needed

### Modifying VM Resources
**Linux**: Edit `platform-libvirt.sh:platform_create_vm()`, modify `virt-install` flags:
- `--memory 4096` - RAM in MB
- `--vcpus 2` - CPU count

**macOS**: Edit `run-vm-utm.scpt`, modify configuration variables:
- `set vmMemory to 4096` - RAM in MB
- No CPU count setting in current script (uses UTM defaults)

### Debugging VM Creation Issues

**Linux**:
```bash
# Check libvirt logs
journalctl -u libvirtd -f

# View VM console
virsh -c qemu:///system console <name>

# Check VM state
virsh -c qemu:///system dominfo <name>
```

**macOS**:
- Open UTM.app and check VM console
- AppleScript errors appear in script output
- Check system logs: Console.app, filter for UTM

## Error Handling Conventions

- `error()` - Fatal errors, exits with code 1
- `warn()` - Non-fatal warnings, continues execution
- `info()` - Status messages

All use colored output (red/yellow/green) for visibility.

## Commit Message Guidelines

When creating commits, follow these conventions:

**Commit message structure:**
- **Subject line**: Brief summary of the change (imperative mood, e.g., "Fix cloud-init ISO cleanup issue")
- **Body**: The body of a commit message should consist of a short description of what was wrong or needed improvement (1 sentence for a small change - a short paragraph of two-three sentences for a major change) followed by a high-level description of what was changed. Commit messages should not contain information about wrong paths or bugs that were introduced and fixed within the same session before committing.
- The body should be line-wrapped at a width of about 72 characters.

**Best practices:**
- Focus on the "why" and "what" of the final solution
- Omit implementation details that were tried and abandoned during development
- Don't mention bugs or errors that were fixed before the commit
- Keep the tone professional and focused on the outcome

## Testing Considerations

### Prerequisites for Testing
- Requires actual RHEL base images (cannot be mocked easily)
- Needs valid Red Hat subscription credentials
- Platform-specific VM software must be installed

### Destructive Operations
- VM creation modifies the libvirt/UTM database
- Creates disk files that consume storage
- Modifies `~/.ssh/known_hosts`

Always test with disposable VM names.

### Platform-Specific Testing
You can only test the platform you're running on:
- Linux CI: Can test libvirt path
- macOS CI: Can test UTM path
- Cross-platform testing requires both environments

## Recent Changes & Migration

### Cloud-init Migration (Recent)
- **Before**: Used `virt-customize` to modify base images
- **After**: Uses cloud-init ISO attached to unmodified base images
- **Reason**: virt-customize unavailable on macOS

If working with older commits, be aware of this architectural change.

### ISO Tool Changes
- **Before**: Used `genisoimage`
- **After**: Uses `xorriso` (Linux) / `hdiutil` (macOS)
- **Reason**: `xorriso` is more actively maintained, ships with modern distros

## Known Limitations

1. **SSH Key**: Only supports `~/.ssh/id_rsa.pub` (no alternative key paths)
2. **IP Detection (macOS)**: UTM's AppleScript API doesn't always provide IP immediately
3. **VM Name Restrictions**: Cannot contain periods (conflicts with hostname format)
4. **Network Mode**: Fixed to shared/NAT (no bridged mode support currently)
5. **Resource Configuration**: Hardcoded (4GB RAM, 2 vCPUs on Linux)

## Future Enhancement Ideas

Based on README notes and code structure:
- Auto-create config.env with interactive prompts if missing
- Auto-create `~/.local/share/rhelmcp/` directory
- Support alternative SSH key paths
- Make VM resources configurable via flags
- Add VM snapshot/backup functionality
- Support other Linux distros (currently RHEL-specific)
