# modules/ipfs-cluster-volunteer.nix
#
# ONE SERVICE: be a VOLUNTEER PEER in someone else's IPFS Cluster.
#
# This is the NixOS equivalent of the coordinator's "Full install (Docker)"
# path: a Kubo node plus an ipfs-cluster peer, both on this box, the cluster
# peer joined to a cluster we do not own. It is deliberately written as ONE
# opt-in (`services.ipfsClusterVolunteer.enable = true`) rather than as two
# because the pair is a single fact about the box: a cluster peer with no Kubo
# under it has nothing to pin into, and a Kubo here exists only to hold what the
# cluster allocates.
#
# WHAT IT WRAPS. nixpkgs already ships `services.kubo` and
# `services.ipfs-cluster`, and this module configures both rather than replacing
# them. What nixpkgs' cluster module does NOT express is everything that makes a
# peer a VOLUNTEER instead of an owner: peer name, follower mode, whom to trust
# with the pinset, and whom to dial on boot. Those are supplied here as
# ENVIRONMENT VARIABLES on the cluster units, which is a real ipfs-cluster
# feature and not a trick: `ipfs-cluster-service` loads its config with
# `LoadJSONFileAndEnv` (cmdutils/configs.go), and every config section runs
# `envconfig.Process(<key>, ...)`, so
#
#   cluster section      -> CLUSTER_<FIELD>          (CLUSTER_PEERNAME, CLUSTER_FOLLOWERMODE, ...)
#   consensus.crdt       -> CLUSTER_CRDT_<FIELD>     (CLUSTER_CRDT_TRUSTEDPEERS)
#   ipfs_connector       -> CLUSTER_IPFSHTTP_<FIELD> (CLUSTER_IPFSHTTP_NODEMULTIADDRESS)
#   api.restapi          -> CLUSTER_RESTAPI_<FIELD>
#
# and the env value WINS over service.json on every start. That matters for a
# declarative box: service.json is written ONCE, at first boot, by the
# `ipfs-cluster-init` unit (it is guarded by ConditionDirectoryNotEmpty), so a
# config change that only edited that file would never take effect again on a
# box that has already been born. Env vars are re-applied on every start, so
# changing an option here and converging actually changes the running peer.
#
# WHY FOLLOWER MODE IS THE DEFAULT, AND WHAT IT IS NOT. `follower_mode = true`
# makes OUR peer refuse local pin/unpin calls: it is a statement about what this
# box will do, and it is the honest shape for a volunteer, because a volunteer
# who can write the pinset can also corrupt someone else's curated collection by
# accident. `trusted_peers` is the OTHER half and points the other way: it names
# the peers whose CRDT writes we will accept, i.e. it protects US from anyone
# else on the gossip channel. Neither is a permission the coordinator grants us;
# both are things this box decides about itself, which is exactly why they
# belong in this repo rather than in a message from the coordinator.
#
# WHAT WE STILL TRUST THE COORDINATOR WITH: disk. They decide which CIDs exist
# and how many replicas each wants, and our node fetches what it is allocated.
# The bound on that is `storageMax`, which is why it is a required-feeling
# option with a small default rather than "as much as the disk has".
{
  config,
  lib,
  ...
}: let
  cfg = config.services.ipfsClusterVolunteer;

  # ipfs-cluster parses list-valued env vars as COMMA-separated (envconfig's
  # slice handling), so this is the join every list option below goes through.
  csv = lib.concatStringsSep ",";

  # The env block handed to BOTH cluster units. `init` gets it so the config it
  # writes on day one already says the right thing; `daemon` gets it so the same
  # facts are re-asserted on every start and stay editable afterwards.
  clusterEnv =
    {
      # Who we appear as in `ipfs-cluster-ctl peers ls` on every peer in the
      # cluster, including the coordinator's dashboard. Defaults to the
      # hostname: a peer name is an identity, and the box already has one.
      CLUSTER_PEERNAME = cfg.peerName;

      # The volunteer posture (see the header). "true"/"false" as strings
      # because this is an env var; envconfig parses them into the bool field.
      CLUSTER_FOLLOWERMODE =
        if cfg.followerMode
        then "true"
        else "false";
      CLUSTER_PINONLYONTRUSTEDPEERS =
        if cfg.pinOnlyOnTrustedPeers
        then "true"
        else "false";

      # Whose CRDT writes we accept as pinset truth. Empty would mean "trust
      # everyone who knows the cluster secret", which is a much larger set than
      # "the coordinator".
      CLUSTER_CRDT_TRUSTEDPEERS = csv cfg.trustedPeers;

      # Whom to dial on boot to find the cluster. In CRDT mode this is
      # `peer_addresses`, not a one-shot `--bootstrap` flag: the flag also WIPES
      # local state and appends its peers to the trusted set, which is fine for
      # a hand-run first join and wrong as a permanent service definition.
      CLUSTER_PEERADDRESSES = csv cfg.bootstrapPeers;

      # Where our Kubo API is. Same default as upstream, written down because it
      # is the contract between the two halves of this module: change
      # `services.kubo.settings.Addresses.API` and this must follow.
      CLUSTER_IPFSHTTP_NODEMULTIADDRESS = "/ip4/127.0.0.1/tcp/${toString cfg.kuboApiPort}";

      # The cluster's own REST API: LOOPBACK ONLY, and no firewall port for it
      # anywhere in this module. `ipfs-cluster-ctl` talks to it, so it must
      # exist; nobody off this box has any business reaching it.
      CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS = "/ip4/127.0.0.1/tcp/9094";

      # Where the peer listens for cluster gossip. This is the one cluster port
      # that is public (see the firewall block below).
      CLUSTER_LISTENMULTIADDRESS = "/ip4/0.0.0.0/tcp/${toString cfg.clusterPort}";
    }
    // lib.optionalAttrs (cfg.announceAddresses != []) {
      # FOR A BOX BEHIND NAT ONLY. A peer announces the addresses it thinks it
      # has; behind NAT those are private and nobody can dial them back, so the
      # operator states the reachable one instead (the coordinator's docs call
      # this "your public or Tailscale IP"). A plain cloud VM with a public IP
      # must leave this empty: announcing an address is a claim, and a wrong
      # claim is worse than none.
      CLUSTER_ANNOUNCEMULTIADDRESS = csv cfg.announceAddresses;
    };
in {
  options.services.ipfsClusterVolunteer = {
    enable = lib.mkEnableOption "a Kubo node plus an ipfs-cluster peer that joins someone else's cluster as a read-only volunteer (follower mode)";

    peerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "The name this peer shows up as in the cluster (CLUSTER_PEERNAME). Visible to the coordinator and to every other peer.";
    };

    bootstrapPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["/ip4/149.210.143.16/tcp/9096/p2p/12D3KooWMRpaSMLHj3aoJqfxDMErRfu64HeHbwTttUynofsuBbzd"];
      description = ''
        Full multiaddresses of the peers to dial on boot, i.e. how this node
        finds the cluster at all (`peer_addresses`). The coordinator supplies
        this together with the cluster secret. Deliberately has NO default: this
        module describes the shape of a volunteer peer, not which cluster you
        volunteered for, so the cluster is named by the host that joins it.
      '';
    };

    trustedPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["12D3KooWMRpaSMLHj3aoJqfxDMErRfu64HeHbwTttUynofsuBbzd"];
      description = ''
        Peer IDs whose CRDT writes this node accepts as pinset truth
        (`consensus.crdt.trusted_peers`). In practice: the coordinator, and
        nothing else. Note this is the peer ID alone, not a multiaddress.

        Leaving it empty means trusting EVERY peer that holds the cluster
        secret, which is why `enable` asserts it is set.
      '';
    };

    followerMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Refuse pin/unpin issued locally (`follower_mode`). True is the whole
        point of a volunteer peer: this box hosts what it is allocated and
        writes nothing to someone else's curated pinset, even by mistake.

        Setting this false does NOT gain pinset authority in a cluster whose
        other peers do not trust this one; it only removes our own safety catch.
      '';
    };

    pinOnlyOnTrustedPeers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allocate pins only to trusted peers (`pin_only_on_trusted_peers`). Matches the coordinator's published volunteer config. Near-inert on a follower, which allocates nothing, and correct if this peer is ever promoted.";
    };

    storageMax = lib.mkOption {
      type = lib.types.str;
      default = "50GB";
      example = "200GB";
      description = ''
        The ceiling this box offers the cluster (Kubo's `Datastore.StorageMax`).
        THE ONE NUMBER THAT COSTS REAL MONEY, so it is stated per host.

        It is a Kubo-side soft limit enforced by garbage collection, not a
        quota: keep it comfortably under the free space on the filesystem that
        holds /var/lib/ipfs, or the disk fills before the limit is reached and
        the failure lands on the whole box rather than on IPFS.
      '';
    };

    swarmPort = lib.mkOption {
      type = lib.types.port;
      default = 4001;
      description = "Kubo's public libp2p swarm port (TCP and UDP/QUIC). Must be reachable for this node to serve the content it hosts.";
    };

    clusterPort = lib.mkOption {
      type = lib.types.port;
      default = 9096;
      description = "The cluster gossip/libp2p port. Must be reachable from the coordinator, which is how allocations and status reach this peer.";
    };

    kuboApiPort = lib.mkOption {
      type = lib.types.port;
      default = 5001;
      description = "Loopback port for Kubo's HTTP API, which the cluster peer drives. Never exposed: whoever reaches this API controls this node's pinset and can read every key it holds.";
    };

    announceAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["/ip4/203.0.113.7/tcp/9096"];
      description = "Only for a NAT'd box: the cluster multiaddresses to announce instead of the ones autodetected (`announce_multiaddress`). Leave empty on a host with a public IP.";
    };

    secretFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/ipfs-cluster/env";
      description = ''
        Path ON THE BOX to an EnvironmentFile holding the shared cluster secret
        as `CLUSTER_SECRET=<64 hex chars>`. That secret is the cluster's only
        access gate, so it is a sops secret decrypted to tmpfs at activation
        (see modules/secrets.nix); the default is that secret's pinned path.

        The file is read by systemd as root before the unit drops to the ipfs
        user, so the plaintext never has to be readable by the service account.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the two ports this peer must have reachable: `swarmPort` (TCP+UDP) for IPFS itself and `clusterPort` (TCP) for cluster gossip. The Kubo API, the Kubo gateway and the cluster REST API are never opened.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bootstrapPeers != [];
        message = "services.ipfsClusterVolunteer: bootstrapPeers is empty, so this peer has no way to find the cluster. Set it to the multiaddress the coordinator gave you.";
      }
      {
        assertion = cfg.trustedPeers != [];
        message = "services.ipfsClusterVolunteer: trustedPeers is empty, which trusts EVERY peer holding the cluster secret with this node's pinset. Set it to the coordinator's peer ID.";
      }
      {
        # A bootstrap entry must be a FULL multiaddress, peer ID included. An
        # address without the /p2p/ segment parses and dials and then cannot
        # authenticate the peer it reached, so the node comes up healthy, joins
        # nothing, and reports no error worth reading. Catching it at eval is
        # the difference between a typo and an afternoon.
        assertion = lib.all (addr: lib.hasInfix "/p2p/" addr) cfg.bootstrapPeers;
        message = "services.ipfsClusterVolunteer: every bootstrapPeers entry must be a full multiaddress including the /p2p/<peer-id> segment (e.g. /ip4/1.2.3.4/tcp/9096/p2p/12D3Koo...). Got: ${csv cfg.bootstrapPeers}";
      }
      {
        # The peer ID inside each bootstrap address should be one we actually
        # trust with the pinset. This is a WARNING-SHAPED assertion rather than
        # a deep check: it is legitimate to bootstrap through a peer you do not
        # trust (any cluster member can introduce you to the gossip channel),
        # so it only fires when NONE of the bootstrap peers is trusted, which in
        # a single-coordinator cluster like this one means the two values have
        # drifted apart and one of them is a typo.
        assertion =
          lib.any
          (addr: lib.any (peer: lib.hasInfix peer addr) cfg.trustedPeers)
          cfg.bootstrapPeers;
        message = "services.ipfsClusterVolunteer: no bootstrapPeers entry names a peer from trustedPeers. In a cluster with a single coordinator these are the same peer ID, so one of the two is likely mistyped.";
      }
    ];

    # --- The storage layer: a Kubo node that exists to hold cluster content ---
    services.kubo = {
      enable = true;

      # GC ON, which is not the nixpkgs default and is load-bearing here.
      # StorageMax is enforced BY garbage collection, so without GC the datastore
      # grows past it: everything the cluster allocated is pinned and therefore
      # safe from collection, while the unpinned blocks this node picked up
      # serving others are exactly what should be dropped when the box gets
      # full.
      enableGC = true;

      # Do not scan the local network. The nixpkgs module maps this to Kubo's
      # `server` profile, which also filters private address ranges out of what
      # we dial and announce. Correct for a VPS (some hosts read LAN scanning as
      # abuse), and harmless on a home box that is only doing public work.
      localDiscovery = false;

      settings = {
        # LOOPBACK API. The cluster peer is the only client that needs it.
        Addresses.API = "/ip4/127.0.0.1/tcp/${toString cfg.kuboApiPort}";

        # LOOPBACK GATEWAY. This box is a replica, not a public gateway: content
        # is served over libp2p to whoever asks, which needs no HTTP surface.
        # Leaving the gateway on localhost keeps it usable for a human debugging
        # over an SSH tunnel and invisible to everyone else.
        Addresses.Gateway = "/ip4/127.0.0.1/tcp/8080";

        # IPv4-ONLY, listing the transports explicitly rather than taking the
        # module default, which includes four `/ip6/` entries. modules/profiles/
        # cloud.nix disables IPv6 on this class of host, and binding a v6 socket
        # on a box with no v6 address is noise in the log at best.
        Addresses.Swarm = [
          "/ip4/0.0.0.0/tcp/${toString cfg.swarmPort}"
          "/ip4/0.0.0.0/udp/${toString cfg.swarmPort}/quic-v1"
          "/ip4/0.0.0.0/udp/${toString cfg.swarmPort}/quic-v1/webtransport"
        ];

        Datastore.StorageMax = cfg.storageMax;

        # ANNOUNCE WHAT WE ARE FOR, not everything we have touched. Kubo's
        # default strategy ("all") republishes provider records for every block
        # in the datastore, including blocks cached while serving other people's
        # requests. "pinned" announces the recursively pinned DAGs, which on
        # this box IS the cluster's allocation to us: it is the content we
        # promised to keep findable, and the rest is cache that GC may drop at
        # any moment, so announcing it is a promise we do not keep.
        Provide.Strategy = "pinned";

        # A connection budget. Kubo's defaults are tuned for a machine with room
        # to spare; a 2-4 GB VPS that is also running a cluster peer is not that
        # machine, and an unbounded peer count is the usual way an IPFS node
        # turns into a memory problem. These are deliberately modest and are the
        # first thing to raise if this peer looks slow to fetch allocations.
        Swarm.ConnMgr = {
          Type = "basic";
          LowWater = 100;
          HighWater = 300;
          GracePeriod = "20s";
        };
      };

      # IPFS opens a lot of sockets. The default soft limit is not enough for a
      # node with hundreds of peers, and running out shows up as mysterious
      # dial failures rather than as an obvious error.
      serviceFdlimit = 65536;
    };

    # --- The membership layer: the cluster peer itself ---
    services.ipfs-cluster = {
      enable = true;

      # VERSION, since it is the first thing to suspect if a join fails: nixpkgs
      # 26.05 ships ipfs-cluster 1.1.5 and the coordinator's Docker setup runs
      # 1.1.6. That release is maintenance only (dependency bumps, go1.26, its
      # own notes say "no breaking changes" and "configuration changes: none"),
      # so the two interoperate. If a later coordinator version ever does break
      # compatibility, the fix is an overlay pinning `pkgs.ipfs-cluster` to a
      # matching version, not a change to this module.

      # CRDT, not raft, and this is not a preference: the cluster we are joining
      # is CRDT (that is what makes follower peers and trusted_peers meaningful),
      # and a raft peer cannot join it at all.
      consensus = "crdt";

      # The shared secret, as an EnvironmentFile. nixpkgs hands this to the init
      # unit; the daemon override below hands it to the daemon too, so the
      # secret survives even if service.json is ever rewritten.
      secretFile = cfg.secretFile;

      # Opens 9096 (the module hardcodes that port number, which is why
      # `clusterPort` staying at its default matters if you use this).
      openSwarmPort = cfg.openFirewall && cfg.clusterPort == 9096;
    };

    # The volunteer posture, applied to the config file at birth...
    systemd.services.ipfs-cluster-init.environment = clusterEnv;

    # ...and re-asserted on every start of the daemon, which is what makes these
    # options editable on a box that already exists (see the header).
    systemd.services.ipfs-cluster = {
      environment = clusterEnv;

      # ORDERING, which upstream's module leaves unstated. The peer can survive
      # Kubo being absent (it retries), but starting it first guarantees a noisy
      # first minute after every reboot for no reason.
      after = ["ipfs.service"];
      wants = ["ipfs.service"];

      serviceConfig = {
        # The secret for the DAEMON, not just for init. Upstream assumes the
        # value was baked into service.json on day one; that is true here too,
        # and it means the secret exists in two places. This is the one that
        # tracks the repo.
        EnvironmentFile = cfg.secretFile;

        # A peer that dies must come back. Upstream sets no Restart at all, so
        # a single crash silently ends this box's participation until someone
        # notices the dashboard is missing a peer.
        Restart = "on-failure";
        RestartSec = "10s";

        LimitNOFILE = 65536;
      };
    };

    # --- The public surface, stated in one place ---
    #
    # Exactly two ports, both of which MUST be reachable for this box to be
    # useful: without the swarm port we can fetch content but nobody can fetch
    # it from us, which makes the replica worthless; without the cluster port
    # the coordinator cannot reach us and allocations never arrive.
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [cfg.swarmPort] ++ lib.optional (cfg.clusterPort != 9096) cfg.clusterPort;
      # QUIC is UDP on the same port number, and it is how a large share of the
      # network now dials. Leaving it closed does not break the node, it just
      # quietly halves who can reach it.
      allowedUDPPorts = [cfg.swarmPort];
    };
  };
}
