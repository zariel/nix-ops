{ lib, pkgs, ... }:
let
  nightLight = pkgs.writeShellApplication {
    name = "night-light";
    runtimeInputs = [
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      case "''${1:-status}" in
        toggle)
          if systemctl --user is-active --quiet wlsunset.service; then
            systemctl --user stop wlsunset.service
          else
            systemctl --user start wlsunset.service
          fi
          ;;
        status)
          state="$(systemctl --user is-active wlsunset.service || true)"
          case "$state" in
            active)
              icon=""
              class="enabled"
              tooltip="Night light: automatic (London sunrise/sunset)"
              ;;
            failed)
              icon=""
              class="failed"
              tooltip="Night light: service failed"
              ;;
            *)
              icon=""
              class="disabled"
              tooltip="Night light: off"
              ;;
          esac

          jq -cn --arg text "$icon" --arg class "$class" \
            --arg tooltip "$tooltip" \
            '{text: $text, class: $class, tooltip: ($tooltip + "\nClick or Super+Ctrl+N to toggle")}'
          ;;
        *)
          echo "usage: night-light [status|toggle]" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  home.packages = [ nightLight ];

  services.wlsunset = {
    enable = true;
    # Use London as the solar location for the Europe/London timezone.
    latitude = 51.5;
    longitude = -0.1;
    temperature = {
      day = 6500;
      night = 4000;
    };
  };

  systemd.user.services.wlsunset = {
    Unit.ConditionEnvironment = lib.mkForce [
      "WAYLAND_DISPLAY"
      "XDG_CURRENT_DESKTOP=niri"
    ];
    Service = {
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  programs.waybar.settings.mainBar."custom/night-light" = {
    exec = "${nightLight}/bin/night-light status";
    return-type = "json";
    interval = 2;
    on-click = "${nightLight}/bin/night-light toggle";
    tooltip = true;
  };
}
