{
  description = "art-ipfs-cluster — a NixOS volunteer peer for a curated IPFS Cluster (birth: nixos-anywhere, converge: colmena, secrets: sops-nix)";

  # This repo is the STANDALONE version of one my-boxes host: same three verbs
  # (birth with nixos-anywhere, converge with colmena, secrets with sops-nix),
  # one box, one service. It is standalone on purpose, so that joining someone
  # else's cluster can be proven end to end without touching a fleet that runs
  # real workloads; the service module is written to be liftable into my-boxes
  # unchanged when it is.

  inputs = {
    # ONE nixpkgs, current stable. 26.05 carries both modules this repo builds
    # on (services.kubo and services.ipfs-cluster), so nothing here needs a
    # second pin or an overlay.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Partitioning, declaratively, at birth.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Encrypted-secrets-in-git. The cluster secret is the only secret here, and
    # it is the whole access gate, so this input is load-bearing.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # BIRTH: install this whole config onto a stock provider image over SSH via
    # kexec, partitioning with disko. Pinned here rather than run ad hoc from
    # the internet, so the tool that wipes a disk is a version this repo chose.
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    sops-nix,
    nixos-anywhere,
    ...
  } @ inputs: let
    # The OPERATOR's platform: where `nix develop`, the checks and the deploy
    # tooling run. NOT necessarily the platform any box runs (see fleet below).
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    # --- The fleet: the SINGLE source of truth for which boxes exist. ---
    #
    # One host today. It is still a MAP, and both nixosConfigurations and the
    # colmena nodes below are generated from it, because the moment a second
    # volunteer box exists (a spare at home, a second VPS) it must be one new
    # entry and not a second copy of the wiring.
    fleet = {
      pin-01 = {
        module = ./hosts/pin-01;
        tags = ["cloud"];

        # WHERE COLMENA CONNECTS.
        #
        # A LITERAL IP, which is the weaker of the two options and is written
        # down as such rather than pretended otherwise. It is the address
        # Hetzner handed this box at its first birth (2026-09-23), and it stays
        # correct only for as long as this exact server exists.
        #
        # A DNS NAME WOULD BE BETTER, for a specific rather than stylistic
        # reason: this box's Primary IP is on auto-delete, so deleting and
        # rebirthing the server (which is how it gets a bigger disk, since disko
        # describes a disk rather than migrating one) brings it back on a
        # DIFFERENT address, and this line is then quietly wrong in a way that
        # surfaces only as a deploy which cannot connect.
        #
        # To switch: add `A pin-01.ska.sh -> <addr>` and replace this with
        # `targetHost = "pin-01.ska.sh";`. Nothing else in the repo changes --
        # no certificate depends on it (this box terminates no TLS) and the
        # cluster finds its peers over libp2p, not DNS.
        targetHost = "2.28.233.179";

        # THE BOX'S OWN ARCHITECTURE, which is not the operator's.
        #
        # pin-01 runs on a Hetzner CAX (Ampere Altra), because on 2026-09-23 the
        # entire x86 CX line was out of stock at every location while the ARM
        # line was available, and ARM is also roughly half the price for the
        # same disk: CAX21 (4 vCPU, 8 GB, 80 GB) at 10.99 EUR/mo against CPX22
        # (2 vCPU, 4 GB, 80 GB) at 19.99. For a box whose whole job is to sit
        # there holding data, that is the easy trade.
        #
        # Switching back to x86 is TWO lines: this one, and the profile import
        # in hosts/pin-01/default.nix. Nothing else in the repo is
        # architecture-aware, which is the point of the profile split.
        system = "aarch64-linux";
      };
    };

    # The shared module list every host gets. Both nixosConfigurations and the
    # colmena nodes assemble THIS, so there is no second source of truth for
    # what a box in this repo is.
    hostModules = hostModule: [
      disko.nixosModules.disko
      sops-nix.nixosModules.sops
      ./modules/common.nix
      ./modules/ipfs-cluster-volunteer.nix
      hostModule
    ];

    mkHost = host:
      nixpkgs.lib.nixosSystem {
        system = host.system;
        specialArgs = {inherit inputs self;};
        modules = hostModules host.module;
      };

    # The config of the one host, for the checks below to make assertions about.
    pin01 = self.nixosConfigurations.pin-01.config;

    # An eval-only check: `nix flake check` fails if the assertion does, and
    # produces an empty output if it holds. Cheap, and it runs on every change.
    assertCheck = name: cond: message:
      pkgs.runCommand name {} (
        if cond
        then "touch $out"
        else throw "check ${name} FAILED: ${message}"
      );
  in {
    nixosConfigurations = lib.mapAttrs (_name: host: mkHost host) fleet;

    # --- colmena: CONVERGE the box from one command. ---
    #
    #   nix develop -c colmena apply --on @cloud
    #
    # Each node re-uses the exact module list of its nixosConfiguration, so the
    # thing colmena deploys IS the thing `nix flake check` evaluated.
    colmena =
      {
        meta = {
          # The OPERATOR's pkgs. Each node whose architecture differs overrides
          # it below; without that, colmena would evaluate an aarch64 host
          # against x86 pkgs and produce a closure that cannot run.
          nixpkgs = import nixpkgs {inherit system;};
          specialArgs = {inherit inputs self;};

          # Per-node pin override, derived from `fleet` so it cannot drift from
          # the map above.
          nodeNixpkgs =
            builtins.mapAttrs (_name: host: import nixpkgs {system = host.system;})
            (lib.filterAttrs (_name: host: host.system != system) fleet);
        };
      }
      // lib.mapAttrs (name: host: {...}: {
        deployment = {
          targetHost = host.targetHost or name;

          # Deploy as `admin` and let it sudo for activation: root is
          # deliberately key-less after birth (modules/common.nix), so root is
          # birth-only and every converge goes through the hardened account.
          targetUser = "admin";
          privilegeEscalationCommand = ["sudo" "-H" "--"];

          # BUILD ON THE TARGET when the box is not the operator's architecture.
          #
          # This is not a preference, it is the only path that works here:
          # pin-01 is aarch64 and telemaque (where deploys are run) is x86_64
          # with no binfmt emulation registered, so a local build cannot even
          # start. The box has 4 Ampere cores and pulls almost everything from
          # cache.nixos.org, which builds aarch64-linux for the stable channel,
          # so in practice this substitutes rather than compiles.
          #
          # Derived from `fleet` rather than hardcoded, so an x86 host added
          # later gets the normal build-here-push-the-closure shape with no
          # edit.
          buildOnTarget = host.system != system;

          # Tags are SCOPING, not decoration: a bare `colmena apply` targets
          # every node, and this repo is meant to grow a second volunteer box.
          tags = host.tags;
        };
        imports = hostModules host.module;
      })
      fleet;

    # --- Checks: the invariants that make this a volunteer peer ---
    #
    # These are the claims the coordinator's trust model makes, asserted against
    # the config that will actually be deployed rather than believed. They cost
    # one eval and they are the difference between "we set follower mode" and
    # "follower mode is set".
    checks.${system} = {
      # THE VOLUNTEER POSTURE. If any of these three silently stopped being
      # true, this box would look identical and behave like a peer that can
      # write someone else's pinset, or accept writes from anyone holding the
      # secret.
      volunteer-posture-holds =
        assertCheck "volunteer-posture-holds"
        (
          pin01.systemd.services.ipfs-cluster.environment.CLUSTER_FOLLOWERMODE
          == "true"
          && pin01.systemd.services.ipfs-cluster.environment.CLUSTER_CRDT_TRUSTEDPEERS != ""
          && pin01.systemd.services.ipfs-cluster-init.environment.CLUSTER_FOLLOWERMODE == "true"
        )
        "pin-01 must run in follower mode with a non-empty trusted-peers list, on BOTH the init and daemon units";

      # THE PUBLIC SURFACE. Two ports in, and specifically NOT the Kubo API
      # (5001, which is full control of this node), the gateway (8080) or the
      # cluster REST API (9094).
      public-surface-is-two-ports =
        assertCheck "public-surface-is-two-ports"
        (
          lib.sort (a: b: a < b) pin01.networking.firewall.allowedTCPPorts
          == [22 4001 9096]
          && pin01.networking.firewall.allowedUDPPorts == [4001]
        )
        "pin-01 must open exactly 22, 4001/tcp+udp and 9096/tcp; got TCP ${toString pin01.networking.firewall.allowedTCPPorts} UDP ${toString pin01.networking.firewall.allowedUDPPorts}";

      # THE SECRET PATH IS ONE VALUE. The service module defaults its
      # EnvironmentFile to a literal path and modules/secrets.nix pins the
      # decrypted secret to a literal path. They are two files, so they can
      # drift; if they do, the daemon starts with no CLUSTER_SECRET and fails to
      # join with an error that does not mention either file.
      secret-path-is-one-value =
        assertCheck "secret-path-is-one-value"
        (pin01.services.ipfsClusterVolunteer.secretFile == pin01.sops.secrets."ipfs-cluster/env".path)
        "services.ipfsClusterVolunteer.secretFile and sops.secrets.\"ipfs-cluster/env\".path must be the same path";

      # THE CLUSTER TALKS TO OUR OWN KUBO, on loopback. A cluster peer pointed
      # at someone else's API would pin into a node we do not control.
      cluster-uses-local-kubo =
        assertCheck "cluster-uses-local-kubo"
        (
          pin01.systemd.services.ipfs-cluster.environment.CLUSTER_IPFSHTTP_NODEMULTIADDRESS
          == "/ip4/127.0.0.1/tcp/5001"
          && pin01.services.kubo.settings.Addresses.API == "/ip4/127.0.0.1/tcp/5001"
        )
        "the cluster peer must drive this box's own Kubo API on loopback";

      # DISABLED IS INERT. The module must add nothing at all when it is not
      # enabled, which is what makes it safe to import into my-boxes' shared
      # module list later, where most hosts will never enable it.
      disabled-is-inert = let
        bare =
          (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/ipfs-cluster-volunteer.nix
              {
                networking.hostName = "inert";
                system.stateVersion = "26.05";
              }
            ];
          })
          .config;
      in
        assertCheck "disabled-is-inert"
        (
          !bare.services.kubo.enable
          && !bare.services.ipfs-cluster.enable
          && !(bare.systemd.services ? ipfs-cluster)
          && bare.networking.firewall.allowedTCPPorts == []
        )
        "importing modules/ipfs-cluster-volunteer.nix without enabling it must change nothing";

      # And the box's config EVALUATES, fully: every assertion in every module
      # fires, every option type is checked, and the derivation is computed.
      #
      # EVALUATES rather than BUILDS, and that is a real reduction worth naming:
      # pin-01 is aarch64 and this check runs on the operator's x86 machine,
      # which has no binfmt emulation, so actually building it here is not
      # possible. Forcing `.drvPath` does all the work that catches a config
      # mistake (assertions, types, the module system) and stops short of
      # compiling. The real build happens on the box itself at birth and at
      # every converge (buildOnTarget above), which is also where a genuine
      # build failure would surface.
      #
      # `checks.aarch64-linux.pin-01-builds` below is the full build, for a
      # machine that can actually run it.
      pin-01-evaluates =
        assertCheck "pin-01-evaluates"
        (lib.isString self.nixosConfigurations.pin-01.config.system.build.toplevel.drvPath)
        "pin-01's configuration must evaluate";
    };

    # The full build of the box, on a machine of its own architecture. Not part
    # of the operator's `nix flake check` for the reason above; run it from an
    # ARM machine, or in CI with an aarch64 runner.
    checks.aarch64-linux.pin-01-builds =
      self.nixosConfigurations.pin-01.config.system.build.toplevel;

    packages.${system} = {
      # The deploy tool, within reach of a clone. A repo whose point is that
      # anyone can operate the box cannot require a colmena installed out of
      # band.
      colmena = pkgs.colmena;
      default = pkgs.colmena;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.colmena
        # Birth, from the pinned input rather than from whatever is on PATH.
        nixos-anywhere.packages.${system}.default
        # Secrets: edit them (sops), derive a box's recipient from its SSH host
        # key (ssh-to-age), and mint the operator key (age).
        pkgs.sops
        pkgs.ssh-to-age
        pkgs.age
        # provision/birth.sh shells out to ssh and ssh-keygen (it verifies the
        # staged identity against the committed public half before sending it).
        pkgs.openssh
        # What a Hetzner box is created with, and what the runbook shells out
        # to. Committed to the shell so operating this repo needs nothing
        # installed by hand.
        pkgs.hcloud
        pkgs.jq
        pkgs.curl # Talk to the running peer from a workstation over an SSH tunnel.
        pkgs.ipfs-cluster
        pkgs.kubo
        pkgs.bashInteractive
      ];
    };

    formatter.${system} = pkgs.alejandra;
  };
}
