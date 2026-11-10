{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware.nix
    ../../roles/dnsVip
  ];

  services.dnsVip = {
    enable = true;
    ipv4Addresses = [
      "172.53.53.53"
      "10.254.253.53"
    ];
    nodeIp = "10.254.53.4";
    bgpPeerIp = "10.254.53.5";
  };

  programs.nh = {
    enable = true;
    clean.enable = true;
  };
}
