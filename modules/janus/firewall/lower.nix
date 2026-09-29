# SPDX-License-Identifier: Apache-2.0
# Zone firewall, NAT, and port forwards. docs/06 §7–8.
{
  config,
  lib,
  ...
}: let
  fw = config.janus.firewall;
  net = config.janus.network;

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

  vlanNetdev = vlan: "${vlan.port}.${toString vlan.id}";
  portIface = name: let
    port = net.ports.${name};
  in
    if port.device != null
    then port.device
    else name;
  vlanByRef = ref:
    lib.findFirst (n: n == ref || vlanNetdev net.vlans.${n} == ref) null (lib.attrNames net.vlans);
  resolve = name:
    if net.ports ? ${name}
    then portIface name
    else if vlanByRef name != null
    then vlanNetdev net.vlans.${vlanByRef name}
    else name;
  wanIface = name: let
    wan = net.wans.${name};
  in
    if wan.mode == "pppoe"
    then "ppp-${name}"
    else resolve wan.uplink;

  q = s: ''"${s}"'';
  list = xs: lib.concatMapStringsSep ", " q xs;

  zoneIfaces = name: zone:
    if zone.interfaces != []
    then zone.interfaces
    else if name == "wan"
    then map wanIface (lib.attrNames net.wans)
    else map (n: "br-${n}") (lib.filter (n: net.lans.${n}.zone == name) (lib.attrNames net.lans));

  zones = lib.mapAttrs zoneIfaces fw.zones;

  sshRate = fw.rateLimits.sshNew;

  protos = protocol:
    if protocol == "tcp+udp"
    then ["tcp" "udp"]
    else [protocol];

  port = p:
    if builtins.isInt p
    then toString p
    else p;

  natWanNames = lib.filter (n: builtins.elem net.wans.${n}.role ["default" "backup" "custom"]) (lib.attrNames net.wans);

  masquerade = lib.concatMap (lanName: let
    lan = net.lans.${lanName};
    src = cidr lan.address lan.prefixLength;
  in
    lib.optionals lan.nat.enable (map (wanName: ''
        oifname ${q (wanIface wanName)} ip saddr ${src} masquerade
      '')
      natWanNames)) (lib.attrNames net.lans);

  forwards = lib.concatLists (lib.mapAttrsToList (fname: rule: let
    wans =
      if rule.wan == null
      then lib.filter (n: net.wans.${n}.role == "default") (lib.attrNames net.wans)
      else [rule.wan];
    allow =
      if rule.sourceAllow == []
      then ""
      else "ip saddr { ${lib.concatStringsSep ", " rule.sourceAllow} } ";
  in
    lib.concatMap (proto:
      lib.concatMap (wanName: [
        ''
          iifname ${q (wanIface wanName)} ${allow}${proto} dport ${port rule.externalPort} dnat to ${rule.to.host}:${toString rule.to.port} comment ${q fname}
        ''
      ])
      wans)
    (protos rule.protocol))
  fw.portForwards);

  forwardAccept = lib.concatLists (lib.mapAttrsToList (_: rule:
    map (proto: ''
      ip daddr ${rule.to.host} ${proto} dport ${toString rule.to.port} accept
    '') (protos rule.protocol))
  fw.portForwards);

  hairpin = lib.concatLists (lib.mapAttrsToList (_: rule:
    if !rule.hairpin
    then []
    else
      lib.concatMap (lanName: let
        lan = net.lans.${lanName};
      in
        lib.optionals lan.nat.hairpin (map (proto: ''
          ip saddr ${cidr lan.address lan.prefixLength} ip daddr ${rule.to.host} ${proto} dport ${toString rule.to.port} snat to ${lan.address}
        '') (protos rule.protocol))) (lib.attrNames net.lans))
  fw.portForwards);

  iif = ifaces: body:
    if ifaces == []
    then ""
    else ''
      iifname { ${list ifaces} } ${body}
    '';

  serviceRules = lib.concatLists (lib.mapAttrsToList (sname: svc: let
    ifaces = lib.concatLists (map (z:
      if z == "*"
      then lib.concatLists (lib.attrValues zones)
      else zones.${z} or [])
    svc.zones);
    dport =
      if svc.port != null
      then toString svc.port
      else if sname == "ssh"
      then toString config.janus.access.ssh.port
      else if sname == "dns"
      then "53"
      else if sname == "dhcp"
      then "67"
      else null;
    proto =
      if sname == "icmp"
      then null
      else if sname == "dhcp"
      then "udp"
      else if sname == "dns"
      then null
      else "tcp";
  in
    if sname == "icmp" || dport == null
    then []
    else if sname == "ssh"
    then [
      (iif ifaces "tcp dport ${dport} ct state new limit rate ${sshRate} accept")
      (iif ifaces "tcp dport ${dport} ct state new drop")
    ]
    else if proto == null
    then [
      (iif ifaces "tcp dport ${dport} accept")
      (iif ifaces "udp dport ${dport} accept")
    ]
    else [(iif ifaces "${proto} dport ${dport} accept")])
  fw.services);

  dhcpOpen = lib.concatMap (n: let
    lan = net.lans.${n};
  in
    lib.optional lan.dhcp.enable (iif ["br-${n}"] "udp dport 67 accept")) (lib.attrNames net.lans);

  zoneInput = lib.concatStrings (lib.mapAttrsToList (name: zone: let
    ifaces = zones.${name};
    action =
      if zone.input == "accept"
      then "accept"
      else if zone.input == "reject"
      then "reject"
      else "";
  in
    lib.optionalString (action != "" && ifaces != []) (iif ifaces action))
  fw.zones);

  policies = lib.concatMapStrings ({
    from,
    to,
    action,
  }: let
    src = zones.${from} or [];
    dst = zones.${to} or [];
  in
    lib.optionalString (src != [] && dst != []) ''
      iifname { ${list src} } oifname { ${list dst} } ${action}
    '')
  fw.policies;

  extraRules = lib.concatMapStrings (rule: let
    src = zones.${rule.from} or [];
    dst = zones.${rule.to} or [];
  in
    lib.optionalString (src != [] && dst != []) ''
      iifname { ${list src} } oifname { ${list dst} } ${lib.optionalString (rule.protocol != null) "${rule.protocol} "}${lib.optionalString (rule.dport != null) "dport ${port rule.dport} "}${lib.optionalString (rule.dest != null) "ip daddr ${rule.dest} "}${rule.action} comment ${q rule.name}
    '')
  fw.rules;

  v6drop = lib.concatMapStrings (n:
    lib.optionalString (net.lans.${n}.ipv6.mode == "disabled") ''
      iifname ${q "br-${n}"} meta nfproto ipv6 drop
    '') (lib.attrNames net.lans);

  disabledLans = lib.filter (n: net.lans.${n}.ipv6.mode == "disabled") (lib.attrNames net.lans);

  proxied = map (n: cidr net.lans.${n}.address net.lans.${n}.prefixLength) (lib.filter (n: net.lans.${n}.proxied) (lib.attrNames net.lans));

  content = ''
    ${lib.optionalString (proxied != []) ''
      set janus_proxied_src {
        type ipv4_addr
        flags interval
        elements = { ${lib.concatStringsSep ", " proxied} }
      }
    ''}

    chain input {
      type filter hook input priority 0; policy drop;
      iifname "lo" accept
      ct state established,related accept
      ct state invalid drop
      icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept
      icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-query } accept
      ${lib.concatStringsSep "\n" (lib.filter (s: s != "") (dhcpOpen ++ serviceRules))}
      ${zoneInput}
      ${fw.hooks.inputExtra}
    }

    chain forward {
      type filter hook forward priority 0; policy drop;
      ct state established,related accept
      ct state invalid drop
      ${v6drop}
      ${policies}
      ${lib.concatStringsSep "\n" forwardAccept}
      ${extraRules}
      ${fw.hooks.forwardExtra}
    }

    chain output {
      type filter hook output priority 0; policy accept;
    }

    chain prerouting {
      type nat hook prerouting priority dstnat; policy accept;
      ${lib.concatStringsSep "\n" forwards}
      ${fw.hooks.preroutingRaw}
    }

    chain postrouting {
      type nat hook postrouting priority srcnat; policy accept;
      ${lib.concatStringsSep "\n" masquerade}
      ${lib.concatStringsSep "\n" hairpin}
    }
  '';
in {
  config = {
    networking.firewall.enable = false;
    networking.nftables.enable = true;
    networking.nftables.tables = lib.mkMerge [
      {
        janus = {
          family = "inet";
          content = content;
        };
      }
      (lib.mkIf (disabledLans != []) {
        janus-ra = {
          family = "bridge";
          content = ''
            chain forward {
              type filter hook forward priority 0; policy accept;
              ${lib.concatMapStrings (n: ''
                iifname ${q "br-${n}"} ether type ip6 icmpv6 type nd-router-advert drop
              '')
              disabledLans}
            }
          '';
        };
      })
    ];
  };
}
