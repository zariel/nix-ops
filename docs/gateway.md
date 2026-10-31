# Gateway migration

`nixosConfigurations.gateway` ports the running VyOS gateway inspected on
2026-10-26. The live configuration takes precedence over `../vyos-config`.
No installation or activation is performed by adding this host.

## Ownership and maintenance

- systemd-networkd owns physical links, the LACP bond, VLANs, WireGuard, WAN DHCP,
  IPv6 advertisements, and container veth addressing/routes on both sides of
  each link. Native NixOS containers use systemd-nspawn to own their private
  namespaces and veth lifetime. Networkd configures links as they appear,
  independently of application readiness.
- FRR owns BGP, PIM/IGMP/MLD and the static reject/Thread routes. Networkd is told
  to leave foreign routes, nexthops and policy rules alone. There is no OSPF in
  the live configuration, so none is enabled here.
- nftables owns filtering, NAT, MSS adjustment and the TFTP conntrack helper.
  Its dedicated `inet gateway` table is replaced atomically; other tables and
  conntrack state are not flushed.
- dnsmasq supplies DHCP and TFTP, with its DNS listener disabled. The existing
  external DNS VIP remains authoritative. Reservations are ordinary Nix entries
  in `systems/gateway/reservations.nix`, grouped by subnet: `name = [ "MAC" "IP" ];`.
  All 58 live reservations are included, including MACs used in different VLANs.
- Chrony, Avahi, node-exporter and FRR run as native systemd services. Matchbox,
  UniFi and speedtest-exporter run as native services in separate NixOS containers.
  Their application versions remain 0.11.0, 9.5.21 and 3.5.4 respectively. UniFi
  uses Java 17 and the native module's MongoDB 7; restoring an application backup
  avoids opening the old OCI MongoDB files with a different database major.
- FRR exports kernel `/32` routes in `10.5.0.0/24` through the existing ICX peer.
  Networkd installs each route when its veth comes up; container shutdown removes
  the interface/route and withdraws the BGP advertisement. Application addresses
  are defined once in `apps.nix`; adding an application in this pool needs no BGP
  network statement. A failed application
  process does not withdraw its route while the container stays running.
- Application units wait for `network-online.target`. Native systemd directory
  management owns service state/runtime/log directories, and UniFi retains its
  restored `system.properties` without a startup rewrite. Its container allows
  three minutes for Java and database initialization before startup times out.
- nftables classifies `ve-*` interfaces as the container zone, preserving packet
  policy through the routed namespaces. Containers use the DNS VIP; Podman
  networking and the shared application bridge are removed.

Dnsmasq fits these five small subnets and PXE without a Kea database/control
agent. Kea would also allow Nix reservation data (JSON can be generated), but
would add machinery without a current requirement for DHCP HA or an API.

Networkd fits a router whose physical topology changes infrequently. NetworkManager
connection profiles are an alternative when frequent interactive link changes
matter; a custom reconciler would add lifecycle and rollback behaviour to maintain.
Neither alternative eliminates a link interruption when recreating a bond or VLAN.

## What applies without rebooting

| Change | Activation behaviour |
| --- | --- |
| DHCP reservation | dnsmasq SIGHUP through a reload trigger; leases persist |
| DHCP pools/options/PXE settings | dnsmasq restart; existing client leases remain valid |
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
nix build .#checks.x86_64-linux.gateway .#checks.x86_64-linux.gateway-apps
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
- DNS interception follows the live router: IPv4 IoT/WireGuard, IPv6 IoT/trusted.
  IPv4 trusted DNS is not intercepted. The management NTP redirect now matches
  `bond0.100`, correcting the old `bond0` match.
- The zone policies retain permissive rules such as IPv6 transit-to-router and
  IoT-to-containers. This migration does not silently tighten those rules.
  Kernel warnings are forwarded to the existing TCP syslog collector through rsyslog.
  Drop counters replace VyOS's per-rule logging; inspect `nft list table inet gateway`.
- CN/RU IPv4 ranges are a fixed snapshot in `geoip-cn-ru.nft`, used only on the
  same transit/WAN paths as before. They will age; refresh deliberately from a
  trusted GeoIP source. No automatic network fetch is part of boot or activation.
- Driver defaults replace the old offload/ring-buffer/sysctl performance tuning.
  CAKE retains 950 Mbit/s upload, 890 Mbit/s download, 20 ms RTT and NAT-aware
  per-host fairness. Validate throughput and latency on the actual hardware.
- TFTP listens on internal DHCP interfaces plus transit/WireGuard, constrained by
  the firewall. BIOS clients get `undionly.kpxe`, UEFI x86 clients get `ipxe.efi`,
  and iPXE clients get `http://10.5.0.8/boot.ipxe` on the servers subnet.
- Matchbox retains `10.5.0.8` and UniFi retains `10.5.0.10`; DHCP/PXE and DNS
  references stay valid. Speedtest-exporter moves from host networking to
  `10.5.0.11:9798`. Update its monitoring scrape target; transit permits that port
  from `172.20.0.0/16`. Its exporter implementation and metric names are retained.
- For an existing NixOS Podman deployment, stop all three `podman-*` application
  units before switching. After the switch, remove the unused `gateway-apps`
  Podman network and delete `pod-containers` during maintenance. Networkd does
  not delete removed netdevs. On the ICX, verify the application `/32` routes
  replace `10.5.0.0/24`, including withdrawal/recovery when stopping/starting a
  container. Use `systemctl status container@matchbox` and
  `nixos-container run matchbox -- systemctl status matchbox` to inspect both
  lifecycle layers.

## Installation and state transfer

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

1. Back up VyOS configuration, DHCP leases, WireGuard key, TFTP files, Matchbox
   data and UniFi state. Stop UniFi for its final consistent data copy. Preserve
   ownership when copying application state. Download a UniFi application backup
   (`.unf`) before stopping the old controller. Build the complete NixOS closure
   before cutover so application startup does not depend on WAN downloads.
2. WireGuard's existing key is encrypted in `secrets/gateway.yaml`. sops-nix
   decrypts it to `/run/secrets/gateway-wireguard`, readable by `systemd-network`;
   networkd waits for decryption and reloads when the secret changes. Preserve
   the current gateway's `/etc/ssh/ssh_host_ed25519_key` on the new installation
   (root-owned, mode `0600`), since its public key is the gateway recipient in
   `.sops.yaml`. Alternatively, obtain the new host's public key, convert it with
   `ssh-to-age`, update the gateway recipient and run
   `sops updatekeys secrets/gateway.yaml` using the existing gaming identity before cutover.
   Never commit the SSH private key. Verify WireGuard's public key still matches
   the existing clients. Edit the encrypted secret with `sops secrets/gateway.yaml`.
3. Copy `/config/containers/matchbox` to `/var/lib/gateway/matchbox`.
   The native Matchbox service owns that mounted state directory. Keep the old
   UniFi directories as a rollback backup. Start UniFi with fresh state under
   `/var/lib/gateway/unifi-native`, then restore the `.unf` backup through
   `https://10.5.0.10:8443`. Do not copy the old raw MongoDB database into this
   directory. If retaining a custom certificate, copy the old `data/keystore` to
   `unifi-native/data/keystore` while the native service is stopped and make it
   readable by its `unifi` user. The old OCI certificate-import hook is absent.
   Verify device inform/adoption and persisted settings after restarting
   `container@unifi`. UniFi stays at 9.5.21; moving to UniFi OS Server is separate.
4. Copy `/config/tftpboot` to `/var/lib/tftpboot`, including `ipxe.efi` and
   `undionly.kpxe`. Files must be readable and owned by `dnsmasq` because
   `tftp-secure` is enabled. Check Matchbox's asset/profile paths and HTTP boot
   URL. The source repository does not contain these stateful assets.
5. Account for existing dynamic DHCP leases before starting a fresh DHCP server.
   Convert active leases to dnsmasq's format or temporarily reserve their
   addresses; do not blindly copy an ISC/Kea lease database into dnsmasq.
   There must be only one authoritative DHCP server during cutover.

At cutover, verify LACP members, VLAN MTUs, WAN lease/default routes, IPv6 PD,
all four BGP peers, learned DNS/service routes, DHCP renewals in each VLAN,
BIOS/UEFI/iPXE boot, WireGuard, UniFi adoption, mDNS/Thread, Roon ARC, torrent
forwarding and CAKE latency. Test guest/IoT isolation from real clients too.
The isolated VM checks cover packet policy, native application startup, namespace
isolation and BGP route installation/withdrawal through an independent peer's
kernel routing table. They cannot prove ISP negotiation, switch LACP compatibility
or migrated application data.

References: [networkctl reload](https://www.freedesktop.org/software/systemd/man/latest/networkctl.html),
[netdev lifecycle](https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html),
[dnsmasq host-file reload and PXE](https://dnsmasq.org/docs/dnsmasq-man.html),
[NixOS containers](https://nixos.org/manual/nixos/stable/#ch-containers).
