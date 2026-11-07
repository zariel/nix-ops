{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  nftables,
  conntrack-tools,
  frr,
  iproute2,
  systemd,
  procps,
  coreutils,
}:
stdenvNoCC.mkDerivation {
  pname = "routerctl";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [ makeWrapper ];
  doCheck = true;
  checkPhase = ''
    ${python3}/bin/python3 test_routerctl.py
  '';
  installPhase = ''
    mkdir -p $out/bin $out/libexec/routerctl
    cp routerctl.py $out/libexec/routerctl/
    makeWrapper ${python3}/bin/python3 $out/bin/routerctl \
      --add-flags $out/libexec/routerctl/routerctl.py \
      --prefix PATH : ${
        lib.makeBinPath [
          nftables
          conntrack-tools
          frr
          iproute2
          systemd
          procps
          coreutils
        ]
      }
  '';
  meta = {
    description = "Read-only gateway firewall, NAT, routing and multicast reports";
    mainProgram = "routerctl";
    platforms = lib.platforms.linux;
  };
}
