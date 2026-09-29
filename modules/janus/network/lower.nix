# SPDX-License-Identifier: Apache-2.0
# Lower janus.network into networkd, pppd, and dnsmasq. docs/06 §1–9, ADR-0004, ADR-0009.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.network;
  wanNames = lib.attrNames cfg.wans;
  lanNames = lib.attrNames cfg.lans;

  portIface = name: let
    port = cfg.ports.${name};
  in
    if port.device != null
    then port.device
    else name;

  vlanNetdev = vlan: "${vlan.port}.${toString vlan.id}";

  vlanByRef = ref:
    lib.findFirst (
      n: n == ref || vlanNetdev cfg.vlans.${n} == ref
    )
    null (lib.attrNames cfg.vlans);

  resolve = name:
    if cfg.ports ? ${name}
    then portIface name
    else if vlanByRef name != null
    then vlanNetdev cfg.vlans.${vlanByRef name}
    else name;

  wanIface = name: let
    wan = cfg.wans.${name};
  in
    if wan.mode == "pppoe"
    then "ppp-${name}"
    else resolve wan.uplink;

  wanIndex = lib.listToAttrs (lib.imap0 (i: n: {
      name = n;
      value = i;
    })
    wanNames);

  wanMetric = name: let
    wan = cfg.wans.${name};
  in
    if wan.metric != null
    then wan.metric
    else if wan.role == "backup"
    then 1100 + wanIndex.${name}
    else 100 + wanIndex.${name};

  wanTable = name: 100 + wanIndex.${name};

  installDefault = name: let
    role = cfg.wans.${name}.role;
  in
    role == "default" || role == "backup";

  ulaOf = name: lan: let
    raw =
      if lan.ipv6.ula == "auto"
      then builtins.hashString "sha256" "${config.janus.system.hostName}-${name}"
      else lan.ipv6.ula;
    hex = builtins.substring 0 10 raw;
  in
    if lan.ipv6.ula == "auto"
    then "fd${builtins.substring 0 2 hex}:${builtins.substring 2 4 hex}:${builtins.substring 6 4 hex}"
    else lan.ipv6.ula;

  pdWan = lib.findFirst (n: builtins.elem cfg.wans.${n}.ipv6.mode ["dhcpv6-pd" "passthrough" "slaac"]) null wanNames;

  dhcpLanNames = lib.filter (n: cfg.lans.${n}.dhcp.enable) lanNames;

  portLink = name: port: let
    match =
      lib.optionalAttrs (port.match.path or null != null) {Path = port.match.path;}
      // lib.optionalAttrs (port.match.macAddress or null != null) {MACAddress = port.match.macAddress;};
  in
    lib.optionalAttrs (match != {}) {
      "10-port-${name}" = {
        matchConfig = match;
        linkConfig =
          {
            Name = portIface name;
          }
          // lib.optionalAttrs (port.mtu != null) {MTUBytes = toString port.mtu;}
          // lib.optionalAttrs (port.macAddress != null) {MACAddress = port.macAddress;};
      };
    };

  vlanNetdevs =
    lib.mapAttrs' (n: vlan: {
      name = "30-vlan-${n}";
      value = {
        netdevConfig = {
          Kind = "vlan";
          Name = vlanNetdev vlan;
        };
        vlanConfig.Id = vlan.id;
      };
    })
    cfg.vlans;

  parentVlans = lib.zipAttrsWith (_: vs: lib.concatLists vs) (lib.mapAttrsToList (_: vlan: {
      ${vlan.port} = [vlanNetdev vlan];
    })
    cfg.vlans);

  memberFile = lanName: member: let
    vlans =
      if cfg.ports ? ${member}
      then parentVlans.${member} or []
      else [];
  in {
    "30-member-${lanName}-${builtins.replaceStrings ["."] ["-"] member}" = {
      matchConfig.Name = resolve member;
      networkConfig =
        {Bridge = "br-${lanName}";}
        // lib.optionalAttrs (vlans != []) {VLAN = vlans;};
      bridgeConfig.Isolated = cfg.lans.${lanName}.isolation;
    };
  };

  parentFile = name: vlans:
    lib.optionalAttrs (vlans != [] && !(lib.any (lan: lib.elem name cfg.lans.${lan}.members) lanNames)) {
      "20-port-${name}" = {
        matchConfig.Name = portIface name;
        networkConfig.VLAN = vlans;
      };
    };

  wanFile = name: let
    wan = cfg.wans.${name};
    iface = resolve wan.uplink;
    v6 = wan.ipv6.mode;
    dhcp = wan.mode == "dhcp";
    both = dhcp && v6 != "disabled";
  in
    if wan.mode == "pppoe"
    then {
      "40-wan-parent-${name}" = {
        matchConfig.Name = iface;
        networkConfig = {
          LinkLocalAddressing = "ipv6";
          IPv6AcceptRA = false;
          ConfigureWithoutCarrier = true;
        };
      };
    }
    else {
      "40-wan-${name}" = {
        matchConfig.Name = iface;
        networkConfig =
          {
            IPv6AcceptRA = v6 == "slaac" || v6 == "dhcpv6-pd";
            LinkLocalAddressing = "ipv6";
            ConfigureWithoutCarrier = true;
            IPv6PrivacyExtensions = "kernel";
          }
          // lib.optionalAttrs dhcp {
            DHCP =
              if both
              then "yes"
              else "ipv4";
          }
          // lib.optionalAttrs (wan.mode == "static" && wan.static.dns != []) {DNS = wan.static.dns;}
          // lib.optionalAttrs (wan.mode == "static") {DNSDefaultRoute = false;};
        address = lib.optional (wan.mode == "static" && wan.static.address != null) "${wan.static.address}/${toString wan.static.prefixLength}";
        routes =
          lib.optional (wan.mode == "static" && installDefault name && wan.static.gateway != null) {
            Gateway = wan.static.gateway;
            Metric = wanMetric name;
          }
          ++ lib.optional (wan.mode == "static" && wan.static.gateway != null) {
            Gateway = wan.static.gateway;
            Table = wanTable name;
          };
        routingPolicyRules = lib.optional (wan.mode == "static" && wan.static.address != null) {
          From = "${wan.static.address}/32";
          Table = wanTable name;
          Priority = 10000 + wanIndex.${name};
          Family = "ipv4";
        };
        dhcpV4Config =
          lib.optionalAttrs dhcp {
            UseDNS = false;
            UseNTP = false;
            UseHostname = false;
            UseDomains = false;
            UseRoutes = installDefault name;
            RouteMetric = wanMetric name;
            SendRelease = wan.dhcp.sendRelease;
          }
          // lib.optionalAttrs (dhcp && wan.dhcp.hostname != null) {Hostname = wan.dhcp.hostname;}
          // lib.optionalAttrs (dhcp && wan.dhcp.vendorClass != null) {VendorClassIdentifier = wan.dhcp.vendorClass;}
          // lib.optionalAttrs (dhcp && wan.dhcp.clientId != null) {ClientIdentifier = wan.dhcp.clientId;};
        linkConfig = lib.optionalAttrs (wan.macAddress != null) {MACAddress = wan.macAddress;};
      };
    };

  lanFile = name: let
    lan = cfg.lans.${name};
    mode = lan.ipv6.mode;
    ula = ulaOf name lan;
  in {
    "50-lan-${name}" = {
      matchConfig.Name = "br-${name}";
      address =
        ["${lan.address}/${toString lan.prefixLength}"]
        ++ lib.optional (mode == "ula-only") "${ula}::1/64";
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
        ConfigureWithoutCarrier = true;
        IPv6SendRA = mode != "disabled";
        IPv6PrivacyExtensions = "kernel";
        LinkLocalAddressing = "ipv6";
        DHCPPrefixDelegation = mode == "delegated" && pdWan != null;
      };
      ipv6SendRAConfig =
        lib.optionalAttrs (mode == "ula-only") {
          RouterLifetimeSec = 0;
          EmitDNS = true;
          DNS = "${ula}::1";
        }
        // lib.optionalAttrs (mode == "delegated") {
          EmitDNS = true;
          DNS = lan.address;
        };
      dhcpPrefixDelegationConfig = lib.optionalAttrs (mode == "delegated" && pdWan != null) {
        UplinkInterface = wanIface pdWan;
        SubnetId = wanIndex.${pdWan} + 1;
        Announce = true;
        Assign = true;
      };
    };
  };

  lanNetdev = name: {
    "50-lan-${name}" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-${name}";
      };
    };
  };

  pppSecrets = lib.concatMapStrings (name: let
    wan = cfg.wans.${name};
  in
    lib.optionalString (wan.mode == "pppoe" && wan.pppoe.password != null) ''
      ${wan.pppoe.username} * ${wan.pppoe.password} *
    '')
  wanNames;

  pppFromSecret = name: cfg.wans.${name}.pppoe.passwordFile != null || cfg.wans.${name}.pppoe.passwordSecret != null;

  pppPeerBody = name: ''
    ifname ppp-${name}
    noauth
    hide-password
    persist
    maxfail 0
    nodetach
    nodefaultroute
    ${lib.optionalString (cfg.wans.${name}.pppoe.mtu != null) "mtu ${toString cfg.wans.${name}.pppoe.mtu}"}
    ${lib.optionalString (cfg.wans.${name}.pppoe.mru != null) "mru ${toString cfg.wans.${name}.pppoe.mru}"}
    ${lib.optionalString (cfg.wans.${name}.pppoe.lcpEchoInterval != null) "lcp-echo-interval ${toString cfg.wans.${name}.pppoe.lcpEchoInterval}"}
    ${lib.optionalString (cfg.wans.${name}.pppoe.lcpEchoFailure != null) "lcp-echo-failure ${toString cfg.wans.${name}.pppoe.lcpEchoFailure}"}
    ${lib.optionalString cfg.wans.${name}.pppoe.ipv6 "+ipv6"}
    ${lib.optionalString (cfg.wans.${name}.pppoe.serviceName != null) "rp_pppoe_service ${cfg.wans.${name}.pppoe.serviceName}"}
  '';

  pppPrepare = name: let
    wan = cfg.wans.${name};
    ppp = wan.pppoe;
    src =
      if ppp.passwordFile != null
      then ppp.passwordFile
      else config.sops.secrets.${ppp.passwordSecret}.path;
  in
    pkgs.writeShellScript "janus-pppoe-prep-${name}" ''
      set -eu
      install -d -m 0700 /run/janus/ppp
      src=${lib.escapeShellArg src}
      ${
        if ppp.passwordSecret != null
        then ''
          user=$(sed -n 's/^username:[[:space:]]*//p' "$src" | head -n 1)
          pass=$(sed -n 's/^password:[[:space:]]*//p' "$src" | head -n 1)
          user=''${user#\"}; user=''${user%\"}
          pass=''${pass#\"}; pass=''${pass%\"}
        ''
        else ''
          user=${lib.escapeShellArg ppp.username}
          pass=$(tr -d '\n' < "$src")
        ''
      }
      if [ -z "$user" ] || [ -z "$pass" ]; then
        echo "janus: PPPoE credentials for ${name} are empty" >&2
        exit 1
      fi
      quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
      umask 077
      {
        printf 'plugin %s\n' ${lib.escapeShellArg "${pkgs.rp-pppoe}/lib/rp-pppoe.so"}
        printf 'nic-%s\n' ${lib.escapeShellArg (resolve wan.uplink)}
        printf 'user "%s"\n' "$(quote "$user")"
        printf 'password "%s"\n' "$(quote "$pass")"
        cat << 'EOF'
      ${pppPeerBody name}
      EOF
      } > /run/janus/ppp/janus-${name}
    '';

  pppService = name: let
    wan = cfg.wans.${name};
    fromSecret = pppFromSecret name;
  in
    lib.optionalAttrs (wan.mode == "pppoe") {
      "janus-pppoe-${name}" = {
        description = "PPPoE WAN ${name}";
        after =
          ["systemd-networkd.service" "network-pre.target"]
          ++ lib.optional (wan.pppoe.passwordSecret != null) "sops-install-secrets.service";
        wants = ["network-online.target"];
        requires = lib.optional (wan.pppoe.passwordSecret != null) "sops-install-secrets.service";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = lib.optional fromSecret (pppPrepare name);
          ExecStart =
            if fromSecret
            then "${pkgs.ppp}/sbin/pppd file /run/janus/ppp/janus-${name}"
            else "${pkgs.ppp}/sbin/pppd call janus-${name}";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    };

  policyScript = pkgs.writeShellScript "janus-wan-policy" ''
    set -eu
    mkdir -p /run/janus/wan
    ${lib.concatMapStrings (name: let
        wan = cfg.wans.${name};
      in ''
        name=${lib.escapeShellArg name}
        iface=${lib.escapeShellArg (wanIface name)}
        table=${toString (wanTable name)}
        pri=${toString (10000 + wanIndex.${name})}
        mkdir -p "/run/janus/wan/$name"
        ${
          if wan.mode == "static"
          then ''
            printf '%s\n' ${lib.escapeShellArgs wan.static.dns} > "/run/janus/wan/$name/dns"
          ''
          else ''
            if [ -e "/sys/class/net/$iface/ifindex" ]; then
              idx=$(cat "/sys/class/net/$iface/ifindex")
              if [ -f "/run/systemd/netif/leases/$idx" ]; then
                sed -n 's/^DNS=//p' "/run/systemd/netif/leases/$idx" > "/run/janus/wan/$name/dns"
              fi
            fi
          ''
        }
        if [ -e "/sys/class/net/$iface" ]; then
          addr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}')
          addr=''${addr%%/*}
          gw=$(ip -4 route show default dev "$iface" | awk '{print $3; exit}')
          if [ -n "$addr" ]; then
            ip rule del from "$addr" lookup "$table" priority "$pri" 2>/dev/null || true
            ip rule add from "$addr" lookup "$table" priority "$pri"
          fi
          if [ -n "$gw" ]; then
            ip route replace default via "$gw" dev "$iface" table "$table"
          fi
        fi
      '')
      wanNames}
  '';
in {
  config = lib.mkMerge [
    {
      # Name stable jacks even before a WAN or LAN uses them.
      systemd.network.links = lib.mkMerge (lib.mapAttrsToList portLink cfg.ports);
    }
    (lib.mkIf (cfg.wans != {} || cfg.lans != {}) {
      networking.useNetworkd = true;
      networking.useDHCP = false;
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = lib.mkDefault 1;
        "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      };

      systemd.network.netdevs = lib.mkMerge [
        vlanNetdevs
        (lib.mkMerge (map lanNetdev lanNames))
      ];
      systemd.network.networks = lib.mkMerge [
        (lib.mkMerge (lib.mapAttrsToList parentFile parentVlans))
        (lib.mkMerge (map wanFile wanNames))
        (lib.mkMerge (lib.concatMap (lan: map (memberFile lan) cfg.lans.${lan}.members) lanNames))
        (lib.mkMerge (map lanFile lanNames))
      ];
      systemd.network.config.routeTables = lib.listToAttrs (map (n: {
          name = "janus-${n}";
          value = wanTable n;
        })
        wanNames);

      services.dnsmasq = lib.mkIf (dhcpLanNames != []) {
        enable = true;
        settings = {
          port = 0;
          bind-interfaces = true;
          interface = map (n: "br-${n}") dhcpLanNames;
          dhcp-leasefile = "/var/lib/janus/leases/dnsmasq.leases";
          dhcp-range = map (n: let
            lan = cfg.lans.${n};
          in "${lan.dhcp.rangeStart},${lan.dhcp.rangeEnd},${lan.dhcp.leaseTime}")
          dhcpLanNames;
          dhcp-host = lib.concatMap (n:
            lib.mapAttrsToList (host: lease: "${lease.mac},${lease.ip},${host}") cfg.lans.${n}.dhcp.staticLeases)
          dhcpLanNames;
        };
      };

      environment.etc = lib.mkMerge (
        map (name: let
          wan = cfg.wans.${name};
        in
          lib.optionalAttrs (wan.mode == "pppoe" && !pppFromSecret name) {
            "ppp/peers/janus-${name}".source = pkgs.writeText "peer-${name}" ''
              plugin ${pkgs.rp-pppoe}/lib/rp-pppoe.so
              nic-${resolve wan.uplink}
              user ${wan.pppoe.username}
              ${pppPeerBody name}
            '';
          })
        wanNames
        ++ [
          (lib.optionalAttrs (pppSecrets != "") {
            "ppp/chap-secrets" = {
              mode = "0600";
              text = pppSecrets;
            };
          })
        ]
      );

      systemd.services = lib.mkMerge [
        (lib.mkMerge (map pppService wanNames))
        (lib.mkIf (wanNames != []) {
          janus-wan-policy = {
            description = "Record WAN DNS and reply-path routes";
            after = ["systemd-networkd.service" "network-online.target"];
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = policyScript;
            };
          };
        })
      ];

      systemd.timers.janus-wan-policy = lib.mkIf (wanNames != []) {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "10s";
          OnUnitActiveSec = "15s";
        };
      };

      systemd.tmpfiles.rules = ["d /var/lib/janus/leases 0755 root root -"];
    })
  ];
}
