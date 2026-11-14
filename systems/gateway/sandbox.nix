{
  NoNewPrivileges = true;
  # Network daemons must not reach privileged host management sockets or secrets.
  InaccessiblePaths = [
    "-/run/systemd/private"
    "-/run/dbus/system_bus_socket"
    "-/nix/var/nix/daemon-socket"
    "-/run/secrets"
    "-/etc/ssh"
  ];
  PrivateDevices = true;
  PrivateTmp = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  ProtectClock = true;
  ProtectControlGroups = true;
  ProtectHostname = true;
  ProtectKernelLogs = true;
  ProtectKernelModules = true;
  ProtectKernelTunables = true;
  ProtectProc = "invisible";
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
  SystemCallArchitectures = "native";
  SystemCallFilter = [ "@system-service" ];
  SystemCallErrorNumber = "EPERM";
  UMask = "0077";
  LimitCORE = 0;
  TasksMax = 512;
}
