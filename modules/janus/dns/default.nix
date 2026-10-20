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
      description = "prefer allows a plaintext resolver. require accepts only https://, tls://, and quic:// for resolvers that answer clients. Bootstrap addresses stay plaintext.";
    };
    domestic.resolvers = mkOption {
      type = types.listOf types.str;
      defaultText = "the resolvers for janus.system.region (docs/21); empty for ir";
      description = "Domestic resolvers. Unset, these follow janus.system.region. ir is empty until this list is set. With the proxy enabled, that empty list fails evaluation.";
    };
    domestic.probe = mkOption {
      type = types.str;
      internal = true;
      defaultText = "the probe name for janus.system.region";
      description = "Name janus dns check resolves as domestic. Unset, this follows janus.system.region.";
    };
    domestic.domains = mkOption {
      type = types.listOf types.str;
      defaultText = "the domestic names for janus.system.region (docs/21)";
      description = "Names sent to the domestic resolvers. Unset, these follow janus.system.region.";
    };
    domestic.ecs = mkOption {
      type = types.enum ["allow" "strip"];
      default = "allow";
      description = "Recorded policy. Neither engine attaches a client subnet. sing-box 1.13 disables the DNS cache for any query that carries one, including 0.0.0.0/0. xray 26 has no client-subnet field. The resolver sees the source address of the query.";
    };
    remote.resolvers = mkOption {
      type = types.listOf types.str;
      default = ["https://1.1.1.1/dns-query" "https://dns.google/dns-query"];
      description = "Resolvers for names that are not domestic.";
    };
    remote.via = mkOption {
      type = types.enum ["tunnel" "direct"];
      default = "tunnel";
      description = "Path to the remote resolvers. On a bypass LAN or router, tunnel is ignored and every recursive name stays on the domestic resolvers; direct sends the names outside the domestic sets to the remote resolvers from the WAN, encrypted.";
    };
    remote.ecs = mkOption {
      type = types.enum ["allow" "strip"];
      default = "strip";
      description = "Recorded policy. Neither engine attaches a client subnet. sing-box 1.13 disables the DNS cache for any query that carries one, including 0.0.0.0/0. xray 26 has no client-subnet field. The resolver sees the source address of the query.";
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
      defaultText = "the domestic names for janus.system.region, plus *.lan and geosite:private";
      description = "Names that receive real answers. Unset, these follow janus.system.region.";
    };
    ipv6Answers = mkOption {
      type = types.enum ["keep" "strip-for-proxied" "strip-all"];
      default = "strip-for-proxied";
      description = "How AAAA answers are handled. strip-for-proxied withholds a globally routable AAAA from a proxied name. An address in the IPv6 fake-IP range is not a leak.";
    };
    bootstrap = mkOption {
      type = types.listOf types.str;
      defaultText = "the addresses for janus.system.region (docs/21); empty for ir";
      description = "IP addresses used only to resolve DoH and DoT hostnames. Unset, these follow janus.system.region. The build does not look the hostnames up.";
    };
    recursive = mkOption {
      type = types.bool;
      default = true;
      description = "Ask upstream resolvers. False answers only hosts and static leases.";
    };
    interceptPlaintext = mkOption {
      type = types.bool;
      default = true;
      description = "Redirect plaintext DNS from LANs to the router.";
    };
    blockDoT = mkOption {
      type = types.bool;
      default = true;
      description = "Reject DNS over TLS (port 853) from LANs. Default on (docs/11 §4.4).";
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
      description = "sing-box DNS cache capacity. xray 26 has no size; a value other than 4096 fails evaluation.";
    };
    cache.minTtl = mkOption {
      type = types.int;
      default = 60;
      description = "TTL sing-box writes on each routed answer. It has no floor-only TTL. 0 leaves the upstream TTL. xray 26 has no such field; a value other than 60 fails evaluation.";
    };
  };
}
