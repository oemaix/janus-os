# SPDX-License-Identifier: Apache-2.0
# janus.network option types and structural assertions. docs/06, docs/08 §4.
# Lowering into networkd, pppd, and dnsmasq is phase 1.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.janus.network;

  ipv4ToInt = addr: let
    p = lib.splitString "." addr;
  in
    if builtins.length p != 4
    then null
    else lib.foldl' (acc: o: acc * 256 + lib.toInt o) 0 p;

  shift = n:
    if n <= 0
    then 1
    else 2 * (shift (n - 1));

  prefixMask = prefix: let
    host = 32 - prefix;
  in
    (shift prefix - 1) * (shift host);

  overlap = a: b: let
    shorter =
      if a.prefix < b.prefix
      then a
      else b;
    mask = prefixMask shorter.prefix;
  in
    builtins.bitAnd a.ip mask == builtins.bitAnd b.ip mask;

  lanSubnet = lan: let
    ip = ipv4ToInt lan.address;
  in
    if ip == null
    then null
    else {
      inherit ip;
      inherit (lan) prefixLength;
      prefix = lan.prefixLength;
    };

  linkNames =
    lib.attrNames cfg.ports
    ++ lib.attrNames cfg.vlans
    ++ lib.attrNames cfg.wifi
    ++ lib.attrNames config.janus.hardware.peripherals
    ++ lib.mapAttrsToList (n: v: "${v.port}.${toString v.id}") cfg.vlans
    ++ map (n: "port:${n}") (lib.attrNames cfg.ports)
    ++ map (n: "vlan:${n}") (lib.attrNames cfg.vlans);

  known = name: lib.elem name linkNames;
in {
  options.janus.network = {
    ports = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          device = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Kernel interface name from the board profile, such as eth0.";
          };
          match = mkOption {
            type = types.attrs;
            default = {};
            description = "Stable match (MAC, path, or USB id) when the kernel name is not stable.";
          };
          mtu = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Interface MTU. Null keeps the driver default.";
          };
          macAddress = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Override or clone a MAC address.";
          };
        };
      });
      default = {};
      description = "Physical ports by stable name. docs/06 §2.";
    };

    vlans = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          port = mkOption {
            type = types.str;
            description = "Parent port name.";
          };
          id = mkOption {
            type = types.ints.between 1 4094;
            description = "802.1Q VLAN id.";
          };
        };
      });
      default = {};
      description = "Named VLANs. A member may also use port.id. docs/06 §3.";
    };

    wans = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          uplink = mkOption {
            type = types.str;
            description = "Port, VLAN, or peripheral this WAN attaches to.";
          };
          mode = mkOption {
            type = types.enum ["dhcp" "static" "pppoe" "wwan"];
            description = "Addressing mode.";
          };
          role = mkOption {
            type = types.enum ["default" "backup" "custom" "iptv"];
            default = "default";
            description = "Routing role. iptv is specified and deferred until after 1.0.";
          };
          metric = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Route metric. Null assigns 100 plus the WAN index.";
          };
          dhcp = mkOption {
            type = types.submodule {
              options = {
                vendorClass = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "DHCP vendor class.";
                };
                clientId = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "DHCP client id.";
                };
                requestOptions = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "DHCP options to request.";
                };
                hostname = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Hostname sent with DHCP.";
                };
                sendRelease = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Send DHCPRELEASE when the WAN stops.";
                };
              };
            };
            default = {};
            description = "DHCP client options.";
          };
          static = mkOption {
            type = types.submodule {
              options = {
                address = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Static IPv4 address.";
                };
                prefixLength = mkOption {
                  type = types.ints.between 0 32;
                  default = 24;
                  description = "Prefix length.";
                };
                gateway = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "IPv4 gateway.";
                };
                dns = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "DNS servers learned as data, not installed into resolv.conf.";
                };
              };
            };
            default = {};
            description = "Static addressing.";
          };
          pppoe = mkOption {
            type = types.submodule {
              options = {
                username = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "PPPoE username.";
                };
                password = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Inline password. Requires janus.security.allowInlineSecrets.";
                };
                passwordFile = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Password file created on the board.";
                };
                passwordSecret = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "sops secret name holding the PPPoE username and password.";
                };
                serviceName = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "PPPoE service name.";
                };
                mtu = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "PPPoE MTU.";
                };
                mru = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "PPPoE MRU.";
                };
                lcpEchoInterval = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "LCP echo interval in seconds.";
                };
                lcpEchoFailure = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "LCP echo failures before the link is dropped.";
                };
                ipv6 = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable IPv6CP.";
                };
              };
            };
            default = {};
            description = "PPPoE settings.";
          };
          wwan = mkOption {
            type = types.submodule {
              options = {
                peripheral = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Name of the wwan peripheral.";
                };
                apn = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "APN. Used for qmi and mbim. Ethernet modes ignore it.";
                };
                pin = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "SIM PIN. Requires janus.security.allowInlineSecrets.";
                };
                auth = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "WWAN authentication.";
                };
              };
            };
            default = {};
            description = "WWAN uplink. Bring-up is a later phase.";
          };
          ipv6.mode = mkOption {
            type = types.enum ["disabled" "slaac" "dhcpv6-pd" "static" "passthrough"];
            default = "disabled";
            description = "IPv6 mode on this WAN.";
          };
          ipv6.prefixDelegationHint = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional prefix hint for DHCPv6-PD.";
          };
          healthCheck.enable = mkOption {
            type = types.bool;
            default = false;
            description = "Probe this WAN. Defaults on for a backup WAN and when more than one default WAN exists.";
          };
          healthCheck.targets = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Probe targets.";
          };
          healthCheck.interval = mkOption {
            type = types.str;
            default = "10s";
            description = "Probe interval.";
          };
          healthCheck.failures = mkOption {
            type = types.int;
            default = 3;
            description = "Consecutive failures before the WAN is marked down.";
          };
          macAddress = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC clone for a carrier lock.";
          };
        };
      }));
      default = {};
      description = "WAN uplinks. docs/06 §4.";
    };

    lans = mkOption {
      type = types.attrsOf (types.submodule ({
        name,
        config,
        ...
      }: {
        options = {
          members = mkOption {
            type = types.listOf types.str;
            description = "Ports, VLANs, or Wi-Fi APs in this bridge.";
          };
          address = mkOption {
            type = types.str;
            description = "LAN IPv4 address.";
          };
          prefixLength = mkOption {
            type = types.ints.between 0 32;
            description = "LAN prefix length.";
          };
          domain = mkOption {
            type = types.str;
            default = "lan";
            description = "DNS domain for this LAN.";
          };
          dhcp.enable = mkOption {
            type = types.bool;
            default = true;
            description = "DHCPv4 server.";
          };
          dhcp.rangeStart = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "First address of the pool. Null uses the .100 address.";
          };
          dhcp.rangeEnd = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Last address of the pool. Null uses the .199 address.";
          };
          dhcp.leaseTime = mkOption {
            type = types.str;
            default = "12h";
            description = "DHCP lease time.";
          };
          dhcp.staticLeases = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                mac = mkOption {
                  type = types.str;
                  description = "Client MAC.";
                };
                ip = mkOption {
                  type = types.str;
                  description = "Reserved address.";
                };
              };
            });
            default = {};
            description = "Static leases by hostname.";
          };
          ipv6.mode = mkOption {
            type = types.enum ["disabled" "ula-only" "delegated"];
            default = "disabled";
            description = "LAN IPv6. The bypass traffic mode defaults this to delegated.";
          };
          zone = mkOption {
            type = types.str;
            default = name;
            description = "Firewall zone. Defaults to the LAN name.";
          };
          proxied = mkOption {
            type = types.bool;
            default = true;
            description = "Subject this LAN to the traffic mode.";
          };
          nat.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Masquerade this LAN toward WAN.";
          };
          nat.hairpin = mkOption {
            type = types.bool;
            default = true;
            description = "NAT reflection for port forwards.";
          };
          isolation = mkOption {
            type = types.bool;
            default = false;
            description = "Bridge port isolation.";
          };
        };
        config = let
          parts = lib.splitString "." config.address;
          prefix = lib.concatStringsSep "." (lib.take 3 parts);
        in {
          dhcp.rangeStart = lib.mkIf (config.dhcp.enable && builtins.length parts == 4) (lib.mkDefault "${prefix}.100");
          dhcp.rangeEnd = lib.mkIf (config.dhcp.enable && builtins.length parts == 4) (lib.mkDefault "${prefix}.199");
        };
      }));
      default = {};
      description = "LAN bridges. docs/06 §5.";
    };

    wifi = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          peripheral = mkOption {
            type = types.str;
            description = "Wi-Fi peripheral name.";
          };
          ssid = mkOption {
            type = types.str;
            description = "Access-point SSID. Not a secret.";
          };
          passphrase = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Inline passphrase. Requires janus.security.allowInlineSecrets.";
          };
          passphraseFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Passphrase file on the state partition.";
          };
          passphraseSecret = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "sops secret name.";
          };
          band = mkOption {
            type = types.enum ["2g" "5g"];
            default = "2g";
            description = "Band.";
          };
          channel = mkOption {
            type = types.either types.int (types.enum ["auto"]);
            default = "auto";
            description = "Channel, or auto.";
          };
          security = mkOption {
            type = types.enum ["wpa2" "wpa3" "wpa2+3"];
            default = "wpa2";
            description = "Wi-Fi security.";
          };
          lan = mkOption {
            type = types.str;
            default = "lan";
            description = "LAN this AP joins.";
          };
          hidden = mkOption {
            type = types.bool;
            default = false;
            description = "Hide the SSID.";
          };
        };
      });
      default = {};
      description = "Wi-Fi access points. docs/06 §11.";
    };

    igmpProxy = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "IGMP proxy. Deferred until after 1.0.";
          };
          upstream = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Upstream WAN name.";
          };
          downstream = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Downstream LAN names.";
          };
        };
      };
      default = {};
      description = "IGMP/MLD proxy. docs/06 §10.";
    };
  };

  config = let
    wanNames = lib.attrNames cfg.wans;
    lanNames = lib.attrNames cfg.lans;
    defaultWanNames = lib.filter (n: cfg.wans.${n}.role == "default") wanNames;
    nets =
      lib.mapAttrsToList (n: lan: {
        inherit n;
        net = lanSubnet lan;
      })
      cfg.lans;
    pairs = lib.concatLists (lib.imap0 (i: a: map (b: {inherit a b;}) (lib.drop (i + 1) nets)) nets);
  in {
    assertions =
      lib.concatMap (n: [
        {
          assertion = known cfg.wans.${n}.uplink;
          message = "janus.network.wans.${n}.uplink '${cfg.wans.${n}.uplink}' is not a port, VLAN, or peripheral.";
        }
      ])
      wanNames
      ++ lib.concatMap (n:
        lib.concatMap (member: [
          {
            assertion = known member;
            message = "janus.network.lans.${n}.members entry '${member}' is not a port, VLAN, or peripheral.";
          }
        ])
        cfg.lans.${n}.members)
      lanNames
      ++ lib.concatMap ({
        a,
        b,
      }: [
        {
          assertion = a.net == null || b.net == null || !overlap a.net b.net;
          message = "janus.network.lans.${a.n} and janus.network.lans.${b.n} overlap in IPv4.";
        }
      ])
      pairs
      ++ lib.concatMap (
        n: let
          wan = cfg.wans.${n};
          wip =
            if wan.mode != "static" || wan.static.address == null
            then null
            else {
              ip = ipv4ToInt wan.static.address;
              prefix = wan.static.prefixLength;
            };
        in
          lib.concatMap (
            lan: let
              ln = lanSubnet lan;
            in
              lib.optional (wip != null && wip.ip != null && ln != null) {
                assertion = !overlap wip ln;
                message = "janus.network.wans.${n} overlaps janus.network.lans address ${lan.address}.";
              }
          ) (lib.attrValues cfg.lans)
      )
      wanNames
      ++ [
        {
          assertion = lib.length defaultWanNames <= 1 || lib.all (n: cfg.wans.${n}.metric != null) defaultWanNames;
          message = "More than one role=default WAN needs an explicit janus.network.wans.<name>.metric.";
        }
      ]
      ++ lib.concatMap (n: [
        {
          assertion =
            cfg.wans.${n}.pppoe.password
            == null
            || config.janus.security.allowInlineSecrets;
          message = "janus.network.wans.${n}.pppoe.password is inline. Set janus.security.allowInlineSecrets or use passwordSecret.";
        }
        {
          assertion = cfg.wans.${n}.wwan.pin == null || config.janus.security.allowInlineSecrets;
          message = "janus.network.wans.${n}.wwan.pin is inline. Set janus.security.allowInlineSecrets or a secret file.";
        }
      ])
      wanNames
      ++ lib.mapAttrsToList (n: ap: {
        assertion = ap.passphrase == null || config.janus.security.allowInlineSecrets;
        message = "janus.network.wifi.${n}.passphrase is inline. Set janus.security.allowInlineSecrets or passphraseSecret.";
      })
      cfg.wifi;

    warnings =
      lib.optional (cfg.wans != {}) "janus.network.wans is not lowered into networkd yet."
      ++ lib.optional (cfg.lans != {}) "janus.network.lans is not lowered into networkd and dnsmasq yet."
      ++ lib.optional (cfg.wifi != {}) "janus.network.wifi is not lowered yet."
      ++ lib.optional cfg.igmpProxy.enable "janus.network.igmpProxy is deferred until after 1.0."
      ++ lib.concatMap (n: lib.optional (cfg.wans.${n}.role == "iptv") "janus.network.wans.${n}.role = iptv is deferred until after 1.0.") wanNames;
  };
}
