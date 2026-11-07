{
  config,
  lib,
  pkgs,
  ...
}:
let
  dns = import ./settings.nix { inherit lib; };
  directory = "/var/lib/bind";
  credential = "ddns-secret:/var/lib/gateway-ddns/secret";
  seed =
    zone:
    pkgs.writeText "${zone}.zone" ''
      $ORIGIN ${zone}.
      $TTL 300
      @ IN SOA primary.${dns.domain}. hostmaster.cbannister.casa. (
        1 300 60 2592000 60
      )
      @ IN NS dns1.cbannister.casa.
      @ IN NS dns2.cbannister.casa.
      @ IN NS dns3.cbannister.casa.
      ${lib.optionalString (zone == dns.domain) "primary IN A ${dns.primary}"}
    '';
  seeds = lib.genAttrs dns.zones seed;
  checkKey = pkgs.writeText "kea-ddns-check.key" ''
    key "kea-ddns" {
      algorithm hmac-sha256;
      secret "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  '';
in
{
  networking.resolvconf.useLocalResolver = false;
  services.bind = {
    enable = true;
    inherit directory;
    listenOn = [
      "127.0.0.1"
      dns.primary
    ];
    listenOnIpv6 = [ ];
    ipv4Only = true;
    forwarders = [ ];
    extraOptions = ''
      recursion no;
      notify-source ${dns.primary};
    '';
    extraConfig = ''include "/run/named/kea-ddns.key";'';
    zones = lib.genAttrs dns.zones (zone: {
      master = true;
      file = "${directory}/${zone}";
      slaves = dns.replicas;
      allowQuery = [ "127.0.0.1" ] ++ dns.replicas;
      extraConfig = ''
        notify explicit;
        also-notify { ${lib.concatMapStrings (ip: "${ip}; ") dns.replicas} };
        // D2 maintains ownership records in both forward and reverse zones.
        update-policy { grant kea-ddns zonesub ${if zone == dns.domain then "A DHCID" else "PTR DHCID"}; };
      '';
    });
    # Check the generated configuration against seed data and a public test key.
    preCheckConfig = ''
      substituteInPlace "$target" --replace-fail /run/named/kea-ddns.key ${checkKey}
      ${lib.concatMapStringsSep "\n" (zone: ''
        substituteInPlace "$target" --replace-fail '${directory}/${zone}' '${seeds.${zone}}'
      '') dns.zones}
    '';
  };

  systemd.services.gateway-ddns-key = {
    description = "Generate the local DHCP DNS update credential";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "gateway-ddns";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    # Only publish a complete key; subsequent boots must retain the same identity.
    script = ''
      if [ ! -s /var/lib/gateway-ddns/secret ]; then
        ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 > /var/lib/gateway-ddns/secret.tmp
        mv /var/lib/gateway-ddns/secret.tmp /var/lib/gateway-ddns/secret
      fi
    '';
  };

  systemd.services.bind = {
    requires = [ "gateway-ddns-key.service" ];
    after = [ "gateway-ddns-key.service" ];
    serviceConfig = {
      LoadCredential = [ credential ];
      UMask = "0077";
    };
    preStart = lib.mkAfter ''
      secret=$(cat "$CREDENTIALS_DIRECTORY/ddns-secret")
      printf 'key "kea-ddns" { algorithm hmac-sha256; secret "%s"; };\n' "$secret" > /run/named/kea-ddns.key
      ${lib.concatMapStringsSep "\n" (zone: ''
        # Seed once: overwriting a live zone would discard leases and its journal.
        if [ ! -e '${directory}/${zone}' ]; then
          install -m 0600 '${seeds.${zone}}' '${directory}/${zone}'
        fi
      '') dns.zones}
      ${pkgs.bind}/bin/named-checkconf ${config.services.bind.configFile}
    '';
  };

  services.kea.dhcp-ddns = {
    enable = true;
    settings = {
      ip-address = "127.0.0.1";
      port = 53001;
      tsig-keys = [
        {
          name = "kea-ddns";
          algorithm = "HMAC-SHA256";
          secret-file = "/run/credentials/kea-dhcp-ddns-server.service/ddns-secret";
        }
      ];
      forward-ddns.ddns-domains = [
        {
          name = "${dns.domain}.";
          key-name = "kea-ddns";
          dns-servers = [ { ip-address = "127.0.0.1"; } ];
        }
      ];
      reverse-ddns.ddns-domains = map (zone: {
        name = "${zone}.";
        key-name = "kea-ddns";
        dns-servers = [ { ip-address = "127.0.0.1"; } ];
      }) dns.reverseZones;
    };
  };
  systemd.services.kea-dhcp-ddns-server = {
    requires = [ "gateway-ddns-key.service" ];
    wants = [ "bind.service" ];
    after = [
      "gateway-ddns-key.service"
      "bind.service"
    ];
    serviceConfig.LoadCredential = [ credential ];
  };
  # DNS availability must not determine whether clients can obtain a lease.
  systemd.services.kea-dhcp4-server = {
    wants = [ "kea-dhcp-ddns-server.service" ];
    after = [ "kea-dhcp-ddns-server.service" ];
  };
}
