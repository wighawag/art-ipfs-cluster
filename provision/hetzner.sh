#!/usr/bin/env bash
#
# provision/hetzner.sh: the Hetzner provider seam.
#
# CONTRACT, which is the whole point of this file being separate:
#
#     create a fresh Linux box via the `hcloud` CLI (cloud-init drops the SSH
#     key) and print an SSH-reachable IPv4 to stdout. Nothing else.
#
# That printed IP is the input to birth: nixos-anywhere kexecs the box into a
# NixOS installer and disko repartitions the disk, so whatever image is booted
# here survives for about two minutes. Because this is the ONLY file that knows
# about Hetzner, flake.nix, modules/ and hosts/ never mention a provider, and a
# second one (a home box, another cloud) is a sibling script with the same
# contract rather than an abstraction layer.
#
# cloud-init's ONLY job here is dropping the SSH key. No packages, no services,
# no box-specific setup: all real configuration is declared in NixOS and lands
# at birth. Keep it that way.
#
# INPUTS (environment variables)
#   SSH_PUBLIC_KEY      (required) the public key cloud-init authorizes for
#                       root, so nixos-anywhere can get in. Either the key
#                       string itself or a path to a .pub file.
#   HCLOUD_SERVER_NAME  (default: pin-01) the Hetzner server name.
#   HCLOUD_SERVER_TYPE  (default: cax11) the SKU. This decides the DISK, which
#                       is the number that has to agree with `storageMax` in
#                       hosts/pin-01/default.nix. cax11 is 2 vCPU (Ampere) /
#                       4 GB / 40 GB at 6.49 EUR/mo, which is what the repo's
#                       25GB is sized for, and which was the only instance
#                       under the operator's 7 EUR/month budget that Hetzner
#                       had in stock on 2026-09-23.
#
#                       ARM IS THE DEFAULT, deliberately. That day the whole
#                       x86 CX line was out of stock at every location while the
#                       CAX line was available, and ARM is also about half the
#                       price for the same disk (CAX21 10.99 EUR/mo against
#                       CPX22's 19.99, with twice the cores and twice the RAM).
#                       The repo supports both: moving to an x86 type means
#                       switching the host's `system` in flake.nix and its
#                       profile import in hosts/pin-01/default.nix to the x86
#                       pair. Picking a type whose ARCHITECTURE disagrees with
#                       the flake produces a box that installs and then will not
#                       boot, so provision/birth.sh refuses that combination.
#   HCLOUD_IMAGE        (default: debian-12) stock image; birth replaces it.
#   HCLOUD_LOCATION     (default: nbg1) Hetzner location.
#   HCLOUD_PRIMARY_IPV4 (optional) name or id of an EXISTING Primary IP to
#                       attach instead of minting a new one. This is how a
#                       REBIRTH keeps its address: a Primary IP is its own
#                       resource that outlives the server if its auto-delete
#                       flag is cleared, so the DNS record and colmena's
#                       targetHost keep pointing at the right machine.
#   Auth: the `hcloud` CLI's own token (HCLOUD_TOKEN or an active
#   `hcloud context`), which is the provider's concern and not this seam's.
#
# OUTPUT
#   stdout: exactly the IPv4, one line. Capture with IP="$(provision/hetzner.sh)".
#   stderr: progress. Non-zero exit on any failure.
set -euo pipefail

err() { printf '%s\n' "$*" >&2; }
die() {
  err "provision/hetzner.sh: $*"
  exit 1
}

command -v hcloud >/dev/null 2>&1 ||
  die "the 'hcloud' CLI is not on PATH (run inside \`nix develop\`)."

# THE TOKEN, from sops when this runs on a my-boxes fleet box that carries one.
# An explicit HCLOUD_TOKEN or an `hcloud context` still wins, so this changes
# nothing on a machine that is not one. The credential enters exactly the
# process that needs it rather than a shell profile: it can delete every server
# in the project.
if [[ -z "${HCLOUD_TOKEN:-}" && -r /run/secrets/hetzner/env ]]; then
  set -a
  # shellcheck disable=SC1091 # runtime path, not present at lint time
  . /run/secrets/hetzner/env
  set +a
fi

: "${SSH_PUBLIC_KEY:?set SSH_PUBLIC_KEY to the public key (or .pub path) cloud-init should authorize}"

if [[ -f "$SSH_PUBLIC_KEY" ]]; then
  ssh_public_key="$(cat -- "$SSH_PUBLIC_KEY")"
else
  ssh_public_key="$SSH_PUBLIC_KEY"
fi
[[ "$ssh_public_key" == ssh-* || "$ssh_public_key" == ecdsa-* ]] ||
  die "SSH_PUBLIC_KEY does not look like a public key (expected it to start with 'ssh-' or 'ecdsa-')."

server_name="${HCLOUD_SERVER_NAME:-pin-01}"
server_type="${HCLOUD_SERVER_TYPE:-cax11}"
image="${HCLOUD_IMAGE:-debian-12}"
location="${HCLOUD_LOCATION:-nbg1}"

# --- cloud-init: the key, and nothing else -----------------------------------
#
# `chpasswd.expire: false` is not setup either: several stock images (Debian on
# Hetzner among them) ship root with an EXPIRED password, and PAM then refuses
# EVERY ssh session, including a key-authenticated non-interactive one, with
# "password change required but no TTY available". That would block
# nixos-anywhere at birth. We never use the password; this just lets the key we
# do drop open a session.
user_data_file="$(mktemp)"
trap 'rm -f "$user_data_file"' EXIT
cat >"$user_data_file" <<EOF
#cloud-config
ssh_authorized_keys:
  - ${ssh_public_key}
chpasswd:
  expire: false
EOF

err "Creating Hetzner server '${server_name}' (${server_type}, ${image}, ${location})..."

# --- Preflight: is this type placeable at this location RIGHT NOW? ----------
#
# `hcloud server create` answers an out-of-stock SKU with
#     error during placement (resource_unavailable, <trace id>)
# which does not say whether the type, the location or the whole shared line is
# the problem, and leaves you guessing at a combination. Hetzner runs out of
# shared vCPU capacity at a location periodically, so this is a normal Tuesday
# rather than an exceptional failure, and it deserves a real answer.
#
# Skippable with HCLOUD_SKIP_AVAILABILITY_CHECK=1: availability is a race no
# matter what (stock can vanish between the check and the create), so this must
# never be the thing that stops a create you know is fine.
if [[ -z "${HCLOUD_SKIP_AVAILABILITY_CHECK:-}" ]] &&
  [[ -x "$(dirname "${BASH_SOURCE[0]}")/hetzner-availability.sh" ]]; then
  if ! "$(dirname "${BASH_SOURCE[0]}")/hetzner-availability.sh" "$server_type" "$location" >&2; then
    err ""
    err "provision/hetzner.sh: '${server_type}' cannot be placed at '${location}' right now."
    err "    Pick a location from the '${server_type} available at' line above:"
    err "        HCLOUD_LOCATION=<loc> provision/birth.sh --provider hetzner"
    err "    or a type from the 'available at ${location}' line:"
    err "        HCLOUD_SERVER_TYPE=<type> provision/birth.sh --provider hetzner"
    err "    Mind the DISK of whatever you pick: it has to stay above"
    err "    storageMax + ~10GB (see hosts/pin-01/default.nix)."
    err "    Override this check with HCLOUD_SKIP_AVAILABILITY_CHECK=1."
    exit 1
  fi
fi
create_args=(
  --name "$server_name"
  --type "$server_type"
  --image "$image"
  --location "$location"
  --user-data-from-file "$user_data_file"
  --start-after-create
)

# A RETAINED ADDRESS, when one was kept. Fail EARLY and by name if it is not
# there: discovering that after the server exists means a box on the wrong
# address, which is worse than no box at all.
if [[ -n "${HCLOUD_PRIMARY_IPV4:-}" ]]; then
  hcloud primary-ip describe "$HCLOUD_PRIMARY_IPV4" >/dev/null 2>&1 ||
    die "HCLOUD_PRIMARY_IPV4='$HCLOUD_PRIMARY_IPV4' is not a Primary IP this account can see."
  create_args+=(--primary-ipv4 "$HCLOUD_PRIMARY_IPV4")
  err "Attaching the retained Primary IP '$HCLOUD_PRIMARY_IPV4'."
fi

# NO IPv6 is requested, and that is deliberate rather than an omission:
# modules/profiles/cloud.nix disables IPv6 on this class of host (Hetzner
# assigns a /64 it does not advertise, so having it means hardcoding a
# provider-assigned address into the repo). Hetzner attaches a v6 /64 anyway;
# the box simply does not configure it.

hcloud server create "${create_args[@]}" >&2 || die "hcloud server create failed."

ip="$(hcloud server ip "$server_name")" ||
  die "created the server but could not read its public IPv4 via 'hcloud server ip'."
[[ -n "$ip" ]] || die "created the server but 'hcloud server ip' returned no address."

err "Server '${server_name}' created; SSH-reachable IPv4:"
printf '%s\n' "$ip"
