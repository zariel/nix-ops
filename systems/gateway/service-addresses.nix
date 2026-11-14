{ ... }:
let
  services = import ../../roles/gateway-services/settings.nix;
in
{
  systemd.network = {
    enable = true;
    # Only the per-interface readiness units gate gateway services.
    wait-online.enable = false;
    networks."10-loopback" = {
      matchConfig.Name = "lo";
      address = map (address: "${address}/32") (builtins.attrValues services.addresses);
      # The exact host block supports BGP origination and rejects unallocated IPs.
      routes = [
        {
          Destination = services.prefix;
          Type = "unreachable";
        }
      ];
    };
  };
}
