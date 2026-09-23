# hosts/pin-01/default.nix
#
# The volunteer peer. A host file is THIN by design: it says what is unique to
# THIS box and nothing else.
#
# THE NAME. `pin-01` is a ROLE name, following my-boxes' ADR-0004: machines with
# a personality in that fleet get Ulysse 31 names, and something that is purely
# a role just says its role (as `box-01` does there). This box is purely a role:
# it holds pins for a cluster it does not own. The name is also deliberately
# NOT `box-02`, so that folding this repo into my-boxes later cannot collide
# with a name that fleet may have taken in the meantime.
{...}: {
  imports = [
    ../../modules/disko-single-gpt.nix
    # The ARM machine-class profile: UEFI + systemd-boot, because a Hetzner CAX
    # (Ampere Altra) has no legacy BIOS. Swap this for ../../modules/profiles/
    # cloud-x86.nix together with the `system` line in flake.nix to move this
    # host back to an x86 instance.
    ../../modules/profiles/cloud-arm.nix
  ];

  networking.hostName = "pin-01";

  # Hetzner Cloud presents /dev/sda on both its x86 and its ARM lines. A
  # different provider is a one-line change.
  my.diskDevice = "/dev/sda";

  # --- The one service this box exists for ---
  services.ipfsClusterVolunteer = {
    enable = true;

    # What the coordinator's dashboard and every other peer will call us.
    # Defaults to the hostname; stated here because the name is public and
    # shared, so it should be chosen rather than inherited by accident.
    peerName = "wighawag-pin-01";

    # WHOSE CLUSTER. These two values come from the coordinator's public
    # volunteer instructions (github.com/rudyvdtas/ipfs-cluster-coordinator),
    # and they are the non-secret half of joining: the address to dial and the
    # peer ID whose pinset writes we accept. The SECRET half is the shared
    # CLUSTER_SECRET, which the coordinator sends privately and which lives
    # encrypted in secrets/ipfs-cluster.env.
    #
    # VERIFY BOTH OF THESE WITH YOUR CONTACT before the first boot, over a
    # channel you trust. A wrong bootstrap address costs nothing (we fail to
    # connect), but a wrong TRUSTED PEER ID is the one value in this file that
    # can hurt: it names who may write the pinset this box will then go and
    # fetch. The peer ID inside the bootstrap multiaddress below and the
    # trustedPeers entry are the same string, which is a useful cross-check and
    # not a coincidence.
    bootstrapPeers = [
      "/ip4/149.210.143.16/tcp/9096/p2p/12D3KooWMRpaSMLHj3aoJqfxDMErRfu64HeHbwTttUynofsuBbzd"
    ];
    trustedPeers = [
      "12D3KooWMRpaSMLHj3aoJqfxDMErRfu64HeHbwTttUynofsuBbzd"
    ];

    # HOW MUCH DISK WE ARE DONATING.
    #
    # THIS NUMBER MUST FIT THE SERVER YOU ACTUALLY BUY, and it is the one line
    # in this repo that is wrong by default if you skip it: a 40GB instance
    # cannot honour a 50GB datastore ceiling, so it fills the root filesystem
    # and takes the box down instead of capping anything. Rule of thumb:
    # StorageMax <= disk - 10GB (OS, store, logs, and room for a BUILD, which
    # on this host happens locally rather than being pushed prebuilt).
    #
    #   CAX11 / CPX12    40GB disk  ->  "25GB"
    #   CAX21 / CPX22    80GB disk  ->  "60GB"
    #   CAX31 / CPX32   160GB disk  -> "140GB"
    #
    # Set for a CAX11 (40GB), which is provision/hetzner.sh's default server
    # type and the only instance under the operator's 7 EUR/month budget that
    # Hetzner had in stock. Change the two together, or the box comes up with a
    # datastore ceiling its disk cannot honour.
    #
    # 25GB IS BELOW THE 50GB THE COORDINATOR MENTIONS, and that is deliberate
    # rather than an oversight. Their 50GB figure belongs to the two paths that
    # attach a cluster peer to an EXISTING node; the full-install path this repo
    # mirrors states only "disk space: configurable via IPFS_STORAGE_MAX", and
    # their FAQ says in as many words to "start with a smaller amount if you are
    # unsure". A 25GB replica that stays up is worth more to the cluster than a
    # 60GB one that was never affordable. Raising it later is this line plus a
    # bigger instance, which is a rebirth, not a resize.
    storageMax = "25GB";

    # `followerMode` and `pinOnlyOnTrustedPeers` are left at the module's
    # defaults (both true), which is the volunteer posture. They are NOT copied
    # here: a host-side copy of a module default is a second source of truth
    # that drifts the moment either is edited.

    # `announceAddresses` is empty (module default) because a Hetzner Cloud box
    # has a public IPv4 and can autodetect it correctly. A box behind NAT, or
    # one reachable only over a mesh, must state its reachable address there.
  };

  # THE SECRET IS NOT HERE. It is `CLUSTER_SECRET` in secrets/ipfs-cluster.env,
  # encrypted with sops, decrypted to /run/secrets/ipfs-cluster/env at
  # activation. Changing it is `sops secrets/ipfs-cluster.env` plus a deploy,
  # with no change to this file.
}
