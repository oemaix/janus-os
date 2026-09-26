# Janus OS — example configuration
#
# This file is the recommended starting point. Copy it, change the values
# marked with "CHANGE ME", and build:
#
#   nix build .#images.home-router
#
# Everything here is a NixOS module. You only need three ideas from the Nix
# language:
#   * strings          "like this"
#   * lists            [ "a" "b" "c" ]
#   * attribute sets   { key = value; nested = { key = value; }; }
#
# Lines starting with "#" are comments. Blocks between "/*" and "*/" are
# commented-out templates you can enable by removing the markers.

{ config, lib, ... }:

{
  ############################################################################
  # Hardware
  ############################################################################

  janus.hardware.board = "nanopi-r4s";                     # CHANGE ME: rpi4 | nanopi-r4s | ...

  janus.hardware.peripherals = {
    # A USB Ethernet adapter as an extra port.
    # usbnic0 = { class = "nic"; match.usbVendorProduct = "0bda:8153"; };

    # A 4G dongle that shows up as an Ethernet NIC (ECM/NCM) with an AT port.
    # lte0 = { class = "wwan"; match.usbVendorProduct = "12d1:1506"; wwan.mode = "auto"; };

    # A small OLED with two buttons.
    # screen = { class = "hmi"; hmi.driver = "ssd1306";
    #            hmi.buttons = { gpio17 = "cycle-group"; gpio27 = "refresh"; }; };
  };

  ############################################################################
  # System
  ############################################################################

  janus.system = {
    hostName = "janus";
    timeZone = "Asia/Shanghai";                            # CHANGE ME
  };

  janus.access.ssh.authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@laptop"   # CHANGE ME (required)
  ];
  # janus.access.ssh.passwordAuthentication = true;       # not recommended

  ############################################################################
  # Physical ports
  ############################################################################
  # The board profile provides default names; override here to swap ports.

  janus.network.ports = {
    wan = { device = "eth0"; };                            # swap these two lines to swap WAN/LAN
    lan = { device = "eth1"; };
  };

  # WAN VLAN and IPTV are specified but not part of 1.0. See docs/06 §3.
  # janus.network.vlans.iptv = { port = "wan"; id = 85; };

  ############################################################################
  # WAN
  ############################################################################

  janus.network.wans = {
    main = {
      uplink = "wan";
      mode   = "pppoe";                                    # CHANGE ME: dhcp | static | pppoe
      role   = "default";
      pppoe = {
        username     = "user@carrier";                     # CHANGE ME
        passwordFile = "/var/lib/janus/secrets/pppoe";     # provisioned once over SSH
        ipv6         = true;
      };
      ipv6.mode = "passthrough";                           # IPv6CP + DHCPv6-PD on the PPPoE link
    };

    # After 1.0: IPTV on a WAN VLAN, no default route.
    # iptv = {
    #   uplink = "iptv";
    #   mode   = "dhcp";
    #   role   = "iptv";
    #   dhcp.vendorClass = "IPTV_RG";
    # };

    /* Backup uplink through the 4G dongle declared above.
    lte = {
      uplink = "lte0";
      mode   = "wwan";
      role   = "backup";
      wwan   = { peripheral = "lte0"; apn = "internet"; };
    };
    */
  };

  ############################################################################
  # LAN
  ############################################################################

  janus.network.lans = {
    home = {
      members      = [ "lan" ];
      address      = "192.168.10.1";
      prefixLength = 24;
      domain       = "home.lan";
      dhcp = {
        rangeStart = "192.168.10.100";
        rangeEnd   = "192.168.10.199";
        staticLeases = {
          nas     = { mac = "aa:bb:cc:dd:ee:01"; ip = "192.168.10.5"; };
          printer = { mac = "aa:bb:cc:dd:ee:02"; ip = "192.168.10.6"; };
        };
      };
      ipv6.mode = "disabled";                              # safest when tunneling; see docs/06
      proxied   = true;
    };

    /* A guest network on VLAN 20 of the LAN port, isolated from "home".
    guest = {
      members      = [ "lan.20" ];   # requires janus.network.vlans.guest-vlan = { port = "lan"; id = 20; };
      address      = "192.168.20.1";
      prefixLength = 24;
      isolation    = true;
      proxied      = false;          # guests get plain carrier Internet
    };
    */
  };

  # After 1.0, with the iptv WAN above.
  # janus.network.igmpProxy = { enable = true; upstream = "iptv"; downstream = [ "home" ]; };

  ############################################################################
  # Firewall
  ############################################################################

  janus.firewall = {
    # Defaults already: lan -> wan accept, wan -> anything drop, guest -> lan drop.
    portForwards = {
      /* nas-https = {
        protocol = "tcp"; externalPort = 443;
        to = { host = "192.168.10.5"; port = 443; };
        hairpin = true;
      }; */
    };
  };

  ############################################################################
  # Proxy (circumvention)
  ############################################################################

  janus.proxy = {
    enable = true;
    engine = "sing-box";                                   # or "xray"
    mode   = "rule-based";                                 # direct | rule-based | proxy-all

    subscriptions = {
      providerA = {
        url     = "https://example.invalid/sub?token=...";  # CHANGE ME
        refresh = "6h";
        via     = "tunnel-then-direct";
      };
      # providerB = { url = "..."; refresh = "0 4 * * *"; };
    };

    # Manually defined nodes (optional).
    nodes = {
      /* my-vps = {
        protocol = "vless";
        server   = "203.0.113.10"; port = 443;
        vless    = { uuid = "00000000-0000-0000-0000-000000000000"; flow = "xtls-rprx-vision"; };
        tls      = { enable = true; serverName = "www.example.com"; utls = "chrome";
                     reality = { publicKey = "..."; shortId = "abcd"; }; };
      }; */
    };

    # Region groups by name matching. Each is a url-test group over all subscriptions.
    groups = {
      JP = { match = { kind = "regex"; pattern = "japan|jp|日本|🇯🇵"; }; strategy = "url-test"; };
      US = { match = { kind = "regex"; pattern = "united states|\\bus\\b|usa|美国|🇺🇸"; }; strategy = "url-test"; };
      HK = { match = { kind = "regex"; pattern = "hong ?kong|\\bhk\\b|香港|🇭🇰"; }; strategy = "url-test"; };
      SG = { match = { kind = "regex"; pattern = "singapore|\\bsg\\b|新加坡|🇸🇬"; }; strategy = "url-test"; };
      UK = { match = { kind = "regex"; pattern = "united kingdom|britain|\\buk\\b|英国|🇬🇧"; }; strategy = "url-test"; };
      EU = { match = { kind = "regex"; pattern = "germany|france|netherlands|德国|法国|荷兰|🇩🇪|🇫🇷|🇳🇱"; }; strategy = "url-test"; };
      IN = { match = { kind = "regex"; pattern = "india|\\bin\\b|印度|🇮🇳"; }; strategy = "url-test"; };

      # Glob example: all nodes whose name starts with "Premium".
      # Premium = { match = { kind = "glob"; pattern = "Premium*"; }; };

      # PEG example (Janet): names containing "JP" but not "x0.5" (discounted bandwidth).
      # JP-full = { match = { kind = "peg";
      #   pattern = ''(* (not (any (if-not "x0.5" 1)) "x0.5") (any (if-not "JP" 1)) "JP")''; }; };

      # Usage groups — templates. Uncomment together with the matching rule below.
      /* Telegram = { members = [ "group:SG" "group:HK" ]; strategy = "fallback"; }; */
      /* Gemini   = { members = [ "group:US" ];            strategy = "url-test"; }; */
      /* Claude   = { members = [ "group:US" "group:JP" ]; strategy = "fallback"; }; */
      /* Netflix  = { members = [ "group:JP" "group:SG" ]; strategy = "manual"; default = "group:JP"; }; */
    };

    defaultTarget = "group:Auto";                          # Auto = url-test over everything

    rules = [
      { match = { geosite = [ "private" ]; geoip = [ "private" ]; }; target = "direct"; }
      { match = { geosite = [ "cn" ]; };                               target = "direct"; }
      { match = { geoip   = [ "cn" ]; };                               target = "direct"; }
      { match = { geosite = [ "category-ads-all" ]; };                 target = "block"; }

      /* { match = { geosite = [ "telegram" ]; geoip = [ "telegram" ]; }; target = "group:Telegram"; } */
      /* { match = { domainSuffix = [ "gemini.google.com" "generativelanguage.googleapis.com" ]; }; target = "group:Gemini"; } */
      /* { match = { domainSuffix = [ "anthropic.com" "claude.ai" ]; };  target = "group:Claude"; } */
      /* { match = { geosite = [ "netflix" ]; };                          target = "group:Netflix"; } */
    ];
  };

  ############################################################################
  # DNS policy
  ############################################################################

  janus.dns = {
    carrierResolvers = "never";
    encryption       = "prefer";
    domestic.resolvers = [ "https://dns.alidns.com/dns-query" "https://doh.pub/dns-query" ];
    remote.resolvers   = [ "https://1.1.1.1/dns-query" "https://dns.google/dns-query" ];
    fakeIp.enable      = "auto";
    ipv6Answers        = "strip-for-proxied";
    blockDoT           = true;
  };

  ############################################################################
  # Monitoring and remote access
  ############################################################################

  janus.monitoring = {
    enable     = true;
    interfaces = [ "main" "home" ];
    scope      = "counters";
  };

  /* janus.remoteAccess.wireguard.vps = {
    privateKeyFile = "/var/lib/janus/secrets/wg-vps.key";
    address        = "10.99.0.2/24";
    peer = { publicKey = "..."; endpoint = "vps.example.com:51820";
             allowedIPs = [ "10.99.0.0/24" ]; persistentKeepalive = 25; };
  }; */

  ############################################################################
  # Escape hatch: plain NixOS options are allowed.
  ############################################################################
  # system.stateVersion is managed by Janus; do not set it here.
}
