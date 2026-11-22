{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "netflector";
  version = "0.17.1";
  src = fetchFromGitHub {
    owner = "netflector";
    repo = "netflector";
    tag = "v${finalAttrs.version}";
    hash = "sha256-mL8q3nMUmLZa2dBWmR/n4JsAACwMYiM/kaEFhkQR6vA=";
  };
  cargoHash = "sha256-EfdT/vYPPFkp3oCuMnRGj2HlvYB8eOsYUS0Xna3b8AU=";
  # These DIAL tests inspect the host's own interface addresses, which the build
  # sandbox does not have; this gateway does not enable DIAL.
  checkFlags = [
    "--skip=reflector::dial::proxy::tests::a_rest_endpoint_on_this_host_is_not_adopted"
    "--skip=reflector::dial::rewrite::tests::rewrite_location_refuses_a_device_on_this_host"
  ];
  postInstall = ''
    install -Dm644 -t $out/share/man/man8 man/netflector.8
    install -Dm644 -t $out/share/man/man5 man/netflector.toml.5
  '';
  meta = {
    description = "Reflect link-local service discovery between interface pairs";
    homepage = "https://github.com/netflector/netflector";
    license = lib.licenses.bsd2;
    mainProgram = "netflector";
    platforms = lib.platforms.linux;
  };
})
