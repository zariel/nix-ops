#!/usr/bin/env bash
# Exercise the deployed BIRD configuration on isolated links, without VRRP.
set -euo pipefail

work=$(mktemp -d)
router="trusted-check-$$"
core="core-check-$$"
cleanup() {
  for ns in "$router" "$core"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill || true
    ip netns del "$ns" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

ip netns add "$router"
ip netns add "$core"
ip -n "$router" link add transit type veth peer name peer
ip -n "$router" link set peer netns "$core"
ip -n "$core" link set peer name transit
for ns in "$router" "$core"; do
  ip -n "$ns" link set lo up
  ip -n "$ns" link set transit up
done
ip -n "$router" address add 10.254.0.8/31 dev transit
ip -n "$router" address add 10.254.254.2/32 dev lo
ip -n "$core" address add 10.254.0.9/31 dev transit
ip -n "$router" link add trusted type dummy
ip -n "$router" link set trusted up
ip -n "$router" address add 10.1.2.6/32 dev trusted
ip -n "$router" route add 10.1.2.0/24 dev trusted proto static src 10.1.2.6 metric 100
ip -n "$router" link add servers type dummy
ip -n "$router" link set servers up
ip -n "$router" address add 10.1.1.6/32 dev servers
ip -n "$router" route add 10.1.1.0/24 dev servers proto static src 10.1.1.6 metric 100
ip -n "$router" rule add priority 100 from 10.254.254.2/32 table 100
ip -n "$router" rule add priority 101 from 10.254.0.8/32 table 100
ip -n "$router" rule add priority 200 table main
ip -n "$router" rule add priority 300 table 100

cat > "$work/core.conf" <<'EOF'
router id 10.254.0.9;
protocol device {}
protocol static fixture {
  ipv4;
  route 192.0.2.53/32 blackhole;
  route 10.1.2.0/24 blackhole;
  route 10.1.1.0/24 blackhole;
  route 0.0.0.0/0 blackhole;
}
protocol bgp backup {
  local 10.254.0.9 as 65001;
  neighbor 10.254.0.8 as 65120;
  # Expose echoed routes to the oracle instead of hiding them by AS-loop rejection.
  allow local as 1;
  ipv4 { import all; export where source = RTS_STATIC; };
}
EOF
ip netns exec "$core" bird -c "$work/core.conf" -s "$work/core.sock" -P "$work/core.pid"
ip netns exec "$router" bird -c "${1:-/etc/bird/bird.conf}" -s "$work/router.sock" -P "$work/router.pid"

wait_for() {
  for ((attempt=0; attempt<100; attempt++)); do
    if "$@"; then return; fi
    sleep 0.1
  done
  echo "Timed out: $*" >&2
  return 1
}
established() { birdc -s "$work/core.sock" show protocols all backup | grep -q 'BGP state:.*Established'; }
advertised() { birdc -s "$work/core.sock" show route protocol backup | grep -q '10.1.2.0/24'; }
servers_advertised() { birdc -s "$work/core.sock" show route protocol backup | grep -q '10.1.1.0/24'; }
servers_withdrawn() { ! servers_advertised; }
withdrawn() { ! advertised; }
identity_advertised() { birdc -s "$work/core.sock" show route protocol backup | grep -q '10.254.254.2/32'; }
dns_installed() { ip -n "$router" route show table 100 192.0.2.53/32 | grep -q 'via 10.254.0.9'; }
routed_via_core() {
  for source in 10.254.254.2 10.254.0.8; do
    ip -n "$router" route get 10.1.2.16 from "$source" | grep -q 'via 10.254.0.9 dev transit' || return 1
  done
}
routed_via_trusted() {
  for source in 10.254.254.2 10.254.0.8; do
    ip -n "$router" route get 10.1.2.16 from "$source" | grep -q 'dev trusted' || return 1
  done
}

wait_for established
wait_for dns_installed
wait_for identity_advertised
wait_for withdrawn
test -z "$(birdc -s "$work/router.sock" show route protocol trusted_connected | grep '10.1.2.0/24' || true)"
ip -n "$router" route show 10.1.2.0/24 | grep -q 'dev trusted proto static'
wait_for routed_via_core

# Adding/removing the address here cannot affect the production broadcast domain.
ip -n "$router" address add 10.1.2.1/24 dev trusted
wait_for advertised
wait_for routed_via_trusted
ip -n "$router" address del 10.1.2.1/24 dev trusted
wait_for withdrawn
wait_for routed_via_core
ip -n "$router" route show 10.1.2.0/24 | grep -q 'dev trusted proto static'
# The servers gateway follows the same connected-only rule.
wait_for servers_withdrawn
test -z "$(birdc -s "$work/router.sock" show route protocol servers_connected | grep '10.1.1.0/24' || true)"
ip -n "$router" address add 10.1.1.1/24 dev servers
wait_for servers_advertised
ip -n "$router" address del 10.1.1.1/24 dev servers
wait_for servers_withdrawn
ip -n "$router" route show 10.1.1.0/24 | grep -q 'dev servers proto static'

identity_advertised
test -z "$(birdc -s "$work/core.sock" show route protocol backup | grep -E '10.1.2.6/32|10.1.1.6/32|0.0.0.0/0|192.0.2.53/32' || true)"
echo 'PASS: connected-only origination of the trusted and servers /24s, withdrawal, stable identity, standby ARP route, fabric route import, and no route leaks'
