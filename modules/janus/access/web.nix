# SPDX-License-Identifier: Apache-2.0
# Maintenance page. docs/20. Janet serves HTTP; stunnel terminates TLS.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.access.web;
  janusCmd = pkgs.writeShellApplication {
    name = "janus";
    runtimeInputs = with pkgs; [jq iproute2 nftables vnstat coreutils systemd util-linux gnutar];
    text = builtins.readFile ../../../pkgs/janus.sh;
  };
  runCmd = pkgs.writeShellApplication {
    name = "janus-web-run";
    runtimeInputs = [janusCmd pkgs.jq pkgs.coreutils];
    text = builtins.readFile ../../../pkgs/janus-web-run.sh;
  };
  webCmd = pkgs.writeShellApplication {
    name = "janus-web";
    runtimeInputs = with pkgs; [jq openssl systemd coreutils janet];
    text =
      ''
        JANUS_WEB_JANET=${../../../janet/web.janet}
      ''
      + builtins.readFile ../../../pkgs/janus-web.sh;
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
in {
  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.passphraseFile != null;
          message = "janus.access.web.enable requires janus.access.web.passphraseFile.";
        }
        {
          assertion = cfg.zones != [];
          message = "janus.access.web.zones must name at least one zone.";
        }
        {
          assertion = !lib.elem "wan" cfg.zones;
          message = "janus.access.web.zones must not contain wan.";
        }
      ]
      ++ map (zone: {
        assertion = config.janus.firewall.zones ? ${zone};
        message = "janus.access.web.zones contains '${zone}', which is not a firewall zone.";
      })
      cfg.zones;

    users.users.janus-web = {
      isSystemUser = true;
      group = "janus-web";
      home = "/var/empty";
    };
    users.users.janus-web-tls = {
      isSystemUser = true;
      group = "janus-web-tls";
      extraGroups = ["janus-web"];
      home = "/var/empty";
    };
    users.groups.janus-web = {};
    users.groups.janus-web-tls = {};

    security.sudo.extraRules = [
      {
        users = ["janus-web"];
        commands = [
          {
            command = "${runCmd}/bin/janus-web-run";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    environment.etc."janus/web.json".text = builtins.toJSON {
      enable = true;
      port = cfg.port;
      zones = cfg.zones;
      passphraseFile = cfg.passphraseFile;
      cert = "/var/lib/janus/web/cert.pem";
      key = "/var/lib/janus/web/key.pem";
      socket = "/run/janus-web/http.sock";
      paused = "/var/lib/janus/web/paused";
      hostname = config.janus.system.hostName;
      inherit san;
      subscriptions = lib.attrNames config.janus.proxy.subscriptions;
      inherit lans;
      wifi = lib.attrNames config.janus.network.wifi;
      proxy = config.janus.proxy.enable;
      monitoringScope = config.janus.monitoring.scope;
      audit = config.janus.monitoring.audit.enable;
    };

    environment.etc."janus/stunnel.conf".text = ''
      foreground = yes
      syslog = no
      socket = a:IPV6_V6ONLY=0

      [janus]
      accept = [::]:${toString cfg.port}
      connect = /run/janus-web/http.sock
      cert = /var/lib/janus/web/cert.pem
      key = /var/lib/janus/web/key.pem
    '';

    environment.etc."janus/bin/janus-web".source = "${webCmd}/bin/janus-web";
    environment.etc."janus/bin/janus-web-run".source = "${runCmd}/bin/janus-web-run";

    janus.firewall.services.maintenance = {
      zones = cfg.zones;
      port = cfg.port;
      confine = true;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/janus 0755 root root -"
      "d /var/lib/janus/web 0751 root janus-web-tls -"
    ];

    systemd.services.janus-web-cert = {
      description = "Maintenance page certificate";
      before = ["janus-web.service" "janus-web-tls.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${webCmd}/bin/janus-web cert";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/web";
      };
    };

    systemd.services.janus-web = {
      description = "Maintenance page";
      wantedBy = ["multi-user.target"];
      after = ["janus-web-cert.service" "network-online.target"];
      requires = ["janus-web-cert.service"];
      unitConfig.ConditionPathExists = "!/var/lib/janus/web/paused";
      environment = {
        JANUS_WEB_JSON = "/etc/janus/web.json";
        JANUS_WEB_HTML = "${../../../janet/web.html}";
        JANUS_WEB_EXEC = "${runCmd}/bin/janus-web-run";
        JANUS_WEB_USE_SUDO = "1";
        JANUS_WEB_SUDO_BIN = "${pkgs.sudo}/bin/sudo";
        JANUS_WEB_OPENSSL = "${pkgs.openssl}/bin/openssl";
      };
      serviceConfig = {
        Type = "notify";
        User = "janus-web";
        Group = "janus-web";
        RuntimeDirectory = "janus-web";
        RuntimeDirectoryMode = "0750";
        ExecStart = "${webCmd}/bin/janus-web serve";
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStartSec = "10s";
        ExecCondition = ["${webCmd}/bin/janus-web ready"];
        LoadCredential = "passphrase:${cfg.passphraseFile}";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = "/var/lib/janus/web";
      };
    };

    systemd.services.janus-web-tls = {
      description = "Maintenance page TLS";
      wantedBy = ["multi-user.target"];
      after = ["janus-web.service"];
      requires = ["janus-web.service"];
      bindsTo = ["janus-web.service"];
      unitConfig.ConditionPathExists = "!/var/lib/janus/web/paused";
      serviceConfig = {
        Type = "simple";
        User = "janus-web-tls";
        Group = "janus-web-tls";
        ExecStart = "${pkgs.stunnel}/bin/stunnel /etc/janus/stunnel.conf";
        Restart = "on-failure";
        RestartSec = "2s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/web";
      };
    };
  };
}
