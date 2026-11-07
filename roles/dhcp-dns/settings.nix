{ lib }:
let
  networks = {
    servers = {
      id = 10;
      prefix = "10.1.1";
    };
    trusted = {
      id = 20;
      prefix = "10.1.2";
    };
    guest = {
      id = 30;
      prefix = "192.168.2";
    };
    iot = {
      id = 40;
      prefix = "10.1.3";
    };
    lan = {
      id = 100;
      prefix = "10.1.0";
    };
  };
  domain = "dhcp.cbannister.casa";
  reverseZones = map (
    network:
    "${lib.concatStringsSep "." (lib.reverseList (lib.splitString "." network.prefix))}.in-addr.arpa"
  ) (builtins.attrValues networks);
in
{
  inherit networks domain reverseZones;
  zones = [ domain ] ++ reverseZones;
  primary = "10.254.254.1";
  replicas = [
    "10.254.53.0"
    "10.254.53.2"
    "10.254.53.4"
  ];
}
