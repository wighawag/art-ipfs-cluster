# modules/profiles/cloud-common.nix
#
# What EVERY cloud VM in this repo gets, regardless of its architecture or its
# firmware: no IPv6, store hygiene, and the virtio modules stage-1 needs to see
# a disk at all.
#
# The two things that are NOT here are exactly the two that vary with the metal:
# what the FIRMWARE can launch (legacy BIOS on Hetzner's x86 line, UEFI on its
# ARM line) and therefore which bootloader is correct. Those live in the sibling
# profiles, and a host imports EXACTLY ONE of them:
#
#   ./cloud-x86.nix   Hetzner CX / CPX / CCX  (legacy BIOS, GRUB)
#   ./cloud-arm.nix   Hetzner CAX             (UEFI, systemd-boot)
#
# This split exists because the CX line went out of stock everywhere on
# 2026-09-23 and the ARM line did not, which turned "which architecture" from a
# non-question into a live one. Keeping the shared half shared means adding the
# second architecture cost one small file rather than a fork of the first.
{lib, ...}: {
  # --- IPv6: OFF ---
  #
  # Hetzner assigns every cloud server a /64 and DOES NOT ADVERTISE IT, so
  # "working IPv6" on this provider means writing a provider-assigned address
  # into the repo, which makes a rebuild produce a box that boots fine and is
  # quietly wrong. Off is the honest state: `enableIPv6 = false` sets the
  # disable_ipv6 sysctls only, so AF_INET6 sockets still succeed while no v6
  # addresses exist.
  #
  # WHAT IT COSTS HERE, and it is a real cost for THIS service specifically: an
  # IPv6-only IPFS peer cannot reach us, and we announce no v6 address, so a
  # slice of the network can neither dial us nor fetch what we host. The node
  # still works over IPv4 with the rest, and the answer if that slice ever
  # matters is a host that owns its address deliberately, not a half-configured
  # stack. Kubo's swarm listeners are pinned to /ip4/ in the service module for
  # the same reason.
  networking.enableIPv6 = lib.mkDefault false;

  # --- Store hygiene on a disk nobody is watching ---
  #
  # This box's whole job is to fill a disk with someone else's content. A Nix
  # store that also grows without bound turns "the datastore reached its limit"
  # into "the box is full", and the failure lands at the worst moment: a deploy
  # that cannot build. That is sharper here than on most hosts, because this box
  # BUILDS ITS OWN CLOSURE (see buildOnTarget in flake.nix) rather than
  # receiving it prebuilt.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    # By AGE, so the last known-good generation is still there to roll back to
    # after a quiet fortnight.
    options = "--delete-older-than 14d";
  };

  nix.optimise = {
    automatic = true;
    dates = ["weekly"];
  };

  # --- What stage-1 can see ---
  #
  # Cloud VMs present disks and controllers over VIRTIO on both architectures,
  # so the initrd needs these or the root device never appears and stage-1 hangs
  # waiting for it. There is no hardware-configuration.nix in this repo (the box
  # is birthed, not nixos-generate-config'd), so it is declared explicitly.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sd_mod"
    "sr_mod"
  ];
}
