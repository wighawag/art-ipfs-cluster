# modules/secrets.nix
#
# The sops-nix base: which encrypted file a host reads, and how it decrypts.
#
# There is exactly ONE secret in this repo, and it is the one that matters: the
# shared CLUSTER_SECRET. It is the cluster's only access gate (the coordinator's
# own trust model says so: "there is no open sign-up, the secret is the access
# gate"), so it must never be committed in plaintext, never land in the Nix
# store, and never be pasted into a shell where it lands in history.
#
# HOW DECRYPTION WORKS ON THE BOX:
#   - sops-nix uses the host's own ed25519 SSH host key as an age identity
#     (`sops.age.sshKeyPaths` defaults to it), so NO extra key material is ever
#     distributed to the box. The box can read what was encrypted to it because
#     it is itself.
#   - At activation it decrypts to a tmpfs path under /run/secrets/. The Nix
#     store only ever holds the ENCRYPTED file.
#
# WHO can decrypt is decided in /.sops.yaml (the operator's age key + this
# host's, derived from its SSH host key), not here. Adding a second box means
# adding its recipient there and running `sops updatekeys secrets/*`.
{
  config,
  lib,
  ...
}: {
  sops.defaultSopsFile = ../secrets/ipfs-cluster.env;

  # Declared only where the service is enabled, so a host that does not run the
  # cluster peer does not try to decrypt a file it may not even be a recipient
  # of. On this repo's single host that is a distinction without a difference;
  # it is written this way because an unconditional declaration is precisely
  # what turns "this box does not run that" into a FAILED ACTIVATION the day a
  # second box exists.
  sops.secrets = lib.optionalAttrs config.services.ipfsClusterVolunteer.enable {
    "ipfs-cluster/env" = {
      sopsFile = ../secrets/ipfs-cluster.env;

      # dotenv: the WHOLE file is decrypted to `path`, which is exactly what
      # systemd's EnvironmentFile= expects. Its one key is CLUSTER_SECRET.
      format = "dotenv";

      # Root-owned, root-readable only. systemd reads EnvironmentFile as root
      # before dropping to the unit's user, so the `ipfs` account that runs the
      # daemon never needs read access to the plaintext, and a compromise of
      # that account does not hand over the cluster's access gate.
      mode = "0400";
      owner = "root";
      group = "root";

      # The stable path modules/ipfs-cluster-volunteer.nix defaults its
      # `secretFile` option to. Pinned here so the contract between the two
      # modules is written down rather than implied by sops-nix's naming.
      path = "/run/secrets/ipfs-cluster/env";
    };
  };
}
