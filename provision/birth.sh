#!/usr/bin/env bash
#
# provision/birth.sh: install this repo's config onto a fresh box, with the
# box's PRE-MINTED IDENTITY in place before first boot.
#
# DESTRUCTIVE. nixos-anywhere kexecs into an installer and disko ERASES the
# whole disk. Run it against a freshly created server, never against anything
# you want to keep. Everything after birth is `colmena apply`, which is not
# destructive and rolls back.
#
# WHAT IT DOES, in order:
#   1. create the box, unless --ip says one already exists. The provider seam is
#      provision/<provider>.sh, whose whole contract is "make a box, print an
#      SSH-reachable IPv4", so this script stays provider-agnostic.
#   2. decrypt secrets/<host>/ssh-host-key into a private tmpfs staging dir as
#      etc/ssh/ssh_host_ed25519_key (0600)
#   3. verify that key's public half against the COMMITTED
#      hosts/<host>/ssh_host_ed25519_key.pub, and refuse on mismatch
#   4. wait for the fresh box to answer on ssh, then zap its partition table
#   5. run nixos-anywhere with --extra-files pointing at that staging dir, which
#      kexecs the box into a NixOS installer and lets disko repartition it
#   6. shred the staging dir, on success, failure and interrupt alike
#   7. check the box answers as `admin`, which is who colmena will deploy as
#
# THE KEXEC IS NIXOS-ANYWHERE'S DOING, not something this script arranges: it
# uploads a kexec image to the running Debian, boots the NixOS installer in
# place with no provider console and no rescue mode, and installs from there.
# Hetzner's own rescue system is the fallback if kexec ever fails on a box (boot
# it from the console, then run this with --ip pointing at the rescue system):
# the install path is identical, only what is running when it starts differs.
#
# WHY STEP 1 EXISTS AT ALL. sops-nix decrypts on the box using the box's own
# ed25519 host key as an age identity. A fresh box has no host key, so it cannot
# decrypt the cluster secret, so its FIRST ACTIVATION FAILS and the install
# aborts. Placing the key before first boot removes that circularity entirely:
# see the header of /.sops.yaml and my-boxes' ADR-0008.
#
# WHY STEP 2 IS NOT CEREMONY. The age recipient in .sops.yaml is derived from
# the committed PUBLIC half. A mismatched pair produces a box that boots
# perfectly and then cannot decrypt a single secret, which is a miserable thing
# to diagnose on a machine whose disk you have just wiped.
#
# DECRYPTING NEEDS THE ADMIN AGE KEY (~/.config/sops/age/keys.txt). If that file
# is root-owned on this machine, run this script under sudo; sops says so
# clearly when it cannot find an identity.
#
# MINTING A FRESH IDENTITY (only when forking this repo, or rotating the key):
#   ssh-keygen -t ed25519 -N "" -C root@<host> -f /tmp/k
#   cp /tmp/k.pub hosts/<host>/ssh_host_ed25519_key.pub
#   ssh-to-age -i /tmp/k.pub                      # -> the .sops.yaml recipient
#   sops -e --input-type binary --output-type binary \
#        --filename-override secrets/<host>/ssh-host-key /tmp/k > secrets/<host>/ssh-host-key
#   sops updatekeys secrets/ipfs-cluster.env      # re-key to the new recipient
#   shred -u /tmp/k /tmp/k.pub
#
# USAGE
#   # create a Hetzner box and birth it, in one command:
#   SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub \
#     provision/birth.sh --provider hetzner --ssh-key ~/.ssh/id_ed25519
#
#   # or birth a box that already exists:
#   provision/birth.sh --ip <addr> --ssh-key ~/.ssh/id_ed25519
#
#   --provider <name> create the box by running provision/<name>.sh first
#                     (default: hetzner). That script's own env vars apply:
#                     SSH_PUBLIC_KEY is required, HCLOUD_* are optional (server
#                     name, type, image, location, retained Primary IP).
#   --ip <addr>       skip creation and birth an EXISTING ssh-reachable box.
#   --host <name>     flake host to install (default: pin-01). hosts/<name>/
#                     must exist.
#   --ssh-key <path>  identity to authenticate WITH, for both this script and
#                     nixos-anywhere. Without it, ssh uses whatever default
#                     identities the invoking user has, which under sudo means
#                     ROOT's keys rather than yours.
#   --disk <dev>      whole-disk device to zap first (default: /dev/sda).
#   --no-zap          skip the zap. Default is to zap: disko wipes anyway, but a
#                     pre-existing GPT can confuse it.
#   --no-host-key     birth WITHOUT placing the pre-minted key. The box then
#                     cannot decrypt the cluster secret and its activation
#                     fails; only useful for debugging.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

err() { printf '%s\n' "$*" >&2; }
die() {
  err "provision/birth.sh: $*"
  exit 1
}

host="pin-01"
provider="hetzner"
ip=""
ssh_key=""
disk="/dev/sda"
zap="yes"
place_host_key="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:?--host needs a value}"; shift 2 ;;
    --provider) provider="${2:?--provider needs a value}"; shift 2 ;;
    --ip) ip="${2:?--ip needs a value}"; shift 2 ;;
    --ssh-key) ssh_key="${2:?--ssh-key needs a value}"; shift 2 ;;
    --disk) disk="${2:?--disk needs a value}"; shift 2 ;;
    --no-zap) zap="no"; shift ;;
    --no-host-key) place_host_key="no"; shift ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -d "$repo_root/hosts/$host" ]] || die "no hosts/$host/ in this repo"

for tool in nixos-anywhere sops ssh ssh-keygen shred; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "$tool not on PATH. Run this from \`nix develop\`, which provides the whole toolchain."
done

ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null)
[[ -n "$ssh_key" ]] && ssh_opts+=(-i "$ssh_key")

# --- Create the box, unless one was named -----------------------------------
#
# The seam is a SEPARATE SCRIPT and its contract is one line of stdout, so this
# file contains no provider knowledge at all: no hcloud, no API, no SKU. That is
# what keeps "which cloud" out of the birth logic and out of the flake.
if [[ -z "$ip" ]]; then
  seam="$repo_root/provision/$provider.sh"
  [[ -x "$seam" ]] || die "no executable provision/$provider.sh (pass --ip to birth an existing box)"
  err "creating a box with provision/$provider.sh"

  # HCLOUD_SERVER_NAME defaults to the flake host name, so `--host pin-01`
  # produces a server called pin-01 rather than a second name to keep straight.
  # An explicit value still wins.
  ip="$(HCLOUD_SERVER_NAME="${HCLOUD_SERVER_NAME:-$host}" "$seam")" ||
    die "provision/$provider.sh failed; no box was birthed."
  [[ -n "$ip" ]] || die "provision/$provider.sh printed no address."
  err "provider says the box is at $ip"
fi

# --- Wait for ssh -------------------------------------------------------------
#
# A just-created cloud box answers ping before it answers sshd, and cloud-init
# has to run before the key we asked for is authorized. Without this wait the
# next step fails on a box that was about to be perfectly fine.
err "waiting for ssh on $ip"
for attempt in $(seq 1 60); do
  if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 -o BatchMode=yes "root@$ip" true 2>/dev/null; then
    err "ssh is up (after ${attempt} attempts)"
    break
  fi
  [[ $attempt -eq 60 ]] && die "no ssh on $ip after 5 minutes. The box exists; re-run with --ip $ip once it answers."
  sleep 5
done

# --- Stage the pre-minted identity on tmpfs ---------------------------------
#
# /run/user/<uid> (or /dev/shm under sudo) is memory-backed, so the plaintext
# private key never touches a disk. The trap shreds it on every exit path,
# including Ctrl-C mid-install.
stage=""
cleanup() {
  [[ -n "$stage" && -d "$stage" ]] || return 0
  find "$stage" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT INT TERM

extra_files_args=()
if [[ "$place_host_key" == "yes" ]]; then
  enc_key="$repo_root/secrets/$host/ssh-host-key"
  pub_key="$repo_root/hosts/$host/ssh_host_ed25519_key.pub"
  [[ -f "$enc_key" ]] || die "no $enc_key — mint one (see this script's header) or pass --no-host-key"
  [[ -f "$pub_key" ]] || die "no $pub_key — the committed public half is what the identity is verified against"

  tmpbase="${XDG_RUNTIME_DIR:-/dev/shm}"
  stage="$(mktemp -d "$tmpbase/birth-$host.XXXXXX")"
  chmod 700 "$stage"
  mkdir -p "$stage/etc/ssh"

  sops -d --input-type binary --output-type binary "$enc_key" > "$stage/etc/ssh/ssh_host_ed25519_key" ||
    die "could not decrypt $enc_key. This needs the ADMIN age key (~/.config/sops/age/keys.txt); if it is root-owned, re-run under sudo."
  chmod 600 "$stage/etc/ssh/ssh_host_ed25519_key"
  cp "$pub_key" "$stage/etc/ssh/ssh_host_ed25519_key.pub"
  chmod 644 "$stage/etc/ssh/ssh_host_ed25519_key.pub"

  # The verification that stops a silently undecryptable box (see the header).
  derived="$(ssh-keygen -y -f "$stage/etc/ssh/ssh_host_ed25519_key" | awk '{print $1" "$2}')"
  committed="$(awk '{print $1" "$2}' "$pub_key")"
  [[ "$derived" == "$committed" ]] ||
    die "the decrypted private key does not match $pub_key. Refusing: this box would boot fine and decrypt nothing."

  extra_files_args=(--extra-files "$stage")
  err "identity: staged and verified against hosts/$host/ssh_host_ed25519_key.pub"
else
  err "identity: NOT placing a host key (--no-host-key). Activation will fail to decrypt the cluster secret."
fi

# --- Zap, then birth ---------------------------------------------------------
#
# Belt and braces: disko wipes the disk anyway, but a pre-existing GPT can
# confuse it, and the stock image arrives with one.
if [[ "$zap" == "yes" ]]; then
  err "zapping $disk on $ip"
  ssh "${ssh_opts[@]}" "root@$ip" "command -v sgdisk >/dev/null 2>&1 && sgdisk --zap-all $disk || true"
fi

# --- Architecture ------------------------------------------------------------
#
# THE BUILD LOCATION IS NOT SET HERE, deliberately. nixos-anywhere's default
# (`--build-on auto`) already resolves it better than this script could: it
# compares the local system to the flake's, checks `extra-platforms`, and then
# TEST-BUILDS a trivial derivation for the target system to find out whether
# binfmt emulation actually works, falling back to building on the target only
# if it does not. Passing `--build-on-remote` would both override that and use a
# flag upstream has deprecated.
#
# What that means in practice here: pin-01 is aarch64 and this script normally
# runs on an x86_64 machine with no binfmt registered, so the closure is built
# ON THE BOX. That is not a RAM problem even on a 4 GB instance, because
# nixos-anywhere targets the MOUNTED DISK for the system closure
# (`remote-store=local?root=/mnt`), not the installer's RAM-backed root. It is
# mostly substitution from cache.nixos.org, which builds aarch64-linux for the
# stable channel.
#
# Register binfmt for aarch64 on the machine you deploy from and `auto` will
# switch to building locally with no change here.
host_system="$(nix eval --raw "$repo_root#nixosConfigurations.$host.config.nixpkgs.system" 2>/dev/null || true)"
local_system="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || true)"
if [[ -n "$host_system" && -n "$local_system" && "$host_system" != "$local_system" ]]; then
  err "target is $host_system, this machine is $local_system: nixos-anywhere will decide where to build"
fi

# --- The mismatch that produces a box which installs and never boots --------
#
# A CAX is aarch64 and a CX/CPX/CCX is x86_64. If the flake says one and the
# server is the other, nixos-anywhere will happily install a closure the
# firmware cannot execute -- it checks where it can BUILD, never whether the
# target can RUN the result -- and the failure appears as a box that completes
# installation and then never comes back. Refuse instead, while it is still
# cheap: the fix is either a different HCLOUD_SERVER_TYPE or the two-line switch
# of the host's `system` and profile import.
if [[ -n "$host_system" ]]; then
  target_arch="$(ssh "${ssh_opts[@]}" -o ConnectTimeout=10 "root@$ip" 'uname -m' 2>/dev/null || true)"
  case "$target_arch:$host_system" in
    aarch64:aarch64-linux | x86_64:x86_64-linux) : ;;
    :*) err "warning: could not read the box's architecture; proceeding" ;;
    *)
      die "architecture mismatch: the box reports '$target_arch' but .#$host is built for '$host_system'. Installing would produce a machine that never boots. Create the right server type, or switch the host's \`system\` in flake.nix and its profile import in hosts/$host/default.nix."
      ;;
  esac
fi

err "installing .#$host onto $ip (this erases $disk)"
nixos-anywhere \
  --flake "$repo_root#$host" \
  "${extra_files_args[@]}" \
  ${ssh_key:+-i "$ssh_key"} \
  "root@$ip"

# --- Verify what the NEXT step depends on ------------------------------------
#
# As `admin`, not root: after birth, root is key-less by design
# (modules/common.nix), so a root check would always fail on a perfectly good
# box. `admin` is who colmena connects as, so this proves the exact property the
# first converge needs.
# --- Verify what the NEXT step depends on ------------------------------------
#
# As `admin`, not root: after birth, root is key-less by design
# (modules/common.nix), so a root check would always fail on a perfectly good
# box. `admin` is who colmena connects as, so this proves the exact property the
# first converge needs.
#
# WITH A RETRY LOOP, because the single attempt this used to make was a FALSE
# NEGATIVE GENERATOR. nixos-anywhere prints "Done!" when it has seen the machine
# go down for reboot, not when the machine is back: the box still has to POST,
# run its bootloader, boot a kernel, and start sshd, which on a small ARM
# instance is comfortably longer than one ten-second connect timeout. The first
# real birth from this repo reported "the box did not answer as admin" on a box
# that was merely still booting. A check that cries wolf on a good box is worse
# than no check, because the next person learns to ignore it.
#
# my-boxes hit the same shape from the other direction (verifying as the wrong
# USER) and its birth.sh carries a comment about it; this is the timing half of
# the same lesson.
err "waiting for the box to finish booting, then verifying it answers as admin"
admin_ok="no"
for attempt in $(seq 1 40); do
  if ssh "${ssh_opts[@]}" -o ConnectTimeout=10 -o BatchMode=yes "admin@$ip" \
    'echo "$(hostname): $(readlink -f /run/current-system)"' 2>/dev/null; then
    admin_ok="yes"
    err "answered after ${attempt} attempt(s)"
    break
  fi
  sleep 5
done

if [[ "$admin_ok" == "yes" ]]; then
  err ""
  err "birth complete: $host is at $ip."
  err ""
  # THE HOST KEY CHANGED UNDER THIS ADDRESS, and saying so here saves a scare.
  # The kexec installer generated its own throwaway key, nixos-anywhere's ssh
  # wrote it into this user's known_hosts, and the booted system now presents
  # the PRE-MINTED key from secrets/$host/ssh-host-key instead. A normal ssh to
  # this address will therefore report REMOTE HOST IDENTIFICATION HAS CHANGED,
  # which is correct and expected exactly once.
  err "    NOTE: this address's host key changed at reboot (installer -> the"
  err "    repo's pre-minted key). Clear the stale entry before your first"
  err "    ordinary ssh, or it will look like an attack:"
  err "        ssh-keygen -R $ip"
  err ""
  err "Next: point targetHost at it in flake.nix, then \`colmena apply --on @cloud\`."
else
  err ""
  err "provision/birth.sh: no answer as admin at $ip after ~3 minutes."
  err "    The disk is already written, so nothing here is destructive to retry."
  err "    Check, in this order:"
  err "      ssh admin@$ip                     # it may simply have been slow"
  err "      hcloud server describe $host      # is it running?"
  err "      hcloud server request-console $host   # VNC: watch it boot"
  err "    A box that pings but never opens 22 is usually a boot failure;"
  err "    the console is the only place that says so."
  exit 1
fi
