# Gateway migration

`nixosConfigurations.gateway` ports the running VyOS gateway inspected on
2026-10-26, reconciled with `../vyos-config` main `760dcac3` on 2026-11-14. The ROON
network follows `a21df908`, the BluOS reflection intent of `9af2b642`, the pod
access of `17f0c972` and, for ROON, the IPv4 ping policy of `b11e4c9b`.
Selected live addresses and firewall rules were verified over SSH on 2026-11-14.
The live configuration takes precedence when preparing cutover.
No installation or activation is performed by adding this host.

The persistent Jujutsu workspace is `/home/chris/nix-ops-gateway` (`gateway`).
Run gateway development and validation commands there; the default workspace
remains on `main`.

The NixOS replacement retains VyOS's trusted VRRP identity: permanent
`10.1.2.5/32`, floating `10.1.2.1/24`, backup peer `10.1.2.6`, VRID 20 and
priority 200 with preemption disabled. Stop VyOS before starting the NixOS
primary on the shared network; they must not run with the same node address.

## Ownership and maintenance

- systemd-networkd owns physical links, the LACP bond, VLANs, WireGuard, WAN DHCP,
  IPv6 advertisements, and the dedicated service addresses on loopback.
  Networkd configures links independently of application readiness.
- FRR owns BGP, PIM/IGMP/MLD and the static reject route. Networkd learns the Thread
  OMR route from OTBR and leaves foreign routes, nexthops and policy rules alone. There is no OSPF in
  the live configuration, so none is enabled here.
- nftables owns filtering, NAT, MSS adjustment and the TFTP conntrack helper.
  Its dedicated `inet gateway` table is replaced atomically; other tables and
  conntrack state are not flushed.
- Kea supplies DHCPv4 with persistent memfile leases. Atftpd supplies TFTP.
  Kea D2 updates lease records in the gateway's BIND primary. The three DNS VMs
  serve persistent secondary copies through the DNS VIP.
  Reservations are ordinary Nix entries
  in `systems/gateway/reservations.nix`, grouped by subnet: `name = [ "MAC" "IP" ];`.
  All 59 live reservations are included, including MACs used in different VLANs
  and `bc250-lounge`, which is absent from the VyOS repository scripts.
- Chrony, node-exporter, FRR, Matchbox 0.11.0, the mDNS reflector and the Roon
  discovery relay run as native systemd services. There are no application containers on
  this gateway. UniFi OS Server runs separately on pve2 VM 203 at `10.1.0.23`.
- The `roon-discovery` unit runs udp-proxy-2020 0.1.4, the release in VyOS's
  container image, packaged in `packages/udp-proxy-2020`. It relays UDP 9003
  broadcasts between `bond0.20` and `bond0.60` only, keeping each sender's
  source address so ROCK and Trusted clients reply to each other directly.
  It captures and re-injects frames through packet sockets, which nftables does
  not filter; the routed unicast replies follow the ROON firewall rules. The
  relay reads interface subnets once at startup, so its start script waits for
  Trusted's VRRP `10.1.2.1/24`, as on VyOS. Because preemption is disabled, a
  primary that starts while the backup owns that address waits until handback.
- Networkd owns the application's `/32` addresses on loopback and an unreachable
  summary route for `10.5.0.0/26`. FRR announces that host block through the ICX.
  Application restarts and removal of one address do not withdraw other services;
  removal of the summary route withdraws the block.
- Matchbox serves only `10.5.0.8:80`, as the unprivileged `matchbox` user.
  Its private mount namespace exposes the boot data read-only. The firewall
  allows HTTP from trusted, servers, management and IoT, and permits only
  tracked replies from the service identity. Guest and WAN requests are denied.

Kea is configured through `services.kea.dhcp4.settings`; NixOS generates its
JSON configuration and manages the service and state directory. Reservations
remain scoped to their subnet, and client classes select PXE boot files and
UniFi discovery options. No SQL database or HTTP control API is enabled.
`services.atftpd` serves the boot assets from `/var/lib/tftpboot`.
Kea waits for its six LAN interfaces through networkd's per-interface readiness
units; it does not wait for the WAN or unused ports.

## Host service addresses

The site host-service policy, kept in the infra workspace as
`docs/host-services.md`, reserves `10.5.0.0/16` for host-owned services, with one `/26` per host.
NetBox holds the gateway's reserved `10.5.0.0/26` block. The settings in
`roles/gateway-services/settings.nix` feed listeners, DHCP options, DNS records
and firewall destinations. The BGP `network` statement advertises this `/26`;
the entire `/16` is not originated. Unallocated addresses in the block hit its
unreachable route instead of following the WAN default.

| Service | Dedicated address | DNS name |
| --- | --- | --- |
| Matchbox | `10.5.0.8` | `matchbox.cbannister.casa` |
| TFTP | `10.5.0.9` | `gateway-tftp.cbannister.casa` |
| NTP | `10.5.0.10` | `gateway-ntp.cbannister.casa` |
| Node exporter | `10.5.0.11` | `gateway-metrics.cbannister.casa` |
| DHCP DNS primary | `10.5.0.53` | `gateway-dhcp-dns.cbannister.casa` |

Router identity `10.254.254.1`, the core BGP link `10.254.0.0/31`, SSH/SFTP
management access and trusted VRRP keep their existing addresses. DHCP broadcast,
mDNS and the WireGuard WAN listener retain their protocol-specific attachments.
The shared resolver VIP `10.254.253.53` stays on the independent DNS hosts.

Changes are staged across `../vyos-config`, this gateway branch and `../home-ops`.
VyOS gains compatibility listeners before clients switch; its container bridge
and BGP announcement shrink to `/26`. NixOS serves only the dedicated endpoints.
Deploy the new service DNS records before updating the metrics target, and migrate
NTP/PXE clients before cutover. The canonical policy documents ordering, rollback,
NetBox activation and the legacy `/24` hold. The service-address migration was
rolled out on VyOS on 2026-11-14, together with the three DNS VMs, Kubernetes
NTP/metrics consumers and Beefchunk's NTP client. VyOS advertises the `/26` and
retains compatibility endpoints; NetBox reflects the verified live addresses.
The native NixOS gateway, its systemd hardening and DHCP DNS primary still require
the separate OS installation and cutover described below.

## Service isolation and resource limits

`systems/gateway/hardening.nix` supplements the pinned NixOS and systemd unit
defaults. `sandbox.nix` defines the common restrictions for gateway-owned units:
no privilege escalation, read-only system files, private temporary files and
devices, blocked namespace creation, syscall filtering and native-only syscall
architecture. Network daemons cannot access host management sockets or raw SOPS
secrets. Each unit receives only its required address families and capabilities.
Systemd delivers BIND and D2 credentials separately.

| Service | Required access and exceptions | Hard memory limit |
| --- | --- | --- |
| FRR | Network administration, raw sockets and privilege dropping; writes `/run/frr` and managed persistent PIM state in `/var/lib/frr`. The pinned Zebra binary requests `CAP_SYS_ADMIN`, while mount and namespace operations remain blocked. | 1 GiB |
| Keepalived | VRRP network administration and raw sockets. The native module's PID files require writable `/run`. | 256 MiB |
| Kea DHCPv4 | IPv4 packet sockets and its managed lease/runtime directories. | 512 MiB |
| Kea D2 | No capabilities; IP traffic restricted to localhost. | 256 MiB |
| BIND | Existing upstream sandbox; IP traffic restricted to localhost and the three DNS replicas. | 1 GiB |
| TFTP | Dynamic unprivileged user, privileged-port binding, read-only boot files. Upload requests are rejected. | 128 MiB |
| Syslog forwarding | Dynamic unprivileged user; reads the journal with a persistent cursor, writes managed state/runtime directories and connects only to `10.45.0.2`. | 256 MiB |
| Matchbox | Dedicated unprivileged user; binds only IPv4 TCP 80 and reads boot assets. | 256 MiB |
| Roon discovery | Dynamic unprivileged user with raw packet access; binds only IPv4 UDP 9003 and has no IP traffic on its sockets. | 128 MiB |
| Chrony | Retains clock adjustment; no direct hardware clock devices. | 128 MiB |
| mDNS reflector | Dynamic unprivileged user with raw packet access; binds no IP port and has no IP traffic on its sockets. | 128 MiB |
| Node exporter | Existing upstream sandbox and no capabilities. Read-only timex syscalls remain available for metrics. | 512 MiB |
| D-Bus broker / NSS cache | Local IPC and identity lookup, with capability/syscall restrictions. | 256 / 128 MiB |
| SSH | Retains host filesystem access and privilege transitions for sudo and deployment. | 1 GiB |
| Nix daemon | Retains build namespaces and privilege transitions; only root and chris may submit requests. | 2 GiB |

Soft memory thresholds precede the hard limits. A process exceeding its hard
limit can be killed; restart policies recover network daemons after failures.
These limits leave headroom for the configured home network, and must be reviewed
if route counts, lease counts or enabled workloads grow substantially. Routing
services have no CPU quota. Matchbox is limited to one CPU, and Nix builds use
one job/one core with lower CPU and I/O weights.

Other boot and hardware services retain their upstream unit restrictions. The
manager defaults to 512 tasks per unit and disables core dumps; units can retain
explicit limits where their function requires them. Coredump storage and processing
are disabled, and journald storage is bounded to 256 MiB on disk and 64 MiB at
runtime. SSH, Nix, activation and secret installation remain privileged host
administration boundaries. These restrictions reduce the impact of a compromised
service; they do not isolate the host kernel from its routing daemons.

The `gateway-hardening` VM check boots the complete production service set with
test hardware and credentials. It exercises WAN DHCP, client leases, TFTP reads
and denied writes, live syslog forwarding, SSH/sudo, sandboxed Nix builds, service
recovery and asset uploads. Process identities, mount restrictions and cgroup
limits are observed through the kernel. The other gateway checks cover BGP,
VRRP, DNS replication, packet filtering, mDNS reflection, Roon discovery relaying
and feed-update failure recovery.

### Upload Matchbox assets

The `chris` account belongs to `matchbox-assets`. Upload files to the writable
host directory; the running service sees the same files through a read-only
mount at `/var/lib/matchbox`:

```sh
scp new-image.img chris@10.1.2.5:/var/lib/gateway/matchbox/assets/
curl http://10.5.0.8/assets/new-image.img
```

No service restart is needed. Keep uploaded files readable by the service, for
example mode `0644`. During the initial data import, run these commands as root so existing files can
also be replaced over SFTP:

```sh
chgrp -R matchbox-assets /var/lib/gateway/matchbox/assets
chmod -R g+rwX /var/lib/gateway/matchbox/assets
```

The service user is not a member of the upload group.

References: [systemd execution restrictions](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html),
[systemd resource controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html),
[FRR Zebra capability requirements](https://github.com/FRRouting/frr/blob/frr-10.7.1/zebra/main.c).

## DHCP DNS

The gateway is the writable primary for `dhcp.cbannister.casa` and the reverse
zones of its six DHCPv4 networks. Kea D2 submits authenticated updates over
loopback. Each DNS VM transfers these zones from `10.5.0.53` and answers
queries from its local persistent copy. DHCP advertises `10.254.253.53`;
direct access to `172.53.53.53` remains permitted during migration.
Static `cbannister.casa` and `unifi` forward zones remain managed independently
on each DNS VM.

Lease names use `<hostname>.<network>.dhcp.cbannister.casa`. Reservation names
take precedence over names supplied by those clients. Unnamed dynamic clients
receive names such as `host-10-1-2-200.trusted.dhcp.cbannister.casa`. The network
suffix keeps names separate when a device uses more than one VLAN. Kea accepts
client-supplied names, but D2 can write forward records only in the DHCP zone.
Kea updates A and PTR records on acquisition and renewal, and removes them on
release or lease reclamation.

There are no hardcoded PTR records. A reservation gets a PTR when it obtains a
lease; an offline reservation or a device configured with a static address does
not get a PTR from this mechanism. The obsolete `10.1.8.0/24` reverse zone is
removed. SLAAC and Thread addresses are outside this DHCPv4 integration.
ROON's static reverse zone is also replaced by the replicated DHCP zone. The Roon
devices keep their static `cbannister.casa` A records, such as
`rock.cbannister.casa`, while their PTRs name lease records such as
`rock.roon.dhcp.cbannister.casa`.

The primary sends zone notifications to all three DNS VMs. A gateway outage
stops changes, but existing secondary copies remain authoritative for up to
30 days without a successful refresh. Each VM can restart and use its saved
copy during that interval. A freshly installed VM needs an initial transfer
before it can answer lease queries. DHCP DNS availability does not control VIP
health or DHCP service startup.

The TSIG secret is encrypted in `secrets/gateway-ddns.yaml` for the gateway and
administrator age recipients. Sops-nix decrypts it to the root-only
`/run/secrets/gateway-ddns` before BIND and D2 start; systemd credentials deliver
it to both services. Changing the secret restarts both consumers. Only the three
DNS VM addresses can query or transfer zones from the gateway's network listener.
The update key can change A/DHCID records in the DHCP forward zone and PTR/DHCID
records in the reverse zones, but cannot change zone authority.

Preserve `/var/lib/bind` on all four machines, `/var/lib/kea` on the gateway,
and the gateway's SSH host identity used for SOPS decryption across reinstalls.
Retain the encrypted secret files and access to the administrator decryption
identity. Initial zone files are seeded only when absent; ordinary deployment
and restarts retain live data and journals.

To rotate the TSIG secret, edit `secrets/gateway-ddns.yaml` with SOPS and deploy
the gateway. Store a base64-encoded 32-byte random value under `tsig_secret`.
No DNS VM secret changes are required. The runtime-generated
`/run/named/kea-ddns.key` is recreated from the systemd credential at each BIND
start and is not a separate source of truth.

For rollout, deploy the gateway first, then each DNS VM. Existing leases populate
DNS when clients renew; they are not imported from the removed static PTR files.
Verify a leased address through each VM before relying on the VIP:

```sh
dig @10.254.53.0 -x 10.1.2.10
dig @10.254.53.2 -x 10.1.2.10
dig @10.254.53.4 -x 10.1.2.10
dig @10.254.253.53 chris-iphone.trusted.dhcp.cbannister.casa A
```

Use `journalctl -u kea-dhcp-ddns-server -u bind` on the gateway to inspect
updates, and `journalctl -u bind` on a DNS VM to inspect transfers. The
`checks.x86_64-linux.dhcp-dns` VM test covers real leases, replication, record
removal, primary recovery and a DNS VM reboot while the primary is unavailable.

Networkd fits a router whose physical topology changes infrequently. NetworkManager
connection profiles are an alternative when frequent interactive link changes
matter; a custom reconciler would add lifecycle and rollback behaviour to maintain.
Neither alternative eliminates a link interruption when recreating a bond or VLAN.

## mDNS reflection

VyOS reflects mDNS through one Avahi process whose allow-list applies to every
reflector interface, so a VLAN that joins the reflector sends and receives every
listed service. The NixOS gateway instead grants each service between specific
VLAN pairs. The `mdns-reflector` unit runs netflector 0.17.1, packaged in
`packages/netflector`, from grants in `systems/gateway/services.nix`. Each grant
names client VLANs, device VLANs and services: queries cross from clients to
devices, and the devices' answers and announcements cross back. Nothing is
reflected in the other direction. The build rejects a generated configuration
that `netflector --check-config` refuses, such as two entries that could
reflect the same packet.

| Services | Clients | Devices | Purpose |
| --- | --- | --- | --- |
| `_hap._tcp`, `_hap._udp`, `_airplay._tcp`, `_raop._tcp`, `_ipp._tcp`, `_printer._tcp`, `_companion-link._tcp` | Trusted | IoT | Apple Home hubs, iPhones and Macs on Trusted control HomeKit accessories and AirPlay receivers on IoT. IoT may open only AirPlay return connections to Trusted, so it has no use for Trusted's services. |
| `_meshcop._udp`, `_matter._tcp`, `_matterc._udp`, `_matterd._udp` | Trusted, IoT, OTBR, Matter controllers | the same VLANs | Thread border routers, Matter controllers and devices discover each other in every direction, as before. |
| `_musc._tcp` | Trusted | ROON | The BluOS app on Trusted finds the Bluesound players. Their Spotify, TIDAL, Qobuz Connect and AirPlay advertisements stay on ROON. |

netflector captures mDNS and re-emits it through packet sockets, sourced from
the gateway's own address on the egress VLAN with hop limit 255, so clients
accept the answers as on-link. Packet sockets bypass nftables, so the firewall
holds no mDNS allowances; the policy lives in the grants. The gateway's IGMP and
MLD memberships for the mDNS groups use the existing multicast membership rules.
Answers lose link-local address records, which the other VLAN could not reach.
The unit starts once the VLAN interfaces exist; netflector then follows address
changes itself, without ordering against networkd or VRRP. It runs on the primary only;
the trusted backup runs no reflector.

## Firewall maintenance

Edit `systems/gateway/firewall-policy.nix` for zones, named address/port sets,
and zone-to-zone permissions. `local` means the gateway itself. Entries such as
`ipv4.trusted.to.local` permit traffic from trusted clients to the gateway.
The policy imports `addressSet`, `portSet` and `setRef` from
`firewall-helpers.nix`. `addressSet [ "192.0.2.1" "192.0.2.2" ]` constructs an
IPv4 address set; `portSet [ 22 443 ]` constructs a port set. Both supply the
nftables type and interval flag, and return ordinary attribute sets.

Each zone-pair entry is an ordered list of rule attribute sets. The `tcp`,
`udp`, `tcpUdp` and `icmpv6` helpers set `l4proto` and preserve the other fields.
They reject an explicit `l4proto` in their argument. For example, this rule
allows SSH:

```nix
tcp {
  dport = 22;
  comment = "SSH";
}
```

Rules support `l4proto`, `saddr`, `daddr`, `sport`, `dport`, `icmpv6Type`,
`verdict` and `comment`. The verdict defaults to `accept`; use `verdict = "drop"`
for ordered exclusions. Match values can be single values or lists. Use
`setRef "k8s_nodes"` for a named set, `{ from = 30000; to = 65535; }` for a
port range, and `{ mask = "::ffff:ffff:ffff:ffff"; value = "::7c7d:c6ff:fec7:26ac"; }`
for a masked address match. Port matches require TCP or UDP. Unknown fields
and invalid port values fail evaluation.

Address matches use the entry's IPv4 or IPv6 family. Shared DHCP, DNS, NTP,
SSH, TFTP and ICMP rules are defined at the top of the policy file. Use
`comment` to describe the service or purpose.

IPv4 and IPv6 permissions are independent. Omitted zone pairs default to deny,
and unmatched traffic within a listed pair is dropped. Internal IPv6 pairs
share an ICMPv6 allowance; exceptions replace that pair's complete rule list.
WAN IPv6 permits the listed error types, with neighbor discovery allowed to
the gateway. Keep ordered drops, such as GeoIP restrictions, before broader
allowances.

`firewall.nix` generates chains only for listed policies and owns the base
rules, NAT, MSS adjustment and conntrack helper. Loopback, established/related
traffic, DHCP/RA exceptions and traffic within a zone are handled before the
zone-pair rules. The GeoIP snapshot remains separate in `geoip-cn-ru.nft`.

Validate changes with the rule rendering check and both gateway VM checks shown below. They exercise
IPv4/IPv6 isolation, service exceptions, DHCP, TFTP, NAT, native application traffic and
firewall reloads. Inspect the applied policy with `nft list table inet gateway`;
rule comments identify services and purposes.

## Inspect live gateway state

After deploying the gateway configuration, connect with your existing SSH
administrator account and use `routerctl`. The command reads live kernel and
FRR state without changing rules, connections, routes, or counters.

```sh
ssh chris@10.1.2.5
routerctl list
sudo routerctl firewall | less -S
sudo routerctl nat
sudo routerctl connections
sudo routerctl bgp
sudo routerctl bgp-neighbors 10.254.0.1
sudo routerctl bgp-prefixes
sudo routerctl bgp-route 10.254.253.53/32
sudo routerctl route 10.254.253.53
sudo routerctl igmp
sudo routerctl mld
sudo routerctl pim
sudo routerctl multicast
sudo routerctl links
sudo routerctl qos
sudo routerctl vrrp
```

The firewall report includes all nftables tables, rule handles, packet counters,
and byte counters; it omits set elements to keep large blocklists readable. Use
`sudo nft list set inet spamhaus_drop drop_v4` to inspect a blocklist's contents.
NAT reports include the prerouting and postrouting rules and both IPv4 and IPv6
translations, with original and reply tuples from conntrack.

NAT rule counters count the first packet of each new connection. They do not
measure the connection's total traffic. Connection accounting records packets
and bytes in both directions for connections created after accounting is
enabled. Existing connections retain their state and acquire accounting when
they are replaced by new connections. Replacing firewall rules resets their
counters; reading a report does not reset them.

Use the native `watch` command for repeated samples, or JSON output for scripts:

```sh
sudo watch -d -n 2 routerctl nat
sudo routerctl --json bgp
ssh chris@10.1.2.5 'sudo routerctl --json mld'
```

Each report includes its timestamp, the native commands, their output, and exit
status. Commands have a timeout and each report captures at most 2 MiB of output.
A nonzero exit status and the JSON `incomplete` flag identify errors or partial
results, including output truncation. To inspect a larger table, run the displayed
native command directly with an appropriate filter. `bgp-route` accepts an IP
address for a longest-prefix match or a CIDR prefix for an exact lookup; `route`
accepts a destination IP for the kernel's selected path and source address.

The VRRP report shows the addresses on `bond0.20` alongside keepalived's process
state. The presence of `10.1.2.1/24` indicates local ownership; a running
keepalived process can also be in BACKUP or FAULT.

## What applies without rebooting

| Change | Activation behaviour |
| --- | --- |
| DHCP reservations/pools/options/PXE settings | Kea restart; file-backed leases persist and existing client leases remain valid |
| Firewall/NAT | atomic nftables reload; existing conntrack entries persist |
| BGP policy/static routes | FRR integrated-config reload; affected peers/routes may reconverge |
| Addresses/routes/DHCP in `.network` files | networkd reload and affected-link reconfiguration |
| `.netdev` / `.link` changes | pinned NixOS may restart networkd; some changes still need explicit recreation/replug |
| Kernel/bootloader/early hardware changes | take effect at the next planned boot |

VLAN ID changes, link renames, bond changes and deleting virtual interfaces need
special care. Networkd does not delete removed netdevs, and immutable attributes
cannot be applied to an existing device. Plan these changes with console access:
move traffic if possible, remove only the affected link, then reload networkd.
Do not routinely delete/recreate the bond or run a blanket network restart.
Deploy-rs rollback restores configuration, but cannot reconstruct every previous
kernel networking state or undo a lost upstream lease.

Normal deployments after installation use the existing deploy-rs rollback flow:

```sh
nix build .#nixosConfigurations.gateway.config.system.build.toplevel
nix build .#checks.x86_64-linux.gateway-firewall .#checks.x86_64-linux.gateway .#checks.x86_64-linux.gateway-apps
nix develop -c deploy .#gateway
```

Use a trusted or management client that can reach `10.1.0.1`, and keep a console
available for topology changes. The deploy account is `chris`, as on other NixOS
hosts, not the old `vyos` account. Automatic OS upgrades are disabled. The flake
lock pins packages, but changes to shared base modules or that lock also affect
this router; review its build before deploying. A single router still requires
an outage for its initial OS replacement and eventual kernel maintenance.

## Deliberate differences and retained limitations

- VLAN 140, its DHCP subnet, AirVPN VRF and VPN firewall zone are removed as requested.
- VLAN 99 is obsolete: it had DHCP configuration but no live lease; the active
  WAN was VyOS `eth3` (now `wan0`). It is omitted rather than starting a second WAN DHCP client.
- `rescue0` is left unnumbered. The live router had `10.1.0.1/24` on both this unplugged
  NIC and VLAN 100. Management remains on VLAN 100; using a rescue NIC needs its
  own non-overlapping subnet and explicit firewall access.
- WAN IPv6 DHCP/RA and prefix assignment to `dum99` are disabled by
  `ipv6WanEnabled` in `network.nix` until Hyperoptic fixes its failing advertised
  upstream gateway. Trusted and IoT retain ULA addressing and advertisements
  for Matter, including site and Thread routes, with no IPv6 default route.
  IPv6 DNS advertisements remain disabled until the DNS VIP is reachable
  through the ICX. ISP global prefixes are not advertised to LANs. The planned
  /56 delegation settings remain provisioned; verify the lease/prefix when
  enabling WAN IPv6 because a new DHCPv6 DUID can change the ISP allocation.
- ROON (VLAN 60, `10.1.4.0/24`) is IPv4-only, as on VyOS: it has no link-local
  address or IPv6 forwarding, and every IPv6 pair involving the zone is denied.
  Its DHCP pool ends at `.239`. As on VyOS, its DNS is not intercepted; the zone
  may reach only `10.254.253.53`, not the legacy resolver address. Trusted,
  including WireGuard peers, may reach every ROON device. Pings from ROON to the
  gateway are not rate limited, unlike VyOS's 10/second limit; the rule helpers
  have no rate-limit field. Only `_musc._tcp` is reflected from ROON, to Trusted;
  unlike VyOS's shared Avahi allow-list, ROON neither receives nor emits the
  Apple, printing, Thread or Matter services, and needs no mDNS firewall rules.
- DNS interception redirects IPv4 trusted, IoT and WireGuard requests to
  `10.254.253.53`, exempting both IPv4 DNS VIPs. IPv6 DNS interception is removed.
  Trusted and IoT WAN policy blocks TCP and UDP port 853 for both families.
  The management NTP redirect matches
  `bond0.100`, correcting the old `bond0` match.
- IPv6 transit-to-router remains permissive. The obsolete container zone and
  its permissions for retired gateway applications are removed.
  Kernel warnings are forwarded to the existing TCP syslog collector through rsyslog.
  Drop counters replace VyOS's per-rule logging; inspect `nft list table inet gateway`.
- WAN router egress allows DHCP, resolver DNS, NTP, HTTPS, WireGuard and selected
  ICMP/IPv6 link-control traffic. WAN IPv4 source validation is loose to permit
  asymmetric routes. Torrent ingress requires TCP destination NAT; public Roon
  ARC access is removed. The live CN/RU transit/WAN policy remains backed by
  the fixed snapshot in `geoip-cn-ru.nft`; refresh it deliberately from a trusted source.
- mDNS reflection is granted per service and direction between VLAN pairs,
  instead of through VyOS's one Avahi allow-list across every reflector
  interface; see [mDNS reflection](#mdns-reflection). Trusted's own HomeKit,
  AirPlay, printing and companion-link advertisements no longer reach IoT.
  Legacy unicast mDNS queriers, which ask from ephemeral ports, are not served.
- Node exporter listens only on `10.5.0.11`. Routed pod access includes PDU
  and IPMI HTTPS certificate uploads, UniFi controller HTTPS at `10.1.0.23` and
  the existing Proxmox management ports.
- IPv4 PIM is passive on trusted, IoT and ROON, matching VyOS: FRR remains the IGMP
  querier without PIM neighbor discovery. There are no PIM neighbors, and the
  output policy does not permit PIM control traffic in any case.
- The pinned kernel is 6.18.63, newer than the 6.18.56 fix for
  [CVE-2026-98432](https://kernel.googlesource.com/pub/scm/linux/security/vulns/+/refs/heads/master/cve/published/2026/CVE-2026-98432.mbox).
  VyOS's temporary IPv4-options mitigation is therefore unnecessary here.
- Driver defaults replace the old offload/ring-buffer/sysctl performance tuning.
  CAKE retains 950 Mbit/s upload, 900 Mbit/s download, 20 ms RTT and NAT-aware
  per-host fairness. Validate throughput and latency on the actual hardware.
- TFTP listens through atftpd, with access constrained by the firewall.
  BIOS clients get `undionly.kpxe`, UEFI x86 clients get `ipxe.efi`,
  and iPXE clients get `http://10.5.0.8/boot.ipxe` on the servers subnet.
- Matchbox retains `10.5.0.8`, preserving DHCP/PXE references. UniFi discovery
  through DHCP and DNS points to the separate server at `10.1.0.23`.
- Before switching an existing NixOS application-container deployment, stop
  `container@matchbox` and any legacy `podman-*` application units. The native
  service uses the same host data path. Remove unused container/Podman netdevs
  during maintenance; networkd does not delete removed netdevs. Verify the exact
  `10.5.0.0/26` route on the ICX and inspect `systemctl status matchbox`.

## Installation and state transfer

Recovery access during cutover comes from the
[out-of-band network](oob-network.md), which does not depend on the gateway.

The live machine is a UEFI Intel i5-7500 with mlx4_en LAN and igb WAN NICs.
MAC-based links rename VyOS eth0/eth1 to lan0/lan1, eth3 to wan0, eth2 to spare0
and eth4 to rescue0, avoiding kernel ethN naming races.

The hardware file is an installation contract, not a copy of VyOS's disk layout.
It expects a new ext4 root labelled `nixos` and an EFI filesystem labelled `ESP`.
Check firmware mode and generate/review the hardware configuration on the target
before installing. Do not format or reuse the current VyOS persistence partition
without a separate backup and an explicit cutover plan. Keep a bootable VyOS disk
for rollback if possible.

Before the first NixOS boot:

1. Back up VyOS configuration, DHCP leases, WireGuard key, TFTP files and Matchbox
   data. Verify the UniFi migration to pve2 VM 203 and its PBS backups before
   retiring the old gateway controller. Preserve ownership when copying
   application state. Build the complete NixOS closure
   before cutover so application startup does not depend on WAN downloads.
2. WireGuard's existing key is encrypted in `secrets/gateway.yaml`. sops-nix
   decrypts it to `/run/secrets/gateway-wireguard`, readable by `systemd-network`;
   networkd waits for decryption and reloads when the secret changes. Preserve
   the current gateway's `/etc/ssh/ssh_host_ed25519_key` on the new installation
   (root-owned, mode `0600`), since its public key is the gateway recipient in
   `.sops.yaml`. Alternatively, obtain the new host's public key, convert it with
   `ssh-to-age`, update the gateway recipient and run
   `sops updatekeys secrets/gateway.yaml` and
   `sops updatekeys secrets/gateway-ddns.yaml` using the existing gaming identity before cutover.
   Never commit the SSH private key. Verify WireGuard's public key still matches
   the existing clients. Edit the encrypted secret with `sops secrets/gateway.yaml`.
3. Copy `/config/containers/matchbox` to `/var/lib/gateway/matchbox`.
   The native Matchbox service owns that mounted state directory. UniFi state
   belongs to pve2 VM 203; keep the old gateway directories as a rollback backup.
4. Copy `/config/tftpboot` to `/var/lib/tftpboot`, including `ipxe.efi` and
   `undionly.kpxe`. Files must be world-readable (for example, mode `0644`) and
   directories world-searchable (`0755`); the TFTP service runs as `nobody`.
   Ownership can remain `root:root`. Check Matchbox's asset/profile paths and
   HTTP boot URL. The source repository does not contain these stateful assets.
5. Account for existing dynamic DHCP leases before starting a fresh DHCP server.
   Import active leases into Kea's memfile format with the configured subnet
   IDs (10 servers, 20 trusted, 30 guest, 40 IoT, 60 ROON, 100 management), or temporarily
   reserve their addresses. Do not copy an ISC or dnsmasq lease file into Kea.
   Back up and retain `/var/lib/kea` across subsequent NixOS deployments.
   There must be only one authoritative DHCP server during cutover.

At cutover, verify LACP members, VLAN MTUs, WAN lease/default routes, IPv6 PD,
all four BGP peers, learned DNS/service routes, DHCP renewals in each VLAN,
BIOS/UEFI/iPXE boot, WireGuard, UniFi adoption, mDNS/Thread, Roon discovery from
Trusted clients, blocked public Roon ARC access,
torrent forwarding and CAKE latency. Test guest/IoT isolation from real clients too.
The isolated VM checks cover packet policy, native application startup, namespace
isolation and BGP route installation/withdrawal through an independent peer's
kernel routing table. They cannot prove ISP negotiation, switch LACP compatibility
or migrated application data.

## Staged UniFi OS Server

Provisioned on 2026-10-31 on `pve2` as VM **203**, named `unifi-os`: Debian 13,
2 vCPUs, 4 GiB RAM and a 50 GiB disk on `local-zfs`, with automatic boot enabled.
Systemd-networkd and systemd-resolved manage its networking. Its staging address
is reserved DHCP `10.1.0.23` (MAC `BC:24:11:B4:9C:2C`) on management VLAN 100,
and its UI is `https://unifi.cbannister.casa:11443/`. The authoritative DNS
records for `unifi.cbannister.casa.` and `unifi.` point to `10.1.0.23`, as does
the live gateway's DHCP controller discovery option on VLAN 100.
Proxmox tags the VM's `net0` on
`vmbr0`; the guest uses ordinary untagged Ethernet. Beefchunk carries VLAN 100
on LAG 3 toward pve2 (ports `1/1/39` and `1/1/41`) and LAG 4 toward the lounge
switch (ports `1/1/5` and `1/1/6`). NetBox records the uplinks and VLAN membership.
The AP at `10.1.0.22` and USW-Lite at `10.1.0.12` both respond directly from
the VM. The reservation is in `../vyos-config/config-parts/dhcp.sh` and was
applied and saved separately on the live gateway. SSH access is through `chris`
with the existing administrator SSH identity and passwordless sudo.

The official UniFi OS Server **5.1.42** bundle supplies Network **10.5.67** and
runs through the vendor's `uosserver.service`. Provisioning left it ready for
owner setup and a controller backup import. Verify device migration to this
server before retiring the legacy VyOS controller at `10.5.0.10`.

Bootstrap configuration is archived in `/var/lib/unifi-provision/bootstrap`.
Cloud-init is disabled after provisioning and its host-side snippet dependency
and bootstrap media are detached. The VM's system disk holds its runtime
configuration, so a PBS restore does not require the original Proxmox snippet.

### PBS protection

- Storage `pbs-pve2` uses server `10.1.1.32`, datastore `tank`, namespace `pve2`.
  Backup group `vm/203` is separate from `pve`'s groups in the root namespace.
- PBS identity `pve2-backup@pbs!pve2` has access only to `/datastore/tank/pve2`.
  Reading the root namespace with this identity was verified to fail. The old,
  disabled `pbs` storage entry on pve2 was left unchanged.
- Job `backup-unifi-pve2` snapshots **only VM 203** at `01/2:15`, every two hours
  on odd hours at `:15`. Both hosts use `Europe/London`; pve's existing PBS job
  runs on even hours at `:00`.
- Retention keeps the last 7, daily 14, weekly 3 and monthly 6 backups. Both
  initial snapshots passed PBS data verification. The final snapshot's extracted
  VM configuration also confirms it has no external bootstrap dependency.
  Snapshot `vm/203/2026-10-31T13:26:53Z` includes the VLAN 100 NIC tag and passed
  PBS data verification after the management-network move.
- Root-only `/var/lib/unifi-provision/legacy-recovery` contains a stopped-state
  archive of the old controller and its latest automatic `.unf` backup. These
  files are also protected by the VM's PBS backups; they are not imported into
  UniFi OS Server automatically.

### Legacy controller recovery

The VyOS controller failed on 2026-10-31 after a forced shutdown left an orphaned
Podman storage container and files in its unmounted `merged` directory. Those
files prevented Podman from replacing the container. The persistent UniFi data
was intact. Recovery preserved the state under
`/config/containers/unifi-recovery-20261031`, moved the orphaned root there,
removed only UniFi's orphaned storage record, and restarted its existing 9.5.21
image. Its status endpoint subsequently reported `up: true` with no restart loop.

The generated VyOS unit gives shutdown only five seconds. A systemd drop-in
extends Podman's shutdown grace to 90 seconds and the unit timeout to 120 seconds.
It also removes the stopped container during `ExecStop`, before systemd tears
down the cgroup containing its fuse-overlayfs helper. A graceful restart with
this ordering succeeded, and the controller's status endpoint reported healthy.
The persistent source is
`/config/systemd/vyos-container-unifi.service.d/50-shutdown-grace.conf`;
`/config/scripts/vyos-postconfig-bootup.script` installs it into `/run` after
VyOS applies its configuration. The hook's original copy is in the recovery
directory. Other gateway containers were not restarted.

After verifying migration to `10.1.0.23`, retire the old VyOS controller.
The NixOS gateway has no UniFi application. The retired controller address
`10.5.0.10` is reused by NTP; the current UniFi server is `10.1.0.23`.

References: [networkctl reload](https://www.freedesktop.org/software/systemd/man/latest/networkctl.html),
[netdev lifecycle](https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html),
[Kea DHCPv4 configuration](https://kea.readthedocs.io/en/kea-3.2.1/arm/dhcp4-srv.html).
