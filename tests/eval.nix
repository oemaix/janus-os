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
      buildSystem = pkgs.stdenv.hostPlatform.system;
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
          ipv6.mode = "delegated";
        };
      }
    ];
    rules = os.config.networking.nftables.tables.janus.content;
    dhcp = os.config.systemd.network.networks."40-wan-main".networkConfig.DHCP;
    range = builtins.head os.config.services.dnsmasq.settings.dhcp-range;
    dnsOpt = builtins.head os.config.services.dnsmasq.settings.dhcp-option;
    raDns = os.config.systemd.network.networks."50-lan-lan".ipv6SendRAConfig.DNS;
  in
    pkgs.runCommand "eval-router" {} ''
      cat > rules.nft <<'EOF'
      ${rules}
      EOF
      grep -q masquerade rules.nft
      grep -q 192.168.10.0/24 rules.nft
      test ${lib.escapeShellArg dhcp} = ipv4
      echo ${lib.escapeShellArg range} | grep -q 192.168.10.100
      echo ${lib.escapeShellArg range} | grep -q 'set:janus-lan,'
      echo ${lib.escapeShellArg dnsOpt} | grep -q 'tag:janus-lan,option:dns-server,192.168.10.1'
      test ${lib.escapeShellArg raDns} = _link_local
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.dnsmasq.wants)} | grep -F -q 'sys-subsystem-net-devices-br\x2dlan.device'
      if printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.dnsmasq.wants)} | grep -F -q network-online.target; then
        echo "dnsmasq still waits for the WAN" >&2
        exit 1
      fi
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
      nativeBuildInputs = [self.packages.${system}.janus-build pkgs.age pkgs.sops pkgs.jq];
    } ''
      export HOME=$TMPDIR
      janus-build init "$TMPDIR/fleet"
      test -f "$TMPDIR/fleet/flake.nix"
      test -d "$TMPDIR/fleet/.git"
      url=$(sed -n 's/.*inputs\.janus\.url = "\([^"]*\)".*/\1/p' "$TMPDIR/fleet/flake.nix")
      case "$url" in
        github:oemaix/janus-os/*)
          ref=''${url#github:oemaix/janus-os/}
          case "$ref" in
            main | [0-9]*) ;;
            *)
              echo "janus url is not a train: $url" >&2
              exit 1
              ;;
          esac
          if [ ''${#ref} -eq 40 ] && ! echo "$ref" | grep -q '[^0-9a-f]'; then
            echo "janus url is a commit: $url" >&2
            exit 1
          fi
          jq -e --arg ref "$ref" '
            .nodes.janus.original.ref == $ref
            and (.nodes.janus.original | has("rev") | not)
            and (.nodes.janus.locked.rev | test("^[0-9a-f]{40}$"))
          ' "$TMPDIR/fleet/flake.lock" >/dev/null
          ;;
        path:*) ;;
        *)
          echo "unexpected janus url: $url" >&2
          exit 1
          ;;
      esac
      cd "$TMPDIR/fleet"
      if janus-build update --train 1.3-dev; then
        echo "a topic branch was accepted as a train" >&2
        exit 1
      fi
      if janus-build update --train v1.3.0; then
        echo "a tag was accepted as a train" >&2
        exit 1
      fi
      if janus-build update --train 1.3.0; then
        echo "a patch version was accepted as a train" >&2
        exit 1
      fi
      now=$(sed -n 's/.*inputs\.janus\.url = "\([^"]*\)".*/\1/p' flake.nix)
      test "$now" = "$url"
      janus-build host add potato
      test -f hosts/potato/configuration.nix
      janus-build secret keygen potato > "$TMPDIR/age.key"
      test -s secrets/keys/potato.pub
      grep -q age1 secrets/keys/potato.pub
      if printf '%s\n' x | janus-build secret set secrets/nope/potato.yaml; then
        echo "unknown secret path should exit 2" >&2
        exit 1
      fi
      if : | janus-build secret set secrets/wifi/potato/ap.yaml; then
        echo "empty secret was accepted" >&2
        exit 1
      fi
      printf '%s\n' 'page-secret' | janus-build secret set secrets/web/potato.yaml
      test -s secrets/web/potato.yaml
      if grep -q page-secret secrets/web/potato.yaml; then
        echo "maintenance passphrase was stored in plaintext" >&2
        exit 1
      fi
      SOPS_AGE_KEY_FILE="$TMPDIR/age.key" sops -d --extract '["value"]' secrets/web/potato.yaml > "$TMPDIR/web-pass"
      printf '%s' 'page-secret' | cmp - "$TMPDIR/web-pass"
      printf '%s\n' 'username: alice' 'password: s3cret' | janus-build secret set secrets/pppoe/potato/wan.yaml
      SOPS_AGE_KEY_FILE="$TMPDIR/age.key" sops -d secrets/pppoe/potato/wan.yaml > "$TMPDIR/pppoe"
      printf '%s\n' 'username: alice' 'password: s3cret' | cmp - "$TMPDIR/pppoe"
      printf '%s\n' 'uuid: abc' 'password: node-secret' | janus-build secret set secrets/nodes/exit.yaml
      SOPS_AGE_KEY_FILE="$TMPDIR/age.key" sops -d secrets/nodes/exit.yaml > "$TMPDIR/node"
      printf '%s\n' 'uuid: abc' 'password: node-secret' | cmp - "$TMPDIR/node"
      printf '%s\n' 'wg-private' | janus-build secret set secrets/wireguard/potato/uplink.yaml
      SOPS_AGE_KEY_FILE="$TMPDIR/age.key" sops -d --extract '["value"]' secrets/wireguard/potato/uplink.yaml > "$TMPDIR/wg"
      printf '%s' 'wg-private' | cmp - "$TMPDIR/wg"
      if grep -q -- '--arg value' "$(command -v janus-build)"; then
        echo "secret plaintext is passed to jq as an argument" >&2
        exit 1
      fi
      grep -q 'jq -Rs' "$(command -v janus-build)"
      janus-build host add other
      janus-build secret keygen other > "$TMPDIR/other.key"
      if SOPS_AGE_KEY_FILE="$TMPDIR/other.key" sops -d --extract '["value"]' secrets/web/potato.yaml > "$TMPDIR/stolen"; then
        echo "maintenance passphrase was readable by another host" >&2
        exit 1
      fi
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
    rpi4 = one "rpi4";
    rpi2 = one "rpi2";
    vf2 = one "visionfive2";
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
      echo ${lib.escapeShellArg (lib.concatStringsSep " " r4s.config.boot.initrd.availableKernelModules)} | grep -q dw_mmc-rockchip
      echo ${text potato.config.system.build.janusBoardImage.firmwareInstall} | grep -q u-boot.gxl
      if echo ${lib.escapeShellArg (lib.concatStringsSep " " potato.config.boot.initrd.availableKernelModules)} | grep -q sdhci_meson; then
        echo "le potato still requests sdhci_meson" >&2
        exit 1
      fi
      test ${toString (lib.length (lib.attrNames zero.config.janus.network.ports))} = 0
      echo ${text zero.config.system.build.janusBoardImage.bootExtra} | grep -q config.txt
      echo ${text zero.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2837-rpi-zero-2-w.dtb
      test ${
        if zero.config.system.build.janusImage.hybridFatMbr or false
        then "yes"
        else "no"
      } = yes
      test ${lib.escapeShellArg (lib.head (lib.attrNames rpi.config.janus.network.ports))} = eth0
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2710-rpi-3-b.dtb
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2710-rpi-3-b-plus.dtb
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q '\[pi3\]'
      echo ${text rpi.config.system.build.janusBoardImage.bootExtra} | grep -q '\[pi3+\]'
      test ${
        if rpi.config.system.build.janusImage.hybridFatMbr or false
        then "yes"
        else "no"
      } = yes
      test ${lib.escapeShellArg rpi4.config.janus.build.strategy} = emulated
      test ${lib.escapeShellArg rpi4.pkgs.stdenv.hostPlatform.system} = aarch64-linux
      test ${lib.escapeShellArg (lib.head (lib.attrNames rpi4.config.janus.network.ports))} = eth0
      test ${toString rpi4.config.janus.storage.firmwareOffsetMiB} = 0
      test ${
        if rpi4.config.system.build.janusImage.hybridFatMbr or false
        then "yes"
        else "no"
      } = yes
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2711-rpi-4-b.dtb
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2711-rpi-cm4-io.dtb
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q '\[pi4\]'
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q '\[cm4\]'
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q arm_64bit
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q start4.elf
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q fixup4.dat
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q /dtbs/broadcom/bcm2711-rpi-4-b.dtb
      echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q /dtbs/broadcom/bcm2711-rpi-cm4-io.dtb
      if echo ${text rpi4.config.system.build.janusBoardImage.bootExtra} | grep -q 'bcm2711-rpi-400\|\[pi400\]'; then
        echo "rpi4 profile still names the Pi 400" >&2
        exit 1
      fi
      test ${lib.escapeShellArg rpi2.config.janus.build.strategy} = cross
      test ${lib.escapeShellArg rpi2.config.nixpkgs.hostPlatform.system} = armv7l-linux
      test ${lib.escapeShellArg rpi2.config.nixpkgs.buildPlatform.system} = ${lib.escapeShellArg pkgs.stdenv.hostPlatform.system}
      test ${lib.escapeShellArg (lib.head (lib.attrNames rpi2.config.janus.network.ports))} = eth0
      test ${toString rpi2.config.janus.storage.firmwareOffsetMiB} = 0
      test ${
        if rpi2.config.system.build.janusImage.hybridFatMbr or false
        then "yes"
        else "no"
      } = yes
      echo ${text rpi2.config.system.build.janusBoardImage.bootExtra} | grep -q bcm2836-rpi-2-b.dtb
      echo ${text rpi2.config.system.build.janusBoardImage.bootExtra} | grep -q 'device_tree=bcm2836-rpi-2-b.dtb'
      if echo ${text rpi2.config.system.build.janusBoardImage.bootExtra} | grep -q arm_64bit; then
        echo "rpi2 config.txt enables aarch64" >&2
        exit 1
      fi
      test ${lib.escapeShellArg vf2.config.janus.build.strategy} = cross
      test ${lib.escapeShellArg vf2.config.nixpkgs.hostPlatform.system} = riscv64-linux
      test ${toString vf2.config.janus.storage.firmwareOffsetMiB} = 0
      test ${toString (lib.length (lib.attrNames vf2.config.janus.network.ports))} = 2
      echo ${lib.escapeShellArg (lib.concatStringsSep " " vf2.config.boot.initrd.availableKernelModules)} | grep -q pcie-starfive
      echo ${lib.escapeShellArg (lib.concatStringsSep " " vf2.config.boot.initrd.availableKernelModules)} | grep -q phy-jh7110-pcie
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q u-boot-spl.bin.normal.out
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q u-boot.itb
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q 0xf0000
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q 0xf00000
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q jh7110-starfive-visionfive-2-v1.2a.dtb
      echo ${text vf2.config.system.build.janusBoardImage.bootExtra} | grep -q jh7110-starfive-visionfive-2-v1.3b.dtb
      test ${lib.escapeShellArg plain.config.janus.build.strategy} = emulated
      test ${lib.escapeShellArg plain.config.sops.age.keyFile} = /var/lib/janus/secrets/age.key
      echo ok > "$out"
    '';
  eval-rpi2-mbr =
    pkgs.runCommand "eval-rpi2-mbr" {
      nativeBuildInputs = [pkgs.gptfdisk];
    } ''
      set -eu
      truncate -s 64M disk.img
      boot_start=1
      bootMiB=16
      sgdisk -o \
        -n "1:$((boot_start * 2048)):$(((boot_start + bootMiB) * 2048 - 1))" \
        -c 1:JANUS_BOOT -t 1:EF00 \
        disk.img >/dev/null
      export boot_start bootMiB
      bash ${../pkgs/hybrid-mbr.sh}
      typebyte=$(od -An -t u1 -j 450 -N 1 disk.img | tr -d '[:space:]')
      test "$typebyte" = 12
      start=$(od -An -t u4 -j 454 -N 4 disk.img | tr -d '[:space:]')
      count=$(od -An -t u4 -j 458 -N 4 disk.img | tr -d '[:space:]')
      test "$start" = 2048
      test "$count" = 32768
      eetype=$(od -An -t u1 -j 466 -N 1 disk.img | tr -d '[:space:]')
      eestart=$(od -An -t u4 -j 470 -N 4 disk.img | tr -d '[:space:]')
      eecount=$(od -An -t u4 -j 474 -N 4 disk.img | tr -d '[:space:]')
      test "$eetype" = 238
      test "$eestart" = 1
      test "$eecount" = 2047
      sig=$(od -An -t x1 -j 510 -N 2 disk.img | tr -d '[:space:]')
      test "$sig" = 55aa
      sgdisk -p disk.img | grep -q JANUS_BOOT
      echo ok > "$out"
    '';
  eval-tier3-boot = let
    board = name:
      mk [
        {
          janus.hardware.board = name;
          janus.access.ssh.authorizedKeys = [key];
        }
      ];
    rpi2 = board "rpi2";
    rpi4 = board "rpi4";
    vf2 = board "visionfive2";
  in
    pkgs.runCommand "eval-tier3-boot" {
      nativeBuildInputs = [pkgs.gnutar pkgs.xz];
      passAsFile = ["bootExtra"];
      bootExtra = builtins.unsafeDiscardStringContext vf2.config.system.build.janusBoardImage.bootExtra;
    } ''
      set -eu
      grep -A 12 -F ubootVisionFive2 ${self.inputs.nixpkgs}/pkgs/misc/uboot/default.nix > uboot.slice
      grep -q u-boot-spl.bin.normal.out uboot.slice
      grep -q u-boot.itb uboot.slice
      grep -q u-boot-spl.bin.normal.out "$bootExtraPath"
      grep -q u-boot.itb "$bootExtraPath"
      grep -q 0xf0000 "$bootExtraPath"
      grep -q 0xf00000 "$bootExtraPath"
      list_dts() {
        src=$1
        shift
        if [ -d "$src" ]; then
          for rel in "$@"; do
            test -f "$src/$rel"
          done
        else
          tar -tf "$src" > listing
          for rel in "$@"; do
            grep -q "$rel" listing
          done
        fi
      }
      list_dts ${rpi2.config.boot.kernelPackages.kernel.src} \
        arch/arm/boot/dts/broadcom/bcm2836-rpi-2-b.dts
      list_dts ${rpi4.config.boot.kernelPackages.kernel.src} \
        arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dts \
        arch/arm64/boot/dts/broadcom/bcm2711-rpi-cm4-io.dts
      list_dts ${vf2.config.boot.kernelPackages.kernel.src} \
        arch/riscv/boot/dts/starfive/jh7110-starfive-visionfive-2-v1.2a.dts \
        arch/riscv/boot/dts/starfive/jh7110-starfive-visionfive-2-v1.3b.dts
      echo ok > "$out"
    '';
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
      test ${toString os.config.systemd.services.janus-pppoe-main.unitConfig.StartLimitBurst} = 3
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
        janus.dns.encryption = "require";
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
    pre = os.config.systemd.services.janus-engine-prepare.serviceConfig.ExecStart;
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
      jq -e '[.inbounds[] | select(.type == "tproxy" and .network == "udp" and .listen == "0.0.0.0" and .listen_port == 5353)] | length == 1' ${engine} >/dev/null
      jq -e '[.inbounds[] | select(.type == "tproxy" and .network == "udp" and .listen == "::" and .listen_port == 5353)] | length == 1' ${engine} >/dev/null
      jq -e '[.inbounds[] | select(.type == "tproxy" and .network == "tcp")] | length == 0' ${engine} >/dev/null
      grep -q geodata-missing ${preText}
      grep -q '0x00004a01' ${markFile}
      grep -q 'dport 53 return' ${markFile}
      grep -q 'ip6 daddr != fc00::/18' ${markFile}
      grep -q 'priority -200' ${markFile}
      grep -q 'dport 853 reject' ${markFile}
      grep -q '1.1.1.1' ${markFile}
      if grep -q 'udp dport 443 reject' ${markFile}; then
        echo "QUIC is dropped for every LAN destination" >&2
        exit 1
      fi
      jq -e 'any(.route.rules[]; .network == "udp" and .port == [443] and .action == "reject")' ${engine} >/dev/null
      jq -e '.dns.cache_capacity == 4096' ${engine} >/dev/null
      jq -e '[.dns.servers[] | select(.tag | startswith("domestic-lan-"))] | length == 1' ${engine} >/dev/null
      jq -e '[.dns.servers[] | select(.tag | startswith("remote-lan-"))] | length == 1' ${engine} >/dev/null
      jq -e '[.dns.servers[] | select(.tag | startswith("bootstrap-"))] | length == 1' ${engine} >/dev/null
      jq -e 'any(.dns.servers[]; .tag == "domestic-lan-0" and .server == "dns.alidns.com")' ${engine} >/dev/null
      if jq -e 'any(.dns.servers[]; .server == "dot.pub")' ${engine} >/dev/null; then
        echo "the second domestic resolver is still queried" >&2
        exit 1
      fi
      jq -e 'any(.dns.rules[]; .server == "domestic-lan-0" and .rewrite_ttl == 60 and .client_subnet == null)' ${engine} >/dev/null
      jq -e 'any(.dns.rules[]; .server == "remote-lan-0" and .rewrite_ttl == 60 and .client_subnet == null)' ${engine} >/dev/null
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
      grep -a -F -q 'dest}.partial' ${proxyBin}
      if grep -a -F -q 'rm -f "/var/lib/janus/geodata/' ${proxyBin}; then
        echo "geo refresh deletes the live rule set" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  eval-proxy-lans = let
    os = mk [
      base
      {
        janus.network.vlans.guest-vlan = {
          port = "lan";
          id = 20;
        };
        janus.network.vlans.iot-vlan = {
          port = "lan";
          id = 30;
        };
        janus.network.lans.home = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.network.lans.guest = {
          members = ["lan.20"];
          address = "192.168.20.1";
          prefixLength = 24;
          proxy.mode = "bypass";
        };
        janus.network.lans.iot = {
          members = ["lan.30"];
          address = "192.168.30.1";
          prefixLength = 24;
          proxy.mode = "bypass";
          dns.recursive = false;
        };
        janus.dns.listen.lans = ["home"];
        janus.proxy = {
          enable = true;
          nodes.demo = {
            protocol = "vless";
            server = "203.0.113.10";
            port = 443;
            vless.uuid = "b831381d-6324-4d53-ad4f-8cda48b30811";
            tls.enable = true;
            tls.serverName = "www.example.com";
            tls.insecure = true;
          };
          rules = [
            {
              match.domains = ["blocked.example"];
              target = "block";
            }
            {
              match.domains = ["proxy.example"];
              target = "group:Auto";
            }
          ];
        };
      }
    ];
    engine = os.config.system.build.janusEngineConfig;
    mark = os.config.networking.nftables.tables.janus_intercept.content;
    nat = os.config.networking.nftables.tables.janus.content;
    policy = os.config.environment.etc."janus/dns-policy.json".text;
    markFile = pkgs.writeText "mark.nft" mark;
    natFile = pkgs.writeText "nat.nft" nat;
    dnsOpts = lib.concatStringsSep "\n" os.config.services.dnsmasq.settings.dhcp-option;
    guestRa = os.config.systemd.network.networks."50-lan-guest".ipv6SendRAConfig.EmitDNS or false;
  in
    pkgs.runCommand "eval-proxy-lans" {
      nativeBuildInputs = [pkgs.sing-box pkgs.jq];
    } ''
      sing-box check -c ${engine}
      jq -e 'any(.dns.servers[]; .type == "udp" and .server == "223.5.5.5")' ${engine} >/dev/null
      jq -e 'any(.inbounds[]; .tag == "dns-lan-guest" and .listen == "192.168.20.1" and .listen_port == 53 and .network == "udp")' ${engine} >/dev/null
      jq -e 'any(.inbounds[]; .tag == "dns-lan-guest-tcp" and .listen == "192.168.20.1" and .network == "tcp")' ${engine} >/dev/null
      jq -e '.route.final == "direct"' ${engine} >/dev/null
      jq -e '
        .dns.rules as $r
        | ($r | to_entries | map(select(.value.domain == ["blocked.example"] and .value.action == "reject" and .value.source_ip_cidr == ["192.168.10.0/24"])) | .[0].key) as $block
        | ($r | to_entries | map(select(.value.domain == ["proxy.example"] and .value.server == "fakeip" and .value.source_ip_cidr == ["192.168.10.0/24"])) | .[0].key) as $fake
        | ($r | to_entries | map(select(.value.query_type == ["AAAA"] and .value.action == "reject" and .value.source_ip_cidr == ["192.168.10.0/24"] and .value.domain == null)) | .[0].key) as $aaaa
        | ($block != null) and ($fake != null) and ($aaaa != null) and ($block < $aaaa) and ($fake < $aaaa)
      ' ${engine} >/dev/null
      jq -e 'any(.dns.rules[]; .source_ip_cidr == ["192.168.20.0/24"] and .server == "domestic-guest-0" and .action == "route")' ${engine} >/dev/null
      if jq -e 'any(.dns.rules[]; .source_ip_cidr == ["192.168.20.0/24"] and .server == "fakeip")' ${engine} >/dev/null; then
        echo "bypass guest received a fake-IP" >&2
        exit 1
      fi
      if jq -e 'any(.route.rules[]; .source_ip_cidr == ["192.168.20.0/24"])' ${engine} >/dev/null; then
        echo "bypass guest entered the route table" >&2
        exit 1
      fi
      jq -e 'any(.dns.rules[]; .source_ip_cidr == ["192.168.30.0/24"] and .action == "reject")' ${engine} >/dev/null
      echo ${lib.escapeShellArg policy} | jq -e '.lans[] | select(.name == "home") | .mode == "rule-based" and .fakeIp == true' >/dev/null
      echo ${lib.escapeShellArg policy} | jq -e '.lans[] | select(.name == "guest") | .mode == "bypass" and .fakeIp == false' >/dev/null
      echo ${lib.escapeShellArg policy} | jq -e '.lans[] | select(.name == "iot") | .recursive == false and .address == "192.168.30.1"' >/dev/null
      grep -q '192.168.10.0/24' ${natFile}
      if grep -q '192.168.20.0/24' ${natFile}; then
        echo "bypass guest is in janus_proxied_src" >&2
        exit 1
      fi
      grep 'meta mark set 0x00004a01' ${markFile} | grep -q 'br-home'
      if grep 'meta mark set 0x00004a01' ${markFile} | grep -q 'br-guest'; then
        echo "bypass guest is marked into table 2022" >&2
        exit 1
      fi
      grep 'redirect to :5353' ${natFile} | grep -q 'br-guest'
      grep 'redirect to :5353' ${natFile} | grep -q 'br-iot'
      echo ${lib.escapeShellArg dnsOpts} | grep -q 'tag:janus-home,option:dns-server,192.168.10.1'
      if echo ${lib.escapeShellArg dnsOpts} | grep -q 192.168.20.1; then
        echo "guest is told to use the router" >&2
        exit 1
      fi
      test ${
        if guestRa
        then "yes"
        else "no"
      } = no
      echo ok > "$out"
    '';
  eval-proxy-bypass-fakeip = fail "eval-proxy-bypass-fakeip" [
    base
    {
      janus.network.lans.lan = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
        proxy.mode = "bypass";
        dns.fakeIp.enable = true;
      };
      janus.proxy.enable = true;
    }
  ];
  eval-proxy-bypass-remote = fail "eval-proxy-bypass-remote" [
    base
    {
      janus.network.lans.lan = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
        proxy.mode = "bypass";
        dns.remote.resolvers = ["https://dns.google/dns-query"];
      };
      janus.proxy.enable = true;
    }
  ];
  eval-proxy-xray-lan = fail "eval-proxy-xray-lan" [
    base
    {
      janus.network.vlans.guest-vlan = {
        port = "lan";
        id = 20;
      };
      janus.network.lans.home = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.lans.guest = {
        members = ["lan.20"];
        address = "192.168.20.1";
        prefixLength = 24;
        proxy.mode = "bypass";
      };
      janus.proxy = {
        enable = true;
        engine = "xray";
      };
    }
  ];
  eval-proxy-bootstrap-empty = fail "eval-proxy-bootstrap-empty" [
    base
    {
      janus.network.lans.lan = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
        dns.bootstrap = [];
      };
      janus.proxy.enable = true;
    }
  ];
  eval-dns-require-plain = fail "eval-dns-require-plain" [
    base
    {
      janus.network.lans.lan = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.dns.encryption = "require";
      janus.dns.domestic.resolvers = ["223.5.5.5"];
      janus.dns.bootstrap = ["223.5.5.5"];
      janus.proxy.enable = true;
    }
  ];
  eval-dns-listen-unknown = fail "eval-dns-listen-unknown" [
    base
    {janus.dns.listen.lans = ["nope"];}
  ];
  eval-dns-xray-cache = fail "eval-dns-xray-cache" [
    base
    {
      janus.proxy = {
        enable = true;
        engine = "xray";
      };
      janus.dns.cache.size = 1024;
    }
  ];
  eval-proxy-sourcelan = fail "eval-proxy-sourcelan" [
    base
    {
      janus.network.vlans.guest-vlan = {
        port = "lan";
        id = 20;
      };
      janus.network.lans.home = {
        members = ["lan"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.lans.guest = {
        members = ["lan.20"];
        address = "192.168.20.1";
        prefixLength = 24;
      };
      janus.proxy = {
        enable = true;
        rules = [
          {
            match.domains = ["shared.example"];
            match.sourceLan = ["guest"];
            target = "direct";
          }
        ];
      };
    }
  ];
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
    proxyBin = os.config.environment.etc."janus/bin/janus-proxy".source;
    mark = os.config.networking.nftables.tables.janus_intercept.content;
    rules = pkgs.writeText "xray-intercept.nft" ''
      table inet janus_intercept {
        ${mark}
      }
    '';
    start = os.config.systemd.services.janus-engine.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-proxy-xray" {
      nativeBuildInputs = [pkgs.jq pkgs.xray pkgs.nftables];
    } ''
      xray run -test -c ${engine}
      jq -e '.inbounds[] | select(.protocol == "dokodemo-door" and .port == 12345)' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.tag == "dns-udp4" and .listen == "0.0.0.0" and .port == 5353 and .streamSettings.sockopt.tproxy == "tproxy")' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.tag == "dns-udp6" and .listen == "::" and .port == 5353 and .streamSettings.sockopt.tproxy == "tproxy" and .streamSettings.sockopt.v6only == true)' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.tag == "dns-tcp" and .listen == "::" and .port == 5353 and .settings.network == "tcp")' ${engine} >/dev/null
      jq -e 'any(.routing.rules[]; (["dns-tcp","dns-udp4","dns-udp6"] - (.inboundTag // [])) == [])' ${engine} >/dev/null
      jq -e '.inbounds[] | select(.tag == "api" and .port == 8080)' ${engine} >/dev/null
      jq -e '.outbounds[] | select(.protocol == "dns" and .tag == "dns-out")' ${engine} >/dev/null
      jq -e 'any(.routing.rules[]; ((.domain // []) | index("full:example.com")) and .source == ["192.168.10.0/24"] and .outboundTag == "direct")' ${engine} >/dev/null
      jq -e '.dns.queryStrategy == "UseIP"' ${engine} >/dev/null
      jq -e 'any(.dns.servers[]; .address == "fakedns" and .queryStrategy == "UseIPv4")' ${engine} >/dev/null
      jq -e 'any(.inbounds[]; .tag == "dns-lan-lan" and .listen == "192.168.10.1" and .port == 53)' ${engine} >/dev/null
      jq -e 'all(.dns.servers[]; .clientIp == null)' ${engine} >/dev/null
      jq -e '.dns.disableCache != true' ${engine} >/dev/null
      jq -e '.routing.balancers[] | select(.tag == "Wave") | .strategy.type == "roundRobin"' ${engine} >/dev/null
      jq -e '[.inbounds[] | select(.protocol == "tun" or .type == "tun")] | length == 0' ${engine} >/dev/null
      echo ${lib.escapeShellArg start} | grep -q 'xray run'
      grep -q 'export XRAY_LOCATION_ASSET=' ${proxyBin}
      grep -q 'meta l4proto { tcp, udp } meta mark set 0x00004a02 tproxy to :12345' ${rules}
      touch hosts
      export NIX_REDIRECTS="/etc/hosts=$PWD/hosts:/etc/protocols=${pkgs.iana-etc}/etc/protocols:/etc/services=${pkgs.iana-etc}/etc/services"
      LD_PRELOAD="${pkgs.libredirect}/lib/libredirect.so ${pkgs.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
        nft --check --file ${rules}
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
  eval-wifi-sops = let
    os = mk [
      base
      {
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
          ssid = "janus";
          passphraseSecret = "wifi-eval-home";
          lan = "lan";
        };
        sops.secrets.wifi-eval-home.sopsFile = ./fixtures/sops-placeholder;
      }
    ];
    requires = os.config.systemd.services.janus-hostapd-home.requires or [];
    secretRequires = os.config.systemd.services.janus-wifi-secret-home.requires or [];
    secretStart = lib.concatStringsSep " " (lib.toList os.config.systemd.services.janus-wifi-secret-home.serviceConfig.ExecStart);
    script = os.config.systemd.services.janus-hostapd-home.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-wifi-sops" {} ''
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q janus-wifi-secret-home.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " secretRequires)} | grep -q sops-install-secrets.service
      grep -q ${lib.escapeShellArg os.config.sops.secrets.wifi-eval-home.path} ${script}
      printf '%s\n' ${lib.escapeShellArg secretStart} | grep -q ${lib.escapeShellArg os.config.sops.secrets.wifi-eval-home.path}
      test ${lib.escapeShellArg os.config.sops.secrets.wifi-eval-home.key} = value
      echo ok > "$out"
    '';
  eval-wifi-onboard = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.security.allowInlineSecrets = true;
        janus.hardware.peripherals.radio = {
          class = "wifi";
          match.onboard = true;
        };
        janus.network.lans.lan = {
          members = ["home"];
          address = "10.255.252.32";
          prefixLength = 22;
        };
        janus.network.wifi.home = {
          peripheral = "radio";
          ssid = "janus";
          passphrase = "secret-pass";
          lan = "lan";
        };
      }
    ];
    script = os.config.systemd.services.janus-hostapd-home.serviceConfig.ExecStart;
    patch = lib.findFirst (p: p.name == "janus-rpi-onboard-wifi") null os.config.boot.kernelPatches;
    member = os.config.systemd.network.networks."30-member-lan-home";
    firmwareNames = lib.concatMapStringsSep " " (p: p.name) (
      lib.filter (p: lib.isAttrs p && lib.isDerivation p) (
        lib.flatten os.options.hardware.firmware.definitions
      )
    );
  in
    pkgs.runCommand "eval-wifi-onboard" {} ''
      test ${lib.escapeShellArg os.config.systemd.network.links."10-wifi-home".linkConfig.Name} = wifi-home
      test ${lib.escapeShellArg os.config.systemd.network.links."10-wifi-home".matchConfig.Driver} = brcmfmac
      test ${
        if member.linkConfig.Unmanaged or false
        then "yes"
        else "no"
      } = yes
      test ${
        if member.networkConfig ? Bridge
        then "yes"
        else "no"
      } = no
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.boot.kernelModules)} | grep -q brcmfmac
      test ${lib.escapeShellArg patch.structuredExtraConfig.MMC_SDHCI_IPROC.tristate} = m
      test ${lib.escapeShellArg patch.structuredExtraConfig.BRCMFMAC_SDIO.tristate} = y
      echo ${lib.escapeShellArg firmwareNames} | grep -q raspberrypi-wireless-firmware
      grep -q 'ht_capab=\[HT20\]\[SHORT-GI-20\]' ${script}
      grep -q wmm_enabled=1 ${script}
      grep -q 'set type __ap' ${script}
      grep -q 'interface=wifi-home' ${script}
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.janus-hostapd-home.after)} | grep -q 'wifi\\x2dhome'
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.janus-hostapd-home.after)} | grep -q 'br\\x2dlan'
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.janus-hostapd-home.wants)} | grep -q 'br\\x2dlan'
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services.janus-hostapd-home.bindsTo)} | grep -q 'wifi\\x2dhome[.]device'
      if grep -q 'did not join' ${script}; then
        echo "isolation failure path is in the default AP" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  eval-wifi-onboard-isolate = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.security.allowInlineSecrets = true;
        janus.hardware.peripherals.radio = {
          class = "wifi";
          match.onboard = true;
        };
        janus.network.lans.lan = {
          members = ["home"];
          address = "192.168.10.1";
          prefixLength = 24;
          isolation = true;
        };
        janus.network.wifi.home = {
          peripheral = "radio";
          ssid = "janus";
          passphrase = "secret-pass";
          lan = "lan";
        };
      }
    ];
    script = os.config.systemd.services.janus-hostapd-home.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-wifi-onboard-isolate" {} ''
      grep -q 'bridge link set dev wifi-home isolated on' ${script}
      grep -q 'did not join br-lan' ${script}
      grep -q 'bridge port is not isolated' ${script}
      grep -q 'exit 1' ${script}
      echo ok > "$out"
    '';
  eval-wifi-onboard-5g = fail "eval-wifi-onboard-5g" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.security.allowInlineSecrets = true;
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
      janus.network.lans.lan = {
        members = ["home"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.wifi.home = {
        peripheral = "radio";
        ssid = "janus";
        passphrase = "secret-pass";
        lan = "lan";
        band = "5g";
      };
    }
  ];
  eval-wifi-onboard-wpa3 = fail "eval-wifi-onboard-wpa3" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.security.allowInlineSecrets = true;
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
      janus.network.lans.lan = {
        members = ["home"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.wifi.home = {
        peripheral = "radio";
        ssid = "janus";
        passphrase = "secret-pass";
        lan = "lan";
        security = "wpa3";
      };
    }
  ];
  eval-wifi-onboard-channel = fail "eval-wifi-onboard-channel" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.security.allowInlineSecrets = true;
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
      janus.network.lans.lan = {
        members = ["home"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.wifi.home = {
        peripheral = "radio";
        ssid = "janus";
        passphrase = "secret-pass";
        lan = "lan";
        channel = 36;
      };
    }
  ];
  eval-wifi-onboard-two = fail "eval-wifi-onboard-two" [
    {
      janus.hardware.board = "rpi-zero-2w";
      janus.access.ssh.authorizedKeys = [key];
      janus.security.allowInlineSecrets = true;
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
      janus.network.lans.lan = {
        members = ["one" "two"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.wifi.one = {
        peripheral = "radio";
        ssid = "janus";
        passphrase = "secret-pass";
        lan = "lan";
      };
      janus.network.wifi.two = {
        peripheral = "radio";
        ssid = "janus-2";
        passphrase = "secret-pass";
        lan = "lan";
      };
    }
  ];
  eval-wifi-onboard-kernel = let
    os = mk [
      {
        janus.hardware.board = "rpi-zero-2w";
        janus.access.ssh.authorizedKeys = [key];
        janus.security.allowInlineSecrets = true;
        janus.hardware.peripherals.radio = {
          class = "wifi";
          match.onboard = true;
        };
        janus.network.lans.lan = {
          members = ["home"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.network.wifi.home = {
          peripheral = "radio";
          ssid = "janus";
          passphrase = "secret-pass";
          lan = "lan";
        };
      }
    ];
    kernel = os.config.boot.kernelPackages.kernel;
  in
    pkgs.runCommand "eval-wifi-onboard-kernel" {} ''
      grep -q '^CONFIG_MMC_SDHCI_IPROC=m$' ${kernel.configfile}
      grep -q '^CONFIG_BRCMFMAC=m$' ${kernel.configfile}
      grep -q '^CONFIG_BRCMFMAC_SDIO=y$' ${kernel.configfile}
      grep -q '^CONFIG_ARCH_BCM2835=y$' ${kernel.configfile}
      tar -tJf ${kernel.src} > "$TMPDIR/kernel-files"
      dts=$(grep -m1 'arch/arm64/boot/dts/broadcom/bcm2837-rpi-zero-2-w.dts$' "$TMPDIR/kernel-files")
      test -n "$dts"
      tar -xJf ${kernel.src} -O "''${dts%bcm2837-rpi-zero-2-w.dts}Makefile" > "$TMPDIR/broadcom.mk"
      grep -q 'dtb-$(CONFIG_ARCH_BCM2835)' "$TMPDIR/broadcom.mk"
      grep -q 'bcm2837-rpi-zero-2-w.dtb' "$TMPDIR/broadcom.mk"
      echo ok > "$out"
    '';
  eval-wifi-onboard-board = fail "eval-wifi-onboard-board" [
    base
    {
      janus.hardware.board = lib.mkForce "x86_64-test";
      janus.security.allowInlineSecrets = true;
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
      janus.network.lans.lan = {
        members = ["home"];
        address = "192.168.10.1";
        prefixLength = 24;
      };
      janus.network.wifi.home = {
        peripheral = "radio";
        ssid = "janus";
        passphrase = "secret-pass";
        lan = "lan";
      };
    }
  ];
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
        janus.remoteAccess.tailscale.authKeyFile = "/var/lib/janus/secrets/tailscale-authkey";
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
  eval-tailscale-key = fail "eval-tailscale-key" [
    base
    {janus.remoteAccess.tailscale.enable = true;}
  ];
  eval-tailscale-sops = let
    os = mk [
      base
      {
        sops.secrets.tailscale-eval.sopsFile = ./fixtures/sops-placeholder;
        janus.remoteAccess.tailscale = {
          enable = true;
          authKeySecret = "tailscale-eval";
        };
      }
    ];
    requires = os.config.systemd.services.tailscaled.requires or [];
  in
    pkgs.runCommand "eval-tailscale-sops" {} ''
      test ${lib.escapeShellArg os.config.services.tailscale.authKeyFile} = ${lib.escapeShellArg os.config.sops.secrets.tailscale-eval.path}
      test ${lib.escapeShellArg os.config.sops.secrets.tailscale-eval.key} = value
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.janus-tailscale-auth.requiredBy or []))} | grep -q tailscaled.service
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
  eval-refresh-dow = let
    os = mk [
      base
      {
        janus.access.web = {
          enable = true;
          passphraseFile = "/var/lib/janus/secrets/web-passphrase";
        };
        janus.proxy = {
          enable = true;
          geodata.refresh = "0 4 * * 2,4,6";
          subscriptions.a = {
            urlSecret = "subscription/a";
            refresh = "0 4 * * *";
          };
          subscriptions.b = {
            urlSecret = "subscription/b";
            enable = false;
          };
          subscriptions.c = {
            urlSecret = "subscription/c";
            refresh = "30 3 * * 1,5";
          };
          subscriptions.d = {
            urlSecret = "subscription/d";
            refresh = "0 0 * * 0,7";
          };
        };
        sops.secrets."subscription/a".sopsFile = ./fixtures/sops-placeholder;
        sops.secrets."subscription/b".sopsFile = ./fixtures/sops-placeholder;
        sops.secrets."subscription/c".sopsFile = ./fixtures/sops-placeholder;
        sops.secrets."subscription/d".sopsFile = ./fixtures/sops-placeholder;
      }
    ];
    model = os.config.environment.etc."janus/proxy-model.json".source;
  in
    pkgs.runCommand "eval-refresh-dow" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      test ${lib.escapeShellArg os.config.systemd.timers.janus-proxy-refresh-a.timerConfig.OnCalendar} = '*-*-* 04:00:00'
      test ${lib.escapeShellArg os.config.systemd.timers.janus-proxy-refresh-c.timerConfig.OnCalendar} = 'Mon,Fri *-*-* 03:30:00'
      test ${lib.escapeShellArg os.config.systemd.timers.janus-proxy-refresh-d.timerConfig.OnCalendar} = 'Sun *-*-* 00:00:00'
      test ${lib.escapeShellArg os.config.systemd.timers.janus-geodata-refresh.timerConfig.OnCalendar} = 'Tue,Thu,Sat *-*-* 04:00:00'
      echo ${lib.escapeShellArg (lib.concatStringsSep " " os.config.systemd.services."janus-proxy-refresh@".after)} | grep -q sops-install-secrets.service
      test ${
        if os.config.systemd.timers ? "janus-proxy-refresh-b"
        then "yes"
        else "no"
      } = no
      test ${lib.escapeShellArg os.config.janus.proxy.subscriptions.b.urlSecret} = subscription/b
      test ${
        if os.config.janus.proxy.subscriptions.b.enable
        then "yes"
        else "no"
      } = no
      echo ${lib.escapeShellArg os.config.environment.etc."janus/subscriptions.json".text} \
        | jq -e 'has("a") and has("c") and has("d") and (has("b") | not)' >/dev/null
      echo ${lib.escapeShellArg os.config.environment.etc."janus/web.json".text} \
        | jq -e '.subscriptions == ["a","c","d"]' >/dev/null
      jq -e '.subscriptionNames == ["a","c","d"]' ${model} >/dev/null
      echo ok > "$out"
    '';
  eval-refresh-dow-bad = fail "eval-refresh-dow-bad" [
    base
    {
      janus.proxy.enable = true;
      janus.proxy.geodata.refresh = "0 4 * * 8";
    }
  ];
  eval-refresh-dom = fail "eval-refresh-dom" [
    base
    {
      janus.proxy.enable = true;
      janus.proxy.geodata.refresh = "0 4 1 * *";
    }
  ];
  eval-subscription-dropped-group = let
    modules = [
      base
      {
        janus.proxy = {
          enable = true;
          subscriptions.b = {
            urlSecret = "subscription/b";
            enable = false;
          };
          groups.UseB = {
            fromSubscriptions = ["b"];
            match.kind = "regex";
            match.pattern = ".";
          };
        };
        sops.secrets."subscription/b".sopsFile = ./fixtures/sops-placeholder;
      }
    ];
    messages = lib.concatMapStringsSep "\n" (a: a.message) (
      lib.filter (a: !a.assertion) (mk modules).config.assertions
    );
  in
    pkgs.runCommand "eval-subscription-dropped-group" {} ''
      echo ${lib.escapeShellArg messages} | grep -F -q "janus.proxy.groups.UseB.fromSubscriptions names 'b', which is not an enabled subscription on this router."
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
  eval-subscription-dropped-member = let
    modules = [
      base
      {
        janus.proxy = {
          enable = true;
          subscriptions.b = {
            urlSecret = "subscription/b";
            enable = false;
          };
          groups.UseB = {
            members = ["sub:b"];
          };
        };
        sops.secrets."subscription/b".sopsFile = ./fixtures/sops-placeholder;
      }
    ];
    messages = lib.concatMapStringsSep "\n" (a: a.message) (
      lib.filter (a: !a.assertion) (mk modules).config.assertions
    );
  in
    pkgs.runCommand "eval-subscription-dropped-member" {} ''
      echo ${lib.escapeShellArg messages} | grep -F -q "janus.proxy.groups.UseB.members names 'sub:b', which is not an enabled subscription on this router."
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
  eval-subscription-cache =
    pkgs.runCommand "eval-subscription-cache" {
      nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.coreutils];
    } ''
      set -eu
      root=$TMPDIR/root
      mkdir -p "$root/bin" "$root/etc/janus" "$root/var/lib/janus/subscriptions"
      cat > "$root/bin/janet" << 'EOF'
      #!/bin/sh
      nodes=""
      out=""
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "--nodes" ]; then
          nodes=$arg
        fi
        if [ "$prev" = "--output" ]; then
          out=$arg
        fi
        prev=$arg
      done
      cp "$nodes" "$JANUS_NODES_OUT"
      printf '%s\n' '{}' > "$out"
      exit 0
      EOF
      cat > "$root/bin/sing-box" << 'EOF'
      #!/bin/sh
      exit 0
      EOF
      chmod +x "$root/bin/janet" "$root/bin/sing-box"
      printf '%s\n' '{"a":{"format":"auto"}}' > "$root/etc/janus/subscriptions.json"
      printf '%s\n' '{}' > "$root/etc/janus/proxy-model.json"
      printf '%s\n' '[]' > "$root/etc/janus/nodes-manual.json"
      printf '%s\n' '[{"name":"a/built"}]' > "$root/etc/janus/nodes-built.json"
      printf '%s\n' '[{"name":"a/live"}]' > "$root/var/lib/janus/subscriptions/a.json"
      printf '%s\n' '[{"name":"b/stale"}]' > "$root/var/lib/janus/subscriptions/b.json"
      {
        printf '%s\n' 'set -euo pipefail' 'JANUS_ENGINE=sing-box' 'JANUS_SCRIPT=unused' 'JANUS_FAIL_MODE=closed' 'JANUS_INTERCEPT=0' 'JANUS_DNS_TPROXY=0' 'JANUS_EGRESS_TABLE=' 'JANUS_NODES_OUT='"$TMPDIR/nodes.json"
        sed -e "s|/var/lib/janus|$root/var/lib/janus|g" -e "s|/etc/janus|$root/etc/janus|g" ${../pkgs/janus-engine.sh}
      } > "$root/run.sh"
      export PATH="$root/bin:$PATH"
      export JANUS_NODES_OUT=$TMPDIR/nodes.json
      bash "$root/run.sh" render
      jq -e '[.[].name] == ["a/live"]' "$TMPDIR/nodes.json" >/dev/null
      test -s "$root/var/lib/janus/subscriptions/b.json"
      echo ok > "$out"
    '';
  eval-subscription-armor =
    pkgs.runCommand "eval-subscription-armor" {
      nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.coreutils];
    } ''
      set -eu
      root=$TMPDIR/root
      mkdir -p "$root/etc/janus" "$root/var/lib/janus/subscriptions" "$root/run/secrets"
      printf '%s\n' '{"vendor":{"urlSecret":"sub","format":"auto","via":"direct","minimumNodes":1}}' > "$root/etc/janus/subscriptions.json"
      printf '%s\n' 'age-encryption.org/v1' '->' > "$root/run/secrets/sub"
      {
        printf '%s\n' 'set -euo pipefail' 'JANUS_ENGINE=sing-box' 'JANUS_SCRIPT=unused' 'JANUS_FAIL_MODE=closed' 'JANUS_INTERCEPT=0' 'JANUS_DNS_TPROXY=0' 'JANUS_EGRESS_TABLE='
        sed -e "s|/var/lib/janus|$root/var/lib/janus|g" -e "s|/etc/janus|$root/etc/janus|g" -e "s|/run/secrets|$root/run/secrets|g" ${../pkgs/janus-engine.sh}
      } > "$root/run.sh"
      if bash "$root/run.sh" refresh vendor; then
        echo "age armor was accepted as a subscription url" >&2
        exit 1
      fi
      grep -q 'age armor' "$root/var/lib/janus/subscriptions/vendor.error"
      echo ok > "$out"
    '';
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
  eval-monitoring = let
    off = mk [base];
    flows = mk [
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
        janus.monitoring.flows.export.collector = "192.0.2.10";
        janus.monitoring.flows.export.port = 4739;
        janus.monitoring.prometheus = {
          enable = true;
          zones = ["lan"];
        };
      }
    ];
    netflow = mk [
      base
      {
        janus.network.wans.main = {
          uplink = "wan";
          mode = "dhcp";
        };
        janus.monitoring.flows.export = {
          collector = "collector.example";
          protocol = "netflow9";
        };
      }
    ];
    scoped = mk [
      base
      {janus.monitoring.scope = "flows";}
    ];
    named = mk [
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
        janus.monitoring.interfaces = ["main" "lan"];
        janus.monitoring.flows.export.collector = "192.0.2.10";
      }
    ];
    opened = mk [
      base
      {
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.monitoring.prometheus.enable = true;
      }
    ];
    start = flows.config.systemd.services.janus-flow-export.serviceConfig.ExecStart;
    namedStart = named.config.systemd.services.janus-flow-export.serviceConfig.ExecStart;
    metrics = lib.removeSuffix " collect" flows.config.systemd.services.janus-metrics.serviceConfig.ExecStart;
    rules = flows.config.networking.nftables.tables.janus.content;
    openedRules = opened.config.networking.nftables.tables.janus.content;
  in
    pkgs.runCommand "eval-monitoring" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -eu
      test ${
        if off.config.services.prometheus.exporters.node.enable
        then "yes"
        else "no"
      } = no
      test ${
        if off.config.systemd.services ? janus-flow-export
        then "yes"
        else "no"
      } = no
      echo ${lib.escapeShellArg (lib.concatStringsSep "\n" scoped.config.warnings)} | grep -q 'flows.export.collector is unset'
      test ${lib.escapeShellArg flows.config.systemd.services.janus-flow-export.environment.JANUS_FLOW_VERSION} = 10
      test ${lib.escapeShellArg flows.config.systemd.services.janus-flow-export.environment.JANUS_COLLECTOR} = 192.0.2.10:4739
      echo ${lib.escapeShellArg start} | grep -q eth0
      echo ${lib.escapeShellArg start} | grep -q br-lan
      echo ${lib.escapeShellArg namedStart} | grep -q 'janus-flow-export eth0 br-lan'
      if echo ${lib.escapeShellArg namedStart} | grep -q 'janus-flow-export main'; then
        echo "configuration name main was passed to softflowd" >&2
        exit 1
      fi
      test ${lib.escapeShellArg netflow.config.systemd.services.janus-flow-export.environment.JANUS_FLOW_VERSION} = 9
      test ${
        if flows.config.services.prometheus.exporters.node.enable
        then "yes"
        else "no"
      } = yes
      test ${toString flows.config.services.prometheus.exporters.node.port} = 9100
      test ${lib.escapeShellArg flows.config.services.prometheus.exporters.node.listenAddress} = '[::]'
      echo ${lib.escapeShellArg (lib.concatStringsSep " " flows.config.services.prometheus.exporters.node.extraFlags)} | grep -q textfile
      cat > rules.nft <<'EOF'
      ${rules}
      EOF
      grep -q 9100 rules.nft
      grep -q br-lan rules.nft
      cat > opened.nft <<'EOF'
      ${openedRules}
      EOF
      grep 'tcp dport 9100 accept' opened.nft | grep -q tailscale0
      if grep 'tcp dport 9100 accept' opened.nft | grep -q br-lan; then
        echo "port 9100 is accepted on the LAN" >&2
        exit 1
      fi
      drop=$(grep -n 'tcp dport 9100 drop' opened.nft | head -1 | cut -d: -f1)
      lan=$(grep -n 'iifname { "br-lan" } accept' opened.nft | head -1 | cut -d: -f1)
      test -n "$drop"
      test -n "$lan"
      test "$drop" -lt "$lan"
      dir=$TMPDIR/metrics
      mkdir -p "$dir/subs"
      printf '%s\n' '2026-01-02T03:04:05Z' > "$dir/subs/main.stamp"
      printf '%s\n' 'fetch failed' > "$dir/subs/main.error"
      printf '%s\n' '2026-01-03T00:00:00Z' > "$dir/geo.stamp"
      printf '%s\n' '{"proxy":{"node":"fallback","default":"fallback"}}' > "$dir/selection.json"
      jq -n '{proxies:{proxy:{now:"chosen",history:[]},chosen:{history:[{delay:42}]}}}' > "$dir/proxies.json"
      JANUS_ENGINE_UP=1 \
        JANUS_SUBSCRIPTION_DIR=$dir/subs \
        JANUS_GEODATA_STAMP=$dir/geo.stamp \
        JANUS_GEODATA_ERROR=$dir/no-such-error \
        JANUS_SELECTION=$dir/selection.json \
        JANUS_PROXIES=$dir/proxies.json \
        ${metrics} render > "$dir/metrics.prom"
      grep -q '^janus_engine_up 1$' "$dir/metrics.prom"
      grep -q 'janus_subscription_refresh_error{subscription="main"} 1' "$dir/metrics.prom"
      grep -q "janus_subscription_refresh_timestamp_seconds{subscription=\"main\"} $(date -u -d 2026-01-02T03:04:05Z +%s)" "$dir/metrics.prom"
      grep -q "janus_geodata_refresh_timestamp_seconds $(date -u -d 2026-01-03T00:00:00Z +%s)" "$dir/metrics.prom"
      grep -q '^janus_geodata_refresh_error 0$' "$dir/metrics.prom"
      grep -q 'janus_proxy_selected{group="proxy",node="chosen"} 1' "$dir/metrics.prom"
      grep -q 'janus_proxy_group_latency_milliseconds{group="proxy",node="chosen"} 42' "$dir/metrics.prom"
      if grep -q fallback "$dir/metrics.prom"; then
        echo "selection.json overrode the live engine choice" >&2
        exit 1
      fi
      echo ok > "$out"
    '';
  eval-monitoring-collector = fail "eval-monitoring-collector" [
    base
    {janus.monitoring.flows.export.collector = "192.0.2.10:4739";}
  ];
  eval-monitoring-zone = fail "eval-monitoring-zone" [
    base
    {janus.monitoring.prometheus.enable = true;}
    {janus.monitoring.prometheus.zones = ["missing"];}
  ];
  eval-monitoring-iface = fail "eval-monitoring-iface" [
    base
    {janus.monitoring.interfaces = ["nope"];}
  ];
  eval-refresh-error =
    pkgs.runCommand "eval-refresh-error" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -eu
      root=$TMPDIR/root
      mkdir -p "$root/bin" "$root/etc/janus" "$root/var/lib/janus"
      cat > "$root/bin/janet" << 'EOF'
      #!/bin/sh
      exit 1
      EOF
      chmod +x "$root/bin/janet"
      printf '%s\n' '[]' > "$root/etc/janus/geodata-tags.json"
      printf '%s\n' '{}' > "$root/etc/janus/geodata-sources.json"
      printf '%s\n' '{}' > "$root/etc/janus/proxy-model.json"
      printf '%s\n' '[]' > "$root/etc/janus/nodes-manual.json"
      printf '%s\n' '[]' > "$root/etc/janus/nodes-built.json"
      {
        printf '%s\n' 'set -euo pipefail' 'compgen() { return 1; }' 'JANUS_ENGINE=sing-box' 'JANUS_SCRIPT=unused' 'JANUS_FAIL_MODE=closed' 'JANUS_INTERCEPT=0' 'JANUS_DNS_TPROXY=0' 'JANUS_EGRESS_TABLE='
        sed -e "s|/var/lib/janus|$root/var/lib/janus|g" -e "s|/etc/janus|$root/etc/janus|g" ${../pkgs/janus-engine.sh}
      } > "$root/run.sh"
      export PATH="$root/bin:$PATH"
      if bash "$root/run.sh" geodata-refresh; then
        echo "geo refresh succeeded despite a failed render" >&2
        exit 1
      fi
      grep -q 'render after geo refresh failed' "$root/var/lib/janus/geodata/refresh.error"
      echo ok > "$out"
    '';
  eval-build-host = pkgs.runCommand "eval-build-host" {} ''
    set -eu
    JANUS_BUILD_LIB=1
    # shellcheck disable=SC1091
    . ${../pkgs/janus-build.sh}
    bindir=$TMPDIR/bin
    mkdir -p "$bindir"
    cat > "$bindir/uname" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$JANUS_UNAME"
    EOF
    cat > "$bindir/nix" << 'EOF'
    #!/bin/sh
    if [ "$1" = "--impure" ]; then
      printf '%s\n' impure
      exit 0
    fi
    printf '%s\n' pure
    exit 0
    EOF
    chmod +x "$bindir/uname" "$bindir/nix"
    export PATH="$bindir:$PATH"
    export JANUS_UNAME=x86_64
    test "$(host_nix_system)" = x86_64-linux
    test "$(nix_fleet eval --raw x)" = pure
    JANUS_UNAME=aarch64
    test "$(host_nix_system)" = aarch64-linux
    test "$(nix_fleet eval --raw x)" = impure
    if refuse_build_host aarch64-linux potato x86_64-linux >"$TMPDIR/out" 2>"$TMPDIR/err"; then
      echo "expected a build-host mismatch to fail" >&2
      exit 1
    fi
    grep -q 'this machine is aarch64-linux' "$TMPDIR/err"
    grep -q "host 'potato' is set to build on x86_64-linux" "$TMPDIR/err"
    linkdir=$TMPDIR/links
    mkdir -p "$linkdir"
    (
      cd "$linkdir"
      ln -s /nix/store/old result
      prepare_image_link potato
      test -d result
      test ! -L result
      prepare_image_link other
      test -d result
    )
    if ( cd "$linkdir" && rm -rf result && echo x > result && prepare_image_link potato ); then
      echo "a file named result was accepted" >&2
      exit 1
    fi
    if ( cd "$linkdir" && prepare_image_link '../outside' ); then
      echo "host name '../outside' was accepted" >&2
      exit 1
    fi
    cat > "$bindir/nix" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_NIX_LOG"
    printf '%s\n' /nix/store/fake-image
    EOF
    export JANUS_NIX_LOG=$TMPDIR/nix-args
    export JANUS_UNAME=x86_64
    require_build_host() { return 0; }
    (
      cd "$linkdir"
      rm -rf result
      build_host_image potato
    )
    grep -F -q -- 'build --no-link --print-out-paths .#nixosConfigurations.potato.config.system.build.janusImage' "$JANUS_NIX_LOG"
    test -d "$linkdir/result"
    test ! -L "$linkdir/result"
    test -L "$linkdir/result/potato"
    test "$(readlink "$linkdir/result/potato")" = /nix/store/fake-image
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
    off = mk [base];
    slotRule = slot: uuid: link: "ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{janus.slot}${slot}, ENV{ID_PART_ENTRY_UUID}==\"${uuid}\", SYMLINK+=\"disk/by-janus/${link}\"";
  in
    pkgs.runCommand "eval-slots" {
      nativeBuildInputs = [pkgs.systemd];
    } ''
      set -eu
      test ${lib.escapeShellArg os.config.fileSystems."/".device} = /dev/disk/by-janus/root
      test ${lib.escapeShellArg os.config.fileSystems."/nix".device} = /dev/disk/by-janus/nix
      test ${
        if os.config.system.build.janusImage.slots
        then "yes"
        else "no"
      } = yes
      test ${
        if lib.hasAttr "janus-slot-select" os.config.boot.initrd.systemd.services
        then "yes"
        else "no"
      } = no
      printf '%s\n' ${lib.escapeShellArg os.config.boot.initrd.services.udev.rules} > initrd.rules
      printf '%s\n' ${lib.escapeShellArg os.config.services.udev.extraRules} > system.rules
      printf '%s\n' ${lib.escapeShellArg off.config.boot.initrd.services.udev.rules} > off-initrd.rules
      printf '%s\n' ${lib.escapeShellArg off.config.services.udev.extraRules} > off-system.rules
      grep -q by-janus off-initrd.rules && exit 1
      grep -q by-janus off-system.rules && exit 1
      for rules in initrd.rules system.rules; do
        grep -qxF 'ACTION=="add|change", SUBSYSTEM=="block", IMPORT{cmdline}="janus.slot"' "$rules"
        grep -qxF ${lib.escapeShellArg (slotRule ''!="b"'' "4a414e55-5300-4000-8000-000000000002" "root")} "$rules"
        grep -qxF ${lib.escapeShellArg (slotRule ''!="b"'' "4a414e55-5300-4000-8000-000000000003" "nix")} "$rules"
        grep -qxF ${lib.escapeShellArg (slotRule ''=="b"'' "4a414e55-5300-4000-8000-000000000006" "root")} "$rules"
        grep -qxF ${lib.escapeShellArg (slotRule ''=="b"'' "4a414e55-5300-4000-8000-000000000007" "nix")} "$rules"
      done
      udevadm verify --no-style --no-summary initrd.rules
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
      printf '%s\n' 'kernel=vmlinuz' 'initramfs initrd followkernel' > "$TMPDIR/boot/config.txt"
      printf '%s\n' 'old-a' > "$TMPDIR/boot/cmdline-a.txt"
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state JANUS_SLOT_STORE=$store bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} install-slot "$closure" b
      grep -q new-kernel "$TMPDIR/boot/vmlinuz-b"
      grep -q old-kernel "$TMPDIR/boot/vmlinuz"
      grep -q '^DEFAULT slot-b$' "$TMPDIR/boot/extlinux.conf"
      grep -q 'janus.slot=b' "$TMPDIR/boot/cmdline.txt"
      test "$(grep -m1 '^/slot-' "$TMPDIR/boot/limine.conf")" = /slot-b
      grep -q '^kernel=vmlinuz-b$' "$TMPDIR/boot/config.txt"
      grep -q '^initramfs initrd-b followkernel$' "$TMPDIR/boot/config.txt"
      test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = b
      JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state bash ${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall} restore-slot
      test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = a
      grep -q '^DEFAULT slot-a$' "$TMPDIR/boot/extlinux.conf"
      test "$(grep -m1 '^/slot-' "$TMPDIR/boot/limine.conf")" = /slot-a
      grep -q '^kernel=vmlinuz$' "$TMPDIR/boot/config.txt"
      grep -q '^initramfs initrd followkernel$' "$TMPDIR/boot/config.txt"
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
    # The Pi image carries an aarch64 panel. This check compiles and runs
    # the same sources for the machine evaluating it.
    conf = builtins.unsafeDiscardStringContext os.config.environment.etc."janus/hmi-panel.conf".text;
    start = builtins.unsafeDiscardStringContext os.config.systemd.services.janus-hmi-panel.serviceConfig.ExecStart;
    boot = builtins.unsafeDiscardStringContext os.config.system.build.janusBoardImage.bootExtra;
    janus = self.packages.${pkgs.stdenv.hostPlatform.system}.janus-cli;
    panel = pkgs.callPackage ../pkgs/hmi-panel.nix {};
    spi = pkgs.writeText "janus-spi.dts" os.config.system.build.janusSpiDts;
    snap = pkgs.writeShellApplication {
      name = "janus-hmi-snapshot";
      runtimeInputs = with pkgs; [gawk jq iproute2 curl systemd coreutils];
      text = builtins.readFile ../pkgs/janus-hmi-snapshot.sh;
    };
  in
    pkgs.runCommand "eval-hmi" {
      nativeBuildInputs = [pkgs.janet pkgs.dtc];
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
      dtc -@ -I dts -O dtb -o spi.dtbo ${spi}
      test -s spi.dtbo
      grep -q 'target = <&spi>' ${spi}
      grep -q 'rohm,dh2228fv' ${spi}
      grep -q 'spi0 = "/soc/spi@7e204000"' ${spi}
      grep -q 'brcm,bcm2711' ${spi}
      grep -q 'brcm,bcm2837' ${spi}
      grep -q 'dtoverlay=janus-spi' boot
      grep -q 'overlays/janus-spi.dtbo' boot
      if grep -q 'dtparam=spi=on' boot; then
        echo "panel still uses firmware dtparam=spi" >&2
        exit 1
      fi
      grep -q 'gpio=6,19,5,26,13,21,20,16=pu' boot
      test ${os.config.janus.hardware.peripherals.panel.hmi.driver} = sh1106
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-hmi-panel.wantedBy
        then "yes"
        else "no"
      } = yes
      printf '%s\n' ${lib.escapeShellArg start} > unit
      grep -q '/bin/janus-hmi ' unit
      ${panel}/bin/janus-hmi-panel --self-test
      ${snap}/bin/janus-hmi-snapshot conf > snap.out
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
    conf = builtins.unsafeDiscardStringContext os.config.environment.etc."janus/power.conf".text;
    boot = builtins.unsafeDiscardStringContext os.config.system.build.janusBoardImage.bootExtra;
    dts = pkgs.writeText "ina219.dts" os.config.system.build.janusIna219Dts;
    powerBin = pkgs.writeShellApplication {
      name = "janus-power";
      runtimeInputs = with pkgs; [gawk coreutils systemd];
      text = builtins.readFile ../pkgs/janus-power.sh;
    };
  in
    pkgs.runCommand "eval-power" {
      nativeBuildInputs = [pkgs.dtc];
    } ''
      dtc -@ -I dts -O dtb -o overlay.dtbo ${dts}
      test -s overlay.dtbo
      cp ${dts} overlay.dts
      cat > conf << 'ENDCONF'
      ${conf}
      ENDCONF
      grep -q $'sign\tnegative' conf
      grep -q $'armed\t1' conf
      cat > boot << 'ENDBOOT'
      ${boot}
      ENDBOOT
      if grep -q 'dtparam=i2c_arm\|i2c_arm' boot overlay.dts; then
        echo "INA219 overlay still targets the firmware symbol i2c_arm" >&2
        exit 1
      fi
      grep -q 'target = <&i2c1>' overlay.dts
      grep -q 'brcm,bcm2711' overlay.dts
      grep -q 'brcm,bcm2837' overlay.dts
      grep -q 'dtoverlay=janus-ina219' boot
      grep -q 'overlays/janus-ina219.dtbo' boot
      grep -q 'dtoverlay=janus-spi' boot
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
      bin=${powerBin}/bin/janus-power
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

  eval-power-x86 = let
    os = mk [
      base
      {
        janus.hardware.peripherals.ups = {
          class = "power";
          match.i2cAddress = "0x40";
        };
      }
    ];
    boot = builtins.unsafeDiscardStringContext (os.config.system.build.janusBoardImage.bootExtra or "");
    conf = os.config.environment.etc."janus/power.conf".text;
  in
    pkgs.runCommand "eval-power-x86" {} ''
      test ${
        if (builtins.tryEval os.config.system.build.janusIna219Dtbo).success
        then "yes"
        else "no"
      } = no
      cat > conf << 'ENDCONF'
      ${conf}
      ENDCONF
      grep -q $'sign\tnegative' conf
      grep -q $'armed\t1' conf
      cat > boot << 'ENDBOOT'
      ${boot}
      ENDBOOT
      if grep -q dtoverlay=janus-ina219 boot; then
        echo "x86 image installed an INA219 overlay" >&2
        exit 1
      fi
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-power-guard.wantedBy
        then "yes"
        else "no"
      } = yes
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
  eval-web = let
    off = mk [base];
    os = mk [
      base
      {
        janus.system.hostName = "router";
        janus.network.lans.home = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
          zone = "lan";
        };
        janus.access.web = {
          enable = true;
          passphraseFile = "/var/lib/janus/secrets/web-passphrase";
        };
      }
    ];
    web = os.config.environment.etc."janus/bin/janus-web".source;
    run = os.config.environment.etc."janus/bin/janus-web-run".source;
    spec = os.config.environment.etc."janus/web.json".text;
    stunnel = os.config.environment.etc."janus/stunnel.conf".text;
    rules = os.config.networking.nftables.tables.janus.content;
    tmpfiles = builtins.concatStringsSep "\n" os.config.systemd.tmpfiles.rules;
    execCondition = let
      value = os.config.systemd.services.janus-web.serviceConfig.ExecCondition;
    in
      if builtins.isList value
      then builtins.concatStringsSep " " value
      else toString value;
    nets = os.config.environment.etc."janus/lan-nets.json".text;
  in
    pkgs.runCommand "eval-web" {
      nativeBuildInputs = [pkgs.janet pkgs.openssl pkgs.jq];
    } ''
      set -eu
      export JANUS_WEB_HTML=${../janet/web.html}
      test ${
        if off.config.systemd.services ? janus-web
        then "yes"
        else "no"
      } = no
      janet ${../janet/web.janet} check
      printf '%s\n' ${lib.escapeShellArg spec} > web.json
      jq -e '.enable == true and .port == 8443 and .passphraseFile == "/var/lib/janus/secrets/web-passphrase" and (.san | index("DNS:router")) and (.san | index("IP:192.168.10.1")) and .hostname == "router"' web.json >/dev/null
      printf '%s\n' ${lib.escapeShellArg stunnel} > stunnel.conf
      grep -q 'IPV6_V6ONLY=0' stunnel.conf
      grep -q 'accept = \[::\]:8443' stunnel.conf
      grep -q 'connect = /run/janus-web/http.sock' stunnel.conf
      printf '%s\n' ${lib.escapeShellArg rules} > rules.nft
      grep 'tcp dport 8443 accept' rules.nft | grep -q br-home
      grep -q 'tcp dport 8443 drop' rules.nft
      test ${
        if lib.elem "multi-user.target" os.config.systemd.services.janus-web.wantedBy
        then "yes"
        else "no"
      } = yes
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.unitConfig.ConditionPathExists} = '!/var/lib/janus/web/paused'
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.User} = janus-web
      printf '%s\n' ${lib.escapeShellArg os.config.systemd.services.janus-web.environment.JANUS_WEB_EXEC} | grep -q janus-web-run
      printf '%s\n' ${lib.escapeShellArg tmpfiles} | grep -q 'd /var/lib/janus 0755 root root -'
      printf '%s\n' ${lib.escapeShellArg tmpfiles} | grep -q 'd /var/lib/janus/web 0751 root janus-web-tls -'
      printf '%s\n' ${lib.escapeShellArg execCondition} | grep -q 'janus-web ready'
      printf '%s\n' ${lib.escapeShellArg nets} > lan-nets.json
      jq -e '.home.address == "192.168.10.1" and .home.prefixLength == 24' lan-nets.json >/dev/null

      dir=$TMPDIR/state
      mkdir -p "$dir"
      printf 'phrase\n' > "$dir/pass"
      jq -n --arg pass "$dir/pass" --arg cert "$dir/cert.pem" --arg key "$dir/key.pem" --arg paused "$dir/paused" \
        '{enable:true, port:8443, zones:["lan","mgmt"], passphraseFile:$pass, cert:$cert, key:$key, paused:$paused, hostname:"router", san:["DNS:router","IP:192.168.10.1"], socket:"/run/janus-web/http.sock"}' > "$dir/web.json"
      JANUS_WEB_JSON=$dir/web.json ${web} cert
      test -s "$dir/cert.pem"
      test "$(stat -c %a "$dir")" = 751
      test "$(stat -c %a "$dir/cert.pem")" = 644
      test "$(stat -c %a "$dir/key.pem")" = 640
      JANUS_WEB_JSON=$dir/web.json ${web} ready
      fp=$(JANUS_WEB_JSON=$dir/web.json ${web} fingerprint)
      openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 | grep -q "$fp"
      jq -n '{enable:false}' > "$dir/off.json"
      if JANUS_WEB_JSON=$dir/off.json ${web} start; then
        echo "disabled image should exit 2" >&2
        exit 1
      fi
      : > "$dir/empty"
      jq -n --arg pass "$dir/empty" '{enable:true, passphraseFile:$pass, paused:"/no/such", cert:"/no/such", key:"/no/such", port:8443, zones:["lan"]}' > "$dir/empty.json"
      if JANUS_WEB_JSON=$dir/empty.json ${web} start; then
        echo "empty passphrase should exit 1" >&2
        exit 1
      fi
      if JANUS_WEB_JSON=$dir/empty.json ${web} ready; then
        echo "empty passphrase should not pass the service condition" >&2
        exit 1
      fi
      touch "$dir/paused"
      cat > "$dir/systemctl" << 'EOF'
      #!/bin/sh
      exit 0
      EOF
      chmod +x "$dir/systemctl"
      JANUS_WEB_JSON=$dir/web.json JANUS_SYSTEMCTL=$dir/systemctl ${web} stop
      test -f "$dir/paused"
      JANUS_WEB_JSON=$dir/web.json JANUS_SYSTEMCTL=$dir/systemctl ${web} start
      test ! -f "$dir/paused"
      JANUS_WEB_JSON=$dir/web.json JANUS_SYSTEMCTL=$dir/systemctl ${web} status > "$dir/status.out"
      grep -q 'listener: on' "$dir/status.out"
      cat > "$dir/systemctl-fail" << 'EOF'
      #!/bin/sh
      exit 1
      EOF
      chmod +x "$dir/systemctl-fail"
      if JANUS_WEB_JSON=$dir/web.json JANUS_SYSTEMCTL=$dir/systemctl-fail ${web} stop; then
        echo "stop should report systemctl failure" >&2
        exit 1
      fi
      test -f "$dir/paused"
      rm -f "$dir/paused"
      mkdir -p "$dir/etc"
      printf '%s\n' '["home","guest"]' > "$dir/etc/lans.json"
      jq -n '{"home":{"address":"192.168.10.1","prefixLength":24},"guest":{"address":"192.168.11.1","prefixLength":24}}' > "$dir/etc/lan-nets.json"
      printf '%s\n' '1 aa:bb:cc:dd:ee:ff 192.168.10.50 nas *' > "$dir/leases"
      printf '%s\n' '1 aa:bb:cc:dd:ee:f0 192.168.11.50 cam *' >> "$dir/leases"
      wrapper_path=$(sed -n 's/^export PATH="\([^"]*\)".*/\1/p' ${run})
      janus_bin=$(PATH="$wrapper_path" command -v janus)
      JANUS_ETC=$dir/etc JANUS_LEASES=$dir/leases "$janus_bin" lan leases home > "$dir/home-leases"
      grep -q 192.168.10.50 "$dir/home-leases"
      if grep -q 192.168.11.50 "$dir/home-leases"; then
        echo "guest lease was included for home" >&2
        exit 1
      fi
      if JANUS_ETC=$dir/etc JANUS_LEASES=$dir/leases "$janus_bin" lan leases missing; then
        echo "unknown LAN should exit 2" >&2
        exit 1
      fi

      mkdir -p "$dir/out"
      cat > "$dir/janus" << 'EOF'
      #!/bin/sh
      printf '%s\n' "$@" > "$JANUS_OUT/args"
      cat > "$JANUS_OUT/stdin"
      printf '%s\n' '{"ok":true}'
      EOF
      chmod +x "$dir/janus"
      printf '%s\n' 'https://example.invalid/secret' | JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set proxy.subscriptions.a.url
      grep -q 'override' "$dir/out/args"
      grep -q 'proxy.subscriptions.a.url' "$dir/out/args"
      if grep -q secret "$dir/out/args"; then
        echo "subscription URL was placed on the command line" >&2
        exit 1
      fi
      grep -q 'https://example.invalid/secret' "$dir/out/stdin"
      if JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set firewall.x; then
        echo "off-allowlist key should exit 2" >&2
        exit 1
      fi
      : > "$dir/out/args"
      : > "$dir/out/stdin"
      printf '%s\n' 'secret-phrase' | JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set network.wifi.ap.passphrase
      grep -q 'network.wifi.ap.passphrase' "$dir/out/args"
      if grep -q secret-phrase "$dir/out/args"; then
        echo "wifi passphrase was placed on the command line" >&2
        exit 1
      fi
      grep -q secret-phrase "$dir/out/stdin"
      if JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set 'proxy.subscriptions.a/b.url'; then
        echo "slash key should exit 2" >&2
        exit 1
      fi
      if JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set network.lans.home.dhcp.staticLeases.nas aa:bb:cc:dd:ee:ff '10.0.0.5,1.2.3.4'; then
        echo "loose ip should exit 2" >&2
        exit 1
      fi
      JANUS_BIN=$dir/janus JANUS_OUT=$dir/out ${run} override-set network.lans.home.dhcp.staticLeases.nas aa:bb:cc:dd:ee:ff 10.0.0.5
      grep -q -- '--mac' "$dir/out/args"
      grep -q 10.0.0.5 "$dir/out/args"
      echo ok > "$out"
    '';
  eval-web-wan = fail "eval-web-wan" [
    base
    {
      janus.access.web.enable = true;
      janus.access.web.passphraseFile = "/var/lib/janus/secrets/web-passphrase";
      janus.access.web.zones = ["wan"];
    }
  ];
  eval-web-pass = fail "eval-web-pass" [
    base
    {janus.access.web.enable = true;}
  ];
  cli-age-key =
    pkgs.runCommand "cli-age-key" {} ''
      set -eu
      dir=$TMPDIR/root
      mkdir -p "$dir/bin" "$dir/secrets"
      cat > "$dir/bin/systemctl" << 'EOF'
      #!/bin/sh
      printf '%s\n' "$*" >> "$JANUS_LOG"
      if [ "$1" = list-units ]; then
        printf '%s\n' 'janus-web-tls.service loaded failed'
        printf '%s\n' 'janus-pppoe-main.service loaded failed'
        printf '%s\n' 'janus-web.service loaded failed'
        printf '%s\n' 'janus-hostapd-home.service loaded failed'
        printf '%s\n' 'janus-tailscale-auth.service loaded failed'
        printf '%s\n' 'tailscaled.service loaded failed'
      fi
      exit 0
      EOF
      chmod +x "$dir/bin/systemctl"
      printf '%s\n' 'AGE-SECRET-KEY-1test' | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/log" PATH="$dir/bin:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key
      printf '%s\n' 'AGE-SECRET-KEY-1test' | cmp - "$dir/secrets/age.key"
      awk '
        $1 == "restart" && $2 == "sops-install-secrets.service" { sops = NR }
        $1 == "restart" && $2 == "janus-pppoe-main.service" { pppoe = NR }
        $1 == "restart" && $2 == "janus-hostapd-home.service" { ap = NR }
        $1 == "restart" && $2 == "janus-tailscale-auth.service" { auth = NR }
        $1 == "restart" && $2 == "tailscaled.service" { tail = NR }
        $1 == "restart" && $2 == "janus-web.service" { web = NR }
        $1 == "restart" && $2 == "janus-web-tls.service" { tls = NR }
        END {
          if (!(sops && pppoe && ap && auth && tail && web && tls && sops < pppoe && sops < ap && sops < auth && auth < tail && web < tls)) exit 1
        }
      ' "$dir/log"
      echo ok > "$out"
    '';
  eval-web-sops = let
    os = mk [
      base
      {
        sops.secrets.web-router.sopsFile = ./fixtures/sops-placeholder;
        janus.access.web = {
          enable = true;
          passphraseSecret = "web-router";
        };
      }
    ];
    spec = os.config.environment.etc."janus/web.json".text;
    requires = os.config.systemd.services.janus-web.requires or [];
    after = os.config.systemd.services.janus-web.after or [];
  in
    pkgs.runCommand "eval-web-sops" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -eu
      printf '%s\n' ${lib.escapeShellArg spec} > web.json
      jq -e '.passphraseFile == "/run/secrets/web-router"' web.json >/dev/null
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " after)} | grep -q sops-install-secrets.service
      echo ok > "$out"
    '';
  eval-web-secret = fail "eval-web-secret" [
    base
    {
      janus.access.web.enable = true;
      janus.access.web.passphraseSecret = "missing";
    }
  ];
  eval-web-both = fail "eval-web-both" [
    base
    {
      janus.access.web.enable = true;
      janus.access.web.passphraseSecret = "web-eval";
      janus.access.web.passphraseFile = "/var/lib/janus/secrets/web-passphrase";
    }
  ];
  eval-web-zone = fail "eval-web-zone" [
    base
    {
      janus.access.web.enable = true;
      janus.access.web.passphraseFile = "/var/lib/janus/secrets/web-passphrase";
      janus.access.web.zones = ["missing"];
    }
  ];
  eval-region-ru = let
    os = mk [
      base
      {
        janus.system.region = "ru";
        janus.proxy.enable = true;
      }
    ];
    model = os.config.environment.etc."janus/proxy-model.json".source;
  in
    pkgs.runCommand "eval-region-ru" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '.blockQuic == true' ${model} >/dev/null
      jq -e '.dns.domestic.resolvers == ["https://common.dot.dns.yandex.net/dns-query","tls://common.dot.dns.yandex.net"]' ${model} >/dev/null
      jq -e '.dns.domestic.domains == ["ru","su","xn--p1ai","geosite:category-ru"]' ${model} >/dev/null
      jq -e '.rules | length == 0' ${model} >/dev/null
      echo ${lib.escapeShellArg os.config.environment.etc."janus/dns-policy.json".text} | jq -e '.domesticProbe == "ya.ru"' >/dev/null
      echo ok > "$out"
    '';
  eval-region-ir = let
    os = mk [
      base
      {
        janus.system.region = "ir";
        janus.dns.domestic.resolvers = ["https://dns.example.ir/dns-query"];
        janus.dns.bootstrap = ["192.0.2.53"];
        janus.proxy.enable = true;
      }
    ];
    model = os.config.environment.etc."janus/proxy-model.json".source;
    sources = os.config.environment.etc."janus/geodata-sources.json".text;
    engine = os.config.system.build.janusEngineConfig;
  in
    pkgs.runCommand "eval-region-ir" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '.blockQuic == false' ${model} >/dev/null
      jq -e '.dns.domestic.resolvers == ["https://dns.example.ir/dns-query"]' ${model} >/dev/null
      jq -e '.dns.bootstrap == ["192.0.2.53"]' ${model} >/dev/null
      jq -e '.dns.domestic.domains == ["ir","geosite:ir"]' ${model} >/dev/null
      jq -e '.rules | length == 0' ${model} >/dev/null
      jq -e '.geodataSources.tags["geosite-ir"] | test("Chocolate4U/Iran-sing-box-rules")' ${model} >/dev/null
      echo ${lib.escapeShellArg sources} | grep -q 'Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs'
      jq -e '.route.rule_set[] | select(.tag == "geosite-ir") | .url | test("Chocolate4U/Iran-sing-box-rules")' ${engine} >/dev/null
      echo ok > "$out"
    '';
  eval-region-ir-off = pass "eval-region-ir-off" [
    base
    {janus.system.region = "ir";}
  ];
  eval-region-ir-empty = fail "eval-region-ir-empty" [
    base
    {
      janus.system.region = "ir";
      janus.proxy.enable = true;
    }
  ];
  eval-region-replace = let
    os = mk [
      base
      {
        janus.system.region = "ru";
        janus.proxy.enable = true;
        janus.proxy.rules = [
          {
            match.geosite = ["cn"];
            target = "direct";
          }
        ];
      }
    ];
    model = os.config.environment.etc."janus/proxy-model.json".source;
    engine = os.config.system.build.janusEngineConfig;
  in
    pkgs.runCommand "eval-region-replace" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '.rules | length == 1 and .[0].match.geosite == ["cn"]' ${model} >/dev/null
      if jq -e 'any(.rules[]; .match.geosite == ["category-ru"])' ${model} >/dev/null; then
        echo "explicit rules were merged with the ru preset" >&2
        exit 1
      fi
      jq -e '
        .route.rules as $r
        | ($r | to_entries | map(select(any((.value.rule_set // [])[]; . == "geosite-cn"))) | .[0].key) as $direct
        | ($r | to_entries | map(select(.value.network == "udp" and .value.action == "reject")) | .[0].key) as $quic
        | ($direct != null) and ($quic != null) and ($direct < $quic)
      ' ${engine} >/dev/null
      echo ok > "$out"
    '';
}
