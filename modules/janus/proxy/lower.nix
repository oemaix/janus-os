# SPDX-License-Identifier: Apache-2.0
# Lower janus.proxy and janus.dns into sing-box, nftables, and ip rules.
# docs/07, ADR-0006, ADR-0008, ADR-0011, ADR-0016, ADR-0019, D-0030.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.proxy;
  dns = config.janus.dns;
  net = config.janus.network;
  janetScript = ../../../janet/janus.janet;

  ipv4ToInt = addr: let
    p = lib.splitString "." addr;
  in
    lib.foldl' (acc: o: acc * 256 + lib.toInt o) 0 p;

  shift = n:
    if n <= 0
    then 1
    else 2 * (shift (n - 1));

  formatIpv4 = n: let
    octet = shiftBy: builtins.bitAnd (n / shiftBy) 255;
  in "${toString (octet 16777216)}.${toString (octet 65536)}.${toString (octet 256)}.${toString (octet 1)}";

  cidr = addr: prefix: let
    ip = ipv4ToInt addr;
    mask = (shift prefix - 1) * (shift (32 - prefix));
  in "${formatIpv4 (builtins.bitAnd ip mask)}/${toString prefix}";

  onCalendar = s: let
    parts = lib.splitString " " s;
    pad = v:
      if v == "*"
      then "*"
      else if lib.stringLength v < 2
      then "0${v}"
      else v;
  in
    if s == "weekly" || s == "daily" || s == "hourly"
    then s
    else if lib.match "[0-9]+h" s != null
    then "00/${lib.removeSuffix "h" s}:00:00"
    else if lib.match "[0-9]+m" s != null
    then "*:0/${lib.removeSuffix "m" s}:00"
    else if
      lib.length parts
      == 5
      && builtins.elemAt parts 2 == "*"
      && builtins.elemAt parts 3 == "*"
      && builtins.elemAt parts 4 == "*"
    then "*-*-* ${pad (builtins.elemAt parts 1)}:${pad (builtins.elemAt parts 0)}:00"
    else throw "janus interval '${s}' is not Nh, Nm, weekly, daily, hourly, or a five-field cron expression with wildcards in the day fields.";

  wanIndex = lib.listToAttrs (lib.imap0 (i: n: {
    name = n;
    value = i;
  }) (lib.attrNames net.wans));
  wanTable = name: 100 + wanIndex.${name};

  proxiedLans = lib.filter (n: net.lans.${n}.proxied) (lib.attrNames net.lans);
  intercept = cfg.mode != "bypass" && proxiedLans != [];
  bridges = map (n: "br-${n}") proxiedLans;
  dnsTproxy = dns.interceptPlaintext && bridges != [];
  q = s: ''"${s}"'';

  expandRule = rule:
    rule
    // {
      match =
        rule.match
        // {
          sourceIp =
            rule.match.sourceIp
            ++ map (lan: cidr net.lans.${lan}.address net.lans.${lan}.prefixLength) rule.match.sourceLan;
        };
    };

  exceptionRules = lib.optionals (cfg.mode == "proxy-all") (map (name: {
      match.geosite = [name];
      target = "direct";
    })
    cfg.exceptions);

  model = {
    mode = cfg.mode;
    defaultTarget = cfg.defaultTarget;
    blockQuic = cfg.blockQuic;
    groups =
      lib.mapAttrs (_: g: {
        fromSubscriptions = g.fromSubscriptions;
        match = g.match;
        members = g.members;
        strategy = g.strategy;
        default = g.default;
        test = g.test;
        emptyFallback = g.emptyFallback;
      })
      cfg.groups;
    rules = exceptionRules ++ map expandRule cfg.rules;
    subscriptionNames = lib.attrNames cfg.subscriptions;
    dns = {
      carrierResolvers = dns.carrierResolvers;
      encryption = dns.encryption;
      domestic = dns.domestic;
      remote = dns.remote;
      fakeIp = dns.fakeIp;
      ipv6Answers = dns.ipv6Answers;
      hosts = dns.hosts;
      forwarders = dns.forwarders;
      bogusAnswers = dns.bogusAnswers;
    };
  };

  nodeOf = name: n: {
    name = name;
    protocol = n.protocol;
    server = n.server;
    port = n.port;
    tags = n.tags;
    tls = n.tls;
    transport = n.transport;
    vmess = n.vmess;
    vless = n.vless;
    trojan = {
      password =
        if n.trojan.passwordFile != null
        then "janus-build-check"
        else n.trojan.password;
      passwordFile = n.trojan.passwordFile;
    };
    shadowsocks = {
      method = n.shadowsocks.method;
      password =
        if n.shadowsocks.passwordFile != null
        then "janus-build-check"
        else n.shadowsocks.password;
      passwordFile = n.shadowsocks.passwordFile;
      plugin = n.shadowsocks.plugin;
    };
    hysteria2 = n.hysteria2;
    tuic = n.tuic;
  };

  manualNodes = pkgs.writeText "janus-nodes-manual.json" (builtins.toJSON (map (name: nodeOf name cfg.nodes.${name}) (lib.attrNames cfg.nodes)));

  snapshotRaw = name: sub:
    if sub.urlSecret != null || sub.url == null
    then pkgs.writeText "janus-sub-${name}-empty" ""
    else if sub.snapshot.hash != null
    then
      pkgs.fetchurl {
        url = sub.url;
        sha256 = sub.snapshot.hash;
      }
    else if sub.allowMissingAtBuild
    then pkgs.writeText "janus-sub-${name}-empty" ""
    else builtins.fetchurl {url = sub.url;};

  snapshotNodes = name: sub:
    if sub.urlSecret != null || sub.url == null || (sub.snapshot.hash == null && sub.allowMissingAtBuild)
    then pkgs.writeText "janus-sub-${name}.json" "[]"
    else
      pkgs.runCommand "janus-sub-${name}.json" {
        nativeBuildInputs = [pkgs.janet];
      } ''
        args=(
          normalize
          --format ${lib.escapeShellArg sub.format}
          --prefix ${lib.escapeShellArg name}
          --input ${snapshotRaw name sub}
          --output "$out"
        )
        ${lib.optionalString (sub.nameFilter != null) ''
          args+=(--filter-kind regex --filter-pattern ${lib.escapeShellArg sub.nameFilter})
        ''}
        janet ${janetScript} "''${args[@]}"
      '';

  builtNodes =
    pkgs.runCommand "janus-nodes-built.json" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -s 'add' ${manualNodes} ${lib.concatMapStringsSep " " (name: snapshotNodes name cfg.subscriptions.${name}) (lib.attrNames cfg.subscriptions)} > "$out"
    '';

  modelFile = pkgs.writeText "janus-proxy-model.json" (builtins.toJSON model);

  xrayAssets = pkgs.linkFarm "xray-assets" [
    {
      name = "geosite.dat";
      path = "${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat";
    }
    {
      name = "geoip.dat";
      path = "${pkgs.v2ray-geoip}/share/v2ray/geoip.dat";
    }
  ];

  engineConfig = pkgs.runCommand "janus-engine.json" ({
      nativeBuildInputs =
        [pkgs.janet]
        ++ (
          if cfg.engine == "xray"
          then [pkgs.xray]
          else [pkgs.sing-box]
        );
    }
    // lib.optionalAttrs (cfg.engine == "xray") {
      XRAY_LOCATION_ASSET = xrayAssets;
    }) ''
    janet ${janetScript} render \
      --model ${modelFile} \
      --nodes ${builtNodes} \
      --rule-set remote \
      --engine ${cfg.engine} \
      --output "$out"
    ${
      if cfg.engine == "xray"
      then ''xray run -test -c "$out"''
      else ''sing-box check -c "$out"''
    }
  '';

  geosites = lib.unique (
    lib.concatMap (rule: rule.match.geosite or []) model.rules
    ++ lib.concatMap (name:
      if lib.hasPrefix "geosite:" name
      then [(lib.removePrefix "geosite:" name)]
      else [])
    dns.domestic.domains
    ++ lib.concatMap (name:
      if lib.hasPrefix "geosite:" name
      then [(lib.removePrefix "geosite:" name)]
      else [])
    dns.fakeIp.exclude
  );
  geoips = lib.unique (lib.concatMap (rule: rule.match.geoip or []) model.rules);
  geoTags = map (n: "geosite-${n}") geosites ++ map (n: "geoip-${n}") geoips;

  sources =
    {
      geosite = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set";
      geoip = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set";
    }
    // cfg.geodata.sources;

  # Pins are the rule-set files as of 2026-10-13. geodata.hashes overrides them.
  # sing-geoip's rule-set branch has no geoip-private.srs, so that tag is compiled below.
  defaultPins = {
    geosite-private = "sha256-JgSRJD4CZuW6VD9QnKfxOwfW9MLCat4/Z13eoWYfMhM=";
    geosite-cn = "sha256-fl7aoxVpGOu3MmKfe0qz8DBAuZQEVkOPl2wgRgM/wVw=";
    geosite-geolocation-cn = "sha256-zVOuqBkm1GscCqE5rffd/u10s9aRO0oBSDspbk6K9Ng=";
  };
  pins = defaultPins // cfg.geodata.hashes;
  pinned = lib.filterAttrs (tag: _: builtins.elem tag geoTags) pins;
  fetched = lib.mapAttrs (tag: hash:
    pkgs.fetchurl {
      url = "${
        if lib.hasPrefix "geoip-" tag
        then sources.geoip
        else sources.geosite
      }/${tag}.srs";
      sha256 = hash;
    })
  pinned;
  compiled = lib.optionalAttrs (builtins.elem "geoip-private" geoTags && !(pinned ? "geoip-private")) {
    geoip-private = pkgs.runCommand "geoip-private.srs" {nativeBuildInputs = [pkgs.sing-box];} ''
      cat > source.json <<'EOF'
      {"version":2,"rules":[{"ip_cidr":["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","::1/128","fc00::/7","fe80::/10","ff00::/8"]}]}
      EOF
      sing-box rule-set compile source.json -o "$out"
    '';
  };
  geodataFiles = fetched // compiled;
  geodataDir = pkgs.linkFarm "janus-geodata" (lib.mapAttrsToList (tag: file: {
      name = "${tag}.srs";
      path = file;
    })
    geodataFiles);

  passwordFiles = lib.filterAttrs (_: path: path != null) (
    lib.mapAttrs (
      _: n:
        if n.protocol == "trojan"
        then n.trojan.passwordFile
        else if n.protocol == "shadowsocks"
        then n.shadowsocks.passwordFile
        else null
    )
    cfg.nodes
  );

  inlineUrls = lib.filterAttrs (_: sub: sub.url != null && config.janus.security.allowInlineSecrets) cfg.subscriptions;

  helper = pkgs.writeShellApplication {
    name = "janus-proxy";
    runtimeInputs = with pkgs;
      [janet curl jq iproute2 coreutils age nftables systemd gawk]
      ++ (
        if cfg.engine == "xray"
        then [xray bind]
        else [sing-box]
      );
    text =
      ''
        JANUS_SCRIPT=${janetScript}
        JANUS_ENGINE=${cfg.engine}
        JANUS_FAIL_MODE=${cfg.failMode}
        ${lib.optionalString (cfg.engine == "xray") "XRAY_LOCATION_ASSET=${xrayAssets}"}
        ${lib.optionalString (cfg.engine == "xray" && cfg.failMode == "open" && intercept) "JANUS_XRAY_NFT=/etc/janus/xray-open.nft"}
        JANUS_INTERCEPT=${
          if intercept
          then "1"
          else "0"
        }
        JANUS_DNS_TPROXY=${
          if dnsTproxy
          then "1"
          else "0"
        }
        JANUS_EGRESS_TABLE=${
          if cfg.egressWan == null
          then ""
          else toString (wanTable cfg.egressWan)
        }
      ''
      + builtins.readFile ../../../pkgs/janus-engine.sh;
  };

  subMeta =
    lib.mapAttrs (_: sub: {
      format = sub.format;
      via = sub.via;
      userAgent = sub.userAgent;
      headers = sub.headers;
      minimumNodes = sub.minimumNodes;
      nameFilter = sub.nameFilter;
      urlSecret = sub.urlSecret;
    })
    cfg.subscriptions;

  doh = [
    "1.1.1.1"
    "1.0.0.1"
    "8.8.8.8"
    "8.8.4.4"
    "9.9.9.9"
    "149.112.112.112"
    "208.67.222.222"
    "208.67.220.220"
  ];

  privateV4 = "0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4";
  privateV6 = "::1/128, fe80::/10, ff00::/8";
  fakeV6 = dns.fakeIp.v6Range;
  bridgeSet = lib.concatMapStringsSep ", " q bridges;

  markRules =
    if bridges == []
    then ""
    else ''
      iifname { ${bridgeSet} } meta l4proto { tcp, udp } th dport 53 return
      iifname { ${bridgeSet} } ip daddr { ${privateV4} } return
      iifname { ${bridgeSet} } ip6 daddr { ${privateV6} } return
      iifname { ${bridgeSet} } ip6 daddr fc00::/7 ip6 daddr != ${fakeV6} return
      ${lib.optionalString (cfg.engine != "xray") ''
        iifname { ${bridgeSet} } meta mark set 0x00004a01
      ''}
    '';

  guardRules = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
    (lib.optionalString dns.blockDoT ''
      iifname { ${bridgeSet} } meta l4proto { tcp, udp } th dport 853 reject
    '')
    (lib.optionalString dns.blockKnownDoH ''
      iifname { ${bridgeSet} } ip daddr { ${lib.concatStringsSep ", " doh} } tcp dport 443 reject
    '')
    (lib.optionalString cfg.blockQuic ''
      iifname { ${bridgeSet} } udp dport 443 reject
    '')
  ]);
in {
  options.janus.proxy.failMode = lib.mkOption {
    type = lib.types.enum ["closed" "open"];
    default = "closed";
    description = "When the engine is down, closed drops proxied LAN traffic and open sends it out the WAN (ADR-0016).";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pkgs.janet pkgs.sing-box pkgs.curl pkgs.age pkgs.jq];
    boot.kernel.sysctl = lib.mkIf intercept {
      "net.ipv4.conf.all.rp_filter" = lib.mkDefault 2;
      "net.ipv4.conf.default.rp_filter" = lib.mkDefault 2;
    };

    environment.etc =
      {
        "janus/proxy-model.json".source = modelFile;
        "janus/nodes-manual.json".source = manualNodes;
        "janus/nodes-built.json".source = builtNodes;
        "janus/engine.json".source = engineConfig;
        "janus/subscriptions.json".text = builtins.toJSON subMeta;
        "janus/group-defaults.json".text = builtins.toJSON (lib.mapAttrs (_: g: g.default) cfg.groups);
        "janus/geodata-tags.json".text = builtins.toJSON geoTags;
        "janus/geodata-sources.json".text = builtins.toJSON sources;
        "janus/dns-policy.json".text = builtins.toJSON {
          interceptPlaintext = dns.interceptPlaintext;
          ipv6Answers = dns.ipv6Answers;
          carrierResolvers = dns.carrierResolvers;
          encryption = dns.encryption;
          bogusAnswers = dns.bogusAnswers;
        };
        "janus/bin/janus-proxy".source = "${helper}/bin/janus-proxy";
        "janus/password-files.json".text = builtins.toJSON passwordFiles;
      }
      // lib.optionalAttrs (geodataFiles != {}) {
        "janus/geodata".source = geodataDir;
      }
      // lib.optionalAttrs (cfg.engine == "xray" && cfg.failMode == "open" && intercept) {
        "janus/xray-open.nft".text = ''
          table inet janus_xray {
            chain xray {
              type filter hook prerouting priority mangle; policy accept;
              ${markRules}
              iifname { ${bridgeSet} } meta mark set 0x00004a02 tproxy to :12345
            }
          }
        '';
      };

    systemd.tmpfiles.rules = [
      "d /var/lib/janus/engine 0700 root root -"
      "d /var/lib/janus/geodata 0755 root root -"
      "d /var/lib/janus/subscriptions 0700 root root -"
    ];

    systemd.services.janus-intercept = lib.mkIf (intercept || dnsTproxy) {
      description = "Fail-closed route for proxied LAN traffic";
      wantedBy = ["multi-user.target"];
      before = ["network-online.target" "janus-engine.service"];
      after = ["network-pre.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${helper}/bin/janus-proxy intercept-up";
      };
    };

    systemd.services.janus-subscription-urls = lib.mkIf (inlineUrls != {}) {
      description = "Install inline subscription URLs";
      wantedBy = ["multi-user.target"];
      before = ["janus-engine.service" "janus-proxy-refresh@.service"];
      serviceConfig.Type = "oneshot";
      script = ''
        umask 077
        mkdir -p /var/lib/janus/subscription-urls
        ${lib.concatMapStrings (name: ''
          printf '%s\n' ${lib.escapeShellArg inlineUrls.${name}.url} > /var/lib/janus/subscription-urls/${lib.escapeShellArg name}
        '') (lib.attrNames inlineUrls)}
      '';
    };

    systemd.services.janus-engine = {
      description = "Janus proxy engine";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target" "janus-intercept.service"];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "${helper}/bin/janus-proxy geodata-missing"
          "${helper}/bin/janus-proxy render"
        ];
        ExecStart =
          if cfg.engine == "xray"
          then "${pkgs.xray}/bin/xray run -c /var/lib/janus/engine/config.json"
          else "${pkgs.sing-box}/bin/sing-box run -c /var/lib/janus/engine/config.json";
        Environment = lib.optional (cfg.engine == "xray") "XRAY_LOCATION_ASSET=${xrayAssets}";
        ExecStartPost = "${helper}/bin/janus-proxy tun-up";
        ExecStopPost = "${helper}/bin/janus-proxy tun-down";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services."janus-proxy-refresh@" = {
      description = "Refresh subscription %i";
      after = ["janus-subscription-urls.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${helper}/bin/janus-proxy refresh %i";
      };
    };

    systemd.timers =
      lib.mapAttrs' (name: sub:
        lib.nameValuePair "janus-proxy-refresh-${name}" {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = onCalendar sub.refresh;
            Persistent = true;
            Unit = "janus-proxy-refresh@${name}.service";
          };
        })
      cfg.subscriptions
      // {
        janus-geodata-refresh = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = onCalendar cfg.geodata.refresh;
            Persistent = true;
            Unit = "janus-geodata-refresh.service";
          };
        };
      };

    systemd.services.janus-geodata-refresh = {
      description = "Refresh Geo rule sets";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${helper}/bin/janus-proxy geodata-refresh";
      };
    };

    janus.firewall.hooks = lib.mkIf (dns.interceptPlaintext && bridges != []) {
      preroutingRaw = ''
        iifname { ${bridgeSet} } meta l4proto tcp th dport 53 redirect to :5353
      '';
      inputExtra = ''
        tcp dport 5353 accept
        udp dport 5353 accept
      '';
    };

    networking.nftables.tables.janus_intercept = lib.mkIf intercept {
      family = "inet";
      content = ''
        chain proxied {
          type filter hook prerouting priority mangle; policy accept;
          meta mark 0x0000004a return
          fib daddr type local return
          ${markRules}
        }
        ${lib.optionalString (guardRules != "") ''
          chain guard {
            type filter hook prerouting priority -200; policy accept;
            ${guardRules}
          }
        ''}
        ${lib.optionalString (cfg.engine == "xray" && cfg.failMode == "closed") ''
          chain xray {
            type filter hook prerouting priority mangle; policy accept;
            ${markRules}
            iifname { ${bridgeSet} } meta mark set 0x00004a02 tproxy to :12345
          }
        ''}
      '';
    };

    networking.nftables.tables.janus_dns = lib.mkIf dnsTproxy {
      family = "inet";
      content = ''
        chain dns-udp {
          type filter hook prerouting priority mangle; policy accept;
          iifname { ${bridgeSet} } meta l4proto udp th dport 53 meta mark set 0x00004a02 tproxy to :5353
        }
      '';
    };

    system.build.janusEngineConfig = engineConfig;
  };
}
