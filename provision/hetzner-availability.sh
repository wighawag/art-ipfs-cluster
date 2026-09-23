#!/usr/bin/env bash
#
# provision/hetzner-availability.sh: WHERE can this server type actually be
# created right now, and what can be created HERE.
#
# WHY THIS EXISTS. `hcloud server create` answers an out-of-stock SKU with
#
#     error during placement (resource_unavailable, <trace id>)
#
# which does not say whether the type is wrong, the location is wrong, the whole
# line is sold out, or the account is limited. Hetzner periodically runs out of
# shared vCPU capacity at a given location, sometimes for days, and their
# marketing pages are a poor signal (they showed every CX, CPX and CCX type as
# "currently unavailable" on 2026-09-23, while the price API happily reported
# the same types as active). Stock is a per-DATACENTER fact and the API is the
# only honest source for it.
#
# THE API IS THE SOURCE. Each datacenter carries three lists of server-type ids:
#   supported                what the DC could ever run
#   available                what it will place RIGHT NOW   <- the only one that
#                            decides whether create succeeds
#   available_for_migration  what it will accept from elsewhere
# This script resolves a type NAME to its id, then reports every location whose
# `available` list contains it, plus what else is available at the location you
# asked for.
#
# USAGE (needs a Hetzner token, same sources as provision/hetzner.sh)
#   provision/hetzner-availability.sh              # defaults: cax11 at nbg1
#   provision/hetzner-availability.sh cx43 hel1
#   HCLOUD_SERVER_TYPE=cpx31 HCLOUD_LOCATION=fsn1 provision/hetzner-availability.sh
#
# Exit status is the machine-readable half: 0 if the requested type is available
# at the requested location, 1 otherwise. provision/hetzner.sh uses that as a
# preflight so a doomed create never runs.
set -euo pipefail

err() { printf '%s\n' "$*" >&2; }
die() {
  err "provision/hetzner-availability.sh: $*"
  exit 2
}

for tool in hcloud jq; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "$tool is not on PATH (run inside \`nix develop\`)."
done

# Same token handling as the seam: sops when on a fleet box, otherwise whatever
# the CLI already has. Sourced into THIS process only.
if [[ -z "${HCLOUD_TOKEN:-}" && -r /run/secrets/hetzner/env ]]; then
  set -a
  # shellcheck disable=SC1091 # runtime path, not present at lint time
  . /run/secrets/hetzner/env
  set +a
fi

want_type="${1:-${HCLOUD_SERVER_TYPE:-cax11}}"
want_location="${2:-${HCLOUD_LOCATION:-nbg1}}"

server_types_json="$(hcloud server-type list -o json)" ||
  die "could not list server types (is the token valid?)."
datacenters_json="$(hcloud datacenter list -o json)" ||
  die "could not list datacenters."

# The CLI has printed a bare array in every version this repo has seen, but
# accept the API's own {"datacenters": [...]} envelope too rather than failing
# obscurely if that ever changes.
datacenters_json="$(printf '%s' "$datacenters_json" |
  jq 'if type == "object" then (.datacenters // .server_types // .) else . end')"
server_types_json="$(printf '%s' "$server_types_json" |
  jq 'if type == "object" then (.server_types // .) else . end')"

type_id="$(printf '%s' "$server_types_json" |
  jq -r --arg n "$want_type" '.[] | select(.name == $n) | .id' | head -n1)"
[[ -n "$type_id" && "$type_id" != "null" ]] ||
  die "'$want_type' is not a server type this account can see. Known types: $(printf '%s' "$server_types_json" | jq -r '[.[].name] | join(" ")')"

# Locations where the type is placeable right now.
available_at="$(printf '%s' "$datacenters_json" |
  jq -r --argjson id "$type_id" '.[] | select(.server_types.available | index($id)) | .location.name' |
  sort -u | paste -sd' ' -)"

# What IS placeable at the location asked for, so the answer is not just "no".
available_here="$(printf '%s' "$datacenters_json" |
  jq -r --slurpfile st <(printf '%s' "$server_types_json") --arg loc "$want_location" \
    '[.[] | select(.location.name == $loc) | .server_types.available[]] | unique
     | map(. as $i | ($st[0][] | select(.id == $i) | .name)) | sort | join(" ")')"

printf 'requested:       %s at %s\n' "$want_type" "$want_location"
printf '%s available at:  %s\n' "$want_type" "${available_at:-(nowhere right now)}"
printf 'available at %s: %s\n' "$want_location" "${available_here:-(nothing right now)}"

if [[ " $available_at " == *" $want_location "* ]]; then
  exit 0
fi
exit 1
