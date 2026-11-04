# SPDX-License-Identifier: Apache-2.0
# Shared HTTP listener. Speech uses it. Later model faces use it too.
# It is not the maintenance page. docs/08 §1c, D-0062, FR-SEC-013.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.janus.http;
  tokenPath =
    if
      cfg.tokenSecret
      != null
      && (options ? sops)
      && config.sops.secrets ? ${cfg.tokenSecret}
    then config.sops.secrets.${cfg.tokenSecret}.path
    else cfg.tokenFile;
  pathIsSops = path:
    path
    != null
    && (options ? sops)
    && lib.any (secret: secret.path == path) (lib.attrValues config.sops.secrets);
  needsSops = cfg.tokenSecret != null || pathIsSops cfg.tokenFile;
  speech = config.janus.speech;
  httpCmd = pkgs.writeShellApplication {
    name = "janus-http";
    runtimeInputs = with pkgs; [jq openssl systemd coreutils janet];
    text =
      ''
        JANUS_HTTP_JANET=${../../janet/speech.janet}
      ''
      + builtins.readFile ../../pkgs/janus-http.sh;
  };
  lans =
    lib.mapAttrsToList (name: lan: {
      inherit name;
      inherit (lan) address;
    })
    config.janus.network.lans;
  san =
    ["DNS:${config.janus.system.hostName}"]
    ++ map (lan: "IP:${lan.address}") lans;
  zones = config.janus.firewall.zones;
in {
  options.janus.http = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Shared HTTP listener on port 8473.
        False adds no unit, certificate, or token.
        Speech uses it. It is not the maintenance page. D-0062.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8473;
      description = "TLS port. Not janus.access.web.port.";
    };

    zones = mkOption {
      type = types.listOf types.str;
      default = ["lan" "mgmt"];
      description = ''
        Zones where a client may open the port.
        wan fails evaluation. guest and iot only when the firewall defines them.
      '';
    };

    tokenSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        sops secret name for the bearer token.
        One line, value:, in sopsFile. Not the maintenance page passphrase.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Token file from janus secrets put. Exactly one of this and tokenSecret.";
    };

    sopsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "sops document for tokenSecret. Installed only when enable is true.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        {
          assertion = (cfg.tokenFile != null) != (cfg.tokenSecret != null);
          message = ''
            janus.http.enable needs exactly one of janus.http.tokenSecret and janus.http.tokenFile.
            The token is not the maintenance page passphrase. FR-SEC-013.
          '';
        }
        {
          assertion = cfg.tokenSecret == null || cfg.sopsFile != null;
          message = "janus.http.tokenSecret needs janus.http.sopsFile.";
        }
        {
          assertion = cfg.zones != [];
          message = "janus.http.zones needs at least one zone.";
        }
        {
          assertion = !lib.elem "wan" cfg.zones;
          message = "janus.http.zones must not include wan.";
        }
      ]
      ++ map (zone: {
        assertion = zones ? ${zone};
        message = "janus.http.zones contains '${zone}', which is not a firewall zone.";
      })
      cfg.zones;

    users.users.janus-http = {
      isSystemUser = true;
      group = "janus-http";
      home = "/var/empty";
    };
    users.users.janus-http-tls = {
      isSystemUser = true;
      group = "janus-http-tls";
      extraGroups = ["janus-http"];
      home = "/var/empty";
    };
    users.groups.janus-http = {};
    users.groups.janus-http-tls = {};

    environment.etc."janus/http.json".text = builtins.toJSON {
      enable = true;
      inherit (cfg) port zones;
      tokenFile = tokenPath;
      cert = "/var/lib/janus/http/cert.pem";
      key = "/var/lib/janus/http/key.pem";
      socket = "/run/janus-http/http.sock";
      paused = "/var/lib/janus/http/paused";
      hostname = config.janus.system.hostName;
      inherit san;
      asr = speech.asr.enable;
      tts = speech.tts.enable;
    };

    environment.etc."janus/stunnel-http.conf".text = ''
      foreground = yes
      syslog = no
      socket = a:IPV6_V6ONLY=0

      [janus-http]
      accept = :::${toString cfg.port}
      connect = /run/janus-http/http.sock
      cert = /var/lib/janus/http/cert.pem
      key = /var/lib/janus/http/key.pem
    '';

    environment.etc."janus/bin/janus-http".source = "${httpCmd}/bin/janus-http";

    janus.firewall.services.http = {
      zones = cfg.zones;
      port = cfg.port;
      protocol = "tcp";
      confine = true;
    };

    sops.secrets = mkIf (cfg.tokenSecret != null && cfg.sopsFile != null) {
      ${cfg.tokenSecret} = {
        sopsFile = cfg.sopsFile;
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/janus 0755 root root -"
      "d /var/lib/janus/http 0751 root janus-http-tls -"
    ];

    systemd.services.janus-http-cert = {
      description = "Shared HTTP listener certificate";
      before = ["janus-http.service" "janus-http-tls.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${httpCmd}/bin/janus-http cert";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/http";
      };
    };

    systemd.services.janus-http-secret = mkIf needsSops {
      description = "Shared HTTP listener token";
      before = ["janus-http.service"];
      after = ["sops-install-secrets.service"];
      requires = ["sops-install-secrets.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/test -s ${lib.escapeShellArg tokenPath}";
      };
    };

    systemd.services.janus-http = {
      description = "Shared HTTP listener";
      wantedBy = ["multi-user.target"];
      after =
        ["janus-http-cert.service" "network-online.target"]
        ++ lib.optional needsSops "sops-install-secrets.service"
        ++ lib.optional needsSops "janus-http-secret.service";
      requires =
        ["janus-http-cert.service"]
        ++ lib.optional needsSops "sops-install-secrets.service"
        ++ lib.optional needsSops "janus-http-secret.service";
      unitConfig.ConditionPathExists = "!/var/lib/janus/http/paused";
      environment = {
        JANUS_HTTP_JSON = "/etc/janus/http.json";
        JANUS_HTTP_RUNTIME = "/run/janus-http";
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        User = "janus-http";
        Group = "janus-http";
        RuntimeDirectory = "janus-http";
        RuntimeDirectoryMode = "0750";
        ExecStart = "${httpCmd}/bin/janus-http serve";
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStartSec = "10s";
        ExecCondition = ["${httpCmd}/bin/janus-http ready"];
        LoadCredential = lib.optional (tokenPath != null) "token:${tokenPath}";
        # Body files stay owner-only. The socket is chmod 0660 after listen. T-0021.
        UMask = "0077";
        # Speech raises this. A LAN client must not exhaust the router. T-0023.
        MemoryMax =
          if speech.asr.enable || speech.tts.enable
          then "1536M"
          else "128M";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/http";
      };
    };

    systemd.services.janus-http-tls = {
      description = "Shared HTTP listener TLS";
      wantedBy = ["multi-user.target"];
      after = ["janus-http.service"];
      requires = ["janus-http.service"];
      bindsTo = ["janus-http.service"];
      unitConfig.ConditionPathExists = "!/var/lib/janus/http/paused";
      serviceConfig = {
        Type = "simple";
        User = "janus-http-tls";
        Group = "janus-http-tls";
        ExecStart = "${pkgs.stunnel}/bin/stunnel /etc/janus/stunnel-http.conf";
        Restart = "on-failure";
        RestartSec = "2s";
        MemoryMax = "128M";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/http";
      };
    };
  };
}
