# MCP servers shared by the coding agents. Each agent maps them to its own
# config format.
{ lib, pkgs }:
let
  # Servers behind home-ops' mcp-auth component share one pre-registered
  # Pocket ID client per server, named after the server's app.
  pocketIdServer = name: {
    url = "https://${name}-mcp.cbannister.xyz/mcp";
    clientId = "${name}-mcp";
    scopes = [
      "openid"
      "${name}:access"
      "offline_access"
    ];
  };

  servers = {
    playwright.command = lib.getExe pkgs.playwright-mcp;
    # Registers its client dynamically.
    cloudflare.url = "https://mcp.cloudflare.com/mcp";
  }
  // lib.genAttrs [
    "grafana"
    "home-assistant"
    "netbox"
    "unifi"
  ] pocketIdServer;

  # Must match the callback URLs registered on the Pocket ID clients.
  callbackPort = 4321;

  isPocketId = server: server ? clientId;
in
{
  codex = lib.mapAttrs (
    _: server:
    if isPocketId server then
      {
        inherit (server) url scopes;
        oauth = {
          client_id = server.clientId;
          callback_url = "http://127.0.0.1:${toString callbackPort}/callback";
          callback_port = callbackPort;
        };
      }
    else
      server
  ) servers;

  # Claude Code redirects to http://localhost:<callbackPort>/callback.
  claude-code = lib.mapAttrs (
    _: server:
    {
      type = if server ? url then "http" else "stdio";
    }
    // (
      if isPocketId server then
        {
          inherit (server) url;
          oauth = {
            inherit (server) clientId;
            inherit callbackPort;
            scopes = lib.concatStringsSep " " server.scopes;
          };
        }
      else
        server
    )
  ) servers;
}
