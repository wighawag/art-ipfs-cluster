# art-ipfs-cluster

A NixOS box that volunteers storage to a curated IPFS Cluster: it runs a Kubo node and an `ipfs-cluster` peer, joins the cluster the coordinator invited us to, and hosts whatever CIDs that cluster allocates to it. Declarative, reproducible, and deployable from a clone: no `docker compose up`, no hand-edited `service.json`, no secret typed into a shell.

The cluster in question is the one behind [glimmy.xyz](https://glimmy.xyz), whose volunteer instructions live at [rudyvdtas/ipfs-cluster-coordinator](https://github.com/rudyvdtas/ipfs-cluster-coordinator). This repo is the NixOS equivalent of their "Full install (Docker)" path.

## What the box is

```
pin-01 (a small cloud VM)
├── kubo            (IPFS)  swarm 4001 tcp+udp public, API 5001 loopback only
└── ipfs-cluster    (peer)  gossip 9096 tcp public, REST API 9094 loopback only
    └── follower mode: hosts what it is allocated, writes nothing
```

Three files decide everything: `hosts/pin-01/default.nix` says which cluster and how much disk, `modules/ipfs-cluster-volunteer.nix` says what a volunteer peer is, and `secrets/ipfs-cluster.env` holds the shared cluster secret, encrypted.

## The trust question, in both directions

The coordinator's trust model describes what THEY control. Worth being explicit about what WE control, because the two are separate and only one of them is our problem.

**What we assert about ourselves.** `follower_mode = true` means this peer refuses pin and unpin issued locally: we cannot touch someone else's curated pinset even by accident. `trusted_peers` names the single peer ID whose CRDT writes we accept as pinset truth, so nobody else who happens to hold the cluster secret can tell this box what to store. Both are set in this repo, enforced on the box, and asserted by `nix flake check`. They are not permissions granted to us.

**What we are trusting them with.** Disk, bandwidth, and content. The coordinator decides which CIDs exist and how many replicas each wants; this node fetches what it is allocated and serves it to the public IPFS network. The only bound is `storageMax`, which is why it is stated per host rather than left at "whatever fits". Content we have not inspected will be stored on this machine and served from its IP: that is the deal, and it is the reason to know who the coordinator is before joining.

**What the secret is.** The shared `CLUSTER_SECRET` is the cluster's libp2p private-network key. Anyone holding it can join the gossip channel. It is not a password to a service we own; treat a leak as "the cluster must rotate", not "our box is compromised".

## Requirements

A cloud VM (this was written for Hetzner Cloud, which is the shape `modules/profiles/cloud.nix` assumes), x86_64, with:

| Item | Value |
| --- | --- |
| RAM | 2 GB is enough; 4 GB is comfortable |
| Disk | `storageMax` plus about 10 GB for the OS, store, logs and a deploy |
| Ports | 4001 TCP and UDP, 9096 TCP, inbound from anywhere |

Hetzner's cloud lines, with prices verified live against both the rendered page and the price API it calls (EUR per month at NBG1, IPv4 included, as the site displays them):

| Type | Arch | vCPU | RAM | Disk | Price | `storageMax` |
| --- | --- | --- | --- | --- | --- | --- |
| [CAX11](https://www.hetzner.com/cloud/cost-optimized/) | ARM | 2 | 4 GB | 40 GB | **6.49 EUR/mo** | `25GB` (the default) |
| [CAX21](https://www.hetzner.com/cloud/cost-optimized/) | ARM | 4 | 8 GB | 80 GB | 10.99 EUR/mo | `60GB` |
| [CAX31](https://www.hetzner.com/cloud/cost-optimized/) | ARM | 8 | 16 GB | 160 GB | 21.49 EUR/mo | `140GB` |
| [CPX22](https://www.hetzner.com/cloud/regular-performance/) | x86 | 2 | 4 GB | 80 GB | 19.99 EUR/mo | `60GB` |
| [CPX32](https://www.hetzner.com/cloud/regular-performance/) | x86 | 4 | 8 GB | 160 GB | 35.99 EUR/mo | `140GB` |

Prices are as the site displays them for the visitor's country; whether that is net or gross depends on your account's VAT status, so check the console before treating a figure as final.

**This repo defaults to ARM (CAX11)**, for reasons that arrived together. On 2026-09-23 the entire x86 CX line was out of stock at every location while the CAX line was available; ARM is also about half the price for the same disk with twice the cores and RAM; and CAX11 was the only instance under a 7 EUR/month budget that was actually in stock.

Both architectures are supported. Moving to x86 is two lines: `system` in the `fleet` map in `flake.nix`, and the profile import in `hosts/pin-01/default.nix` (`cloud-arm.nix` to `cloud-x86.nix`). They differ only in what the firmware can launch: Hetzner's x86 instances boot legacy BIOS and need GRUB with a bios_grub partition, Ampere boxes are UEFI-only and use systemd-boot. `provision/birth.sh` refuses to install if the server's architecture and the flake's disagree, since that combination installs cleanly and then never boots.

**`storageMax` must fit the server you buy.** It is `25GB` in `hosts/pin-01/default.nix`, sized for a 40 GB instance. Keep it about 10 GB under the disk: the remainder is the OS, the Nix store, logs, and room for a build, which on this host happens locally rather than arriving prebuilt.

### About donating 25 GB rather than 50

The coordinator's 50 GB figure belongs to the two paths that bolt a cluster peer onto an existing node. The full-install path this repo mirrors states only "disk space: configurable via `IPFS_STORAGE_MAX`", and their FAQ says to "start with a smaller amount if you are unsure". A 25 GB replica that stays up is worth more to the cluster than a 60 GB one that was never affordable, and the replication factor is the coordinator's to raise as more volunteers arrive.

Raising it later means a bigger instance, which is a rebirth rather than a resize (disko describes a disk, it does not migrate one). That is cheap here: the identity is in the repo, so a rebirth re-keys nothing, and the cluster re-allocates whatever this peer stopped holding.

A Hetzner Volume would add disk without a bigger instance, but cannot fit this budget: the headroom to 7 EUR is about 0.50 EUR/month, which does not buy tens of gigabytes anywhere. I could not verify Hetzner's current per-GB volume price from their site, so treat that as reasoning about the headroom rather than a quoted figure.

From the coordinator you need three things, one of them private:

- the bootstrap multiaddress (public, already in `hosts/pin-01/default.nix`)
- the coordinator's peer ID (public, same file, and it is the same string as the `/p2p/` part of the bootstrap address, which is a useful cross-check)
- the shared `CLUSTER_SECRET` (private, 64 hex characters, sent to you directly)

Verify the first two with your contact over a channel you trust anyway. A wrong bootstrap address costs nothing because we simply fail to connect; a wrong trusted peer ID is the one value that can hurt, since it names who may write the pinset this box then goes and fetches.

## Setup

Everything below runs from `nix develop`, which puts colmena, nixos-anywhere, sops, ssh-to-age, hcloud and the IPFS tools on PATH. Nothing needs to be installed by hand.

```bash
nix develop
```

### 1. Put the real secret in

```bash
sops secrets/ipfs-cluster.env
```

Replace the placeholder value with the secret the coordinator sent. The file stays encrypted on disk and in git; only the values are encrypted, so a diff shows that `CLUSTER_SECRET` changed and never what it changed to.

### 2. Create and birth the box, in one command

```bash
export HCLOUD_TOKEN=<a token for your Hetzner project>   # or use an `hcloud context`
SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub \
  ./provision/birth.sh --provider hetzner --ssh-key ~/.ssh/id_ed25519
```

That creates a `cax11` at `nbg1` running stock Debian, whose cloud-init authorizes your key and does nothing else, waits for SSH, checks the box's architecture matches the flake, wipes the partition table, and hands the box to nixos-anywhere, which **kexecs it into a NixOS installer in place** (no rescue mode, no provider console, no ISO), partitions with disko and installs this config. When it finishes the box is NixOS, `root` is no longer reachable by key, and `admin` is.

The closure is **built on the target**, because pin-01 is aarch64 and your workstation almost certainly is not, with no binfmt emulation registered. That needs no flag: nixos-anywhere's default `--build-on auto` compares the two systems, checks `extra-platforms`, and test-builds a trivial derivation for the target before deciding, so registering binfmt for aarch64 later switches it to building locally with no change to this repo. `colmena` does the equivalent via `buildOnTarget`. Either way the box substitutes nearly everything from cache.nixos.org, which builds aarch64-linux for the stable channel, rather than compiling it.

Building on a 4 GB instance is not the memory problem it sounds like: nixos-anywhere targets the **mounted disk** for the system closure (`remote-store=local?root=/mnt`), not the installer's RAM-backed root. It is still the slowest step of the install, and the first thing to suspect if it seems to stall rather than fail.

The SKU, location, image, server name and a retained Primary IP are the `HCLOUD_*` environment variables documented at the top of `provision/hetzner.sh`. For a CAX21 instead:

```bash
HCLOUD_SERVER_TYPE=cax21 SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub \
  ./provision/birth.sh --provider hetzner --ssh-key ~/.ssh/id_ed25519
```

(and raise `storageMax` to `60GB` to match its 80 GB disk).

If the box already exists (created in the console, or kexec failed and you booted Hetzner's rescue system instead), skip creation and point at it:

```bash
./provision/birth.sh --ip <ip> --ssh-key ~/.ssh/id_ed25519
```

`provision/hetzner.sh` is the only file in this repo that knows Hetzner exists. Its entire contract is "create a box, print an SSH-reachable IPv4", so a second provider is a sibling script rather than an abstraction.

#### When create fails with `resource_unavailable`

Hetzner periodically runs out of shared-vCPU capacity at a location, sometimes for days, and `hcloud server create` reports it as `error during placement (resource_unavailable, <trace id>)` without saying whether the type, the location or the whole line is the problem. `provision/hetzner.sh` preflights this, so a doomed create is refused before it runs. To ask directly:

```bash
./provision/hetzner-availability.sh              # defaults: cax11 at nbg1
./provision/hetzner-availability.sh cpx32 hel1
```

It prints where the requested type *is* placeable right now and what *is* placeable at the requested location, and exits 0 only if the pair works. Then retry with whichever half you changed:

```bash
HCLOUD_LOCATION=hel1 SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub \
  ./provision/birth.sh --provider hetzner --ssh-key ~/.ssh/id_ed25519
```

The API is the only honest source for this. The marketing pages are not: on 2026-09-23 every CX, CPX and CCX type showed "currently unavailable" on hetzner.com while the price API reported the same types as active. Availability is a per-datacenter fact and a race regardless, so `HCLOUD_SKIP_AVAILABILITY_CHECK=1` bypasses the preflight if you know better.

**If you change the type, check its disk and its architecture.** `storageMax` must stay roughly 10 GB below the disk, and a CAX is ARM while a CX/CPX/CCX is x86: switching lines means switching `system` and the profile import too.

It also places pin-01's **pre-minted SSH host key** before first boot, which is the step that makes the box able to decrypt the cluster secret on its very first activation. Without it there is a circularity: the box decrypts with its own host key, which does not exist until it boots, so the install would abort on a secret it cannot read. The keypair lives in this repo already (public half at `hosts/pin-01/ssh_host_ed25519_key.pub`, private half encrypted at `secrets/pin-01/ssh-host-key`, encrypted to the operator only), the script verifies the pair before sending anything, and it shreds the decrypted copy on every exit path. Decrypting it needs the admin age key, so if that key is root-owned on your machine, run the script under `sudo`.

### 3. Converge

Set `targetHost` in `flake.nix` to the box's DNS name or IP (a name is better: a Hetzner Primary IP on auto-delete changes on rebuild), then:

```bash
colmena apply --on @cloud
```

From here on, every change to this repo reaches the box through that one command.

## Verify it joined

```bash
ssh admin@<box> 'ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094 id'
ssh admin@<box> 'ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094 peers ls'
```

`peers ls` should show at least two peers: this one and the coordinator. If `id` hangs or returns nothing, the daemon is not up: `journalctl -u ipfs-cluster -f`.

What this node is currently holding, and how the fetches are going:

```bash
ssh admin@<box> 'ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094 status'
ssh admin@<box> 'ipfs repo stat'          # how much of storageMax is used
ssh admin@<box> 'systemctl status ipfs ipfs-cluster'
```

That the peer is REACHABLE from outside is the thing most worth checking and the easiest to get wrong, because a node that can dial out looks healthy while serving nobody:

```bash
nc -vz <box> 4001          # swarm, TCP
nc -vzu <box> 4001         # swarm, QUIC
nc -vz <box> 9096          # cluster gossip
```

Some providers filter ports at the network layer, separately from the host firewall. If these fail while `networking.firewall` is correct, look at the provider's own firewall.

## Operating it

Change how much disk is donated: edit `storageMax` in `hosts/pin-01/default.nix`, then `colmena apply --on @cloud`. Lowering it below what is already stored does not delete pins; Kubo's GC drops unpinned cache first, and a genuinely over-full node needs the coordinator to reduce what it allocates here.

Rotate the cluster secret: `sops secrets/ipfs-cluster.env`, then converge. The peer restarts and rejoins.

Roll back a bad deploy: `colmena rollback`, or select an earlier generation from the boot menu.

Rebirth it (resize the disk, change location, recover from a broken box): delete the server and run `provision/birth.sh --provider hetzner` again. Nothing has to be re-keyed, because the identity lives in the repo rather than on the machine: the new box comes up with the same SSH host key, the same age recipient and the same ability to decrypt. The pinset is not lost either, since the cluster re-allocates what this peer stopped holding.

Leave the cluster: set `services.ipfsClusterVolunteer.enable = false` and converge (the units and the firewall holes go away, the data stays on disk), or delete the server. There is nothing to un-register with the coordinator: a peer that stops appearing stops being allocated to, and the cluster's replication factor covers the gap.

## Checks

`nix flake check` asserts the invariants that make this a volunteer rather than an owner:

- follower mode is on, and trusted peers is non-empty, on both the init and daemon units
- every bootstrap address carries a `/p2p/` peer id, and at least one names a trusted peer
- the public surface is exactly SSH, 4001 TCP+UDP and 9096 TCP, and specifically not the Kubo API, the gateway or the cluster REST API
- the path the service reads its secret from is the path sops writes it to
- the cluster peer drives this box's own Kubo, on loopback
- the service module adds nothing at all when it is not enabled
- the host's configuration fully evaluates

That last one is an EVALUATION, not a build, and the distinction is worth knowing: pin-01 is aarch64, so it cannot be built on an x86 workstation without emulation. Forcing the derivation does everything that catches a config mistake (assertions, option types, the whole module system) and stops short of compiling. The real build happens on the box at birth and at every converge. On an ARM machine, `nix flake check --all-systems` builds it for real.

That last one exists because the module is meant to be liftable into a bigger fleet, where most hosts will never enable it.

## Relationship to my-boxes

This repo is deliberately a standalone copy of the [my-boxes](https://github.com/wighawag/my-boxes) shape: same three verbs (birth with nixos-anywhere, converge with colmena, secrets with sops-nix), same `modules/` and `hosts/` split, trimmed of everything that fleet needs for agent sessions and desktops. It exists separately so that joining someone else's cluster can be proven end to end without touching a fleet that runs real workloads.

If it graduates, folding it in is: copy `modules/ipfs-cluster-volunteer.nix` into that repo's shared module list, copy `hosts/pin-01/` as a new host (the name avoids colliding with anything there), add the host's recipient to its `.sops.yaml`, and move the secret. The service module was written for that move: it depends on nothing in this repo except the nixpkgs modules it configures.
