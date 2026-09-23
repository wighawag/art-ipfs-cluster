# modules/common.nix
#
# The host-agnostic baseline every box in this repo gets: ssh key-only login, a
# default-deny firewall, the admin account colmena deploys as, flakes on, and
# the sops base. It enables NO service by itself; a host opts into the cluster
# peer in its own hosts/<name>/default.nix.
#
# This is a DELIBERATE TRIM of my-boxes' modules/common.nix, not a fresh
# invention: same shape, same reasoning, minus everything that only makes sense
# for a fleet that also runs agent sessions and a desktop. What was dropped and
# why is worth knowing if this repo is ever folded back into that one:
#
#   - the sudo-needs-a-password rule: there its whole point is that a human
#     account runs AGENT SESSIONS, so ambient root was reachable by a prompt
#     injection. There is no human account here at all.
#   - knownHosts pinning: that pins a box which is deleted and reborn every
#     trip. This box is born once.
{lib, ...}: {
  imports = [./secrets.nix];

  # --- Nix settings ---
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Trust wheel so `colmena apply` can push a closure built on the operator's
  # machine. Without it the box's Nix daemon rejects the pushed paths as
  # "lacks a signature by a trusted key", because they were built here rather
  # than fetched from a signed cache.
  nix.settings.trusted-users = ["root" "@wheel"];

  # --- The deploy account ---
  #
  # Key-only, in wheel, passwordless sudo. `admin` is not a human: colmena
  # connects as this user over a non-interactive ssh channel with no tty, and
  # escalates with `sudo -H --`, so a password prompt here would break every
  # deploy. The privilege is attached to an identity that can only arrive with a
  # key, which is the property that makes that acceptable.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keys = [
      # The OPERATOR, from a machine they are sitting at. Public half, safe to
      # commit; this is the same key my-boxes authorises, so any machine that
      # can deploy that fleet can deploy this box.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBMqcRVV1OY5dtOSuPIrEJG/N0sltiZ2Q4Xj0mG2f1Wf wighawag@gmail.com"

      # TELEMAQUE'S DEPLOY KEY, and this one is not optional in practice.
      #
      # Birth and converge are almost certainly run FROM telemaque and AS ROOT,
      # because that is where the two credentials they need live: the Hetzner
      # token (/run/secrets/hetzner/env, 0400 root) and the admin age key that
      # decrypts this repo's secrets. Root on telemaque holds the fleet deploy
      # key at /root/.ssh/id_ed25519, and nothing else. Without this line the
      # box would be born fine and then refuse every deploy from the only
      # machine positioned to make one, with birth.sh's own admin check as the
      # first thing to fail.
      #
      # It is DELIBERATELY NOT telemaque's session key. That one lives at
      # ~wighawag/.ssh/id_ed25519 and agent sessions run as wighawag, so
      # authorising it would mean any session (or any prompt injection inside
      # one) could deploy arbitrary config as root to this box. The deploy key
      # is 0400 root:root and sudo costs a password a session does not have,
      # which is the same boundary my-boxes draws for the same reason.
      #
      # Public half also committed in my-boxes at
      # secrets/telemaque/deploy-ssh-key.pub, beside its encrypted private
      # half. Rotate one, rotate both, and converge this box before the old key
      # stops working.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPat/VOsLav1TJApW0OjawPtiNqdI3leXdVtji+qHvxY telemaque-deploy"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # --- SSH: key-only, no passwords ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Birth (nixos-anywhere) runs as root over SSH; keep key-only root for it.
      # After birth nothing authorises a key for root, so root is birth-only.
      PermitRootLogin = "prohibit-password";
    };
  };

  # --- Firewall: on, default-deny inbound, ssh open. ---
  # The cluster peer opens its own two ports in its own module, so the public
  # surface of this box is readable in exactly two files.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22];
  };

  # --- Unattended security updates of the OS are NOT enabled here ---
  #
  # Worth stating rather than leaving as an absence: this box is converged from
  # the repo (`nix run .#converge`), so it updates when the flake lock moves and
  # someone deploys, not on a timer. A volunteer box that nobody looks at for
  # six months is running six-month-old packages. The counter-measure is to
  # deploy, and the reminder is this comment.

  # Matches the pinned nixpkgs release. mkDefault so a host can state its own.
  system.stateVersion = lib.mkDefault "26.05";
}
