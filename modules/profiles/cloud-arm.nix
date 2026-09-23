# modules/profiles/cloud-arm.nix
#
# The machine-class profile for Hetzner's ARM cloud line (CAX, Ampere Altra).
# Import this OR ./cloud-x86.nix, never both.
#
# --- What the firmware can launch ---
#
# An Ampere box has NO legacy BIOS: aarch64 servers boot UEFI, full stop. So the
# x86 profile's whole GRUB-with-a-bios_grub-partition arrangement is not merely
# unnecessary here, it is describing hardware that does not exist. systemd-boot
# is the simple correct answer on a UEFI-only machine: it needs no NVRAM writes
# to be installed (it writes to the ESP), and its `configurationLimit` caps the
# menu the same way GRUB's does.
#
# `canTouchEfiVariables = false` for the same reason it is false on the x86
# side: a cloud VM's NVRAM is not reliably writable or persistent, and the box
# boots the removable-media path from the ESP regardless.
{...}: {
  imports = [./cloud-common.nix];

  # NO bios_grub partition: nothing on this machine can use it. It would cost
  # only 1 MiB, but a partition that exists for firmware the box does not have
  # is a lie in the disk layout, and someone will eventually read it as evidence
  # that this host boots BIOS.
  my.biosCompat = false;

  boot.loader.systemd-boot = {
    enable = true;
    # The cap, same reasoning as the x86 profile's GRUB limit: without it /boot
    # fills and the failure lands at bootloader install, after the build has
    # already succeeded.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = false;
}
