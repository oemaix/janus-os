# Janus OS — example configuration
#
# This file is the shape of hosts/<name>/configuration.nix, one router.
# The fleet index is flake.nix. Add a router with `janus-build host add`.
# Change the values marked with "CHANGE ME", commit, and build:
#
#   janus-build build <host>
#
# Everything here is a NixOS module. You only need three ideas from the Nix
# language:
#   * strings          "like this"
#   * lists            [ "a" "b" "c" ]
#   * attribute sets   { key = value; nested = { key = value; }; }
#
# Lines starting with "#" are comments. Blocks between "/*" and "*/" are
# commented-out templates you can enable by removing the markers.
{
  config,
  lib,
  ...
}: {
  ############################################################################
  # Hardware
  ############################################################################

  janus.hardware.board = "nanopi-r4s"; # CHANGE ME: rpi4 | nanopi-r4s | ...

  janus.hardware.peripherals = {
    # A USB Ethernet adapter as an extra port.
    # usbnic0 = { class = "nic"; match.usbVendorProduct = "0bda:8153"; };

    # Huawei E3372s. The allowlist records this ID as ncm, so mode "auto" is ncm.
    # Ethernet modes do not take an APN. A qmi or mbim dongle does.
    # lte0 = { class = "wwan"; match.usbVendorProduct = "12d1:1506"; wwan.mode = "auto"; };

    # Waveshare 1.3" OLED HAT. The board must be rpi-zero-2w, rpi3, or rpi4.
    # screen = {
    #   class = "hmi";
    #   hmi.profile = "waveshare-1.3-oled-hat";
    #   # hmi.keys.KEY3 = "factory-reset";
    # };

    # mcuzone Pi Zero UPS. On a Raspberry Pi the image enables I²C and the INA219.
    # ups = { class = "power"; match.i2cAddress = "0x40"; };

    # Zero 2 W onboard radio. The board must be rpi-zero-2w. 2.4 GHz, WPA2.
    # Add "ap" to the LAN members. docs/10 §4.7.
    # radio = { class = "wifi"; match.onboard = true; };
  };

  ############################################################################
  # System
  ############################################################################

  janus.system = {
    hostName = "janus";
    timeZone = "Asia/Shanghai"; # CHANGE ME
  };

  janus.access.ssh.authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@laptop" # CHANGE ME (required)
  ];
  # janus.access.ssh.passwordAuthentication = true;       # not recommended
  # SSH destination for janus-build. mkRouter sets this to the
  # nixosConfigurations attribute name. hostName above does not change it.
  # Set the LAN address when that name does not resolve. After Tailscale
  # is up, set a MagicDNS name, the Tailscale IPv4, or an IPv6 literal.
  # deploy, status, backup, and fleet pull read this file immediately.
  # fleet apply needs a clean git tree. A new image is not required (Q-0043).
  # janus.access.deploy.address = "192.168.10.1";

  # Maintenance page (*20*). Included only when enable is set. After that,
  # janus web stop pauses it without a rebuild. The passphrase is one line
  # in secrets/web/<host>.yaml, encrypted to this router. It is not the
  # root password, and SSH stays key-only.
  # janus.access.web.enable = true;
  # janus.access.web.passphraseSecret = "web-janus";
  # sops.secrets.web-janus.sopsFile = ./secrets/web/janus.yaml;

  ############################################################################
  # Physical ports
  ############################################################################
  # The board profile provides default names; override here to swap ports.

  janus.network.ports = {
    wan = {device = "eth0";}; # swap these two lines to swap WAN/LAN
    lan = {device = "eth1";};
  };

  # WAN VLAN and IPTV are specified but not part of 1.0. See docs/06 §3.
  # janus.network.vlans.iptv = { port = "wan"; id = 85; };

  ############################################################################
  # WAN
  ############################################################################

  janus.network.wans = {
    main = {
      uplink = "wan";
      mode = "pppoe"; # CHANGE ME: dhcp | static | pppoe
      role = "default";
      pppoe = {
        username = "user@carrier"; # CHANGE ME
        passwordFile = "/var/lib/janus/secrets/pppoe"; # provisioned once over SSH
        ipv6 = true;
      };
      ipv6.mode = "passthrough"; # IPv6CP + DHCPv6-PD on the PPPoE link
    };

    # After 1.0: IPTV on a WAN VLAN, no default route.
    # iptv = {
    #   uplink = "iptv";
    #   mode   = "dhcp";
    #   role   = "iptv";
    #   dhcp.vendorClass = "IPTV_RG";
    # };

    /*
       Backup uplink through the ncm dongle declared above. No APN.
    lte = {
      uplink = "lte0";
      mode   = "wwan";
      role   = "backup";
      wwan   = { peripheral = "lte0"; };
    };
    */
  };

  ############################################################################
  # LAN
  ############################################################################

  janus.network.lans = {
    home = {
      members = ["lan"];
      address = "192.168.10.1";
      prefixLength = 24;
      domain = "home.lan";
      dhcp = {
        rangeStart = "192.168.10.100";
        rangeEnd = "192.168.10.199";
        staticLeases = {
          nas = {
            mac = "aa:bb:cc:dd:ee:01";
            ip = "192.168.10.5";
          };
          printer = {
            mac = "aa:bb:cc:dd:ee:02";
            ip = "192.168.10.6";
          };
        };
      };
      ipv6.mode = "disabled"; # safest when tunneling; see docs/06
      # proxy.mode is unset, so home inherits janus.proxy.mode (rule-based).
    };

    /*
       D-0042. These stay commented because the VLANs and the firewall
       policies below are commented too. home inherits janus.proxy.mode
       and janus.dns. A set proxy.rules replaces the inherited list. Bind
       the same Nix list to reuse it. Nodes and groups stay on janus.proxy.

       Guest: bypass. Unset dns sends every recursive name to the domestic
       encrypted resolvers, not the carrier and not the tunnel.
       Add "guest" to services.dns.zones, and a guest → wan policy below.
    guest = {
      members      = [ "lan.20" ];   # requires janus.network.vlans.guest-vlan = { port = "lan"; id = 20; };
      address      = "192.168.20.1";
      prefixLength = 24;
      isolation    = true;           # bridge port isolation inside this LAN
      proxy.mode   = "bypass";
    };

    Agents: proxy-all, same groups as home. Needs agents → wan.
    ai = {
      members      = [ "lan.40" ];
      address      = "192.168.40.1";
      prefixLength = 24;
      proxy.mode   = "proxy-all";
    };

    IoT on VLAN 30. No iot → wan policy, so this zone has no WAN path.
    recursive = false answers hosts and leases only.
    iot = {
      members      = [ "lan.30" ];
      address      = "192.168.30.1";
      prefixLength = 24;
      proxy.mode   = "bypass";
      dns.recursive = false;
      nat.enable   = false;
    };
    */
  };

  # After 1.0, with the iptv WAN above.
  # janus.network.igmpProxy = { enable = true; upstream = "iptv"; downstream = [ "home" ]; };

  ############################################################################
  # Firewall
  ############################################################################

  janus.firewall = {
    # Default policy is lan → wan accept. Other zones have no WAN path until
    # a policy accepts it, and zones do not forward to each other. Assigning
    # policies replaces the default, so keep the lan row.
    # policies = [
    #   { from = "lan"; to = "wan"; action = "accept"; }
    #   { from = "guest"; to = "wan"; action = "accept"; }  # guests use the Internet
    #   { from = "ai"; to = "wan"; action = "accept"; }     # agents use the tunnel
    # ];
    # iot is absent, so that zone has no WAN path.
    # services.dns.zones defaults to [ "lan" ]. Add guest and iot so they
    # can ask the router.
    portForwards = {
      /*
         nas-https = {
        protocol = "tcp"; externalPort = 443;
        to = { host = "192.168.10.5"; port = 443; };
        hairpin = true;
      };
      */
    };
  };

  ############################################################################
  # Reference region: cn (mainland China), ru (Russia), ir (Iran).
  # docs/21-reference-regions.md. ir also sets janus.dns.domestic.resolvers.
  # Changing this is a rebuild. It is not a hot override.
  ############################################################################

  janus.system.region = "cn";

  ############################################################################
  # Proxy (circumvention)
  ############################################################################

  janus.proxy = {
    enable = true;
    engine = "sing-box"; # keep this when LANs differ in DNS (docs/07 §2.1)
    mode = "rule-based"; # default every LAN inherits (D-0042)

    subscriptions = {
      providerA = {
        url = "https://example.invalid/sub?token=..."; # CHANGE ME
        refresh = "6h";
        via = "tunnel-then-direct";
      };
      # providerB = { url = "..."; refresh = "0 4 * * 2,4,6"; }; # 04:00 Tue, Thu, Sat
      # On one router in a fleet: janus.proxy.subscriptions.providerC.enable = false;
    };

    # Manually defined nodes (optional).
    nodes = {
      /*
         my-vps = {
        protocol = "vless";
        server   = "203.0.113.10"; port = 443;
        vless    = { uuid = "00000000-0000-0000-0000-000000000000"; flow = "xtls-rprx-vision"; };
        tls      = { enable = true; serverName = "www.example.com"; utls = "chrome";
                     reality = { publicKey = "..."; shortId = "abcd"; }; };
      };
      */
    };

    # Region groups by name matching. Each is a url-test group over all subscriptions.
    groups = {
      JP = {
        match = {
          kind = "regex";
          pattern = "japan|jp|日本|🇯🇵";
        };
        strategy = "url-test";
      };
      US = {
        match = {
          kind = "regex";
          pattern = "united states|\\bus\\b|usa|美国|🇺🇸";
        };
        strategy = "url-test";
      };
      HK = {
        match = {
          kind = "regex";
          pattern = "hong ?kong|\\bhk\\b|香港|🇭🇰";
        };
        strategy = "url-test";
      };
      SG = {
        match = {
          kind = "regex";
          pattern = "singapore|\\bsg\\b|新加坡|🇸🇬";
        };
        strategy = "url-test";
      };
      UK = {
        match = {
          kind = "regex";
          pattern = "united kingdom|britain|\\buk\\b|英国|🇬🇧";
        };
        strategy = "url-test";
      };
      EU = {
        match = {
          kind = "regex";
          pattern = "germany|france|netherlands|德国|法国|荷兰|🇩🇪|🇫🇷|🇳🇱";
        };
        strategy = "url-test";
      };
      IN = {
        match = {
          kind = "regex";
          pattern = "india|\\bin\\b|印度|🇮🇳";
        };
        strategy = "url-test";
      };

      # Glob example: all nodes whose name starts with "Premium".
      # Premium = { match = { kind = "glob"; pattern = "Premium*"; }; };

      # PEG example (Janet): names containing "JP" but not "x0.5" (discounted bandwidth).
      # JP-full = { match = { kind = "peg";
      #   pattern = ''(* (not (any (if-not "x0.5" 1)) "x0.5") (any (if-not "JP" 1)) "JP")''; }; };

      # Usage groups — templates. Uncomment together with the matching rule below.
      # fallback fails on both engines. load-balance is xray only (docs/07 §2.1).
      /*
      Telegram = { members = [ "group:SG" "group:HK" ]; strategy = "fallback"; };
      */
      /*
      Gemini   = { members = [ "group:US" ];            strategy = "url-test"; };
      */
      /*
      Claude   = { members = [ "group:US" "group:JP" ]; strategy = "fallback"; };
      */
      /*
      Netflix  = { members = [ "group:JP" "group:SG" ]; strategy = "manual"; default = "group:JP"; };
      */
      /*
      YouTube = { members = [ "group:US" "group:JP" ]; strategy = "url-test"; };
      */
      /*
      GitHub  = { members = [ "group:US" "group:SG" ]; strategy = "url-test"; };
      */
    };

    defaultTarget = "group:Auto"; # Auto = url-test over everything

    # Unset rules stay empty, and traffic follows defaultTarget.
    # This list is the cn template (docs/21 §4). For ru or ir, replace it
    # with the commented list and set janus.system.region to match.
    rules = [
      {
        match = {
          geosite = ["private"];
          geoip = ["private"];
        };
        target = "direct";
      }
      {
        match = {geosite = ["cn" "geolocation-cn"];};
        target = "direct";
      }
      {
        match = {geoip = ["cn"];};
        target = "direct";
      }
      {
        match = {geosite = ["category-ads-all"];};
        target = "block";
      }

      # Usage templates. sing-box rejects strategy fallback (ADR-0006).
      # { match = { geosite = [ "telegram" ]; geoip = [ "telegram" ]; }; target = "group:Telegram"; }
      # { match = { domainSuffix = [ "gemini.google.com" "generativelanguage.googleapis.com" ]; }; target = "group:Gemini"; }
      # { match = { domainSuffix = [ "anthropic.com" "claude.ai" ]; };  target = "group:Claude"; }
      # { match = { geosite = [ "netflix" ]; };                          target = "group:Netflix"; }
      # { match = { geosite = [ "youtube" ]; };                          target = "group:YouTube"; }
      # { match = { geosite = [ "github" ]; };                           target = "group:GitHub"; }
    ];

    # Russia. Replace rules above. Also set janus.system.region = "ru".
    # rules = [
    #   { match = { geosite = [ "private" ]; geoip = [ "private" ]; }; target = "direct"; }
    #   { match = { domainSuffix = [ "ru" "su" "xn--p1ai" ]; };        target = "direct"; }
    #   { match = { geosite = [ "category-ru" ]; };                    target = "direct"; }
    #   { match = { geoip = [ "ru" ]; };                               target = "direct"; }
    #   { match = { geosite = [ "category-ads-all" ]; };               target = "block"; }
    # ];

    # Iran. Replace rules above. Also set janus.system.region = "ir" and
    # janus.dns.domestic.resolvers.
    # rules = [
    #   { match = { geosite = [ "private" ]; geoip = [ "private" ]; }; target = "direct"; }
    #   { match = { domainSuffix = [ "ir" ]; };                        target = "direct"; }
    #   { match = { geosite = [ "ir" ]; };                             target = "direct"; }
    #   { match = { geoip = [ "ir" ]; };                               target = "direct"; }
    #   { match = { geosite = [ "category-ads-all" ]; };               target = "block"; }
    # ];
  };

  ############################################################################
  # DNS policy
  ############################################################################

  janus.dns = {
    carrierResolvers = "never";
    encryption = "prefer";
    # domestic.resolvers and domestic.domains follow janus.system.region.
    remote.resolvers = ["https://1.1.1.1/dns-query" "https://dns.google/dns-query"];
    fakeIp.enable = "auto";
    ipv6Answers = "strip-for-proxied";
    blockDoT = true;
    # bootstrap follows janus.system.region when unset (D-0040):
    # cn 223.5.5.5 and 223.6.6.6; ru 77.88.8.8 and 77.88.8.1; ir empty.
    # The build does not look hostnames up.
    # bootstrap = [ "223.5.5.5" "223.6.6.6" ];
  };

  ############################################################################
  # Monitoring and remote access
  ############################################################################

  janus.monitoring = {
    enable = true;
    interfaces = ["main" "home"];
    scope = "counters";
  };

  /*
  sops.secrets.tailscale-janus.sopsFile = ./secrets/tailscale/janus.yaml;
  janus.remoteAccess.tailscale = {
    enable = true;
    authKeySecret = "tailscale-janus";
    # authKeyFile is the board file from `janus secrets put`.
    # Exactly one of authKeySecret and authKeyFile.
    # loginServer = "https://headscale.example.com";
    # advertiseRoutes = [ "192.168.10.0/24" ];
    # exitNode = true;
  };
  */

  ############################################################################
  # Escape hatch: plain NixOS options are allowed.
  ############################################################################
  # system.stateVersion is managed by Janus; do not set it here.
}
