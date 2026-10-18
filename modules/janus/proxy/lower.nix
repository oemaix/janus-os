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

  onCalendar = (import ./schedule.nix {inherit lib;}).onCalendar;

  wanIndex = lib.listToAttrs (lib.imap0 (i: n: {
    name = n;
    value = i;
  }) (lib.attrNames net.wans));
  wanTable = name: 100 + wanIndex.${name};

  pick = local: parent:
    if local == null
    then parent
    else local;

  normMatch = match: {
    domains = match.domains or [];
    domainSuffix = match.domainSuffix or [];
    geosite = match.geosite or [];
    geoip = match.geoip or [];
    ipCidr = match.ipCidr or [];
    port = match.port or [];
    protocol = match.protocol or null;
    sourceLan = match.sourceLan or [];
    sourceIp = match.sourceIp or [];
  };

  normRule = rule: {
    match = normMatch (rule.match or {});
    target = rule.target;
  };

  leaseHosts = lanName: lan:
    lib.mapAttrs' (host: lease: {
      name = "${host}.${lan.domain}";
      value = lease.ip;
    })
    lan.dhcp.staticLeases;

  lanView = name: lan: let
    mode =
      if lan.proxy.mode == null
      then cfg.mode
      else lan.proxy.mode;
    rules =
      if lan.proxy.rules == null
      then cfg.rules
      else map normRule lan.proxy.rules;
    exceptions =
      if lan.proxy.exceptions == null
      then cfg.exceptions
      else lan.proxy.exceptions;
    exceptionRules = lib.optionals (mode == "proxy-all") (map (tag: {
        match = normMatch {geosite = [tag];};
        target = "direct";
      })
      exceptions);
  in {
    inherit name mode;
    cidr = cidr lan.address lan.prefixLength;
    address = lan.address;
    inbound = "dns-lan-${name}";
    defaultTarget =
      if lan.proxy.defaultTarget == null
      then cfg.defaultTarget
      else lan.proxy.defaultTarget;
    rules = map expandRule (exceptionRules ++ rules);
    dns = {
      recursive = pick lan.dns.recursive dns.recursive;
      domestic = {
        resolvers = pick lan.dns.domestic.resolvers dns.domestic.resolvers;
        domains = pick lan.dns.domestic.domains dns.domestic.domains;
      };
      remote = {
        resolvers = pick lan.dns.remote.resolvers dns.remote.resolvers;
        via = pick lan.dns.remote.via dns.remote.via;
      };
      fakeIp = {
        enable = pick lan.dns.fakeIp.enable dns.fakeIp.enable;
        v4Range = pick lan.dns.fakeIp.v4Range dns.fakeIp.v4Range;
        v6Range = pick lan.dns.fakeIp.v6Range dns.fakeIp.v6Range;
        exclude = pick lan.dns.fakeIp.exclude dns.fakeIp.exclude;
      };
      ipv6Answers = pick lan.dns.ipv6Answers dns.ipv6Answers;
      hosts = dns.hosts // (pick lan.dns.hosts {}) // (leaseHosts name lan);
      forwarders = pick lan.dns.forwarders dns.forwarders;
      bootstrap = pick lan.dns.bootstrap dns.bootstrap;
    };
  };

  lanViews = lib.mapAttrsToList lanView net.lans;
  proxiedLans = lib.filter (n: net.lans.${n}.internal.intercept) (lib.attrNames net.lans);
  intercept = proxiedLans != [];
  bridges = map (n: "br-${n}") proxiedLans;
  dnsBridges = map (n: "br-${n}") (lib.attrNames net.lans);
  dnsTproxy = dns.interceptPlaintext && dnsBridges != [];
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
    rules = map expandRule cfg.rules;
    lans = lanViews;
    subscriptionNames = lib.attrNames enabledSubscriptions;
    engineSettings = cfg.engineSettings;
    autoGroup = cfg.groupsAuto;
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
      bootstrap = dns.bootstrap;
      recursive = dns.recursive;
      cache = {
        size = dns.cache.size;
        minTtl = dns.cache.minTtl;
      };
    };
    geodataSources = {
      inherit (sources) geosite geoip tags;
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
      jq -s 'add' ${manualNodes} ${lib.concatMapStringsSep " " (name: snapshotNodes name enabledSubscriptions.${name}) (lib.attrNames enabledSubscriptions)} > "$out"
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

  ruleGeosite = rules: lib.concatMap (rule: rule.match.geosite or []) rules;
  geoNames = names:
    lib.concatMap (name:
      if lib.hasPrefix "geosite:" name
      then [(lib.removePrefix "geosite:" name)]
      else [])
    names;
  viewRules = lib.concatMap (view: view.rules) lanViews;
  geosites = lib.unique (
    ruleGeosite model.rules
    ++ ruleGeosite viewRules
    ++ geoNames dns.domestic.domains
    ++ geoNames dns.fakeIp.exclude
    ++ lib.concatMap (view: geoNames view.dns.domestic.domains ++ geoNames view.dns.fakeIp.exclude) lanViews
  );
  geoips = lib.unique (
    lib.concatMap (rule: rule.match.geoip or []) model.rules
    ++ lib.concatMap (rule: rule.match.geoip or []) viewRules
  );
  geoTags = map (n: "geosite-${n}") geosites ++ map (n: "geoip-${n}") geoips;

  userSources = cfg.geodata.sources;
  sources =
    {
      geosite = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set";
      geoip = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set";
    }
    // removeAttrs userSources ["tags"]
    // {
      tags =
        {
          geosite-ir = "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs";
        }
        // (userSources.tags or {});
    };

  tagUrl = tag:
    if sources.tags ? ${tag}
    then sources.tags.${tag}
    else "${
      if lib.hasPrefix "geoip-" tag
      then sources.geoip
      else sources.geosite
    }/${tag}.srs";

  # Pins are the rule-set files as of 2026-10-13, plus the preset tags
  # measured on 2026-10-16 (docs/21). geodata.hashes overrides them.
  # sing-geoip's rule-set branch has no geoip-private.srs, so that tag is compiled below.
  defaultPins = {
    geosite-private = "sha256-JgSRJD4CZuW6VD9QnKfxOwfW9MLCat4/Z13eoWYfMhM=";
    geosite-cn = "sha256-h/MgbEJy0bkWvszzTLMPrerlFiZND0Ir5RhxWvLjKYA=";
    geosite-geolocation-cn = "sha256-nZ1yZRBVD3BBt9GhILFiOF1RW8KUhHQpHCdGko4W70M=";
    geosite-category-ads-all = "sha256-hOLteWF6SSyxra8ovwxZoaQq+FSrk1YFuoTg3ro4bIg=";
    geosite-category-ru = "sha256-kOXxTaBTSrqg/R8PoL6JAs9RWtW/POph7otEJO7JmoQ=";
    geosite-ir = "sha256-SuD3qQ/D8Vau+PKihJU3LOuuv4vrNch2+xcF+nhHb4I=";
    geoip-cn = "sha256-ga2lyv2dgxrcSHdvKc3+VclxPZKHyu753pJe8w9mzOQ=";
    geoip-ru = "sha256-vcpc20TNzwlAAB5ZUjhoIqb0/6iyyO6gA0Cqb1hcf50=";
    geoip-ir = "sha256-Q6AiIGYZPBTzQ8hV29j2djNRFsBAfEtGTeXz7SIemxc=";
  };
  pins = defaultPins // cfg.geodata.hashes;
  pinned = lib.filterAttrs (tag: _: builtins.elem tag geoTags) pins;
  fetched = lib.mapAttrs (tag: hash:
    pkgs.fetchurl {
      url = tagUrl tag;
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

  enabledSubscriptions = lib.filterAttrs (_: sub: sub.enable) cfg.subscriptions;

  secretSubscriptions = lib.filterAttrs (_: sub: sub.urlSecret != null) enabledSubscriptions;

  inlineUrls = lib.filterAttrs (_: sub: sub.url != null && config.janus.security.allowInlineSecrets) enabledSubscriptions;

  waitClock = pkgs.writeShellScript "janus-wait-clock" ''
    ${pkgs.coreutils}/bin/timeout 90 ${pkgs.systemd}/bin/systemd-time-wait-sync || true
  '';

  helper = pkgs.writeShellApplication {
    name = "janus-proxy";
    runtimeInputs = with pkgs;
      [janet curl jq iproute2 coreutils nftables systemd gawk]
      ++ (
        if cfg.engine == "xray"
        then [xray bind]
        else [sing-box]
      );
    text =
      ''
        JANUS_SCRIPT=${janetScript}
        JANUS_ENGINE=${cfg.engine}
        JANUS_DIG=${pkgs.bind}/bin/dig
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
    enabledSubscriptions;

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
  dnsBridgeSet = lib.concatMapStringsSep ", " q dnsBridges;

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
    (lib.optionalString (dns.blockDoT && dnsBridgeSet != "") ''
      iifname { ${dnsBridgeSet} } meta l4proto { tcp, udp } th dport 853 reject
    '')
    (lib.optionalString (dns.blockKnownDoH && dnsBridgeSet != "") ''
      iifname { ${dnsBridgeSet} } ip daddr { ${lib.concatStringsSep ", " doh} } tcp dport 443 reject
    '')
  ]);

  xrayNameOnly = rule: let
    m = rule.match or {};
  in
    (
      (m.domains or [])
      != []
      || (m.domainSuffix or []) != []
      || (m.geosite or []) != []
    )
    && (m.geoip or []) == []
    && (m.ipCidr or []) == []
    && (m.port or []) == []
    && (m.protocol or null) == null;

  xrayDnsKey = view: {
    inherit (view) mode defaultTarget;
    dns = lib.removeAttrs view.dns ["hosts"];
    nameRules = map (rule: {
      domains = rule.match.domains or [];
      domainSuffix = rule.match.domainSuffix or [];
      geosite = rule.match.geosite or [];
      inherit (rule) target;
    }) (lib.filter xrayNameOnly view.rules);
  };
in {
  options.janus.proxy.failMode = lib.mkOption {
    type = lib.types.enum ["closed" "open"];
    default = "closed";
    description = "When the engine is down, closed drops proxied LAN traffic and open sends it out the WAN (ADR-0016).";
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.optionals (cfg.engine == "xray" && lib.length lanViews > 1) (
        let
          head = builtins.head lanViews;
        in
          map (view: {
            assertion = xrayDnsKey view == xrayDnsKey head;
            message = "janus.network.lans.${view.name} does not share a DNS policy with ${head.name}. xray 26 has one DNS module and matches names, not sources.";
          })
          lanViews
      )
      ++ lib.optionals (cfg.engine == "xray") (
        lib.concatMap (a:
          lib.concatMap (b:
            lib.concatMap (name:
              lib.optional (a.dns.hosts ? ${name} && b.dns.hosts ? ${name} && a.dns.hosts.${name} != b.dns.hosts.${name}) {
                assertion = false;
                message = "xray has one hosts table, and ${name} is ${a.dns.hosts.${name}} on ${a.name} and ${b.dns.hosts.${name}} on ${b.name}.";
              }) (lib.attrNames a.dns.hosts))
          lanViews)
        lanViews
      );
    environment.systemPackages = [pkgs.janet pkgs.sing-box pkgs.curl pkgs.jq pkgs.bind];
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
          domesticProbe = dns.domestic.probe;
          fakeIpV4 = dns.fakeIp.v4Range;
          lans =
            map (view: {
              name = view.name;
              address = view.address;
              mode = view.mode;
              recursive = view.dns.recursive;
              ipv6Answers = view.dns.ipv6Answers;
              fakeIp =
                if view.dns.fakeIp.enable == false
                then false
                else if view.dns.fakeIp.enable == true
                then view.mode != "bypass"
                else view.mode != "bypass";
            })
            lanViews;
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

    users.users.janus-engine = {
      isSystemUser = true;
      group = "janus-engine";
    };
    users.groups.janus-engine = {};

    systemd.tmpfiles.rules = [
      "d /var/lib/janus/engine 2750 root janus-engine -"
      "d /var/lib/janus/geodata 0755 root root -"
      "d /var/lib/janus/subscriptions 0700 root root -"
    ];

    systemd.services.janus-intercept = lib.mkIf (intercept || dnsTproxy) {
      description = "Fail-closed route for proxied LAN traffic";
      wantedBy = ["multi-user.target"];
      before = ["network-online.target" "janus-engine.service"];
      # After networkd: it reconfigures interfaces at start and drops
      # policy-routing rules installed before it.
      after = ["network-pre.target" "systemd-networkd.service"];
      wants = ["systemd-networkd.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${helper}/bin/janus-proxy intercept-up";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.services.janus-subscription-urls = lib.mkIf (inlineUrls != {}) {
      description = "Install inline subscription URLs";
      wantedBy = ["multi-user.target"];
      before = ["janus-engine.service" "janus-proxy-refresh@.service"];
      serviceConfig = {
        Type = "oneshot";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus";
      };
      script = ''
        umask 077
        mkdir -p /var/lib/janus/subscription-urls
        ${lib.concatMapStrings (name: ''
          printf '%s\n' ${lib.escapeShellArg inlineUrls.${name}.url} > /var/lib/janus/subscription-urls/${lib.escapeShellArg name}
        '') (lib.attrNames inlineUrls)}
      '';
    };

    systemd.services.janus-engine-prepare = {
      description = "Render the proxy engine configuration";
      wantedBy = ["multi-user.target"];
      before = ["janus-engine.service"];
      after = ["network-pre.target" "janus-subscription-urls.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus";
        ExecStart = [
          waitClock
          "${helper}/bin/janus-proxy geodata-missing"
          "${helper}/bin/janus-proxy render"
        ];
      };
    };

    systemd.services.janus-engine = {
      description = "Janus proxy engine";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target" "janus-intercept.service" "janus-engine-prepare.service"];
      requires = ["janus-engine-prepare.service"];
      serviceConfig = {
        Type = "simple";
        User = "janus-engine";
        Group = "janus-engine";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW";
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW";
        DeviceAllow = "/dev/net/tun rw";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = "/var/lib/janus/engine";
        RestrictAddressFamilies = "AF_INET AF_INET6 AF_NETLINK AF_UNIX";
        SystemCallFilter = "@system-service @network-io";
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
      after =
        ["janus-subscription-urls.service"]
        ++ lib.optional (secretSubscriptions != {}) "sops-install-secrets.service";
      wants = lib.optional (secretSubscriptions != {}) "sops-install-secrets.service";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${helper}/bin/janus-proxy refresh %i";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus";
      };
    };

    systemd.timers =
      lib.mapAttrs' (name: sub:
        lib.nameValuePair "janus-proxy-refresh-${name}" {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = onCalendar sub.refresh;
            Persistent = true;
            RandomizedDelaySec = "10min";
            Unit = "janus-proxy-refresh@${name}.service";
          };
        })
      enabledSubscriptions
      // {
        janus-geodata-refresh = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = onCalendar cfg.geodata.refresh;
            Persistent = true;
            RandomizedDelaySec = "10min";
            Unit = "janus-geodata-refresh.service";
          };
        };
      };

    systemd.services.janus-geodata-refresh = {
      description = "Refresh Geo rule sets";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${helper}/bin/janus-proxy geodata-refresh";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus";
      };
    };

    janus.firewall.hooks = lib.mkMerge [
      # Proxied LAN traffic is policy-routed to the engine tun, which
      # matches no zone pair, so the filter hook would drop it (policy
      # drop). Let the marked flows reach tun0; replies are already
      # covered by the established rule.
      (lib.mkIf intercept {
        forwardExtra = ''
          iifname { ${bridgeSet} } oifname "tun0" accept
        '';
      })
      (lib.mkIf (dns.interceptPlaintext && dnsBridges != []) {
        preroutingRaw = ''
          iifname { ${dnsBridgeSet} } meta l4proto tcp th dport 53 redirect to :5353
        '';
        inputExtra = ''
          tcp dport 5353 accept
          udp dport 5353 accept
        '';
      })
    ];

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
          iifname { ${dnsBridgeSet} } meta l4proto udp th dport 53 meta mark set 0x00004a02 tproxy to :5353
        }
      '';
    };

    system.build.janusEngineConfig = engineConfig;
  };
}
