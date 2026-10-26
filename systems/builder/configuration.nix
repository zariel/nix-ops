{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-builder";
  networking.useDHCP = false;
  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "ens*";
      address = [ "10.1.1.155/24" ];
      gateway = [ "10.1.1.1" ];
      dns = [ "172.53.53.53" ];
    };
  };

  # Builder-specific nix settings
  nix.settings = {
    # Let a large build use all 8 vCPUs while limiting competition for 16 GiB RAM.
    max-jobs = 2;
    cores = 0;
    extra-sandbox-paths = [ config.programs.ccache.cacheDir ];

    # Retain build results until disk pressure, reserving room for ncps's 100G
    # cache and build scratch space on the same filesystem.
    min-free = lib.mkDefault (128 * 1024 * 1024 * 1024);
    max-free = lib.mkDefault (192 * 1024 * 1024 * 1024);
  };

  programs.ccache.enable = true;

  zramSwap.enable = true;

  # Number of build users for parallel builds
  nix.nrBuildUsers = 32;

  nix.settings.trusted-users = lib.mkAfter [
    "nix-remote-builder"
  ];

  # Remote results have no persistent client roots here. A scheduled sweep would
  # discard the shared cache regardless of how much disk space remains.
  nix.gc.automatic = false;

  # Additional SSH key for nix-daemon
  users.users.chris.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM+Nua2Ygsk93Z3aybi+cxuqGjkK6tbP+3rVj6k39RpQ nix-daemon@macbook"
  ];

  users.groups.nix-remote-builder = { };
  users.users.nix-remote-builder = {
    isSystemUser = true;
    group = "nix-remote-builder";
    home = "/var/lib/nix-remote-builder";
    createHome = true;
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILhYchTL2BZZhaN33jlVRjoLnbWMh1O3DXCspoLrlfC7 nix-remote-builder@cbannister.casa"
    ];
  };

  # Builder-specific packages
  environment.systemPackages = with pkgs; [
    neovim
  ];

  services.qemuGuest.enable = true;

  # Serve local build results to the pull-through cache.
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "/var/lib/secrets/harmonia-key" ];
    settings = {
      bind = "127.0.0.1:5001";
      priority = 30;
    };
  };

  services.ncps = {
    enable = true;
    server.addr = "0.0.0.0:5000";
    analytics.reporting.enable = false;
    cache = {
      hostName = "builder.cbannister.casa";
      # Keep client trust when serving either local or upstream paths.
      secretKeyPath = "/var/lib/secrets/harmonia-key";
      maxSize = "100G";
      lru.schedule = "*/15 * * * *";
      upstream = {
        # The builder's substituters exclude this endpoint, preventing a loop.
        urls = [ "http://127.0.0.1:5001" ] ++ config.nix.settings.substituters;
        publicKeys = config.nix.settings.trusted-public-keys;
      };
    };
  };

  systemd.services.ncps = {
    requires = [ "harmonia.socket" ];
    after = [ "harmonia.socket" ];
  };
}
