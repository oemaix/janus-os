# SPDX-License-Identifier: Apache-2.0
# Evaluation checks for the phase 0 skeleton. docs/09 §9.
{
  pkgs,
  lib,
  self,
}: let
  mk = modules:
    self.lib.mkRouter {
      inherit modules;
      source = self;
      configRevision = self.rev or "unknown";
      name = "eval";
    };
  nameOf = modules: (mk modules).config.system.build.toplevel.name;
  bad = modules: builtins.tryEval (nameOf modules);
  pass = name: modules:
    pkgs.runCommand name {} ''
      echo ${lib.escapeShellArg (nameOf modules)} > "$out"
    '';
  fail = name: modules:
    pkgs.runCommand name {} ''
      if [ "${
        if (bad modules).success
        then "yes"
        else "no"
      }" = yes ]; then
        echo "expected evaluation to fail" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval";
  base = {
    janus.hardware.board = "x86_64-test";
    janus.access.ssh.authorizedKeys = [key];
  };
in {
  eval-minimal = pass "eval-minimal" [base];
  eval-missing-board = fail "eval-missing-board" [
    {janus.access.ssh.authorizedKeys = [key];}
  ];
  eval-missing-key = fail "eval-missing-key" [
    {janus.hardware.board = "x86_64-test";}
  ];
  eval-root-writable = fail "eval-root-writable" [
    base
    {janus.storage.layout.partitions.JANUS_ROOT.readOnly = false;}
  ];
  eval-overlap = fail "eval-overlap" [
    base
    {
      janus.network.lans.a = {
        members = ["lan"];
        address = "192.168.1.1";
        prefixLength = 24;
      };
      janus.network.lans.b = {
        members = ["lan"];
        address = "192.168.1.2";
        prefixLength = 24;
      };
    }
  ];
  eval-bad-uplink = fail "eval-bad-uplink" [
    base
    {
      janus.network.wans.main = {
        uplink = "nope";
        mode = "dhcp";
      };
    }
  ];
  eval-inline-secret = fail "eval-inline-secret" [
    base
    {janus.proxy.subscriptions.a.url = "https://example.invalid/sub";}
  ];
  eval-wwan = fail "eval-wwan" [
    base
    {
      janus.hardware.peripherals.lte = {
        class = "wwan";
        match.usbVendorProduct = "1234:5678";
      };
    }
  ];
  eval-nix-size = let
    os = mk [
      base
      {janus.storage.layout.partitions.JANUS_NIX.size = "2048M";}
    ];
    part = os.config.system.build.janusNixPartition;
  in
    pkgs.runCommand "eval-nix-size" {} ''
      test ${part.mode} = exact
      test ${toString part.exactMiB} = 2048
      echo ok > "$out"
    '';
  eval-router = let
    os = mk [
      base
      {
        janus.network.wans.main = {
          uplink = "wan";
          mode = "dhcp";
        };
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
      }
    ];
    rules = os.config.networking.nftables.tables.janus.content;
    dhcp = os.config.systemd.network.networks."40-wan-main".networkConfig.DHCP;
    range = builtins.head os.config.services.dnsmasq.settings.dhcp-range;
  in
    pkgs.runCommand "eval-router" {} ''
      cat > rules.nft <<'EOF'
      ${rules}
      EOF
      grep -q masquerade rules.nft
      grep -q 192.168.10.0/24 rules.nft
      test ${lib.escapeShellArg dhcp} = ipv4
      echo ${lib.escapeShellArg range} | grep -q 192.168.10.100
      test ${
        if os.config.services.openssh.enable
        then "yes"
        else "no"
      } = yes
      test ${
        if os.config.services.vnstat.enable
        then "yes"
        else "no"
      } = yes
      echo ok > "$out"
    '';
  eval-vlan = let
    os = mk [
      base
      {
        janus.network.vlans.iot = {
          port = "lan";
          id = 20;
        };
        janus.network.lans.lan = {
          members = ["lan.20"];
          address = "192.168.20.1";
          prefixLength = 24;
        };
        janus.network.wans.main = {
          uplink = "wan";
          mode = "static";
          static = {
            address = "203.0.113.2";
            prefixLength = 24;
            gateway = "203.0.113.1";
          };
        };
      }
    ];
    vlan = os.config.systemd.network.netdevs."30-vlan-iot".netdevConfig.Name;
  in
    pkgs.runCommand "eval-vlan" {} ''
      test ${lib.escapeShellArg vlan} = lan.20
      echo ok > "$out"
    '';
  cli-usage = let
    system = pkgs.stdenv.hostPlatform.system;
  in
    pkgs.runCommand "cli-usage" {} ''
      set +e
      ${self.packages.${system}.janus-cli}/bin/janus >/dev/null
      s1=$?
      ${self.packages.${system}.janus-build}/bin/janus-build >/dev/null
      s2=$?
      set -e
      test "$s1" = 2
      test "$s2" = 2
      echo ok > "$out"
    '';
  cli-init = let
    system = pkgs.stdenv.hostPlatform.system;
  in
    pkgs.runCommand "cli-init" {
      nativeBuildInputs = [self.packages.${system}.janus-build];
    } ''
      export HOME=$TMPDIR
      janus-build init "$TMPDIR/fleet"
      test -f "$TMPDIR/fleet/flake.nix"
      test -d "$TMPDIR/fleet/.git"
      cd "$TMPDIR/fleet"
      janus-build host add potato
      test -f hosts/potato/configuration.nix
      janus-build secret keygen potato > "$TMPDIR/age.key"
      test -s secrets/keys/potato.pub
      grep -q age1 secrets/keys/potato.pub
      echo ok > "$out"
    '';
  eval-boards = let
    one = board:
      mk [
        {
          janus.hardware.board = board;
          janus.access.ssh.authorizedKeys = [key];
        }
      ];
    yanyu = one "yanyu-stx-r19f";
    r4s = one "nanopi-r4s";
    potato = one "le-potato";
    zero = one "rpi-zero-2w";
    rpi = one "rpi3";
    plain = mk [base];
    # The boot scripts name store paths. Drop that context so the check
    # evaluates the profiles without building U-Boot or the kernel.
    text = value: lib.escapeShellArg (builtins.unsafeDiscardStringContext value);
  in
    pkgs.runCommand "eval-boards" {} ''
      test ${lib.escapeShellArg yanyu.config.systemd.network.links."10-port-lan1".matchConfig.Path} = pci-0000:01:00.0
      test ${lib.escapeShellArg yanyu.config.systemd.network.links."10-port-lan4".matchConfig.Path} = pci-0000:04:00.0
      test ${
        if yanyu.config.system.build.janusBoardImage.limineBios or false
        then "yes"
        else "no"
      } = yes
      test ${toString yanyu.config.janus.storage.firmwareOffsetMiB} = 1
      echo ${text yanyu.config.system.build.janusImage.limineConfigScript} | grep -q 'editor_enabled: no'
      echo ${text yanyu.config.system.build.janusImage.limineBiosPartitionScript} | grep -q 'bios-install'
      test ${toString r4s.config.janus.storage.firmwareOffsetMiB} = 15
      echo ${text r4s.config.system.build.janusBoardImage.firmwareInstall} | grep -q 'seek=64'
      echo ${text potato.config.system.build.janusBoardImage.firmwareInstall} | grep -q u-boot.gxl
      test ${toString (lib.length (lib.attrNames zero.config.janus.network.ports))} = 0
      echo ${text zero.config.system.build.janusBoardImage.bootExtra} | grep -q config.txt
      test ${lib.escapeShellArg (lib.head (lib.attrNames rpi.config.janus.network.ports))} = eth0
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2710-rpi-3-b.dtb
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2710-rpi-3-b-plus.dtb
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q '\[pi3\]'
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q '\[pi3+\]'
      test ${lib.escapeShellArg plain.config.sops.age.keyFile} = /var/lib/janus/secrets/age.key
      echo ok > "$out"
    '';
  eval-rpi4 = fail "eval-rpi4" [
    {
      janus.hardware.board = "rpi4";
      janus.access.ssh.authorizedKeys = [key];
    }
  ];
  eval-pppoe-secret = fail "eval-pppoe-secret" [
    base
    {
      janus.network.wans.main = {
        uplink = "wan";
        mode = "pppoe";
        pppoe.passwordSecret = "missing";
      };
    }
  ];
  eval-pppoe-file = let
    os = mk [
      base
      {
        janus.network.wans.main = {
          uplink = "wan";
          mode = "pppoe";
          pppoe = {
            username = "alice";
            passwordFile = "/var/lib/janus/secrets/pppoe";
          };
        };
      }
    ];
    pre = os.config.systemd.services.janus-pppoe-main.serviceConfig.ExecStartPre;
    script =
      if builtins.isList pre
      then builtins.head pre
      else pre;
  in
    pkgs.runCommand "eval-pppoe-file" {} ''
      grep -q '/var/lib/janus/secrets/pppoe' ${script}
      grep -q 'rp-pppoe.so' ${script}
      grep -q 'ifname ppp-main' ${script}
      echo ok > "$out"
    '';
  eval-seed = let
    os = mk [base];
    seed = os.config.system.build.janusSeed;
  in
    pkgs.runCommand "eval-seed" {} ''
      hash=$(cat ${seed}/seed.hash)
      echo "$hash" | grep -Eq '^[0-9a-f]{64}$'
      test "$(cat ${seed}/seed.generation)" = 1
      echo ok > "$out"
    '';
  eval-proxy = let
    os = mk [
      base
      {
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.dns.blockDoT = true;
        janus.dns.blockKnownDoH = true;
        janus.proxy = {
          enable = true;
          blockQuic = true;
          nodes.demo = {
            protocol = "vless";
            server = "203.0.113.10";
            port = 443;
            vless.uuid = "b831381d-6324-4d53-ad4f-8cda48b30811";
            tls.enable = true;
            tls.serverName = "www.example.com";
            tls.insecure = true;
          };
          groups.Demo = {
            members = ["node:demo"];
            strategy = "url-test";
          };
        };
      }
    ];
    engine = os.config.system.build.janusEngineConfig;
    mark = os.config.networking.nftables.tables.janus_intercept.content;
    dnsUdp = os.config.networking.nftables.tables.janus_dns.content;
    nat = os.config.networking.nftables.tables.janus.content;
    geo = os.config.environment.etc."janus/geodata".source;
    proxyBin = os.config.environment.etc."janus/bin/janus-proxy".source;
    pre = os.config.systemd.services.janus-engine.serviceConfig.ExecStartPre;
    preText = pkgs.writeText "exec-start-pre" (
      if builtins.isList pre
      then lib.concatStringsSep "\n" pre
      else pre
    );
    markFile = pkgs.writeText "mark.nft" mark;
    dnsFile = pkgs.writeText "dns.nft" dnsUdp;
    natFile = pkgs.writeText "nat.nft" nat;
  in
    pkgs.runCommand "eval-proxy" {
      nativeBuildInputs = [pkgs.sing-box pkgs.jq];
    } ''
      sing-box check -c ${engine}
      jq -e '.inbounds[] | select(.type == "tun" and .auto_route == false)' ${engine} >/dev/null
      jq -e '.outbounds[] | select(.tag == "direct" and .routing_mark == 74)' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.type == "tproxy" and .network == "udp")' ${engine} >/dev/null
      jq -e '[.inbounds[] | select(.type == "tproxy" and .network == "tcp")] | length == 0' ${engine} >/dev/null
      grep -q geodata-missing ${preText}
      grep -q '0x00004a01' ${markFile}
      grep -q 'dport 53 return' ${markFile}
      grep -q 'ip6 daddr != fc00::/18' ${markFile}
      grep -q 'priority -200' ${markFile}
      grep -q 'dport 853 reject' ${markFile}
      grep -q '1.1.1.1' ${markFile}
      grep -q 'udp dport 443 reject' ${markFile}
      if grep -q 'hook forward' ${markFile}; then
        echo "DoT and DoH rejects are still on the forward hook" >&2
        exit 1
      fi
      grep -q 'tproxy to :5353' ${dnsFile}
      grep -q '0x00004a02' ${dnsFile}
      grep -q 'meta l4proto tcp th dport 53 redirect to :5353' ${natFile}
      if grep -q 'l4proto udp th dport 53 redirect' ${natFile}; then
        echo "UDP/53 is still NAT-redirected" >&2
        exit 1
      fi
      test -s ${geo}/geosite-private.srs
      test -s ${geo}/geosite-cn.srs
      test -s ${geo}/geosite-geolocation-cn.srs
      test -s ${geo}/geoip-private.srs
      grep -a -F -q 'dest}.partial' ${proxyBin}
      if grep -a -F -q 'rm -f "/var/lib/janus/geodata/' ${proxyBin}; then
        echo "geo refresh deletes the live rule set" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  eval-proxy-password = let
    os = mk [
      base
      {
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.proxy = {
          enable = true;
          nodes.secret = {
            protocol = "trojan";
            server = "203.0.113.10";
            port = 443;
            trojan.passwordFile = "/var/lib/janus/secrets/trojan";
          };
        };
      }
    ];
    nodes = os.config.environment.etc."janus/nodes-built.json".source;
    passwords = os.config.environment.etc."janus/password-files.json".source;
    engine = os.config.system.build.janusEngineConfig;
  in
    pkgs.runCommand "eval-proxy-password" {
      nativeBuildInputs = [pkgs.jq pkgs.sing-box];
    } ''
      jq -e '.[] | select(.name == "secret") | .trojan.passwordFile == "/var/lib/janus/secrets/trojan" and .trojan.password == "janus-build-check"' ${nodes} >/dev/null
      jq -e '.secret == "/var/lib/janus/secrets/trojan"' ${passwords} >/dev/null
      jq -e '.outbounds[] | select(.tag == "secret") | .password == "janus-build-check"' ${engine} >/dev/null
      sing-box check -c ${engine}
      echo ok > "$out"
    '';
  eval-proxy-xray = let
    os = mk [
      base
      {
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.proxy = {
          enable = true;
          engine = "xray";
          nodes.demo = {
            protocol = "trojan";
            server = "203.0.113.10";
            port = 443;
            trojan.password = "janus-build-check";
          };
          groups.Wave = {
            members = ["node:demo"];
            strategy = "load-balance";
          };
          rules = [
            {
              match.domains = ["example.com"];
              target = "direct";
            }
          ];
        };
        janus.security.allowInlineSecrets = true;
      }
    ];
    engine = os.config.system.build.janusEngineConfig;
    mark = os.config.networking.nftables.tables.janus_intercept.content;
    start = os.config.systemd.services.janus-engine.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-proxy-xray" {
      nativeBuildInputs = [pkgs.jq pkgs.xray];
    } ''
      xray run -test -c ${engine}
      jq -e '.inbounds[] | select(.protocol == "dokodemo-door" and .port == 12345)' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.tag == "api" and .port == 8080)' ${engine} >/dev/null
      jq -e '.outbounds[] | select(.protocol == "dns" and .tag == "dns-out")' ${engine} >/dev/null
      jq -e 'any(.routing.rules[]; (.domain // []) | index("full:example.com"))' ${engine} >/dev/null
      jq -e '.routing.balancers[] | select(.tag == "Wave") | .strategy.type == "roundRobin"' ${engine} >/dev/null
      jq -e '[.inbounds[] | select(.protocol == "tun" or .type == "tun")] | length == 0' ${engine} >/dev/null
      echo ${lib.escapeShellArg start} | grep -q 'xray run'
      echo ${lib.escapeShellArg mark} | grep -q 'tproxy to :12345'
      if echo ${lib.escapeShellArg mark} | grep -q '0x00004a01'; then
        echo "xray still marks 0x4a01" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  eval-proxy-xray-insecure = fail "eval-proxy-xray-insecure" [
    base
    {
      janus.security.allowInlineSecrets = true;
      janus.proxy = {
        enable = true;
        engine = "xray";
        nodes.demo = {
          protocol = "trojan";
          server = "203.0.113.10";
          port = 443;
          trojan.password = "janus-build-check";
          tls.enable = true;
          tls.insecure = true;
        };
      };
    }
  ];
  eval-proxy-xray-fallback = fail "eval-proxy-xray-fallback" [
    base
    {
      janus.security.allowInlineSecrets = true;
      janus.proxy = {
        enable = true;
        engine = "xray";
        nodes.demo = {
          protocol = "trojan";
          server = "203.0.113.10";
          port = 443;
          trojan.password = "janus-build-check";
        };
        groups.A = {
          members = ["node:demo"];
          strategy = "fallback";
        };
      };
    }
  ];
  eval-wifi = let
    os = mk [
      base
      {
        janus.security.allowInlineSecrets = true;
        janus.hardware.peripherals.stick = {
          class = "wifi";
          match.usbVendorProduct = "0bda:8176";
        };
        janus.network.lans.lan = {
          members = ["lan" "home"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.network.wifi.home = {
          peripheral = "stick";
          ssid = "ja\$nus";
          passphrase = "secret\$1";
          lan = "lan";
        };
      }
    ];
    script = os.config.systemd.services.janus-hostapd-home.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-wifi" {} ''
      test ${lib.escapeShellArg os.config.systemd.network.networks."30-member-lan-home".networkConfig.Bridge} = br-lan
      test ${lib.escapeShellArg os.config.systemd.network.networks."30-member-lan-home".matchConfig.Name} = wifi-home
      grep -q 'wpa_passphrase=%s' ${script}
      grep -q ${lib.escapeShellArg "ssid='ja\$nus'"} ${script}
      if grep -q '<<' ${script}; then
        echo "hostapd config is still a shell heredoc" >&2
        exit 1
      fi
      echo ${lib.escapeShellArg (lib.concatStrings os.config.boot.blacklistedKernelModules)} | grep -q rtl8xxxu
      echo ok > "$out"
    '';
  eval-wwan-qmi = let
    os = mk [
      base
      {
        janus.hardware.peripherals.lte = {
          class = "wwan";
          match.usbVendorProduct = "2c7c:0125";
          wwan.mode = "qmi";
          wwan.modeSwitch = {
            DefaultVendor = "0x2c7c";
            DefaultProduct = "0x0125";
          };
        };
        janus.network.wans.cell = {
          uplink = "lte";
          mode = "wwan";
          wwan.peripheral = "lte";
          wwan.apn = "in'ternet";
        };
      }
    ];
    connect = os.config.systemd.services.janus-wwan-cell.serviceConfig.ExecStart;
    health = os.config.systemd.services.janus-wwan-health-cell.serviceConfig.ExecStart;
    switch = os.config.systemd.services.janus-wwan-switch-cell.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-wwan-qmi" {} ''
      test ${lib.escapeShellArg os.config.systemd.network.networks."40-wan-cell".matchConfig.Name} = wwan-lte
      test ${lib.escapeShellArg os.config.systemd.network.networks."40-wan-cell".networkConfig.DHCP} = ipv4
      grep -q wds-start-network ${connect}
      grep -F ${lib.escapeShellArg "apn=${lib.escapeShellArg "in'ternet"}"} ${connect}
      if grep -q 'qmi=failed' ${connect}; then
        echo "qmi connect hides failure" >&2
        exit 1
      fi
      if grep -q wds-start-network ${health}; then
        echo "wwan health dials again" >&2
        exit 1
      fi
      echo ${lib.escapeShellArg switch} | grep -q usb_modeswitch
      conf=$(printf '%s\n' ${lib.escapeShellArg switch} | awk '{print $NF}')
      grep -q 'DefaultVendor=0x2c7c' "$conf"
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.boot.kernelModules)} | grep -q qmi_wwan
      echo ok > "$out"
    '';
  eval-remote = let
    os = mk [
      base
      {
        janus.remoteAccess.tailscale.enable = true;
        janus.remoteAccess.wireguard.uplink = {
          privateKeyFile = "/run/secrets/wg";
          address = "10.9.0.2/32";
          peer.publicKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=";
          peer.endpoint = "203.0.113.8:51820";
          peer.allowedIPs = ["0.0.0.0/0"];
          via = "tunnel";
        };
      }
    ];
    ifaces = lib.concatStringsSep " " os.config.janus.firewall.zones.mgmt.interfaces;
  in
    pkgs.runCommand "eval-remote" {} ''
      test ${
        if os.config.services.tailscale.enable
        then "yes"
        else "no"
      } = yes
      test ${lib.escapeShellArg os.config.services.tailscale.useRoutingFeatures} = none
      test ${lib.escapeShellArg (toString os.config.networking.wireguard.interfaces.wg-uplink.fwMark)} = 74
      echo ${lib.escapeShellArg ifaces} | grep -q tailscale0
      echo ${lib.escapeShellArg ifaces} | grep -q wg-uplink
      echo ok > "$out"
    '';
  eval-backup-health = let
    os = mk [
      base
      {
        janus.network.wans.main = {
          uplink = "wan";
          mode = "dhcp";
        };
        janus.network.wans.spare = {
          uplink = "lan";
          mode = "dhcp";
          role = "backup";
        };
      }
    ];
    script = os.config.systemd.services.janus-wan-health.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-backup-health" {} ''
      test ${
        if os.config.systemd.timers.janus-wan-health.enable or false
        then "yes"
        else "no"
      } = yes
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.janus.network.wans.spare.healthCheck.targets)} | grep -q 1.1.1.1
      grep -q 'iface=eth0' ${script}
      grep -q 'role=default' ${script}
      grep -q 'healthy=' ${script}
      echo ok > "$out"
    '';
  eval-proxy-fallback = fail "eval-proxy-fallback" [
    base
    {
      janus.proxy.groups.A = {
        members = ["group:Auto"];
        strategy = "fallback";
      };
    }
  ];
  janet-normalizer =
    pkgs.runCommand "janet-normalizer" {
      nativeBuildInputs = [pkgs.janet pkgs.sing-box pkgs.jq pkgs.coreutils];
    } ''
      set -eu
      script=${../janet/janus.janet}
      test "$(janet "$script" match regex 'japan|jp' 'Tokyo JP')" = yes
      test "$(janet "$script" match regex 'japan|jp' 'London')" = no
      test "$(janet "$script" match glob 'Premium*' 'Premium-HK')" = yes
      test "$(janet "$script" match peg '(some "a")' aaa)" = yes
      json='{"v":"2","ps":"Tokyo JP 1","add":"203.0.113.10","port":"443","id":"b831381d-6324-4d53-ad4f-8cda48b30811","aid":"0","scy":"auto","net":"tcp","tls":"tls","sni":"www.example.com"}'
      {
        printf 'vmess://'
        printf '%s' "$json" | base64 -w0
        printf '\n'
      } > share.txt
      janet "$script" normalize --format share-links --prefix provider --input share.txt --output nodes.json
      jq -e '.[0].protocol == "vmess" and .[0].name == "provider/Tokyo JP 1"' nodes.json >/dev/null
      printf '%s\n' '- {name: Premium-HK, type: vmess, server: 203.0.113.11, port: 443, uuid: b831381d-6324-4d53-ad4f-8cda48b30811, alterId: 0, cipher: auto}' > clash.txt
      janet "$script" normalize --format clash --prefix clash --input clash.txt --output clash.json
      jq -e '.[0].protocol == "vmess" and .[0].server == "203.0.113.11"' clash.json >/dev/null
      cat > model.json <<'EOF'
      {"mode":"rule-based","defaultTarget":"group:Auto","blockQuic":false,"groups":{"Demo":{"members":["node:provider/Tokyo JP 1"],"strategy":"url-test","match":{},"fromSubscriptions":[],"test":{"url":"https://www.gstatic.com/generate_204","interval":"5m","tolerance":50}}},"rules":[],"subscriptionNames":["provider"],"dns":{"domestic":{"resolvers":["https://dns.alidns.com/dns-query"],"domains":[]},"remote":{"resolvers":["https://1.1.1.1/dns-query"],"via":"direct"},"fakeIp":{"enable":false,"exclude":[]},"hosts":{},"forwarders":{},"ipv6Answers":"keep"}}
      EOF
      janet "$script" render --model model.json --nodes nodes.json --rule-set remote --output engine.json
      sing-box check -c engine.json
      cat > block.json <<'EOF'
      {"mode":"rule-based","defaultTarget":"block","blockQuic":false,"groups":{},"rules":[],"subscriptionNames":[],"dns":{"domestic":{"resolvers":[],"domains":[]},"remote":{"resolvers":[],"via":"direct"},"fakeIp":{"enable":false,"exclude":[]},"hosts":{},"forwarders":{},"ipv6Answers":"keep"}}
      EOF
      janet "$script" render --model block.json --nodes nodes.json --rule-set remote --output block-engine.json
      jq -e '.route.final == "direct" and any(.route.rules[]; .action == "reject")' block-engine.json >/dev/null
      sing-box check -c block-engine.json
      echo ok > "$out"
    '';
  eval-boot-install =
    pkgs.runCommand "eval-boot-install" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnused];
    } ''
      set -eu
      closure=$TMPDIR/closure
      mkdir -p "$closure" "$TMPDIR/boot/extlinux" "$TMPDIR/state"
      printf 'console=ttyS0\n' > "$closure/kernel-params"
      printf 'new-kernel\n' > "$closure/kernel"
      printf 'new-initrd\n' > "$closure/initrd"
      printf 'old-kernel\n' > "$TMPDIR/boot/vmlinuz"
      printf 'old-initrd\n' > "$TMPDIR/boot/initrd"
      printf 'old cmdline\n' > "$TMPDIR/boot/cmdline.txt"
      printf '%s\n' 'DEFAULT janus' 'LABEL janus' '  LINUX /vmlinuz' '  INITRD /initrd' '  APPEND old' '  FDT /board.dtb' > "$TMPDIR/boot/extlinux.conf"
      printf '%s\n' 'timeout: 0' '    cmdline: old' > "$TMPDIR/boot/limine.conf"
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} install "$closure"
      grep -q "init=$closure/init" "$TMPDIR/boot/cmdline.txt"
      grep -q new-kernel "$TMPDIR/boot/vmlinuz"
      grep -q 'FDT /board.dtb' "$TMPDIR/boot/extlinux.conf"
      grep -q "cmdline: console=ttyS0 init=$closure/init" "$TMPDIR/boot/limine.conf"
      grep -q old-kernel "$TMPDIR/state/boot-previous/vmlinuz"
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} restore
      grep -q old-kernel "$TMPDIR/boot/vmlinuz"
      grep -q 'old cmdline' "$TMPDIR/boot/cmdline.txt"
      echo ok > "$out"
    '';
}
