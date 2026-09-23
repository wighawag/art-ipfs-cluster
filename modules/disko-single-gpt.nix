# modules/disko-single-gpt.nix
#
# A single-disk GPT layout, taken from my-boxes (same file, same reasoning) so
# that folding this repo back into that fleet is a copy of the host file and the
# service module, not a re-derivation of the disk.
#
# Layout: GPT with an optional 1M BIOS-boot partition (EF02, see below), an EFI
# System Partition (FAT32, /boot), and the rest as one ext4 root.
#
# The disk DEVICE is a per-host option, never hardcoded: Hetzner Cloud presents
# /dev/sda on both its x86 and its ARM lines, other providers /dev/vda or
# /dev/nvme0n1, and that is a one-line host override rather than a fork of this
# file.
#
# THE BIOS-BOOT PARTITION IS CONDITIONAL, via `my.biosCompat`, which the machine
# -class profile sets (true in cloud-x86.nix, false in cloud-arm.nix). It is
# REQUIRED on Hetzner's x86 instances, which boot legacy BIOS on a GPT disk and
# therefore need somewhere for GRUB to embed its core image; it is meaningless
# on an Ampere box, which is UEFI-only. Carrying it unconditionally would cost
# only 1 MiB, but it would also assert in the partition table that the ARM host
# can boot BIOS, which is not true and which someone will eventually believe.
#
# WHY ONE BIG ROOT rather than a separate /var/lib/ipfs: because on this box
# they are the same concern. A dedicated data partition is the right answer when
# the data lives on a volume that outlives the OS (a Hetzner Volume, a second
# disk), and if this peer ever grows one, that is a NEW disko module and a
# rebirth, not an edit here. Until then a separate partition would only add a
# way for one half to fill while the other has room.
{
  lib,
  config,
  ...
}: {
  options.my.diskDevice = lib.mkOption {
    type = lib.types.str;
    default = "/dev/sda";
    example = "/dev/vda";
    description = "The whole-disk device disko partitions for this host.";
  };

  options.my.espSize = lib.mkOption {
    type = lib.types.str;
    default = "512M";
    example = "1G";
    description = "Size of the EFI System Partition, which IS /boot on NixOS and therefore holds a kernel and initrd per retained generation. Birth-only: disko describes a disk, it does not migrate one.";
  };

  options.my.biosCompat = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to carve a 1 MiB BIOS-boot (EF02) partition for GRUB's core image. Required on a legacy-BIOS host with a GPT disk (Hetzner's x86 lines); pointless on a UEFI-only host (Hetzner's ARM line). Set by the machine-class profile, not by the host.";
  };

  config = {
    disko.devices.disk.main = {
      type = "disk";
      device = config.my.diskDevice;
      content = {
        type = "gpt";
        partitions =
          lib.optionalAttrs config.my.biosCompat {
            # Legacy-BIOS boot: GRUB embeds its core image here, because GPT has
            # no MBR gap. 1 MiB, no filesystem.
            boot = {
              priority = 0;
              size = "1M";
              type = "EF02";
            };
          }
          // {
            ESP = {
              priority = 1;
              size = config.my.espSize;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
      };
    };
  };
}
