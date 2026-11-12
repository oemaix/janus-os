# SPDX-License-Identifier: Apache-2.0
# janus.proxy option types and structural assertions. Rendering is modules/janus/proxy/lower.nix.
# docs/07, docs/08 §6.
{
  config,
  lib,
  options,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.janus.proxy;
  schedule = import ./schedule.nix {inherit lib;};
  labels = import ./labels.nix {inherit lib;};

  secretOk = value: value == null || config.janus.security.allowInlineSecrets;
  dns = config.janus.dns;
  lans = config.janus.network.lans;

  pick = local: parent:
    if local == null
    then parent
    else local;

  resolverHost = url: let
    stripped =
      if lib.hasPrefix "https://" url
      then lib.removePrefix "https://" url
      else if lib.hasPrefix "tls://" url
      then lib.removePrefix "tls://" url
      else if lib.hasPrefix "quic://" url
      then lib.removePrefix "quic://" url
      else if lib.hasPrefix "udp://" url
      then lib.removePrefix "udp://" url
      else url;
    noPath = lib.head (lib.splitString "/" stripped);
  in
    if lib.hasPrefix "[" noPath
    then lib.removeSuffix "]" (lib.removePrefix "[" (lib.head (lib.splitString "]" noPath)))
    else lib.head (lib.splitString ":" noPath);

  encryptedUrl = url:
    lib.hasPrefix "https://" url || lib.hasPrefix "tls://" url || lib.hasPrefix "quic://" url;

  needsBootstrap = url:
    encryptedUrl url
    && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" (resolverHost url) == null
    && !lib.hasInfix ":" (resolverHost url);

  lanMode = lan:
    if lan.proxy.mode == null
    then cfg.mode
    else lan.proxy.mode;

  lanRules = lan:
    if lan.proxy.rules == null
    then cfg.rules
    else lan.proxy.rules;

  lanUrls = lan:
    (pick lan.dns.domestic.resolvers dns.domestic.resolvers)
    ++ lib.optionals (lanMode lan != "bypass") (pick lan.dns.remote.resolvers dns.remote.resolvers)
    ++ lib.concatLists (lib.attrValues (pick lan.dns.forwarders dns.forwarders));

  bootViews =
    if lans == {}
    then [
      {
        name = "router";
        bootstrap = dns.bootstrap;
        urls =
          dns.domestic.resolvers
          ++ lib.optionals (cfg.mode != "bypass") dns.remote.resolvers
          ++ lib.concatLists (lib.attrValues dns.forwarders);
      }
    ]
    else
      lib.mapAttrsToList (name: lan: {
        inherit name;
        bootstrap = pick lan.dns.bootstrap dns.bootstrap;
        urls = lanUrls lan;
      })
      lans;

in {
  imports = [./lower.nix];

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
      description = "Default traffic mode. A LAN inherits this unless it sets proxy.mode.";
    };
    defaultTarget = mkOption {
      type = types.either types.str (types.attrsOf types.anything);
      default = {};
      description = "Selector, direct, or block when no rule matches. An empty selector matches every node.";
    };
    subscriptions = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Use this subscription on this router. False keeps url or urlSecret, so the host still names the secret, and drops the snapshot, the timer, and the nodes.";
          };
          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Subscription URL. Inline values require janus.security.allowInlineSecrets.";
          };
          urlSecret = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "sops secret name of the subscription URL. The decrypted file is the URL. In a fleet repo the ciphertext is secrets/subscription/<name>.yaml.";
          };
          format = mkOption {
            type = types.enum ["auto" "share-links" "clash" "sing-box"];
            default = "auto";
            description = "Subscription format.";
          };
          refresh = mkOption {
            type = types.str;
            default = "6h";
            description = "Refresh interval (Nh, Nm, weekly, daily, hourly) or a five-field cron expression. The day-of-month and month are *. The day-of-week may be * or a list such as 2,4,6. 0 and 7 are Sunday.";
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
            description = "Regex that drops junk node names. A name that does not match is kept out of the snapshot.";
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
            description = "String list on the node. Not a label.";
          };
          labels = mkOption {
            type = types.attrsOf types.anything;
            default = {};
            description = "Manual label values. protocol fails evaluation. An empty label repeats its key.";
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
    labels = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          type = mkOption {
            type = types.nullOr (types.enum ["string" "number" "bool" "enum" "empty" "region"]);
            default = null;
            description = "Value type. Required for a key the operator adds. latency does not set it.";
          };
          values = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Tokens for type enum.";
          };
          timeout = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Latency probe timeout. The stored number is this many milliseconds until a sample exists.";
          };
          interval = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Latency probe interval.";
          };
          rules = mkOption {
            type = types.listOf (types.submodule {
              options = {
                match.kind = mkOption {
                  type = types.enum ["regex" "glob" "peg" "geoip" "http" "query"];
                  description = "Labeling rule kind. query is not accepted.";
                };
                match.pattern = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "regex, glob, or peg pattern.";
                };
                match.caseInsensitive = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Case-insensitive name match.";
                };
                match.countries = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Officially assigned codes a geoip rule may write.";
                };
                match.url = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "HTTP probe URL.";
                };
                match.timeout = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "HTTP probe timeout. Default 5s.";
                };
                match.interval = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "HTTP probe interval. Default 1h.";
                };
                value = mkOption {
                  type = types.nullOr types.anything;
                  default = null;
                  description = "Value the matching rule writes. empty and geoip and http take none.";
                };
              };
            });
            default = [];
            description = "Labeling rules. The first match wins.";
          };
        };
      });
      default = {};
      description = "Label keys. vendor, protocol, and latency are declared by the module. docs/07 §11.";
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
            type = types.nullOr types.str;
            default = null;
            description = "direct or block. Exactly one of target, labels, or failover.";
          };
          labels = mkOption {
            type = types.nullOr (types.attrsOf types.anything);
            default = null;
            description = "One selector. A set of key tests is AND. any, all, and not are the combinators.";
          };
          failover = mkOption {
            type = types.nullOr (types.listOf (types.either types.str (types.attrsOf types.anything)));
            default = null;
            description = "Ordered selectors, or direct, or block. The first non-empty selector wins.";
          };
        };
      });
      default = [];
      description = "Ordered routing rules. Unset is an empty list, and traffic follows defaultTarget. The example ships the cn, ru, and ir lists.";
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
      defaultText = "true when janus.system.region is ru, otherwise false";
      description = "Reject QUIC that did not match a direct rule, so clients fall back to TCP. The ru preset defaults this to true.";
    };
    geodata.refresh = mkOption {
      type = types.str;
      default = "weekly";
      description = "Geo data refresh interval (Nh, Nm, weekly, daily, hourly) or a five-field cron expression. The day-of-month and month are *. The day-of-week may be * or a list such as 2,4,6. 0 and 7 are Sunday.";
    };
    geodata.sources = mkOption {
      type = types.attrs;
      default = {};
      description = "Geo data sources. Empty uses the release defaults. tags.<file> is the full URL of one rule-set file and replaces the base URL for that file.";
    };
    geodata.hashes = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "sha256 for a tag that is not taken from the locked rule-set input. The image fetches that tag's URL at build. A referenced tag with neither the lock nor a hash is left for the router.";
    };
    engineSettings = mkOption {
      type = types.attrs;
      default = {};
      description = "Raw engine settings merged last. Unsupported.";
    };
  };

  config = {
    assertions =
      map (message: {
        assertion = false;
        message = message;
      }) (labels.check cfg lans)
      ++ lib.mapAttrsToList (name: sub: {
        assertion = (sub.url != null) != (sub.urlSecret != null);
        message = "janus.proxy.subscriptions.${name} must set exactly one of url or urlSecret.";
      })
      cfg.subscriptions
      ++ lib.mapAttrsToList (name: sub: {
        assertion = sub.urlSecret == null || (
          (options ? sops)
          && (config.sops.secrets ? ${sub.urlSecret})
          && (builtins.tryEval config.sops.secrets.${sub.urlSecret}.sopsFile).success
        );
        message = "janus.proxy.subscriptions.${name}.urlSecret needs sops.secrets.<name>.sopsFile.";
      })
      cfg.subscriptions
      ++ [
        (let
          err = schedule.scheduleError cfg.geodata.refresh;
        in {
          assertion = err == null;
          message =
            if err == null
            then "janus.proxy.geodata.refresh"
            else "janus.proxy.geodata.refresh: ${err}";
        })
      ]
      ++ lib.mapAttrsToList (name: sub: let
        err = schedule.scheduleError sub.refresh;
      in {
        assertion = err == null;
        message =
          if err == null
          then "janus.proxy.subscriptions.${name}.refresh"
          else "janus.proxy.subscriptions.${name}.refresh: ${err}";
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
            assertion = cfg.engine == "sing-box" || !node.tls.insecure;
            message = "janus.proxy.nodes.${name}.tls.insecure is not expressible by xray 26 (ADR-0006).";
          }
          {
            assertion = cfg.engine == "sing-box" || node.shadowsocks.plugin.name == null;
            message = "janus.proxy.nodes.${name}.shadowsocks.plugin is not expressible by xray (ADR-0006).";
          }
          {
            assertion = secretOk node.trojan.password && secretOk node.shadowsocks.password && secretOk node.hysteria2.password && secretOk node.tuic.password;
            message = "janus.proxy.nodes.${name} has an inline password. Use a file or janus.security.allowInlineSecrets.";
          }
        ]
      ) (lib.attrNames cfg.nodes)
      ++ [
        {
          assertion = cfg.egressWan == null || config.janus.network.wans ? ${cfg.egressWan};
          message = "janus.proxy.egressWan '${toString cfg.egressWan}' is not a WAN.";
        }
      ]
      ++ lib.concatMap (rule:
        map (lan: {
          assertion = config.janus.network.lans ? ${lan};
          message = "janus.proxy.rules sourceLan '${lan}' is not a LAN.";
        })
        rule.match.sourceLan)
      cfg.rules
      ++ lib.concatMap (name: let
        lan = lans.${name};
      in
        lib.concatMap (rule:
          map (src: {
            assertion = src == name;
            message = "LAN ${name} inherits a rule whose sourceLan is ${src}. Put that rule on ${src}.proxy.rules. A shared list is inherited by every LAN.";
          }) (rule.match.sourceLan or []))
        (lanRules lan)) (lib.attrNames lans)
      ++ lib.mapAttrsToList (name: lan: {
        assertion = lanMode lan != "bypass" || lan.dns.fakeIp.enable != true;
        message = "janus.network.lans.${name} is bypass and dns.fakeIp.enable is true. A bypass LAN is not intercepted, so a fake-IP has nowhere to go.";
      })
      lans
      ++ lib.mapAttrsToList (name: lan: {
        assertion = lanMode lan != "bypass" || lan.dns.remote.resolvers == null;
        message = "janus.network.lans.${name} is bypass and dns.remote.resolvers is set. A bypass LAN resolves every recursive name on the domestic resolvers.";
      })
      lans
      ++ map (view: {
        assertion = !cfg.enable || view.bootstrap != [] || !lib.any needsBootstrap view.urls;
        message = "A DoH, DoT, or DoQ hostname is configured and janus.dns.bootstrap is empty for ${view.name}. Set IP addresses for that lookup. The build does not resolve the hostname.";
      })
      bootViews
      ++ lib.concatMap (view:
        map (url: {
          assertion = !cfg.enable || dns.encryption != "require" || encryptedUrl url;
          message = "janus.dns.encryption is require, and ${view.name} uses ${url}. Use https://, tls://, or quic://. Bootstrap addresses stay plaintext.";
        })
        view.urls)
      bootViews
      ++ [
        {
          assertion = !cfg.enable || cfg.engine != "xray" || (dns.cache.size == 4096 && dns.cache.minTtl == 60);
          message = "xray 26 has no DNS cache size or minimum TTL. Leave janus.dns.cache at 4096 and 60, or use sing-box.";
        }
      ];
  };
}
