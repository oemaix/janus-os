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
  eval-proxy-local = let
    os = mk [
      base
      {
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.security.allowInlineSecrets = true;
        janus.proxy = {
          enable = true;
          nodes.local = {
            protocol = "shadowsocks";
            server = "127.0.0.1";
            port = 18388;
            shadowsocks.method = "aes-256-gcm";
            shadowsocks.password = "janus-local-proxy-test";
          };
          groups.Local = {
            members = ["node:local"];
            strategy = "manual";
            default = "local";
          };
        };
      }
    ];
    engine = os.config.system.build.janusEngineConfig;
  in
    pkgs.runCommand "eval-proxy-local" {
      nativeBuildInputs = [pkgs.sing-box pkgs.jq pkgs.curl pkgs.python3];
    } ''
      set -eu
      sing-box check -c ${engine}
      jq -e '
        .outbounds[]
        | select(.tag == "local")
        | .type == "shadowsocks"
          and .server == "127.0.0.1"
          and .server_port == 18388
          and .method == "aes-256-gcm"
          and .password == "janus-local-proxy-test"
          and .routing_mark == 74
      ' ${engine} >/dev/null
      jq -e '.outbounds[] | select(.tag == "local") | del(.routing_mark)' ${engine} > outbound.json
      jq -n --slurpfile ob outbound.json '{
        log: {level: "info"},
        inbounds: [{
          type: "socks",
          tag: "socks",
          listen: "127.0.0.1",
          listen_port: 11080
        }],
        outbounds: $ob,
        route: {final: "local"}
      }' > client.json
      jq -n --slurpfile ob outbound.json '{
        log: {level: "info"},
        inbounds: [{
          type: "shadowsocks",
          tag: "ss",
          listen: "127.0.0.1",
          listen_port: $ob[0].server_port,
          method: $ob[0].method,
          password: $ob[0].password
        }],
        outbounds: [{type: "direct", tag: "direct"}]
      }' > server.json
      sing-box check -c client.json
      sing-box check -c server.json
      web=$(mktemp -d)
      printf '%s\n' janus-local-ok > "$web/token"
      python3 -m http.server 18080 --bind 127.0.0.1 --directory "$web" > http.log 2>&1 &
      sing-box run -c server.json > server.log 2>&1 &
      sing-box run -c client.json > client.log 2>&1 &
      trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
      if ! curl -fsS --retry 30 --retry-delay 0 --retry-all-errors --max-time 20 \
        --socks5-hostname 127.0.0.1:11080 \
        http://127.0.0.1:18080/token | grep -q janus-local-ok; then
        echo "--- server ---" >&2
        cat server.log >&2 || true
        echo "--- client ---" >&2
        cat client.log >&2 || true
        echo "--- http ---" >&2
        cat http.log >&2 || true
        exit 1
      fi
      if ! grep -q 'inbound connection' server.log; then
        echo "the page was fetched without a shadowsocks hop" >&2
        cat server.log >&2 || true
        exit 1
      fi
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
  eval-audit = let
    os = mk [
      base
      {
        janus.monitoring.audit.enable = true;
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
      }
    ];
    bin = os.config.environment.etc."janus/bin/janus-audit".source;
    spec = os.config.environment.etc."janus/audit.json".text;
  in
    pkgs.runCommand "eval-audit" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -eu
      printf '%s\n' ${lib.escapeShellArg spec} | jq -e '.enable == true and (.cidrs | index("192.168.10.1/24"))' >/dev/null
      printf '%s\n' '[DESTROY] tcp 6 src=192.168.10.20 dst=203.0.113.9 sport=40000 dport=443 packets=2 bytes=40 src=203.0.113.9 dst=192.168.10.20 sport=443 dport=40000 packets=2 bytes=60' | ${bin} parse > one.json
      jq -e '.proto == "tcp" and .src == "192.168.10.20" and .dst == "203.0.113.9" and .sport == 40000 and .dport == 443 and .bytes == 100 and .domain == null' one.json >/dev/null
      dir=$TMPDIR/audit
      mkdir -p "$dir"
      jq -nc --arg path "$dir/log.jsonl" '{enable:true, retention:"7d", path:$path, cidrs:["192.168.10.1/24"]}' > "$dir/audit.json"
      {
        printf '%s\n' '[DESTROY] tcp 6 src=10.0.0.8 dst=203.0.113.9 sport=1 dport=443 packets=1 bytes=1 src=203.0.113.9 dst=10.0.0.8 sport=443 dport=1 packets=1 bytes=1'
        printf '%s\n' '[DESTROY] tcp 6 src=192.168.10.20 dst=203.0.113.9 sport=40000 dport=443 packets=2 bytes=40 src=203.0.113.9 dst=192.168.10.20 sport=443 dport=40000 packets=2 bytes=60'
      } | JANUS_AUDIT_JSON=$dir/audit.json JANUS_AUDIT_FEED=1 ${bin} record
      test "$(wc -l < "$dir/log.jsonl" | tr -d '[:space:]')" = 1
      jq -e '.src == "192.168.10.20"' "$dir/log.jsonl" >/dev/null
      echo ok > "$out"
    '';
  eval-slots = let
    os = mk [
      base
      {janus.storage.slots.enable = true;}
    ];
  in
    pkgs.runCommand "eval-slots" {} ''
      test ${lib.escapeShellArg os.config.fileSystems."/".device} = /dev/disk/by-janus/root
      test ${lib.escapeShellArg os.config.fileSystems."/nix".device} = /dev/disk/by-janus/nix
      test ${
        if os.config.system.build.janusImage.slots
        then "yes"
        else "no"
      } = yes
      echo ${lib.escapeShellArg os.config.boot.initrd.systemd.services.janus-slot-select.script} | grep -q 4a414e55-5300-4000-8000-000000000006
      echo ${lib.escapeShellArg os.config.environment.etc."janus/slots.json".text} | grep -q 4a414e55-5300-4000-8000-000000000007
      test -n ${lib.escapeShellArg os.config.system.build.janusSlotImages.name}
      echo ok > "$out"
    '';
  eval-boot-slot =
    pkgs.runCommand "eval-boot-slot" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnused];
    } ''
      set -eu
      store=$TMPDIR/nix
      closure=/nix/store/closure
      mkdir -p "$store''${closure#/nix}" "$TMPDIR/boot/extlinux" "$TMPDIR/state"
      printf 'console=ttyS0\n' > "$store''${closure#/nix}/kernel-params"
      printf 'new-kernel\n' > "$store''${closure#/nix}/kernel"
      printf 'new-initrd\n' > "$store''${closure#/nix}/initrd"
      printf 'old-kernel\n' > "$TMPDIR/boot/vmlinuz"
      printf 'old-initrd\n' > "$TMPDIR/boot/initrd"
      printf 'a\n' > "$TMPDIR/boot/slot"
      printf '%s\n' 'DEFAULT slot-a' 'LABEL slot-a' '  LINUX /vmlinuz' '  INITRD /initrd' '  APPEND old-a' 'LABEL slot-b' '  LINUX /vmlinuz-b' '  INITRD /initrd-b' '  APPEND old-b' > "$TMPDIR/boot/extlinux.conf"
      printf '%s\n' 'timeout: 0' '/slot-a' '    cmdline: old-a' '/slot-b' '    cmdline: old-b' > "$TMPDIR/boot/limine.conf"
      printf '%s\n' 'kernel=vmlinuz' > "$TMPDIR/boot/config.txt"
      printf '%s\n' 'old-a' > "$TMPDIR/boot/cmdline-a.txt"
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state JANUS_SLOT_STORE=$store bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} install-slot "$closure" b
      grep -q new-kernel "$TMPDIR/boot/vmlinuz-b"
      grep -q old-kernel "$TMPDIR/boot/vmlinuz"
      grep -q '^DEFAULT slot-b$' "$TMPDIR/boot/extlinux.conf"
      grep -q 'janus.slot=b' "$TMPDIR/boot/cmdline.txt"
      test "$(grep -m1 '^/slot-' "$TMPDIR/boot/limine.conf")" = /slot-b
      grep -q '^kernel=vmlinuz-b$' "$TMPDIR/boot/config.txt"
      test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = b
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} restore-slot
      test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = a
      grep -q '^DEFAULT slot-a$' "$TMPDIR/boot/extlinux.conf"
      test "$(grep -m1 '^/slot-' "$TMPDIR/boot/limine.conf")" = /slot-a
      grep -q '^kernel=vmlinuz$' "$TMPDIR/boot/config.txt"
      echo ok > "$out"
    '';

  eval-hmi = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.hardware.peripherals.panel = {
          class = "hmi";
          hmi.profile = "waveshare-1.3-oled-hat";
          hmi.keys.KEY2 = "factory-reset";
        };
      }
    ];
    conf = os.config.environment.etc."janus/hmi-panel.conf".text;
    boot = builtins.unsafeDiscardStringContext os.config.system.build.janusBoardImage.bootExtra;
    janus = self.packages.${pkgs.stdenv.hostPlatform.system}.janus-cli;
  in
    pkgs.runCommand "eval-hmi" {
      nativeBuildInputs = [pkgs.janet];
    } ''
      janet ${../janet/hmi.janet} check
      cat > conf << 'ENDCONF'
      ${conf}
      ENDCONF
      grep -q $'control\tleft\tpage-prev\t5' conf
      grep -q $'control\tKEY1\trefresh\t21' conf
      grep -q $'control\tKEY2\tfactory-reset\t20' conf
      grep -q $'control\tKEY3\treboot-hold\t16' conf
      cat > boot << 'ENDBOOT'
      ${boot}
      ENDBOOT
      grep -q 'dtparam=spi=on' boot
      grep -q 'gpio=6,19,5,26,13,21,20,16=pu' boot
      test ${os.config.janus.hardware.peripherals.panel.hmi.driver} = sh1106
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-hmi-panel.wantedBy
        then "yes"
        else "no"
      } = yes
      printf '%s\n' ${lib.escapeShellArg os.config.systemd.services.janus-hmi-panel.serviceConfig.ExecStart} > unit
      grep -q '/bin/janus-hmi ' unit
      panel=$(awk -F '\t' '$1=="bin" && $2=="panel" {print $3}' conf)
      snap=$(awk -F '\t' '$1=="bin" && $2=="snapshot" {print $3}' conf)
      "$panel" --self-test
      "$snap" conf > snap.out
      grep -q $'uptime\t' snap.out
      grep -q $'tunnel-error\t0' snap.out
      set +e
      ${janus}/bin/janus reset --state
      code=$?
      set -e
      test "$code" = 2
      echo ok > "$out"
    '';

  eval-hmi-board = fail "eval-hmi-board" [
    base
    {
      janus.hardware.peripherals.panel = {
        class = "hmi";
        hmi.profile = "waveshare-1.3-oled-hat";
      };
    }
  ];
  eval-hmi-profile = fail "eval-hmi-profile" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.hardware.peripherals.panel.class = "hmi";
    }
  ];
  eval-hmi-key = fail "eval-hmi-key" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.hardware.peripherals.panel = {
        class = "hmi";
        hmi.profile = "waveshare-1.3-oled-hat";
        hmi.keys.up = "refresh";
      };
    }
  ];

  eval-power = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.hardware.peripherals.ups = {
          class = "power";
          match.i2cAddress = "0x40";
        };
        janus.hardware.peripherals.panel = {
          class = "hmi";
          hmi.profile = "waveshare-1.3-oled-hat";
        };
      }
    ];
    conf = os.config.environment.etc."janus/power.conf".text;
    boot = builtins.unsafeDiscardStringContext os.config.system.build.janusBoardImage.bootExtra;
    dtbo = os.config.system.build.janusIna219Dtbo;
  in
    pkgs.runCommand "eval-power" {} ''
      test -s ${dtbo}
      cat > conf << 'ENDCONF'
      ${conf}
      ENDCONF
      grep -q $'sign\tnegative' conf
      grep -q $'armed\t1' conf
      cat > boot << 'ENDBOOT'
      ${boot}
      ENDBOOT
      grep -q 'dtparam=i2c_arm=on' boot
      grep -q 'dtoverlay=janus-ina219' boot
      grep -q 'overlays/janus-ina219.dtbo' boot
      grep -q 'dtparam=spi=on' boot
      test ${
        if os.config.janus.hardware.peripherals.ups.power.shutdown.enable
        then "yes"
        else "no"
      } = yes
      test ${
        if lib.elem "network-pre.target" os.config.systemd.services.janus-power-guard.before
        then "yes"
        else "no"
      } = yes
      test ${
        if lib.elem "network-pre.target" os.config.systemd.services.janus-power-guard.wants
        then "yes"
        else "no"
      } = yes
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-power-guard.wantedBy
        then "yes"
        else "no"
      } = yes
      test ${
        if os.config.systemd.services.janus-power-guard.serviceConfig.TimeoutStartSec == "infinity"
        then "yes"
        else "no"
      } = yes
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-power.wantedBy
        then "yes"
        else "no"
      } = yes
      bin=$(awk -F '\t' '$1=="bin" { print $2 }' conf)
      field() {
        printf '%s\n' "$1" | awk -F '\t' -v k="$2" '$1 == k { print $2 }'
      }
      decide() {
        VOLTS=$1 MA=$2 SIGN=$3 ARMED=$4 LOW_MS=$5 CRITICAL_MS=$6 DT_MS=$7 \
          WARN=3.60 SHUTDOWN=3.50 CRITICAL=3.30 \
          "$bin" step
      }
      got=$(decide 3.40 -40 negative 1 59000 0 1000)
      test "$(field "$got" action)" = poweroff
      got=$(decide 3.40 -40 negative 1 58000 0 1000)
      test "$(field "$got" action)" = none
      test "$(field "$got" low-ms)" = 59000
      got=$(decide 3.20 -40 negative 1 0 9000 1000)
      test "$(field "$got" action)" = poweroff
      got=$(decide 3.00 40 negative 1 0 9000 1000)
      test "$(field "$got" action)" = none
      test "$(field "$got" direction)" = charge
      got=$(decide 3.00 -4 negative 1 59000 9000 1000)
      test "$(field "$got" action)" = none
      test "$(field "$got" low-ms)" = 0
      got=$(decide 3.00 -5 negative 1 59000 9000 1000)
      test "$(field "$got" direction)" = idle
      test "$(field "$got" low-ms)" = 0
      got=$(decide 3.00 5 negative 1 59000 9000 1000)
      test "$(field "$got" direction)" = idle
      got=$(decide 3.00 -6 negative 1 0 0 1000)
      test "$(field "$got" direction)" = discharge
      got=$(decide 3.00 -40 negative 0 59000 9000 1000)
      test "$(field "$got" action)" = none
      test "$(field "$got" warning)" = 1
      got=$(decide 3.60 -40 negative 1 0 0 1000)
      test "$(field "$got" warning)" = 1
      test "$(field "$got" action)" = none
      got=$(decide 3.61 -40 negative 1 0 0 1000)
      test "$(field "$got" warning)" = 0
      got=$(VOLTS=3.54 MA=-40 SIGN=negative ARMED=1 "$bin" boot-step)
      test "$(field "$got" action)" = poweroff
      got=$(VOLTS=3.55 MA=-40 SIGN=negative ARMED=1 "$bin" boot-step)
      test "$(field "$got" action)" = none
      got=$(VOLTS=3.40 MA=40 SIGN=negative ARMED=1 "$bin" boot-step)
      test "$(field "$got" action)" = none
      got=$(VOLTS=3.40 MA=-40 SIGN=negative ARMED=0 "$bin" boot-step)
      test "$(field "$got" action)" = none
      sys=$(mktemp -d)
      mkdir -p "$sys/hwmon0"
      printf '%s\n' ina219 > "$sys/hwmon0/name"
      printf '%s\n' 4108 > "$sys/hwmon0/in1_input"
      printf '%s\n' -33 > "$sys/hwmon0/curr1_input"
      JANUS_POWER_SYS=$sys "$bin" status conf | grep -q '4.11 V, -33 mA, discharge, shutdown armed'
      flag=$sys/off
      printf '%s\n' 3540 > "$sys/hwmon0/in1_input"
      printf '%s\n' -40 > "$sys/hwmon0/curr1_input"
      rm -f "$flag"
      set +e
      JANUS_POWER_SYS=$sys JANUS_POWER_OFF="touch $flag" timeout 2 "$bin" guard conf
      code=$?
      set -e
      test "$code" = 124
      test -f "$flag"
      rm -f "$flag"
      printf '%s\n' 3550 > "$sys/hwmon0/in1_input"
      JANUS_POWER_SYS=$sys JANUS_POWER_OFF="touch $flag" "$bin" guard conf
      test ! -f "$flag"
      printf '%s\n' 3000 > "$sys/hwmon0/in1_input"
      printf '%s\n' 40 > "$sys/hwmon0/curr1_input"
      JANUS_POWER_SYS=$sys JANUS_POWER_OFF="touch $flag" "$bin" guard conf
      test ! -f "$flag"
      printf '%s\n' -5 > "$sys/hwmon0/curr1_input"
      JANUS_POWER_SYS=$sys JANUS_POWER_OFF="touch $flag" "$bin" guard conf
      test ! -f "$flag"
      empty=$(mktemp -d)
      JANUS_POWER_SYS=$empty JANUS_POWER_PAUSE=true JANUS_POWER_OFF="touch $flag" "$bin" guard conf
      test ! -f "$flag"
      printf '%s\n' 3000 > "$sys/hwmon0/in1_input"
      printf '%s\n' -40 > "$sys/hwmon0/curr1_input"
      printf '%s\n' 1000 > "$sys/clock"
      : > "$sys/ticks"
      cat > "$sys/now" << 'EOF'
      #!/bin/sh
      n=$(cat "$1")
      printf '%s\n' "$n"
      printf '%s\n' $((n + 10)) > "$1"
      printf 'x\n' >> "$2"
      EOF
      chmod +x "$sys/now"
      JANUS_POWER_SYS=$sys JANUS_POWER_OFF="touch $flag" JANUS_POWER_PAUSE=true \
        JANUS_POWER_NOW="$sys/now $sys/clock $sys/ticks" "$bin" watch conf
      test -f "$flag"
      test "$(grep -c x "$sys/ticks")" = 11
      echo ok > "$out"
    '';

  eval-power-unarmed = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.hardware.peripherals.ups = {
          class = "power";
          match.i2cAddress = "0x43";
        };
      }
    ];
    boot = builtins.unsafeDiscardStringContext os.config.system.build.janusBoardImage.bootExtra;
  in
    pkgs.runCommand "eval-power-unarmed" {} ''
      test ${
        if os.config.janus.hardware.peripherals.ups.power.shutdown.enable
        then "yes"
        else "no"
      } = no
      test ${
        if os.config.environment.etc ? "janus/power.conf"
        then "yes"
        else "no"
      } = no
      test ${
        if os.config.systemd.services ? "janus-power"
        then "yes"
        else "no"
      } = no
      cat > boot << 'ENDBOOT'
      ${boot}
      ENDBOOT
      if grep -q 'dtoverlay=janus-ina219' boot; then
        echo "unarmed profile installed an INA219 overlay" >&2
        exit 1
      fi
      echo ok > "$out"
    '';

  eval-power-low = fail "eval-power-low" [
    base
    {
      janus.hardware.peripherals.ups = {
        class = "power";
        match.i2cAddress = "0x40";
        power.shutdown.volts = 3.40;
      };
    }
  ];
  eval-power-arm = fail "eval-power-arm" [
    base
    {
      janus.hardware.peripherals.ups = {
        class = "power";
        match.i2cAddress = "0x43";
        power.shutdown.enable = true;
      };
    }
  ];
}
