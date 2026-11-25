{
  pkgs,
  codex-cli-nix,
  janestreet-agent-skills,
  llm-agents,
  config,
  lib,
  osConfig,
  ...
}:
let
  home = config.home.homeDirectory;

  llmAgentPackages = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  beadsPackage = llmAgentPackages.beads;

  # Instructions and skills shared by the coding agents.
  agentConfig = {
    skills = {
      draft-commit = ./apps/codex/skills/draft-commit.md;
      socratic-tutor = "${janestreet-agent-skills}/socratic-tutor";
      technical-doc-writer = ./apps/codex/skills/technical-doc-writer;
    };
    context = builtins.readFile ./apps/codex/context.md;
  };

  formatCommitMessage = pkgs.callPackage ../pkgs/format-commit-message.nix { };

  bd = pkgs.writeShellApplication {
    name = "bd";

    runtimeInputs = [
      pkgs.systemd
    ];

    text = ''
      exec systemd-run \
        --user \
        --scope \
        --quiet \
        --collect \
        --property=MemoryHigh=2G \
        --property=MemoryMax=4G \
        --property=MemorySwapMax=1G \
        ${pkgs.lib.getExe' beadsPackage "bd"} "$@"
    '';
  };

  # Rootless podman with the systemd cgroup manager puts containers in their own
  # libpod scopes under the user manager's user.slice, outside the caller's
  # slice. The cgroupfs manager creates them beneath the calling scope instead,
  # which claude-dev delegates for that purpose.
  katlDevContainersConf = pkgs.writeText "katl-dev-containers.conf" ''
    [engine]
    cgroup_manager = "cgroupfs"
  '';

  claudeDev = pkgs.writeShellApplication {
    name = "claude-dev";

    runtimeInputs = [
      pkgs.systemd
    ];

    text = ''
      export CONTAINERS_CONF_OVERRIDE=${katlDevContainersConf}
      exec systemd-run \
        --user \
        --scope \
        --quiet \
        --collect \
        --slice=katl-dev.slice \
        --property=Delegate=yes \
        ${pkgs.lib.getExe config.programs.claude-code.package} "$@"
    '';
  };
in
{
  imports = [
    ./appearance.nix
    ./default-apps.nix
    ./desktop-shell.nix
    ./gaming.nix
    ./night-light.nix
    ./niri-session.nix
  ];

  home.packages = with pkgs; [
    p7zip
    unzip
    wget
    unrar
    deploy-rs
    obsidian
    mpv
    bubblewrap
    rustup
    kubectl
    mkbrr
    bd
    claudeDev
    formatCommitMessage
    gcc
    glow
    nodejs-slim # Runtime for the Codex plugin's Claude Code hooks and commands.
  ];

  home.shellAliases = {
    k = "kubectl";
  };

  # Home Manager's default sd-switch restarts changed user units during
  # activation. In a UWSM session, those units are tied to graphical-session.target,
  # so restarting them can complete UWSM's bind-PID unit and end the compositor.
  systemd.user.startServices = "suggest";

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings."*" = {
      IdentityAgent = "${home}/.1password/agent.sock";
    };
  };

  programs.claude-code = {
    enable = true;
    package = llmAgentPackages.claude-code;
    context = agentConfig.context + builtins.readFile ./apps/claude-code/delegation.md;
    agentsDir = ./apps/claude-code/agents;
    skills = {
      inherit (agentConfig.skills) socratic-tutor;
    };
    mcpServers = (import ../mcp-servers.nix { inherit lib pkgs; }).claude-code;
    # Merge into the existing settings so changes made through /config persist.
    mutableSettings = true;
    settings = {
      extraKnownMarketplaces.openai-codex.source = {
        source = "github";
        repo = "openai/codex-plugin-cc";
      };
      enabledPlugins."codex@openai-codex" = true;
      effortLevel = "high";
      permissions = {
        defaultMode = "auto";
        allow = [ "Bash(git worktree remove:*)" ];
        # --force discards uncommitted changes in the worktree.
        ask = [ "Bash(git worktree remove --force:*)" ];
      };
      spinnerTipsEnabled = false;
      attribution = {
        commit = "";
        pr = "";
        sessionUrl = false;
      };
    };
  };

  programs.codex = {
    enable = true;
    package = codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
    inherit (agentConfig) skills context;
  };

  systemd.user.services.codex-app-server = {
    Unit = {
      Description = "Codex background server";
      X-Restart-Triggers = [ osConfig.environment.etc."codex/config.toml".source ];
    };

    Service = {
      ExecStart = "${pkgs.lib.getExe config.programs.codex.package} app-server --listen unix://";
      WorkingDirectory = home;
      Environment = [
        "PATH=/run/wrappers/bin:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
      ];
      Restart = "on-failure";
      RestartSec = 2;
      # Let the server shut down its workers before systemd kills remaining children.
      KillMode = "mixed";
      TimeoutStopSec = 75;
    };

    Install.WantedBy = [ "default.target" ];
  };

  # Global service switching can stop UWSM, so restart only a changed Codex unit.
  home.activation.restartCodex = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
    if ! ${pkgs.diffutils}/bin/cmp --quiet \
      "''${oldGenPath:-}/home-files/.config/systemd/user/codex-app-server.service" \
      "$newGenPath/home-files/.config/systemd/user/codex-app-server.service" 2>/dev/null \
      && env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        ${pkgs.systemd}/bin/systemctl --user is-active --quiet codex-app-server.service
    then
      run env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        ${pkgs.systemd}/bin/systemctl --user try-restart codex-app-server.service
    fi
  '';

  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
  };

  programs.nh.osFlake = "${home}/infra/nix-ops#nixosConfigurations.gaming";
}
