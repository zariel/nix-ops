# Out-of-band recovery network

The OOB network exists to recover the gateway or Beefchunk when either is down.
It carries only the devices that recovery needs: PiKVM for the consoles and BIOS
of the gateway and servers, the TESmart HDMI switch through which PiKVM selects
those hosts, the PDU for power cycling, the Avocent console server for the ICX
serial consoles, and an OOB NIC on the gateway for SSH and deployment while its
bond is broken. Everything else stays off it. The pve IPMI remains on servers
VLAN 10, and management VLAN 100 becomes UniFi-only.

VLAN 254 (`10.1.254.0/24`) is a flat L2 segment on an unmanaged 8-port Netgear,
uplinked untagged to Beefchunk `1/1/13`. Beefchunk routes it through `ve254` at
`10.1.254.1`, so it does not depend on the gateway. Every device uses a static
address, because the gateway's DHCP service may be the thing that is down.

The TESmart switch belongs here because PiKVM drives it over TCP port 5000 to
choose which host it shows. On servers VLAN 10 that control path would cross
the gateway, so the gateway's own console would depend on the gateway routing.
With both on the Netgear the flow stays on the OOB segment: PiKVM reaches the
TESmart through its connected route, and neither Beefchunk's ACLs nor a
gateway firewall sees it.

There are two recovery paths. While the gateway is down, trusted clients reach
OOB through `trusted-backup`, which holds the VRRP address and forwards trusted
traffic to `10.0.0.0/8` through Beefchunk. While Beefchunk is down, connect a
laptop with the static recovery address `10.1.254.100/24` to the Netgear; it
reaches every OOB device directly, and Beefchunk at `10.1.254.1` when only its
routing is broken. Recovery should not depend on DNS either, so the addresses
are chosen to be written on each device's label and remembered.

## Addressing

`.1` to `.9` are reserved for routing devices. Beefchunk holds `.1`; adding
the second ICX7250 later would turn `.1` into a VRRP address with the two
switches on `.2` and `.3`, so no device's static gateway changes. Each
recovery device takes a round ten, ordered along the recovery chain: see the
console, select the host, cut its power, reach the switches' serial consoles.
A second unit of the same role takes the next number in its ten (a second PDU
would be `.31`). The gateway's OOB port is a host on this network and takes
`.50`; the recovery laptop takes `.100`.

| Address | Device | Label | Purpose |
| --- | --- | --- | --- |
| `10.1.254.1` | Beefchunk `ve254` | OOB router .1 | OOB gateway; SSH to the switch from the OOB segment |
| `10.1.254.10` | PiKVM | OOB .10 | Console for the gateway, MS-01s, pve2 and pbs |
| `10.1.254.20` | TESmart KVM | OOB .20, TCP 5000 | HDMI/USB switching for PiKVM |
| `10.1.254.30` | PDU (Raritan PX2-5260R) | OOB .30 | Power cycling |
| `10.1.254.40` | Avocent ACS 8016 (`console`) | OOB .40 | ICX serial consoles |
| `10.1.254.50` | Gateway `rescue0` (onboard NIC) | OOB .50 | SSH and deploy, including while Beefchunk is down; a host on this network, not a router |
| `10.1.254.100` | Recovery laptop | OOB .100 | Temporary; only while connected for recovery |

The Netgear is unmanaged and has no address. Every device uses the mask
`255.255.255.0` and the gateway `10.1.254.1`, so a label needs only the last
octet.

## Access policy

Beefchunk routes the OOB prefix to every BGP neighbour through
`redistribute connected`, and the Kubernetes nodes, DNS VMs and NAS reach it
without passing the gateway's firewall. Beefchunk's ACLs are therefore the
policy boundary for every flow into or out of OOB. Trusted and IoT clients
still cross the gateway policy first.

FastIron 09.0.10 binds ACLs to the VLAN, not to the `ve`: since 08.0.95
VE-level bindings are converted to VLAN bindings, and `interface ve 254` no
longer accepts `ip access-group`. A VLAN binding filters both switched and
routed traffic on the VLAN's ports, and one inbound and one outbound IPv4 ACL
may be bound at once. Inbound ACLs also filter traffic addressed to the switch;
outbound ACLs do not apply to traffic the switch originates. The ACLs are
stateless, so each permitted conversation needs a rule in each direction.

`OOB-OUT`, outbound on VLAN 254, decides who may reach an OOB device:

| Source | Destination | Traffic | Why |
| --- | --- | --- | --- |
| Trusted `10.1.2.0/24` | Any OOB device | All IPv4 | Operator access, including through trusted-backup |
| Pods `172.20.0.0/16` | Any OOB device | ICMP echo | blackbox-exporter reachability probes |
| Pods | PDU | TCP 443, UDP 161 | Certificate deployment, SNMP polling |
| Any | Any OOB device | ICMP unreachable, time-exceeded | Errors for flows the devices start |

`OOB-IN`, inbound on VLAN 254, decides what an OOB device may send. It admits
replies rather than new connections wherever the protocol allows it:

| Source | Destination | Traffic | Why |
| --- | --- | --- | --- |
| Any OOB device | `10.1.254.1` | All IPv4 | Ping and SSH to the switch from the OOB segment |
| Any OOB device | Trusted | TCP with ACK or RST (`established`), ICMP echo-reply and unreachable | Replies only; OOB devices cannot open TCP connections to trusted clients |
| PiKVM | Trusted | UDP from 20000-40000 | WebRTC video from Janus's RTP ports to the browser, which opens the flow from trusted; without it the web UI's H.264 stream is black |
| Any OOB device | Pods | ICMP echo-reply | Probe replies |
| PDU | Pods | TCP from 443 (`established`), UDP from 161 | Certificate deployment and SNMP replies |
| Any OOB device | `10.45.0.2` | UDP to 514 | Syslog to the cluster |

Both ACLs end with a logged deny. The FastIron guide excludes outbound ACL
logging only on other ICX models and the CLI accepts it here, and on 2026-11-22 the
outbound deny logged on the 7250 as `List Egress denied`. Logging is CPU-bound and
rate limited.

Traffic between OOB devices, such as PiKVM driving the TESmart on TCP 5000,
crosses only the Netgear and needs no rule. Trusted clients reach the
TESmart's port 5000 through the trusted rule, which is how its settings are
read and verified.

The DNS VMs, the NAS and the Kubernetes nodes themselves need no OOB access.
OOB devices get no DNS: they are configured by address, and their
`pdu.cbannister.casa`-style names exist only for clients. They take time from
Beefchunk at `10.1.254.1`, which the rule admitting all traffic to the switch
already covers, so they depend only on their own router. Beefchunk syncs from
the gateway's `10.5.0.10` and runs `ntp master` at stratum 8, so it keeps
serving its own clock while the gateway is down. That matters for PiKVM, which
has no battery-backed clock. SNMP
traps are not used, so no trap destination is permitted.

The gateway needs one rule on each implementation so trusted clients reach
`10.1.254.0/24` through the `transit` zone: VyOS `trusted-transit` and NixOS
`trusted.to.transit` permit only the routed servers, load balancers, DNS and
the Katl API today. Remote WireGuard peers (`10.0.11.0/24`) must not reach OOB.
They share the trusted zone on both gateways, so the gateway rule matches the
trusted LAN as its source as well as the OOB prefix as its destination, and
`OOB-OUT` admits only `10.1.2.0/24` too. The gateways already allow pings from
the whole trusted zone to transit, so a WireGuard peer's ping reaches Beefchunk,
where `OOB-OUT` drops it. Replies are related traffic. trusted-backup already
forwards traffic from `10.1.2.0/24` to `10.0.0.0/8` and imports every route
from the core, so it needs no change.

## Software updates

OOB devices have no internet access or DNS, and opening either would widen the
ACLs for something done a few times a year. Updates instead reach the internet
through the operator's SSH session from a trusted host: a remote dynamic
forward gives PiKVM a SOCKS proxy on its own loopback, and pacman's libcurl
uses it through the proxy variables, resolving names at the far end:

```sh
ssh -R 1080 root@pikvm 'export all_proxy=socks5h://127.0.0.1:1080 https_proxy=socks5h://127.0.0.1:1080 http_proxy=socks5h://127.0.0.1:1080; pikvm-update --no-reboot'
```

`pikvm-update` exits 100 when a reboot is needed and leaves the root
read-write until it happens. Before `reboot`, check that `kvmd -m` succeeds
and look for new `.pacnew` files under `/etc`; most of those present date from
the image. Afterwards check that the root is read-only again and that `kvmd`,
`kvmd-nginx`, `kvmd-janus` and time sync are active. Devices without a shell,
such as the PDU and the Avocent, take firmware files uploaded from a trusted
host instead.

## Syslog

Beefchunk and the OOB devices send syslog over UDP 514 to the cluster's log
receiver at `10.45.0.2`, the Vector aggregator's LoadBalancer address, where a
`network_syslog` source tags them as the `network` stream in VictoriaLogs. The
aggregator's existing syslog listener on TCP 6001 serves VyOS: its events flow
through the VyOS firewall-log parsing and are tagged `vyos`, and FastIron can
send syslog only over UDP or TLS, so the network devices get their own UDP
listener instead.

- **Beefchunk**: `logging host 10.45.0.2` (UDP 514 is FastIron's default),
  which also carries the ACL deny entries. The switch originates this traffic
  from its routed interfaces, so neither OOB ACL applies to it.
- **PDU** and **Avocent**: their syslog server settings, UDP 514, to
  `10.45.0.2`. Both document remote syslog; the exact settings are checked on
  each device when it moves.
- **PiKVM** keeps its logs in journald on a read-only root and has no syslog
  forwarder, and the TESmart has no syslog; neither sends logs.

`OOB-IN` admits UDP to `10.45.0.2` port 514 from the OOB prefix. Syslog needs
no reply, so `OOB-OUT` needs nothing for it. UDP loses messages under load,
which is acceptable for device logs that also stay in each device's own
buffer.

The Kubernetes flows (PDU certificates, PDU SNMP, ICMP probes) leave the nodes
towards the core and never reach the gateway, so the gateway rules that carried
them to VLAN 100 are removed once the PDU moves.

There is no IPv6 on the OOB VLAN: `ve254` has no IPv6 address and IPv6 is not
routed through the core.

## Gateway OOB NIC

The gateway's OOB port is the onboard Intel NIC (`50:9a:4c:4b:f6:0c`),
`rescue0` on NixOS and `eth4` (`MGMT`) on VyOS. It is on a different card from
the i350 that carries the WAN, so one card failure cannot take out both.

The gateway is WAN-facing, so its OOB NIC makes it layer-2 adjacent to a PDU
that can cut power to everything and a KVM that reaches several hosts. The NIC
is host-only: `rescue0` holds `10.1.254.50/24` in a `vrf-oob` VRF, as the Katl
nodes do with their management NICs, so its connected route and its default route
via `10.1.254.1` live in the VRF's table and never enter the main routing table.
`net.ipv4.tcp_l3mdev_accept = 1` lets the existing sshd accept connections that
arrive through the VRF, and replies leave through it. The firewall accepts only
SSH on that interface and no zone pair forwards to or from it. That protects
against misconfiguration, not compromise. A compromised gateway gains nothing
from the cable, because it already owns trusted addresses and `OOB-OUT` admits
trusted to every OOB device, so the NIC stays cabled to Netgear port 6: it is the
way into the OOB segment when Beefchunk is down. PiKVM provides the gateway's
console.

VyOS configured `eth4` with `10.1.0.1/24`, the same address as `bond0.100`.
The NIC had no carrier, so the route was dead, but cabling it to any segment
would have given VyOS a second connected route for VLAN 100's prefix on the
wrong wire, so the address was removed on 2026-11-22. VyOS gets no OOB address
and keeps `eth4` disabled although it is cabled: it is the system being
replaced, and a rollback to it uses PiKVM. The NixOS
gateway (`systems/gateway` on the `nixos-gateway` branch) configures `rescue0`
as described here.

## NetBox state

NetBox is the allocation authority. It records VLAN 254 `OOB` (id 89), prefix
`10.1.254.0/24` (id 164), the routing range `.1`–`.9` (IP range id 35), the
planned `oob-switch` (id 165) and `console` (id 166) devices, Beefchunk's
`ve254` (interface 365), and the addresses in the table above: `.1` (id 200,
on `ve254`), `.10` (202), `.20` (206), `.30` (203), `.40` (204, on
`console:eth0`), `.50` (201) and `.100` (207). Each device's existing record
stays active until the device actually moves, so NetBox keeps describing the
live network; its OOB address becomes active once it answers there.

The TESmart and PiKVM are both powered from the rear socket bar on PDU outlet
12, which also feeds an extension bar. Cycling outlet 12 therefore restarts
the console path as well as the TESmart; restart the TESmart alone by
unplugging its adapter at the bar.

## Migration

The step-by-step rollout, with the exact Beefchunk commands for operator
approval and the dependent changes in each repository, is in the infra
workspace at `docs/oob-rollout.md`. In outline:

1. **Uplink.** Cable the Netgear to `1/1/13`, put `1/1/13` in VLAN 254, bind
   `OOB-IN` and `OOB-OUT`, and allow trusted to reach the prefix on both
   gateways. A recovery laptop on the Netgear verifies routing and the ACLs
   before any device moves.
2. **PiKVM and TESmart, together.** Store the TESmart's OOB settings with the
   operator's `tesmart` tool while it is still reachable at `10.1.1.51`, then
   move both cables to the Netgear, power-cycle the TESmart, re-address PiKVM
   and point its TESmart driver at `10.1.254.20`. Free `1/1/12` and `1/1/18`
   and remove the PiKVM→TESmart gateway rule.
3. **PDU.** Give it a static OOB address and NTP server and move its cable from
   `1/1/10`. Update the certificate job, SNMP target and NetworkPolicy, and
   remove its DHCP reservation and gateway rules.
4. **Avocent.** Address it from its console port, cable it to the Netgear and
   its serial ports to the ICX consoles.
5. **Gateway NIC.** Remove `10.1.0.1/24` from VyOS `eth4`, add `vrf-oob` on
   `nixos-gateway`, with `rescue0` already cabled to the Netgear and disabled on VyOS until cutover.

Move one device at a time (PiKVM and the TESmart count as one), confirm with
the operator what is cabled to each Beefchunk port before changing it, make the
dependent changes in the same window, and mark each NetBox address and device
active once it answers on its OOB address. Mark the VLAN and prefix active once
the uplink carries traffic.

## NetBox access

The `netbox` MCP server reads and writes NetBox as its own non-superuser
account, `netbox-mcp`, so agents make NetBox changes through its tools and
NetBox's changelog attributes them to that user.
