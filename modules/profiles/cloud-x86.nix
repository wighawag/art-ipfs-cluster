# modules/profiles/cloud-x86.nix
#
# The machine-class profile for Hetzner's x86 cloud lines (CX, CPX, CCX) and the
# usual KVM/QEMU shapes. Import this OR ./cloud-arm.nix, never both.
#
# --- What the firmware can launch ---
#
# Hetzner Cloud's x86 instances boot with LEGACY BIOS (SeaBIOS). systemd-boot is
# UEFI-only, so it would install a bootloader the firmware cannot launch and the
# box hangs at "Booting from Hard Disk..." with no further output, which is a
# miserable thing to debug on a machine you cannot see. GRUB with a bios_grub
# partition plus efiSupport boots on BOTH firmware types, and
# efiInstallAsRemovable writes the removable-media EFI path so no NVRAM writes
# are needed (a cloud VM's NVRAM is not reliably writable or persistent).
{...}: {
  imports = [./cloud-common.nix];

  # Ask the disk layout for the 1 MiB BIOS-boot partition GRUB embeds its core
  # image into. GPT has no MBR gap, so without this partition a legacy-BIOS box
  # cannot boot at all. See modules/disko-single-gpt.nix.
  my.biosCompat = true;

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev"; # GPT: GRUB installs into the bios_grub partition.

    # The boot menu's own cap. Without it /boot eventually fills, which fails a
    # deploy at the very last step (bootloader install) rather than at the
    # build, i.e. after everything else has already succeeded.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = false;
}
