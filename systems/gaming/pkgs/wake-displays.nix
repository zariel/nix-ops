{
  writeShellApplication,
  libdrm,
  niri,
  systemd,
  gnused,
}:
writeShellApplication {
  name = "wake-displays";
  runtimeInputs = [
    libdrm
    niri
    systemd
    gnused
  ];
  text = ''
    case "''${1-}" in
      --if-disconnected)
        # Reading connector status does not wake the GPU. Ordinary mouse and
        # keyboard activity should only probe when all displays are missing.
        for status in /sys/bus/pci/devices/0000:03:00.0/drm/card*/card*-*/status; do
          if [[ -r "$status" && $(< "$status") == connected ]]; then
            exit 0
          fi
        done
        ;;
      "") ;;
      *)
        echo "usage: wake-displays [--if-disconnected]" >&2
        exit 2
        ;;
    esac

    # Opening the DRM card resumes amdgpu through the driver's runtime PM
    # callback, then queries its connectors. Closing it allows sleep again.
    modetest -M amdgpu -D pci:0000:03:00.0 -c > /dev/null

    # Also work from SSH, where the compositor's environment is not inherited.
    if [[ -z ''${NIRI_SOCKET-} ]]; then
      NIRI_SOCKET=$(systemctl --user show-environment | sed -n 's/^NIRI_SOCKET=//p')
      export NIRI_SOCKET
    fi
    if [[ -S ''${NIRI_SOCKET-} ]]; then
      niri msg action power-on-monitors
    fi
  '';
}
