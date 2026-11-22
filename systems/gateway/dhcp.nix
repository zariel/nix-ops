{
  config,
  lib,
  ...
}:
let
  reservations = import ./reservations.nix;
  addresses = (import ../../roles/gateway-services/settings.nix).addresses;
  network = import ../../lib/network.nix;
  dns = import ../../roles/dhcp-dns/settings.nix { inherit lib; };
  subnets = dns.networks;
  interfaces = lib.mapAttrsToList (_: subnet: "bond0.${toString subnet.id}") subnets;
  networkReady = map (interface: "systemd-networkd-wait-online@${interface}.service") interfaces;
in
{
  imports = [
    ../../roles/dhcp-dns/primary.nix
    ./service-addresses.nix
  ];

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      authoritative = true;
      valid-lifetime = 28800;
      dhcp-ddns.enable-updates = true;
      ddns-override-no-update = true;
      ddns-override-client-update = true;
      ddns-replace-client-name = "when-not-present";
      ddns-generated-prefix = "host";
      # Renewals repair missed updates after an interruption or initial migration.
      ddns-update-on-renew = true;
      interfaces-config.interfaces = interfaces;
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };
      host-reservation-identifiers = [ "hw-address" ];
      # Reservations and leases are keyed by MAC within each subnet, including
      # devices that send different client IDs when booting another OS.
      match-client-id = false;
      option-data = [
        {
          name = "domain-name-servers";
          data = network.dnsVip;
        }
      ];
      option-def = [
        {
          name = "unifi-controller";
          code = 1;
          space = "vendor-encapsulated-options-space";
          type = "ipv4-address";
        }
      ];
      client-classes = [
        {
          name = "servers";
          test = "pkt.iface == 'bond0.10'";
        }
        {
          name = "ipxe";
          test = "member('servers') and (option[77].hex == 'iPXE' or option[77].hex == 0x0469505845)";
          boot-file-name = "http://${addresses.matchbox}/boot.ipxe";
        }
        {
          name = "efi";
          # Option 93 is an ordered list of 16-bit architecture identifiers.
          test = "match('^(....)*(0007|0009).*$', hexstring(option[93].hex, ''))";
        }
        {
          name = "pxe-efi";
          test = "member('servers') and not member('ipxe') and member('efi')";
          next-server = addresses.tftp;
          boot-file-name = "ipxe.efi";
        }
        {
          name = "pxe-bios";
          test = "member('servers') and not member('ipxe') and not member('efi')";
          next-server = addresses.tftp;
          boot-file-name = "undionly.kpxe";
        }
        {
          name = "unifi";
          test = "pkt.iface == 'bond0.100' and match('.*ubnt.*', option[60].hex)";
          option-data = [
            {
              name = "vendor-encapsulated-options";
              always-send = true;
            }
            {
              name = "unifi-controller";
              space = "vendor-encapsulated-options-space";
              data = "10.1.0.23";
              always-send = true;
            }
          ];
        }
      ];
      subnet4 = lib.mapAttrsToList (zone: subnet: {
        inherit (subnet) id;
        interface = "bond0.${toString subnet.id}";
        subnet = "${subnet.prefix}.0/24";
        pools = [
          { pool = "${subnet.prefix}.200 - ${subnet.prefix}.${if zone == "roon" then "239" else "254"}"; }
        ];
        valid-lifetime = if zone == "guest" then 3600 else 28800;
        ddns-qualifying-suffix = "${zone}.${dns.domain}";
        reservations = lib.mapAttrsToList (name: values: {
          hostname = name;
          hw-address = builtins.elemAt values 0;
          ip-address = builtins.elemAt values 1;
        }) reservations.${zone};
        option-data = [
          {
            name = "routers";
            data = "${subnet.prefix}.1";
          }
        ]
        ++
          lib.optional
            (builtins.elem zone [
              "servers"
              "trusted"
              "roon"
              "lan"
            ])
            {
              name = "ntp-servers";
              data = addresses.ntp;
            }
        ++
          lib.optional
            (builtins.elem zone [
              "servers"
              "trusted"
              "iot"
              "roon"
            ])
            {
              name = "domain-name";
              data = "cbannister.casa";
            };
      }) subnets;
    };
  };

  # Kea requires its subnet interfaces and addresses at startup. Wait only for
  # the LANs, so WAN availability and unplugged spare ports do not gate DHCP.
  systemd.services.kea-dhcp4-server = lib.mkIf config.systemd.network.enable {
    requires = networkReady;
    after = networkReady;
  };

  # Replies must preserve the request's destination address for the TFTP
  # conntrack helper on this router with multiple local addresses.
  services.atftpd = {
    enable = true;
    root = "/var/lib/tftpboot";
    # Use IPv4 packet metadata rather than IPv4-mapped IPv6 addresses.
    extraOptions = [ "--bind-address ${addresses.tftp}" ];
  };
  systemd.services.atftpd = {
    requires = [ "systemd-networkd-wait-online@lo.service" ];
    after = [ "systemd-networkd-wait-online@lo.service" ];
  };
  systemd.tmpfiles.rules = [ "d /var/lib/tftpboot 0755 root root -" ];
}
