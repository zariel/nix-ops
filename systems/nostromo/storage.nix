{
  config,
  lib,
  inputs,
  utils,
  ...
}:
let
  settings = (import ./settings.nix).storage;
  mounts = {
    "/mnt/bighorse" = "bighorse";
    "/mnt/bighorse/arr" = "bighorse/arr";
    "/mnt/bighorse/pve" = "bighorse/pve";
    "/mnt/bighorse/volsync" = "bighorse/volsync";
    "/mnt/bighorse/music" = "bighorse/music";
    "/mnt/bighorse/music/downloads" = "bighorse/music/downloads";
    "/mnt/bighorse/music/lidarr" = "bighorse/music/lidarr";
    "/mnt/bighorse/backups" = "bighorse/backups";
    "/mnt/bighorse/backups/roon" = "bighorse/backups/roon";
    "/mnt/bighorse/sharing" = "bighorse/sharing";
    "/mnt/bighorse/incompletes" = "bighorse/incompletes";
    "/mnt/bighorse/Photos" = "bighorse/Photos";
    "/mnt/bighorse/Photos/Immich" = "bighorse/Photos/Immich";
  };
  consumers = {
    nfs-mountd = [
      "/mnt/bighorse/arr"
      "/mnt/bighorse/pve"
      "/mnt/bighorse/volsync"
      "/mnt/bighorse/music/downloads"
      "/mnt/bighorse/incompletes"
      "/mnt/bighorse/Photos/Immich"
    ];
    nfs-server = consumers.nfs-mountd;
    samba-smbd = [
      "/mnt/bighorse/arr"
      "/mnt/bighorse/music"
      "/mnt/bighorse/music/downloads"
      "/mnt/bighorse/music/lidarr"
      "/mnt/bighorse/backups/roon"
      "/mnt/bighorse/sharing"
    ];
  };
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];
  config = lib.mkMerge [
    {
      sops = {
        useSystemdActivation = true;
        age = {
          keyFile = "/var/lib/sops-nix/key.txt";
          sshKeyPaths = [ ];
          generateKey = false;
        };
        gnupg.sshKeyPaths = [ ];
        secrets.bighorse-key = lib.mkIf settings.enable {
          sopsFile = settings.sopsFile;
          key = "bighorse-key";
          owner = "root";
          mode = "0400";
        };
      };

      assertions = lib.optional settings.enable {
        assertion = settings.sopsFile != null;
        message = "Nostromo managed storage requires an encrypted SOPS file in settings.nix.";
      };

      # The dedicated unlock unit supplies the key after SOPS, without changing keylocation.
      boot.zfs.requestEncryptionCredentials = lib.mkIf settings.enable [ ];
      systemd.services.zfs-mount.enable = !settings.enable;

      fileSystems = lib.mkIf settings.enable (
        lib.mapAttrs (_: dataset: {
          device = dataset;
          fsType = "zfs";
          # Late mounts avoid a cycle: SOPS itself starts after local-fs.target.
          options = [
            "noauto"
            "nofail"
            "x-systemd.requires=bighorse-unlock.service"
          ];
        }) mounts
      );

      systemd.services.bighorse-unlock = lib.mkIf settings.enable {
        description = "Unlock bighorse";
        requires = [
          "zfs-import-bighorse.service"
          "sops-install-secrets.service"
        ];
        after = [
          "zfs-import-bighorse.service"
          "sops-install-secrets.service"
        ];
        path = [ config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = "key:${config.sops.secrets.bighorse-key.path}";
          UMask = "0077";
          Slice = "storage.slice";
        };
        # Activation may revisit an already unlocked pool; the key remains in the kernel.
        script = ''
          if [ "$(zfs get -H -o value keystatus bighorse)" != available ]; then
            zfs load-key -L "file://$CREDENTIALS_DIRECTORY/key" bighorse
          fi
        '';
      };

    }
    {
      systemd.services = lib.mapAttrs (
        _: paths:
        if settings.enable then
          {
            unitConfig.RequiresMountsFor = paths;
            bindsTo = map (path: "${utils.escapeSystemdPath path}.mount") paths;
            after = map (path: "${utils.escapeSystemdPath path}.mount") paths;
          }
        else
          {
            after = [ "zfs-mount.service" ];
            requires = [ "zfs-mount.service" ];
          }
      ) consumers;
    }
  ];
}
