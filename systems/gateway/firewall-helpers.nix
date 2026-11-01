let
  intervalSet = type: elements: {
    inherit type elements;
    flags = [ "interval" ];
  };
  withProtocol =
    l4proto: rule:
    if rule ? l4proto then
      throw "Firewall protocol helpers set l4proto; omit it from the rule argument."
    else
      rule // { inherit l4proto; };
in
{
  addressSet = intervalSet "ipv4_addr";
  portSet = intervalSet "inet_service";
  setRef = name: { set = name; };
  tcp = withProtocol "tcp";
  udp = withProtocol "udp";
  tcpUdp = withProtocol [
    "tcp"
    "udp"
  ];
  icmpv6 = withProtocol "ipv6-icmp";
}
