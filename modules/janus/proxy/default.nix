# SPDX-License-Identifier: Apache-2.0
# janus.proxy option types and structural assertions. The engine is not rendered yet.
# docs/07, docs/08 §6.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.janus.proxy;

  secretOk = value: value == null || config.janus.security.allowInlineSecrets;

  targetOk = target: let
    group =
      if lib.hasPrefix "group:" target
      then lib.removePrefix "group:" target
      else if target == "Auto"
      then "Auto"
      else null;
  in
    target
    == "direct"
    || target == "block"
    || (group != null && (group == "Auto" || cfg.groups ? ${group}));
in {
  options.janus.proxy = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the circumvention engine.";
    };
    engine = mkOption {
      type = types.enum ["sing-box" "xray"];
      default = "sing-box";
      description = "Proxy engine. Features the engine cannot express fail evaluation.";
    };
    mode = mkOption {
      type = types.enum ["bypass" "rule-based" "proxy-all"];
      default = "rule-based";
      description = "Traffic mode.";
    };
    defaultTarget = mkOption {
      type = types.str;
      default = "group:Auto";
      description = "Target when no rule matches.";
    };
    subscriptions = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Subscription URL. Inline values require janus.security.allowInlineSecrets.";
          };
          urlSecret = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "sops secret name of the subscription URL.";
          };
          format = mkOption {
            type = types.enum ["auto" "share-links" "clash" "sing-box"];
            default = "auto";
            description = "Subscription format.";
          };
          refresh = mkOption {
            type = types.str;
            default = "6h";
            description = "Refresh interval or cron expression.";
          };
          userAgent = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "HTTP user agent.";
          };
          headers = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Extra HTTP headers.";
          };
          via = mkOption {
            type = types.enum ["tunnel" "direct" "tunnel-then-direct"];
            default = "tunnel";
            description = "Path used to refresh at runtime.";
          };
          snapshot.hash = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Pin the build-time snapshot. Null fetches it impurely.";
          };
          minimumNodes = mkOption {
            type = types.int;
            default = 1;
            description = "Refuse a refresh with fewer nodes.";
          };
          allowMissingAtBuild = mkOption {
            type = types.bool;
            default = false;
            description = "Build an image when the subscription cannot be fetched.";
          };
          nameFilter = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Matcher that drops junk entries.";
          };
        };
      });
      default = {};
      description = "Subscription sources. docs/07 §3.2.";
    };
    nodes = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          protocol = mkOption {
            type = types.enum ["vless" "vmess" "trojan" "shadowsocks" "hysteria2" "tuic"];
            description = "Outbound protocol.";
          };
          server = mkOption {
            type = types.str;
            description = "Server host.";
          };
          port = mkOption {
            type = types.port;
            description = "Server port.";
          };
          tags = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Matchable tags.";
          };
          tls.enable = mkOption {
            type = types.bool;
            default = false;
            description = "TLS.";
          };
          tls.serverName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TLS server name.";
          };
          tls.alpn = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "ALPN.";
          };
          tls.utls = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "uTLS fingerprint.";
          };
          tls.insecure = mkOption {
            type = types.bool;
            default = false;
            description = "Skip certificate verification.";
          };
          tls.reality.publicKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "REALITY public key.";
          };
          tls.reality.shortId = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "REALITY short id.";
          };
          transport.type = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Transport type.";
          };
          transport.path = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Transport path.";
          };
          transport.host = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Transport host.";
          };
          transport.serviceName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "gRPC service name.";
          };
          vmess.uuid = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "VMess UUID.";
          };
          vmess.security = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "VMess cipher.";
          };
          vmess.alterId = mkOption {
            type = types.int;
            default = 0;
            description = "VMess alter id. New nodes should prefer VLESS.";
          };
          vless.uuid = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "VLESS UUID.";
          };
          vless.flow = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "VLESS flow, or null.";
          };
          trojan.password = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Inline Trojan password.";
          };
          trojan.passwordFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Trojan password file.";
          };
          shadowsocks.method = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Shadowsocks method.";
          };
          shadowsocks.password = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Inline Shadowsocks password.";
          };
          shadowsocks.passwordFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Shadowsocks password file.";
          };
          shadowsocks.plugin.name = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Plugin name.";
          };
          shadowsocks.plugin.options = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Plugin options.";
          };
          hysteria2.password = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Hysteria2 password. sing-box only.";
          };
          hysteria2.up = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Hysteria2 up bandwidth.";
          };
          hysteria2.down = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Hysteria2 down bandwidth.";
          };
          hysteria2.obfs = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Hysteria2 obfuscation.";
          };
          tuic.uuid = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TUIC UUID. sing-box only.";
          };
          tuic.password = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TUIC password.";
          };
          tuic.congestion = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TUIC congestion control.";
          };
        };
      });
      default = {};
      description = "Manual proxy nodes.";
    };
    groups = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          fromSubscriptions = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Subscriptions this matcher applies to. Empty means all.";
          };
          match.kind = mkOption {
            type = types.nullOr (types.enum ["regex" "glob" "peg"]);
            default = null;
            description = "Matcher kind.";
          };
          match.pattern = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Matcher pattern.";
          };
          match.caseInsensitive = mkOption {
            type = types.bool;
            default = true;
            description = "Case-insensitive match.";
          };
          members = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Manual members: node:, group:, or sub: references.";
          };
          strategy = mkOption {
            type = types.enum ["manual" "url-test" "fallback" "load-balance"];
            default = "url-test";
            description = "Selection strategy.";
          };
          default = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Initial node for strategy manual.";
          };
          test.url = mkOption {
            type = types.str;
            default = "https://www.gstatic.com/generate_204";
            description = "URL-test target.";
          };
          test.interval = mkOption {
            type = types.str;
            default = "5m";
            description = "URL-test interval.";
          };
          test.tolerance = mkOption {
            type = types.int;
            default = 50;
            description = "URL-test tolerance in milliseconds.";
          };
          emptyFallback = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Used when the group has no members. direct or group:<name>.";
          };
        };
      });
      default = {};
      description = "Proxy groups. docs/07 §4. Auto exists unless the user defines groups.Auto.";
    };
    rules = mkOption {
      type = types.listOf (types.submodule {
        options = {
          match.domains = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Exact domains.";
          };
          match.domainSuffix = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Domain suffixes.";
          };
          match.geosite = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "GeoSite categories.";
          };
          match.geoip = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "GeoIP categories.";
          };
          match.ipCidr = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Destination prefixes.";
          };
          match.port = mkOption {
            type = types.listOf (types.either types.int types.str);
            default = [];
            description = "Destination ports.";
          };
          match.protocol = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Transport protocol.";
          };
          match.sourceLan = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Source LAN names.";
          };
          match.sourceIp = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Source addresses.";
          };
          target = mkOption {
            type = types.str;
            description = "group:<name>, direct, or block.";
          };
        };
      });
      default = [
        {
          match.geosite = ["private"];
          target = "direct";
        }
        {
          match.geoip = ["private"];
          target = "direct";
        }
      ];
      description = "Ordered routing rules. The default is the region-agnostic private-network exception.";
    };
    exceptions = mkOption {
      type = types.listOf types.str;
      default = ["private" "iptv"];
      description = "proxy-all exceptions that stay direct.";
    };
    egressWan = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Pin engine egress to one WAN.";
    };
    blockQuic = mkOption {
      type = types.bool;
      default = false;
      description = "Reject QUIC so clients fall back to TCP.";
    };
    geodata.refresh = mkOption {
      type = types.str;
      default = "weekly";
      description = "Geo data refresh interval.";
    };
    geodata.sources = mkOption {
      type = types.attrs;
      default = {};
      description = "Geo data sources. Empty uses the release defaults.";
    };
    engineSettings = mkOption {
      type = types.attrs;
      default = {};
      description = "Raw engine settings merged last. Unsupported.";
    };
  };

  config = {
    assertions =
      (lib.optional (!targetOk cfg.defaultTarget) {
        assertion = false;
        message = "janus.proxy.defaultTarget '${cfg.defaultTarget}' is not direct, block, Auto, or a defined group.";
      })
      ++ lib.imap0 (i: rule: {
        assertion = targetOk rule.target;
        message = "janus.proxy.rules.${toString i}.target '${rule.target}' does not name a defined group, direct, or block.";
      })
      cfg.rules
      ++ lib.mapAttrsToList (name: group: {
        assertion =
          group.members
          != []
          || group.match.kind != null
          || group.fromSubscriptions != []
          || group.emptyFallback != null;
        message = "janus.proxy.groups.${name} has no members and no emptyFallback.";
      })
      cfg.groups
      ++ lib.mapAttrsToList (name: sub: {
        assertion = (sub.url != null) != (sub.urlSecret != null);
        message = "janus.proxy.subscriptions.${name} must set exactly one of url or urlSecret.";
      })
      cfg.subscriptions
      ++ lib.concatMap (
        name: let
          sub = cfg.subscriptions.${name};
        in [
          {
            assertion = secretOk sub.url;
            message = "janus.proxy.subscriptions.${name}.url is inline. Use urlSecret or janus.security.allowInlineSecrets.";
          }
        ]
      ) (lib.attrNames cfg.subscriptions)
      ++ lib.concatMap (
        name: let
          node = cfg.nodes.${name};
        in [
          {
            assertion = cfg.engine == "sing-box" || !(lib.elem node.protocol ["hysteria2" "tuic"]);
            message = "janus.proxy.nodes.${name}.protocol ${node.protocol} is not supported by xray.";
          }
          {
            assertion = secretOk node.trojan.password && secretOk node.shadowsocks.password && secretOk node.hysteria2.password && secretOk node.tuic.password;
            message = "janus.proxy.nodes.${name} has an inline password. Use a file or janus.security.allowInlineSecrets.";
          }
        ]
      ) (lib.attrNames cfg.nodes);

    warnings =
      lib.optional cfg.enable "janus.proxy.enable is set. The engine renderer is not implemented yet."
      ++ lib.optional (lib.any (lan: lan.ipv6.mode == "delegated") (lib.attrValues config.janus.network.lans) && (cfg.mode == "rule-based" || cfg.mode == "proxy-all")) ''
        A LAN uses ipv6.mode = delegated while the traffic mode is ${cfg.mode}. IPv6 interception is not implemented yet, so this can leak.
      '';
  };
}
