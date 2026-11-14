{
  pool = "10.5.0.0/16";
  prefix = "10.5.0.0/26";
  addresses = {
    matchbox = "10.5.0.8";
    tftp = "10.5.0.9";
    ntp = "10.5.0.10";
    metrics = "10.5.0.11";
    dhcpDns = "10.5.0.53";
  };
}
