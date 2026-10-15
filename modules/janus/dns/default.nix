# SPDX-License-Identifier: Apache-2.0
# janus.dns option types. The proxy module renders this policy into sing-box. docs/07 §7, docs/08 §7.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.janus.dns = {
    listen.lans = mkOption {
      type = types.either (types.enum ["all"]) (types.listOf types.str);
      default = "all";
      description = "LANs that are told to use the router as their resolver.";
    };
    carrierResolvers = mkOption {
      type = types.enum ["never" "fallback-only" "domestic-only"];
      default = "never";
      description = "When carrier DNS from DHCP or PPPoE may be used.";
    };
    encryption = mkOption {
      type = types.enum ["prefer" "require"];
      default = "prefer";
      description = "Encrypted resolver policy.";
    };
    domestic.resolvers = mkOption {
      type = types.listOf types.str;
      defaultText = "the resolvers for janus.region (docs/21); empty for ir";
      description = "Domestic resolvers. Unset, these follow janus.region. ir has none until this list is set.";
    };
    domestic.domains = mkOption {
      type = types.listOf types.str;
      defaultText = "the domestic names for janus.region (docs/21)";
      description = "Names sent to the domestic resolvers. Unset, these follow janus.region.";
    };
    domestic.ecs = mkOption {
      type = types.enum ["allow" "strip"];
      default = "allow";
      description = "EDNS client subnet for domestic resolvers.";
    };
    remote.resolvers = mkOption {
      type = types.listOf types.str;
      default = ["https://1.1.1.1/dns-query" "https://dns.google/dns-query"];
      description = "Resolvers for names that are not domestic.";
    };
    remote.via = mkOption {
      type = types.enum ["tunnel" "direct"];
      default = "tunnel";
      description = "Path to the remote resolvers.";
    };
    remote.ecs = mkOption {
      type = types.enum ["allow" "strip"];
      default = "strip";
      description = "EDNS client subnet for remote resolvers.";
    };
    fakeIp.enable = mkOption {
      type = types.either types.bool (types.enum ["auto"]);
      default = "auto";
      description = "auto enables fake-IP in rule-based and proxy-all, and disables it in bypass.";
    };
    fakeIp.v4Range = mkOption {
      type = types.str;
      default = "198.18.0.0/15";
      description = "IPv4 fake-IP range.";
    };
    fakeIp.v6Range = mkOption {
      type = types.str;
      default = "fc00::/18";
      description = "IPv6 fake-IP range.";
    };
    fakeIp.exclude = mkOption {
      type = types.listOf types.str;
      defaultText = "the domestic names for janus.region, plus *.lan and geosite:private";
      description = "Names that receive real answers. Unset, these follow janus.region.";
    };
    ipv6Answers = mkOption {
      type = types.enum ["keep" "strip-for-proxied" "strip-all"];
      default = "strip-for-proxied";
      description = "How AAAA answers are handled.";
    };
    interceptPlaintext = mkOption {
      type = types.bool;
      default = true;
      description = "Redirect plaintext DNS from LANs to the router.";
    };
    blockDoT = mkOption {
      type = types.bool;
      default = false;
      description = "Reject DNS over TLS (port 853) from LANs.";
    };
    blockKnownDoH = mkOption {
      type = types.bool;
      default = false;
      description = "Reject known public DoH endpoints from LANs.";
    };
    hosts = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Static host overrides.";
    };
    forwarders = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = {};
      description = "Per-domain forwarders.";
    };
    bogusAnswers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Addresses treated as poisoned.";
    };
    cache.size = mkOption {
      type = types.int;
      default = 4096;
      description = "DNS cache entries.";
    };
    cache.minTtl = mkOption {
      type = types.int;
      default = 60;
      description = "Minimum TTL in seconds.";
    };
  };
}
