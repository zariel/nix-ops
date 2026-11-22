{
  lib,
  buildGoModule,
  fetchFromGitHub,
  libpcap,
}:
buildGoModule (finalAttrs: {
  pname = "udp-proxy-2020";
  # The release in the container image VyOS runs (revision f2daf18d).
  version = "0.1.4";
  src = fetchFromGitHub {
    owner = "synfinatic";
    repo = "udp-proxy-2020";
    tag = "v${finalAttrs.version}";
    hash = "sha256-v2va1BdvqJQ87j8gj8UJqMz/rXj4kyF52gqeYWHVT2g=";
  };
  vendorHash = "sha256-lbfTXN22ZhTWRQjOQOkavJ4UUdse6THIz+hjXaI2GUY=";
  subPackages = [ "cmd/udp-proxy-2020" ];
  buildInputs = [ libpcap ];
  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${finalAttrs.version}"
    "-X main.Tag=v${finalAttrs.version}"
  ];
  meta = {
    description = "Relay UDP broadcasts between interfaces";
    homepage = "https://github.com/synfinatic/udp-proxy-2020";
    license = lib.licenses.mit;
    mainProgram = "udp-proxy-2020";
    platforms = lib.platforms.linux;
  };
})
