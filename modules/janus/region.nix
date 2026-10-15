# SPDX-License-Identifier: Apache-2.0
# janus.region selects domestic DNS and the blockQuic default. docs/21, D-0034.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types mkOptionDefault;

  region = config.janus.region;
  dns = config.janus.dns;

  presets = {
    cn = {
      suffixes = [];
      geosite = ["cn" "geolocation-cn"];
      geoip = ["cn"];
      resolvers = ["https://dns.alidns.com/dns-query" "tls://dot.pub"];
      blockQuic = false;
    };
    ru = {
      suffixes = ["ru" "su" "xn--p1ai"];
      geosite = ["category-ru"];
      geoip = ["ru"];
      resolvers = [
        "https://common.dot.dns.yandex.net/dns-query"
        "tls://common.dot.dns.yandex.net"
      ];
      blockQuic = true;
    };
    ir = {
      suffixes = ["ir"];
      geosite = ["ir"];
      geoip = ["ir"];
      resolvers = [];
      blockQuic = false;
    };
  };
  preset = presets.${region};

  star = name: "*.${name}";
  domains = preset.suffixes ++ map (name: "geosite:${name}") preset.geosite;
  exclude = ["*.lan" "geosite:private"] ++ map star preset.suffixes ++ map (name: "geosite:${name}") preset.geosite;
in {
  options.janus.region = mkOption {
    type = types.enum ["cn" "ru" "ir"];
    default = "cn";
    description = "Reference region. Selects domestic DNS and the blockQuic default in docs/21. Routing rules stay empty until written. Not a hot override.";
  };

  config = {
    janus.proxy.blockQuic = mkOptionDefault preset.blockQuic;
    janus.dns.domestic.resolvers = mkOptionDefault preset.resolvers;
    janus.dns.domestic.domains = mkOptionDefault domains;
    janus.dns.fakeIp.exclude = mkOptionDefault exclude;

    assertions = [
      {
        assertion = !config.janus.proxy.enable || region != "ir" || dns.domestic.resolvers != [];
        message = ''
          janus.proxy.enable is true, janus.region is ir, and janus.dns.domestic.resolvers is empty. Set an encrypted resolver that returns inland addresses for inland names. An anti-filter resolver answers blocked names and belongs on the tunnel, not in this list.
        '';
      }
    ];
  };
}
