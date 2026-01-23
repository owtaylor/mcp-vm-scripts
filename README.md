This folder contains some scripts to manage VMss for MCP testing

== Scripts

=== Configuration

Configuration is read from ~/.config/rhelmcp/config.env

```
# https://console.redhat.com/insights/connector/activation-keys
REDHAT_ORG_ID=123451
REDHAT_ACTIVATION_KEY=myuser-rhelmcp
```

=== ./tools/setup-vm.sh

Uses libvirt to create a system to test with

Usage: ./tools/setup-vm.sh --version=<RHEL-MAJOR>.<RHEL-MINOR> <NAME>

 * Check that libvirtd is running and you can connect with: virsh -c qemu:///system
 * Checks that an image exists at ~/.local/share/rhelmcp/rhel-X.Y-x86_64-kvm.qcow2, if not, errors out referencing
   https://access.redhat.com/downloads/content/rhel
 * Creates a vm using that image
 * Sets it up for mDNS at <NAME>.local
 * Registers it using the variables from rhelmcp/config.env
 * Creates an account with the username of the current user and sets it up for ssh access using the public key from ~/.ssh/id_rsa.pub
 * Starts it
 * Sets it up in ~/.ssh/known_hosts

Enhancements:
 - If config.env doesn't exist, create it, ask the user to edit it "<RETURN> to continue"
 - Make ~/.local/share/rhelmcp/ if it doesn't exist
