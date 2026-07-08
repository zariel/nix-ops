{
  networking = {
    enable = false;
    identityAddress = null; # Stable IPv4 address, without /32.
    localASN = null;
    uplinks = [
      {
        name = "uplink0";
        macAddress = null;
        address = "10.254.1.101";
        peerAddress = "10.254.1.100";
        peerASN = 65001;
      }
      {
        name = "uplink1";
        macAddress = null;
        address = null;
        peerAddress = null;
        peerASN = 65001;
      }
    ];
    cilium = {
      enable = false;
      localASN = 65100;
      # Cilium must explicitly bind this source address when peering with BIRD.
      address = "127.0.0.2";
      podCIDR = "172.20.0.0/16";
      serviceCIDR = "10.45.0.0/24";
    };
  };

  storage = {
    enable = false;
    # Set to ./secrets.yaml after encrypting the existing hex key with SOPS.
    sopsFile = null;
  };
}
