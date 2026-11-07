{ pkgs }:
let
  dns = import ../roles/dhcp-dns/settings.nix { inherit (pkgs) lib; };
  replica = index: { lib, ... }: {
    imports = [ ../roles/dnsVip ];
    services.dnsVip = {
      enable = true;
      nodeIp = builtins.elemAt dns.replicas index;
      bgpPeerIp = "10.254.254.1";
    };
    # Exercise BIND and the production query routing without external BGP peers.
    services.bird.enable = lib.mkForce false;
    services.dnsHealthcheck.enable = lib.mkForce false;
    services.blocky.settings.blocking = {
      denylists = lib.mkForce {
        ads = [ (toString (pkgs.writeText "denylist" "blocky-healthcheck.invalid\n")) ];
      };
      allowlists = lib.mkForce { };
      clientGroupsBlock.default = lib.mkForce [ "ads" ];
    };
    networking.useDHCP = false;
    networking.firewall.enable = false;
    systemd.network.networks."10-test" = {
      matchConfig.Name = "eth1";
      address = [ "${builtins.elemAt dns.replicas index}/16" ];
    };
    environment.systemPackages = [ pkgs.dnsutils ];
    virtualisation.memorySize = 512;
  };
in
pkgs.testers.runNixOSTest {
  name = "dhcp-dns";
  globalTimeout = 420;
  nodes = {
    router = { lib, ... }: {
      imports = [
        ../systems/gateway/dhcp.nix
        ../systems/gateway/firewall.nix
      ];
      networking.useDHCP = false;
      systemd.services.kea-dhcp4-server.wantedBy = lib.mkForce [ ];
      services.kea.dhcp4.settings = {
        ddns-ttl = 2;
        # Exercise renewal immediately instead of reusing a cached fresh lease.
        cache-threshold = 0.0;
      };
      environment.etc."dhcp-dns-client.py".source = ./dhcp-dns-client.py;
      environment.systemPackages = [
        pkgs.dnsutils
        pkgs.python3
        pkgs.iproute2
      ];
      virtualisation.memorySize = 768;
    };
    dns1 = replica 0;
    dns2 = replica 1;
    dns3 = replica 2;
  };
  testScript = ''
    start_all()
    replicas = [dns1, dns2, dns3]

    def network():
        router.succeed("ip link set eth1 name bond0.3001; ip link set bond0.3001 up; ip address add 10.254.254.1/16 dev bond0.3001")
        for name, vlan, prefix in [("trusted", 20, "10.1.2"), ("guest", 30, "192.168.2"), ("servers", 10, "10.1.1"), ("iot", 40, "10.1.3"), ("lan", 100, "10.1.0")]:
            router.succeed(f"ip netns add {name}; ip link add bond0.{vlan} type veth peer name peer; ip link set peer netns {name}; ip link set bond0.{vlan} up; ip address add {prefix}.1/24 dev bond0.{vlan}; ip netns exec {name} ip link set lo up; ip netns exec {name} ip link set peer up; ip netns exec {name} ip address add {prefix}.80/24 dev peer")

    def lease(zone, mac, hostname="-", action="acquire", state=None):
        state = state or zone
        return router.succeed(f"ip netns exec {zone} python /etc/dhcp-dns-client.py {action} {mac} {hostname} /tmp/{state}.json").strip()

    def answer(node, query, expected):
        node.wait_until_succeeds(f"test \"$(dig @127.0.53.10 {query} +short +time=1 +tries=1)\" = '{expected}'", timeout=40)
        node.wait_until_succeeds(f"test \"$(dig -b 127.0.0.1 @172.53.53.53 {query} +short +time=1 +tries=1)\" = '{expected}'", timeout=40)

    network()
    router.succeed("systemctl start kea-dhcp4-server")
    router.wait_for_unit("kea-dhcp4-server.service")
    router.wait_for_unit("kea-dhcp-ddns-server.service")
    router.fail("su nobody -s /bin/sh -c 'test -r /run/named/kea-ddns.key'")
    for node in replicas:
        node.wait_for_unit("dnsdist.service")
        answer(node, "gateway.cbannister.casa A", "10.254.254.1")

    # Reservation names take precedence over client input; anonymous leases get
    # names too. All five production subnets must publish forward and PTR data.
    reserved = lease("trusted", "6c:3a:ff:28:09:e1", "spoofed")
    assert reserved == "10.1.2.10", reserved
    records = [(reserved, "chris-iphone.trusted.dhcp.cbannister.casa.")]
    for zone in ["guest", "servers", "iot", "lan"]:
        address = lease(zone, "02:00:00:00:00:01", "laptop" if zone == "guest" else "-")
        label = "laptop" if zone == "guest" else "host-" + address.replace(".", "-")
        records.append((address, f"{label}.{zone}.dhcp.cbannister.casa."))

    for node in replicas:
        for address, hostname in records:
            answer(node, f"-x {address}", hostname)
            answer(node, f"{hostname} A", address)
        node.succeed("dig @127.0.53.10 -x 10.1.2.10 +norecurse | grep 'flags:.*aa'")
        node.succeed("dig @127.0.53.10 2.1.10.in-addr.arpa SOA +short | grep '2592000'")

    # Neither unsigned clients nor the update key can change zone authority.
    router.fail("printf 'server 127.0.0.1\\nzone 2.1.10.in-addr.arpa\\nupdate add 99.2.1.10.in-addr.arpa 60 PTR forged.cbannister.casa.\\nsend\\n' | nsupdate")
    router.fail("printf 'server 127.0.0.1\\nzone 2.1.10.in-addr.arpa\\nupdate add 2.1.10.in-addr.arpa 60 NS forged.cbannister.casa.\\nsend\\n' | nsupdate -k /run/named/kea-ddns.key")

    # A release removes both directions from every replica.
    guest_ip, guest_name = records[1]
    lease("guest", "02:00:00:00:00:01", "laptop", "release")
    for node in replicas:
        node.wait_until_succeeds(f"dig @127.0.53.10 -x {guest_ip} +norecurse | grep 'status: NXDOMAIN'")
        node.wait_until_succeeds(f"dig @127.0.53.10 {guest_name} A +norecurse | grep 'status: NXDOMAIN'")

    # Keep all copies and the signing identity across a primary restart.
    fingerprint = router.succeed("sha256sum /var/lib/gateway-ddns/secret")
    router.succeed("systemctl restart bind kea-dhcp-ddns-server")
    router.succeed("test \"$(dig @127.0.0.1 -x 10.1.2.10 +short)\" = chris-iphone.trusted.dhcp.cbannister.casa.")
    assert router.succeed("sha256sum /var/lib/gateway-ddns/secret") == fingerprint

    # DHCP must keep allocating while D2 is stopped; renewal repairs lost updates.
    router.succeed("systemctl stop kea-dhcp-ddns-server")
    recovered = lease("trusted", "02:00:00:00:00:02", "recovered", state="recovered")
    router.succeed("systemctl start kea-dhcp-ddns-server")
    router.wait_for_unit("kea-dhcp-ddns-server.service")
    lease("trusted", "02:00:00:00:00:02", "recovered", "renew", state="recovered")
    for node in replicas:
        answer(node, f"-x {recovered}", "recovered.trusted.dhcp.cbannister.casa.")

    # Primary and one serving VM can disappear without affecting other readers.
    router.shutdown()
    dns3.succeed("systemctl stop bind")
    for node in [dns1, dns2]:
        for address, hostname in [records[0], records[2]]:
            answer(node, f"-x {address}", hostname)
            answer(node, f"{hostname} A", address)
    dns1.shutdown()
    dns1.start()
    dns1.wait_for_unit("dnsdist.service")
    answer(dns1, "-x 10.1.2.10", "chris-iphone.trusted.dhcp.cbannister.casa.")
    answer(dns1, "gateway.cbannister.casa A", "10.254.254.1")
    dns3.succeed("systemctl start bind dnsdist")
    answer(dns3, "-x 10.1.2.10", "chris-iphone.trusted.dhcp.cbannister.casa.")

    # On recovery, renew and then release an existing lease through Kea.
    router.start()
    router.wait_for_unit("multi-user.target")
    network()
    router.succeed("systemctl start kea-dhcp4-server")
    assert router.succeed("sha256sum /var/lib/gateway-ddns/secret") == fingerprint
    lease("trusted", "6c:3a:ff:28:09:e1", "spoofed", "renew")
    lease("trusted", "6c:3a:ff:28:09:e1", "spoofed", "release")
    for node in replicas:
        node.wait_until_succeeds("dig @127.0.53.10 -x 10.1.2.10 +norecurse | grep 'status: NXDOMAIN'")
        answer(node, "gateway.cbannister.casa A", "10.254.254.1")
  '';
}
