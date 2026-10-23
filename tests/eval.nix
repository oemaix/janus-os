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
    auto = mk [base];
    sized = spec:
      (mk [
        base
        {janus.storage.layout.partitions.JANUS_NIX.size = spec;}
      ]).config.system.build.janusNixPartition.exactMiB;
    part = os.config.system.build.janusNixPartition;
  in
    pkgs.runCommand "eval-nix-size" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gawk pkgs.findutils];
    } ''
      test ${part.mode} = exact
      test ${toString part.exactMiB} = 2048
      test ${toString part.minimumMiB} = 2560
      test ${toString (sized "1.5M")} = 2
      test ${toString (sized "512.9M")} = 513
      test ${toString (sized "2.1G")} = 2151
      test ${toString (sized "2.5G")} = 2560
      test ${lib.escapeShellArg auto.config.janus.storage.nix.minimumSize} = 2.5G
      test ${toString auto.config.system.build.janusNixPartition.minimumMiB} = 2560
      grep -F -q -- 'f2fs-mib.sh' ${../pkgs/image.nix}
      grep -F -q -- 'f2fs_partition_mib' ${../pkgs/image.nix}
      grep -F -q -- 'nix.img "$nixMinMiB" "$nixSlackPercent" ""' ${../pkgs/image.nix}
      grep -F -q -- 'nix.img 0 0 "$nixExactMiB"' ${../pkgs/image.nix}
      grep -F -q -- 'f2fs-mib.sh' ${../pkgs/slot-images.nix}
      grep -F -q -- 'f2fs_partition_mib' ${../pkgs/slot-images.nix}
      grep -F -q -- 'nix-a.img "$nixMinMiB" "$nixSlackPercent" ""' ${../pkgs/slot-images.nix}
      grep -F -q -- 'nix-a.img 0 0 "$nixExactMiB"' ${../pkgs/slot-images.nix}
      . ${../pkgs/f2fs-mib.sh}
      dir=$(mktemp -d)
      echo x > "$dir/a"
      floor=$(f2fs_partition_mib "$dir" 2560 15 "")
      test "$floor" = 2560
      auto_mib=$(f2fs_partition_mib "$dir" 64 15 "")
      test "$auto_mib" -gt 64
      test "$auto_mib" -lt 2560
      test "$(f2fs_partition_mib "$dir" 2560 15 32)" = 32
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
    ledExec = unit: r4s.config.systemd.services.${unit}.serviceConfig.ExecStart;
    ledScriptOf = unit: lib.head (lib.splitString " " (ledExec unit));
    ledArg = unit: lib.removePrefix "${ledScriptOf unit} " (ledExec unit);
    r4sFirmwareNames = lib.concatMapStringsSep " " (p: p.name) (
      lib.filter (p: lib.isAttrs p && lib.isDerivation p) (
        lib.flatten r4s.options.hardware.firmware.definitions
      )
    );
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
      test ${
        (lib.findFirst (p: p.name == "janus-r4s-netdev-led") (throw "missing R4S netdev LED patch") r4s.config.boot.kernelPatches)
        .structuredExtraConfig
        .LEDS_TRIGGER_NETDEV
        .tristate
      } = y
      test ${
        if (lib.findFirst (p: p.name == "janus-r4s-sd-uhs") null r4s.config.boot.kernelPatches) == null
        then "no"
        else "yes"
      } = yes
      test ${lib.escapeShellArg (ledArg "janus-r4s-wan-led@")} = %i
      test ${lib.escapeShellArg (ledArg "janus-r4s-lan-led@")} = %i
      test ${lib.escapeShellArg r4s.config.systemd.services."janus-r4s-wan-led@".serviceConfig.Restart} = on-failure
      test ${lib.escapeShellArg r4s.config.systemd.services."janus-r4s-lan-led@".serviceConfig.Restart} = on-failure
      test ${toString r4s.config.systemd.services."janus-r4s-wan-led@".startLimitBurst} = 6
      test ${toString r4s.config.systemd.services."janus-r4s-lan-led@".startLimitBurst} = 6
      check_led() {
        script=$1
        led=$2
        other=$3
        grep -q "/sys/class/leds/$led" "$script"
        grep -q '$led/trigger' "$script"
        grep -q '$led/device_name' "$script"
        grep -q '$led/link' "$script"
        grep -q '$led/tx' "$script"
        grep -q '$led/rx' "$script"
        grep -q netdev "$script"
        if grep -q "$other" "$script"; then
          echo "LED script for $led also names $other" >&2
          exit 1
        fi
      }
      check_led ${ledScriptOf "janus-r4s-wan-led@"} green:wan green:lan
      check_led ${ledScriptOf "janus-r4s-lan-led@"} green:lan green:wan
      rules=${lib.escapeShellArg r4s.config.services.udev.extraRules}
      printf '%s\n' "$rules" | grep 'DRIVERS=="r8169"' | grep -q 'janus-r4s-wan-led@%k.service'
      printf '%s\n' "$rules" | grep 'DRIVERS=="rk_gmac-dwmac"' | grep -q 'janus-r4s-lan-led@%k.service'
      if printf '%s\n' "$rules" | grep 'DRIVERS=="r8169"' | grep -q 'lan-led'; then
        echo "r8169 is bound to the lan LED" >&2
        exit 1
      fi
      if printf '%s\n' "$rules" | grep 'DRIVERS=="rk_gmac-dwmac"' | grep -q 'wan-led'; then
        echo "rk_gmac-dwmac is bound to the wan LED" >&2
        exit 1
      fi
      echo ${lib.escapeShellArg r4sFirmwareNames} | grep -q rtl8168h-firmware
      fw=${r4s.config.hardware.firmware}
      # buildEnv links the directory. find does not follow that link.
      n=$(find -L "$fw/lib/firmware" -type f -name 'rtl8168h-2.fw*' | wc -l)
      test "$((n + 0))" = 1
      if find -L "$fw/lib/firmware" -type f ! -name 'rtl8168h-2.fw*' | grep -q .; then
        echo "R4S firmware tree has more than rtl8168h-2.fw" >&2
        exit 1
      fi
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
    r4s = board "nanopi-r4s";
    vf2Rxc = lib.findFirst (p: p.name == "janus-vf2-yt8531-rxc") null vf2.config.boot.kernelPatches;
    r4sUhs = lib.findFirst (p: p.name == "janus-r4s-sd-uhs") null r4s.config.boot.kernelPatches;
  in
    pkgs.runCommand "eval-tier3-boot" {
      nativeBuildInputs = [pkgs.gnutar pkgs.xz pkgs.patch pkgs.dtc pkgs.gcc];
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
      list_dts ${r4s.config.boot.kernelPackages.kernel.src} \
        arch/arm64/boot/dts/rockchip/rk3399-nanopi-r4s.dts \
        arch/arm64/boot/dts/rockchip/rk3399-nanopi-r4s.dtsi
      src=${vf2.config.boot.kernelPackages.kernel.src}
      phy=drivers/net/phy/motorcomm.c
      dts=arch/riscv/boot/dts/starfive/jh7110-starfive-visionfive-2-v1.3b.dts
      rm -rf apply
      mkdir -p "apply/$(dirname "$phy")" "apply/$(dirname "$dts")"
      if [ -d "$src" ]; then
        cp "$src/$phy" "apply/$phy"
        cp "$src/$dts" "apply/$dts"
      else
        tar -tf "$src" > vf2-files
        phy_in=$(grep -m1 "$phy\$" vf2-files)
        dts_in=$(grep -m1 "$dts\$" vf2-files)
        test -n "$phy_in"
        test -n "$dts_in"
        tar -xJf "$src" -O "$phy_in" > "apply/$phy"
        tar -xJf "$src" -O "$dts_in" > "apply/$dts"
      fi
      patch -p1 -d apply < ${vf2Rxc.patch}
      grep -A1 'phydev->dev_flags & PHY_F_RXC_ALWAYS_ON ||' "apply/$phy" > flag-ifs
      flag_n=$(grep -c 'phydev->dev_flags & PHY_F_RXC_ALWAYS_ON ||' flag-ifs || true)
      sleep_n=$(grep -c 'motorcomm,auto-sleep-disabled' flag-ifs || true)
      pll_n=$(grep -c 'motorcomm,keep-pll-enabled' flag-ifs || true)
      test "$flag_n" = 4
      test "$sleep_n" = 2
      test "$pll_n" = 2
      grep -q motorcomm,keep-pll-enabled "apply/$dts"
      grep -q motorcomm,auto-sleep-disabled "apply/$dts"
      r4s_src=${r4s.config.boot.kernelPackages.kernel.src}
      rm -rf r4s-tree
      mkdir -p r4s-tree
      if [ -d "$r4s_src" ]; then
        mkdir -p r4s-tree/arch/arm64/boot r4s-tree/include r4s-tree/scripts/dtc
        cp -a "$r4s_src/arch/arm64/boot/dts" r4s-tree/arch/arm64/boot/dts
        cp -a "$r4s_src/include/dt-bindings" r4s-tree/include/dt-bindings
        cp -a "$r4s_src/include/uapi" r4s-tree/include/uapi
        cp -a "$r4s_src/scripts/dtc/include-prefixes" r4s-tree/scripts/dtc/include-prefixes
      else
        tar -xJf "$r4s_src" -C r4s-tree --strip-components=1 --wildcards \
          '*/arch/arm64/boot/dts/*' \
          '*/include/dt-bindings/*' \
          '*/include/uapi/*' \
          '*/scripts/dtc/include-prefixes/*'
      fi
      patch -p1 --fuzz=0 -d r4s-tree < ${r4sUhs.patch}
      cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I r4s-tree/scripts/dtc/include-prefixes \
        -I r4s-tree/include \
        -o r4s.pp r4s-tree/arch/arm64/boot/dts/rockchip/rk3399-nanopi-r4s.dts
      dtc -q -I dts -O dts -o r4s.dts r4s.pp
      awk '/mmc@fe320000 \{/,/^[[:space:]]*\};/' r4s.dts > sdmmc.node
      test -s sdmmc.node
      grep -q 'cap-sd-highspeed' sdmmc.node
      grep -q 'no-1-8-v' sdmmc.node
      if grep -q 'sd-uhs-' sdmmc.node; then
        echo "sdmmc still advertises a UHS mode" >&2
        exit 1
      fi
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
  eval-wifi-mt76 = let
    names = os:
      lib.concatMapStringsSep " " (p: p.name) (
        lib.filter (p: lib.isAttrs p && lib.isDerivation p) (
          lib.flatten os.options.hardware.firmware.definitions
        )
      );
    declared = id:
      mk [
        base
        {
          janus.hardware.peripherals.stick = {
            class = "wifi";
            match.usbVendorProduct = id;
          };
        }
      ];
    mt7612 = declared "0e8d:7612";
    mt7921 = declared "0e8d:7961";
    rtl = declared "0bda:8176";
  in
    pkgs.runCommand "eval-wifi-mt76" {} ''
      set -eu
      echo ${lib.escapeShellArg (names mt7612)} | grep -q mt7662-firmware
      if echo ${lib.escapeShellArg (names mt7612)} | grep -q mt7921-firmware; then
        echo "MT7612U config also installed MT7921 firmware" >&2
        exit 1
      fi
      fw=${mt7612.config.hardware.firmware}
      n=$(find -L "$fw/lib/firmware" -type f -name 'mt7662.bin*' | wc -l)
      test "$n" = 1
      n=$(find -L "$fw/lib/firmware" -type f -name 'mt7662_rom_patch.bin*' | wc -l)
      test "$n" = 1
      n=$(find -L "$fw/lib/firmware" -type f | wc -l)
      test "$n" = 2
      echo ${lib.escapeShellArg (names mt7921)} | grep -q mt7921-firmware
      fw=${mt7921.config.hardware.firmware}
      n=$(find -L "$fw/lib/firmware" -type f -name 'WIFI_RAM_CODE_MT7961_1.bin*' | wc -l)
      test "$n" = 1
      n=$(find -L "$fw/lib/firmware" -type f -name 'WIFI_MT7961_patch_mcu_1_2_hdr.bin*' | wc -l)
      test "$n" = 1
      n=$(find -L "$fw/lib/firmware" -type f | wc -l)
      test "$n" = 2
      echo ${lib.escapeShellArg (names rtl)} | grep -q rtl8192cu-firmware
      if echo ${lib.escapeShellArg (names rtl)} | grep -q mt7662-firmware; then
        echo "RTL8188CUS config installed MT7612 firmware" >&2
        exit 1
      fi
      fw=${rtl.config.hardware.firmware}
      for f in rtl8192cufw.bin rtl8192cufw_A.bin rtl8192cufw_B.bin rtl8192cufw_TMSC.bin; do
        n=$(find -L "$fw/lib/firmware" -type f -name "$f*" | wc -l)
        test "$n" = 1
      done
      n=$(find -L "$fw/lib/firmware" -type f | wc -l)
      test "$n" = 4
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
    secretWants = os.config.systemd.services.janus-wifi-secret-home.wants or [];
    secretStart = os.config.systemd.services.janus-wifi-secret-home.serviceConfig.ExecStart;
    script = os.config.systemd.services.janus-hostapd-home.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-wifi-sops" {} ''
      set -eu
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q janus-wifi-secret-home.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " secretWants)} | grep -q sops-install-secrets.service
      if printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " secretRequires)} | grep -q sops-install-secrets.service; then
        echo "a failed sops unit must not hide a Wi-Fi override" >&2
        exit 1
      fi
      grep -q ${lib.escapeShellArg os.config.sops.secrets.wifi-eval-home.path} ${script}
      grep -q '/var/lib/janus/secrets/wifi-home' ${script}
      awk '
        /JANUS_WIFI_PASS:-\/var\/lib\/janus\/secrets\/wifi-home/ { over = NR }
        /JANUS_WIFI_SOPS:-/ { sops = NR }
        END { if (!(over && sops && over < sops)) exit 1 }
      ' ${script}
      test ${lib.escapeShellArg os.config.sops.secrets.wifi-eval-home.key} = value
      dir=$TMPDIR/wifi
      mkdir -p "$dir"
      if JANUS_WIFI_PASS=$dir/over JANUS_WIFI_SOPS=$dir/sops ${secretStart}; then
        echo "empty wifi passphrase was accepted" >&2
        exit 1
      fi
      printf '%s\n' 'from-sops' > "$dir/sops"
      JANUS_WIFI_PASS=$dir/missing JANUS_WIFI_SOPS=$dir/sops ${secretStart}
      printf '%s\n' 'from-override' > "$dir/over"
      rm -f "$dir/sops"
      JANUS_WIFI_PASS=$dir/over JANUS_WIFI_SOPS=$dir/sops ${secretStart}
      echo ok > "$out"
    '';
  eval-secret-apply = pkgs.runCommand "eval-secret-apply" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    set -eu
    sed -n '/^subscription_url()/,/^}/p' ${../pkgs/janus-engine.sh} > fn.sh
    . ./fn.sh
    root=$TMPDIR/apply
    mkdir -p "$root/secrets/subscription" "$root/saved"
    meta=$root/meta.json
    export meta
    printf '%s\n' '{"vendor":{"urlSecret":"subscription/vendor"}}' > "$meta"
    printf '%s\n' 'https://sops.example/sub' > "$root/secrets/subscription/vendor"
    printf '%s\n' 'https://saved.example/sub' > "$root/saved/vendor"
    got=$(JANUS_OVERRIDES=$root/no-overrides JANUS_SECRETS_RUN=$root/secrets JANUS_SUBSCRIPTION_URLS=$root/saved subscription_url vendor)
    test "$got" = 'https://sops.example/sub'
    printf '%s\n' '{"proxy.subscriptions.vendor.url":"https://override.example/sub"}' > "$root/overrides.json"
    got=$(JANUS_OVERRIDES=$root/overrides.json JANUS_SECRETS_RUN=$root/secrets JANUS_SUBSCRIPTION_URLS=$root/saved subscription_url vendor)
    test "$got" = 'https://override.example/sub'
    rm -f "$root/secrets/subscription/vendor"
    got=$(JANUS_OVERRIDES=$root/no-overrides JANUS_SECRETS_RUN=$root/secrets JANUS_SUBSCRIPTION_URLS=$root/saved subscription_url vendor)
    test "$got" = 'https://saved.example/sub'
    rm -f "$root/saved/vendor"
    got=$(JANUS_OVERRIDES=$root/no-overrides JANUS_SECRETS_RUN=$root/secrets JANUS_SUBSCRIPTION_URLS=$root/saved subscription_url vendor)
    test -z "$got"
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
          privateKeyFile = "/var/lib/janus/secrets/wg";
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
  eval-wan-policy = let
    os = mk [
      base
      {
        janus.network.wans.main = {
          uplink = "wan";
          mode = "dhcp";
        };
      }
    ];
    script = os.config.systemd.services.janus-wan-policy.serviceConfig.ExecStart;
    ipStub = pkgs.writeShellScript "wan-policy-ip-stub" ''
      printf '%s\n' "$*" >> "$JANUS_IP_LOG"
      if [ -n "''${JANUS_IP_FAIL:-}" ]; then
        exit 1
      fi
      case "$1 $2 $3" in
        "-4 -o addr")
          printf '%s\n' "2: eth0 inet 10.0.0.2/24 scope global" "2: eth0 inet 10.0.0.3/24 scope global"
          ;;
        "-4 route show")
          printf '%s\n' "default via 10.0.0.1 dev eth0"
          ;;
        "rule del from")
          exit 1
          ;;
        "rule add from" | "route replace default")
          ;;
        *)
          echo "unexpected ip: $*" >&2
          exit 1
          ;;
      esac
    '';
  in
    pkgs.runCommand "eval-wan-policy" {} ''
      set -eu
      grep -q '/bin/ip ' ${script}
      grep -q '/bin/awk ' ${script}
      grep -q 'set -euo pipefail' ${script}
      grep -q 'while read -r cidr' ${script}
      if grep -E '(^|[^/[:alnum:]])ip -4' ${script}; then
        echo "janus-wan-policy calls ip from PATH" >&2
        exit 1
      fi
      if grep -E '(^|[^/[:alnum:]])awk ' ${script}; then
        echo "janus-wan-policy calls awk from PATH" >&2
        exit 1
      fi
      ip=$(grep -o '/nix/store/[^ ]*/bin/ip' ${script} | head -1)
      awk=$(grep -o '/nix/store/[^ ]*/bin/awk' ${script} | head -1)
      test -x "$ip"
      test -x "$awk"
      root=$TMPDIR/wan-policy
      mkdir -p "$root/sys/class/net/eth0"
      sed -e "s|$ip|${ipStub}|g" -e "s|/run/janus|$root/run|g" -e "s|/sys/class/net|$root/sys/class/net|g" ${script} > "$root/policy"
      chmod +x "$root/policy"
      export JANUS_IP_LOG=$root/ip.log
      if JANUS_IP_FAIL=1 "$root/policy"; then
        echo "a failed ip was treated as success" >&2
        exit 1
      fi
      : > "$JANUS_IP_LOG"
      unset JANUS_IP_FAIL
      "$root/policy"
      adds=$(grep -c 'rule add from ' "$JANUS_IP_LOG")
      test "$adds" = 2
      grep -q 'rule add from 10.0.0.2 ' "$JANUS_IP_LOG"
      grep -q 'rule add from 10.0.0.3 ' "$JANUS_IP_LOG"
      grep -q 'route replace default via 10.0.0.1 ' "$JANUS_IP_LOG"
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
      echo ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services."janus-proxy-refresh@".wants or []))} | grep -q sops-install-secrets.service
      if echo ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services."janus-proxy-refresh@".requires or []))} | grep -q sops-install-secrets.service; then
        echo "refresh must keep running when sops fails" >&2
        exit 1
      fi
      test ${
        if os.config.systemd.timers ? "janus-proxy-refresh-b"
        then "yes"
        else "no"
      } = no
      test ${lib.escapeShellArg os.config.janus.proxy.subscriptions.b.urlSecret} = subscription/b
      test ${lib.escapeShellArg os.config.sops.secrets."subscription/a".key} = value
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
      kern=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-slotkern/Image
      kern_real=/nix/store/cccccccccccccccccccccccccccccccc-slotkern-real/Image
      initrd=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-slotinit/initrd
      mkdir -p "$store''${closure#/nix}" "$TMPDIR/boot/extlinux" "$TMPDIR/state"
      printf 'console=ttyS0\n' > "$store''${closure#/nix}/kernel-params"
      # The kernel link hops through another /nix/store symlink. The files
      # exist only under the slot store, so following either link fails.
      ln -s "$kern" "$store''${closure#/nix}/kernel"
      ln -s "$initrd" "$store''${closure#/nix}/initrd"
      printf 'old-kernel\n' > "$TMPDIR/boot/vmlinuz"
      printf 'old-initrd\n' > "$TMPDIR/boot/initrd"
      printf 'a\n' > "$TMPDIR/boot/slot"
      printf '%s\n' 'DEFAULT slot-a' 'LABEL slot-a' '  LINUX /vmlinuz' '  INITRD /initrd' '  APPEND old-a' 'LABEL slot-b' '  LINUX /vmlinuz-b' '  INITRD /initrd-b' '  APPEND old-b' > "$TMPDIR/boot/extlinux.conf"
      printf '%s\n' 'timeout: 0' '/slot-a' '    cmdline: old-a' '/slot-b' '    cmdline: old-b' > "$TMPDIR/boot/limine.conf"
      printf '%s\n' 'kernel=vmlinuz' 'initramfs initrd followkernel' > "$TMPDIR/boot/config.txt"
      printf '%s\n' 'old-a' > "$TMPDIR/boot/cmdline-a.txt"
      boot_install=${self.packages.${pkgs.stdenv.hostPlatform.system}.bootInstall}
      src="$store''${closure#/nix}"
      run_install() {
        JANUS_BOOT_DIR=$TMPDIR/boot JANUS_STATE_DIR=$TMPDIR/state JANUS_SLOT_STORE=$store bash "$boot_install" install-slot "$closure" "$1"
      }
      refuse() {
        if run_install b >"$TMPDIR/slot-miss.out" 2>"$TMPDIR/slot-miss.err"; then
          echo "slot install accepted $1" >&2
          exit 1
        fi
        grep -q 'is not in the slot store' "$TMPDIR/slot-miss.err"
        if [ -e "$TMPDIR/boot/vmlinuz-b" ] || [ -e "$TMPDIR/boot/initrd-b" ] || [ -e "$TMPDIR/boot/cmdline.txt" ]; then
          echo "a refused slot install changed the boot entry" >&2
          exit 1
        fi
        grep -q old-kernel "$TMPDIR/boot/vmlinuz"
        test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = a
      }
      refuse "a kernel symlink whose target is not in the slot store"
      mkdir -p "$store/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-slotkern" "$store/store/cccccccccccccccccccccccccccccccc-slotkern-real" "$store/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-slotinit" "$store/escaped"
      ln -s "$kern_real" "$store/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-slotkern/Image"
      printf 'new-kernel\n' > "$store/store/cccccccccccccccccccccccccccccccc-slotkern-real/Image"
      printf 'new-initrd\n' > "$store/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-slotinit/initrd"
      printf 'outside-kernel\n' > "$TMPDIR/outside-kernel"
      ln -sf "$TMPDIR/outside-kernel" "$src/kernel"
      refuse "a kernel symlink that leaves /nix/store"
      printf 'escaped-kernel\n' > "$store/escaped/Image"
      ln -sf /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-slotkern/../../escaped/Image "$src/kernel"
      refuse "a kernel symlink that climbs out of the slot store"
      ln -sf "$kern" "$src/kernel"
      printf 'leaked-params\n' > "$TMPDIR/leaked-params"
      ln -sf "$TMPDIR/leaked-params" "$src/kernel-params"
      refuse "a kernel-params symlink"
      rm -f "$src/kernel-params"
      printf 'console=ttyS0\n' > "$src/kernel-params"
      run_install b
      test ! -h "$TMPDIR/boot/vmlinuz-b"
      test ! -h "$TMPDIR/boot/initrd-b"
      grep -q new-kernel "$TMPDIR/boot/vmlinuz-b"
      grep -q new-initrd "$TMPDIR/boot/initrd-b"
      grep -q "init=$closure/init" "$TMPDIR/boot/cmdline.txt"
      grep -q old-kernel "$TMPDIR/boot/vmlinuz"
      grep -q old-initrd "$TMPDIR/boot/initrd"
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
      run_install a
      test ! -h "$TMPDIR/boot/vmlinuz"
      test ! -h "$TMPDIR/boot/initrd"
      grep -q new-kernel "$TMPDIR/boot/vmlinuz"
      grep -q new-initrd "$TMPDIR/boot/initrd"
      grep -q new-kernel "$TMPDIR/boot/vmlinuz-b"
      grep -q new-initrd "$TMPDIR/boot/initrd-b"
      grep -q "init=$closure/init" "$TMPDIR/boot/cmdline.txt"
      grep -q 'janus.slot=a' "$TMPDIR/boot/cmdline.txt"
      grep -q '^DEFAULT slot-a$' "$TMPDIR/boot/extlinux.conf"
      test "$(grep -m1 '^/slot-' "$TMPDIR/boot/limine.conf")" = /slot-a
      grep -q '^kernel=vmlinuz$' "$TMPDIR/boot/config.txt"
      test "$(tr -d '[:space:]' < "$TMPDIR/boot/slot")" = a
      echo ok > "$out"
    '';
  eval-deploy-slots = pkgs.runCommand "eval-deploy-slots" {
    nativeBuildInputs = [pkgs.jq pkgs.bash];
  } ''
    set -eu
    dir=$TMPDIR/slot-deploy
    mkdir -p "$dir/imgs"
    printf '%s\n' /nix/store/closure > "$dir/imgs/toplevel"
    printf root-a > "$dir/imgs/root-a.img"
    printf nix-a > "$dir/imgs/nix-a.img"
    printf root-b > "$dir/imgs/root-b.img"
    printf nix-b > "$dir/imgs/nix-b.img"
    printf 'a\n' > "$dir/active"
    printf '1\n' > "$dir/install-rc"
    : > "$dir/ssh-log"
    printf '\n' > "$dir/boot-install"
    export JANUS_BOOT_INSTALL=$dir/boot-install
    JANUS_BUILD_LIB=1
    # shellcheck disable=SC1091
    . ${../pkgs/janus-build.sh}
    nix_fleet() {
      case "$*" in
        *slots.json*)
          printf '%s\n' '{"enable":true,"rootA":"4a414e55-5300-4000-8000-000000000002","nixA":"4a414e55-5300-4000-8000-000000000003","rootB":"4a414e55-5300-4000-8000-000000000006","nixB":"4a414e55-5300-4000-8000-000000000007"}'
          ;;
        *janusSlotImages*)
          printf '%s\n' "$dir/imgs"
          ;;
        *)
          echo "unexpected nix_fleet: $*" >&2
          return 1
          ;;
      esac
    }
    ssh_to() {
      printf '%s\n' "$2" >> "$dir/ssh-log"
      case "$2" in
        *'/boot/slot'*)
          cat "$dir/active"
          ;;
        'blockdev --getsize64 '*)
          printf '%s\n' 1000000
          ;;
        'dd of='*)
          cat >/dev/null
          ;;
        *install-slot*)
          return "$(tr -d '[:space:]' < "$dir/install-rc")"
          ;;
        *) ;;
      esac
    }
    if ( deploy_slots via 192.168.10.1 ); then
      echo "slot deploy continued after install-slot failed" >&2
      exit 1
    fi
    grep -q 'JANUS_SLOT_STORE=/run/janus-slot-nix' "$dir/ssh-log"
    grep -q 'mkdir -p /run/janus-slot-nix' "$dir/ssh-log"
    grep -q 'install-slot /nix/store/closure b' "$dir/ssh-log"
    grep -q 'dd of=/dev/disk/by-partuuid/4a414e55-5300-4000-8000-000000000006' "$dir/ssh-log"
    grep -q 'dd of=/dev/disk/by-partuuid/4a414e55-5300-4000-8000-000000000007' "$dir/ssh-log"
    if grep -q '/mnt/' "$dir/ssh-log"; then
      echo "slot deploy used a mount point on /" >&2
      exit 1
    fi
    if grep -q 'systemctl reboot' "$dir/ssh-log"; then
      echo "a failed slot deploy rebooted" >&2
      exit 1
    fi
    if grep -q deploy-pending "$dir/ssh-log"; then
      echo "a failed slot deploy marked the boot pending" >&2
      exit 1
    fi
    tail -n 1 "$dir/ssh-log" | grep -q 'umount /run/janus-slot-nix'
    tail -n 1 "$dir/ssh-log" | grep -q 'mount -o remount,ro /boot'
    : > "$dir/ssh-log"
    printf 'b\n' > "$dir/active"
    printf '0\n' > "$dir/install-rc"
    if ! ( deploy_slots via 192.168.10.1 ); then
      echo "slot deploy stopped after install-slot" >&2
      exit 1
    fi
    grep -q 'install-slot /nix/store/closure a' "$dir/ssh-log"
    grep -q 'dd of=/dev/disk/by-partuuid/4a414e55-5300-4000-8000-000000000002' "$dir/ssh-log"
    grep -q 'dd of=/dev/disk/by-partuuid/4a414e55-5300-4000-8000-000000000003' "$dir/ssh-log"
    if grep -q '/mnt/' "$dir/ssh-log"; then
      echo "slot deploy used a mount point on /" >&2
      exit 1
    fi
    tail -n 1 "$dir/ssh-log" | grep -q 'umount /run/janus-slot-nix'
    tail -n 1 "$dir/ssh-log" | grep -q deploy-pending
    tail -n 1 "$dir/ssh-log" | grep -q 'mount -o remount,ro /boot'
    tail -n 1 "$dir/ssh-log" | grep -q 'systemctl reboot'
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
      nativeBuildInputs = [pkgs.janet pkgs.openssl pkgs.jq pkgs.stunnel];
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
      grep -q 'accept = :::8443' stunnel.conf
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
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.Group} = janus-web
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.Type} = notify
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.NotifyAccess} = main
      test ${
        if os.config.systemd.services.janus-web.serviceConfig.NoNewPrivileges or false
        then "yes"
        else "no"
      } = no
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.CapabilityBoundingSet} = '~CAP_SYS_ADMIN'
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.RuntimeDirectoryMode} = 0750
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.serviceConfig.ReadWritePaths} = /var/lib/janus
      test ${lib.escapeShellArg os.config.systemd.services.janus-web.environment.JANUS_WEB_SUDO_BIN} = ${lib.escapeShellArg "${os.config.security.wrapperDir}/sudo"}
      test ${lib.escapeShellArg os.config.systemd.services.janus-web-tls.serviceConfig.User} = janus-web-tls
      test ${lib.escapeShellArg os.config.systemd.services.janus-web-tls.serviceConfig.Group} = janus-web-tls
      # janus-web-tls reaches the runtime directory through group janus-web.
      # The directory is mode 0750 and the socket is mode 0660. The key is
      # mode 0640 and group janus-web-tls.
      test ${
        if lib.elem "janus-web" os.config.users.users.janus-web-tls.extraGroups
        then "yes"
        else "no"
      } = yes
      grep -q 'exec janet "$JANUS_WEB_JANET" serve' ${../pkgs/janus-web.sh}
      grep -q '(notify-ready)' ${../janet/web.janet}
      if grep -q systemd-notify ${../pkgs/janus-web.sh}; then
        echo "readiness must be sent by the main process" >&2
        exit 1
      fi
      grep -q 'os/chmod sock 8r660' ${../janet/web.janet}
      grep -q 'chmod 0640 "$key"' ${../pkgs/janus-web.sh}
      grep -q 'chown root:janus-web-tls "$key" "$cert"' ${../pkgs/janus-web.sh}
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
      sed \
        -e "s|/var/lib/janus/web/cert.pem|$dir/cert.pem|" \
        -e "s|/var/lib/janus/web/key.pem|$dir/key.pem|" \
        -e "s|/run/janus-web/http.sock|$dir/http.sock|" \
        stunnel.conf > "$dir/stunnel.conf"
      cat > "$dir/http.janet" << 'EOF'
      (def path (os/getenv "SOCK"))
      (def server (net/listen :unix path))
      (defn serve [conn]
        (net/read conn 4096)
        (net/write conn "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        (:close conn))
      (net/accept-loop server serve)
      EOF
      SOCK=$dir/http.sock janet "$dir/http.janet" > "$dir/http.log" 2>&1 &
      http_pid=$!
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if test -S "$dir/http.sock"; then
          break
        fi
        sleep 0.1
      done
      test -S "$dir/http.sock"
      stunnel "$dir/stunnel.conf" > "$dir/stunnel.log" 2>&1 &
      tls_pid=$!
      answered=no
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if ! kill -0 "$tls_pid" 2>/dev/null; then
          echo "stunnel exited during configuration" >&2
          cat "$dir/stunnel.log" >&2
          kill "$http_pid" 2>/dev/null || true
          exit 1
        fi
        if printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' | openssl s_client -connect 127.0.0.1:8443 -quiet -ign_eof > "$dir/v4.out" 2>"$dir/v4.err"; then
          :
        fi
        if grep -q 'HTTP/1.1 200' "$dir/v4.out"; then
          answered=yes
          break
        fi
        sleep 0.1
      done
      if test "$answered" != yes; then
        echo "stunnel did not answer https://127.0.0.1:8443" >&2
        cat "$dir/stunnel.log" "$dir/v4.err" >&2
        kill "$tls_pid" "$http_pid" 2>/dev/null || true
        exit 1
      fi
      if printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' | openssl s_client -connect '[::1]:8443' -quiet -ign_eof > "$dir/v6.out" 2>"$dir/v6.err"; then
        :
      fi
      if ! grep -q 'HTTP/1.1 200' "$dir/v6.out"; then
        echo "stunnel did not answer https://[::1]:8443" >&2
        cat "$dir/stunnel.log" "$dir/v6.err" >&2
        kill "$tls_pid" "$http_pid" 2>/dev/null || true
        exit 1
      fi
      kill "$tls_pid" "$http_pid" 2>/dev/null || true
      wait "$tls_pid" 2>/dev/null || true
      wait "$http_pid" 2>/dev/null || true
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

      # A sops path must install secrets before the listener. The file is still
      # absent here, so start exits 1 and does not reach janus-web.
      mkdir -p "$dir/sops"
      cat > "$dir/sops/systemctl" << 'EOF'
      #!/bin/sh
      printf '%s\n' "$*" >> "$JANUS_LOG"
      if [ "$1" = cat ] && [ "$2" = janus-web-secret.service ]; then
        exit 1
      fi
      exit 0
      EOF
      chmod +x "$dir/sops/systemctl"
      : > "$dir/sops/log"
      jq -n --arg pass /run/secrets/web-router '{enable:true, passphraseFile:$pass, paused:"/no/such", cert:"/no/such", key:"/no/such", port:8443, zones:["lan"]}' > "$dir/sops/web.json"
      if JANUS_WEB_JSON=$dir/sops/web.json JANUS_SYSTEMCTL=$dir/sops/systemctl JANUS_LOG=$dir/sops/log ${web} start 2>"$dir/sops/err"; then
        echo "missing sops passphrase should exit 1" >&2
        exit 1
      fi
      grep -q 'start sops-install-secrets.service' "$dir/sops/log"
      if grep -q 'start janus-web.service' "$dir/sops/log"; then
        echo "listener started before the sops passphrase existed" >&2
        exit 1
      fi
      grep -q 'janus web passphrase file is missing or empty.' "$dir/sops/err"
      if grep -q 'could not install the passphrase secret' "$dir/sops/err"; then
        echo "a finished install is not an install failure" >&2
        exit 1
      fi
      cat > "$dir/sops/systemctl-secret" << 'EOF'
      #!/bin/sh
      printf '%s\n' "$*" >> "$JANUS_LOG"
      if [ "$1" = start ] && [ "$2" = janus-web-secret.service ]; then
        exit 1
      fi
      exit 0
      EOF
      chmod +x "$dir/sops/systemctl-secret"
      : > "$dir/sops/log"
      if JANUS_WEB_JSON=$dir/sops/web.json JANUS_SYSTEMCTL=$dir/sops/systemctl-secret JANUS_LOG=$dir/sops/log ${web} start 2>"$dir/sops/err"; then
        echo "failed passphrase unit should exit 1" >&2
        exit 1
      fi
      grep -q 'start janus-web-secret.service' "$dir/sops/log"
      grep -q 'janus web could not install the passphrase secret.' "$dir/sops/err"
      if grep -q 'passphrase file is missing or empty' "$dir/sops/err"; then
        echo "a failed install was reported as an empty file" >&2
        exit 1
      fi
      if grep -q 'start sops-install-secrets.service' "$dir/sops/log"; then
        echo "passphrase unit should be what pulls sops in" >&2
        exit 1
      fi
      if grep -q 'start janus-web.service' "$dir/sops/log"; then
        echo "listener started after the passphrase unit failed" >&2
        exit 1
      fi
      cat > "$dir/sops/systemctl-ok" << EOF
      #!/bin/sh
      printf '%s\n' "\$*" >> "\$JANUS_LOG"
      if [ "\$1" = start ] && [ "\$2" = janus-web-secret.service ]; then
        printf '%s\n' secret > "$dir/sops/pass"
      fi
      exit 0
      EOF
      chmod +x "$dir/sops/systemctl-ok"
      jq -n --arg pass "$dir/sops/pass" '{enable:true, passphraseFile:$pass, paused:"/no/such", cert:"/no/such", key:"/no/such", port:8443, zones:["lan"]}' > "$dir/sops/web-ok.json"
      : > "$dir/sops/log"
      JANUS_WEB_JSON=$dir/sops/web-ok.json JANUS_SYSTEMCTL=$dir/sops/systemctl-ok JANUS_LOG=$dir/sops/log ${web} start 2>"$dir/sops/err"
      grep -q 'start janus-web-secret.service' "$dir/sops/log"
      grep -q 'start janus-web.service' "$dir/sops/log"
      test -s "$dir/sops/pass"
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
  cli-age-key = pkgs.runCommand "cli-age-key" {
    nativeBuildInputs = [pkgs.python3];
  } ''
    set -eu
    dir=$TMPDIR/root
    mkdir -p "$dir/bin" "$dir/secrets"
    cat > "$dir/bin/systemctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    if [ "$1" = list-units ]; then
      printf '%s\n' 'janus-web-tls.service loaded failed'
      printf '%s\n' 'janus-wireguard-secret-uplink.service loaded failed'
      printf '%s\n' 'janus-pppoe-main.service loaded failed'
      printf '%s\n' 'janus-web.service loaded failed'
      printf '%s\n' 'janus-hostapd-home.service loaded failed'
      printf '%s\n' 'janus-tailscale-auth.service loaded failed'
      printf '%s\n' 'tailscaled.service loaded failed'
    fi
    exit 0
    EOF
    chmod +x "$dir/bin/systemctl"
    cat > "$dir/bin/networkctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    exit 0
    EOF
    chmod +x "$dir/bin/networkctl"
    printf '%s\n' 'AGE-SECRET-KEY-1test' | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/log" PATH="$dir/bin:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key 2>"$dir/err"
    test ! -s "$dir/err"
    printf '%s\n' 'AGE-SECRET-KEY-1test' | cmp - "$dir/secrets/age.key"
    test "$(stat -c %a "$dir/secrets/age.key")" = 600
    awk '
      $1 == "restart" && $2 == "sops-install-secrets.service" { sops = NR }
      $1 == "restart" && $2 == "janus-pppoe-main.service" { pppoe = NR }
      $1 == "restart" && $2 == "janus-hostapd-home.service" { ap = NR }
      $1 == "restart" && $2 == "janus-tailscale-auth.service" { auth = NR }
      $1 == "restart" && $2 == "tailscaled.service" { tail = NR }
      $1 == "restart" && $2 == "janus-web-secret.service" { page = NR }
      $1 == "restart" && $2 == "janus-web.service" { web = NR }
      $1 == "restart" && $2 == "janus-web-tls.service" { tls = NR }
      $1 == "restart" && $2 == "janus-wireguard-secret-uplink.service" { wg = NR }
      $1 == "reconfigure" && $2 == "wg-uplink" { re = NR }
      $1 == "reload" { reload = NR }
      END {
        if (!(sops && pppoe && ap && auth && tail && page && web && tls && wg && re && !reload && sops < pppoe && sops < ap && sops < auth && auth < tail && page < web && web < tls && wg < re)) exit 1
      }
    ' "$dir/log"
    mkdir -p "$dir/wgfail"
    cat > "$dir/wgfail/systemctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    if [ "$1" = list-units ]; then
      printf '%s\n' 'janus-wireguard-secret-uplink.service loaded failed'
    fi
    if [ "$1" = restart ] && [ "$2" = janus-wireguard-secret-uplink.service ]; then
      exit 1
    fi
    exit 0
    EOF
    cat > "$dir/wgfail/networkctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    exit 0
    EOF
    chmod +x "$dir/wgfail/systemctl" "$dir/wgfail/networkctl"
    : > "$dir/wgfail-log"
    printf '%s\n' 'AGE-SECRET-KEY-1test' | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/wgfail-log" PATH="$dir/wgfail:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key 2>"$dir/wgfail-err"
    if grep -q reconfigure "$dir/wgfail-log" || grep -q '^reload$' "$dir/wgfail-log"; then
      echo "networkctl ran after a failed wireguard secret" >&2
      exit 1
    fi
    mkdir -p "$dir/wgreload"
    cat > "$dir/wgreload/systemctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    if [ "$1" = list-units ]; then
      printf '%s\n' 'janus-wireguard-secret-uplink.service loaded failed'
    fi
    exit 0
    EOF
    cat > "$dir/wgreload/networkctl" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_LOG"
    if [ "$1" = reconfigure ]; then
      exit 1
    fi
    exit 0
    EOF
    chmod +x "$dir/wgreload/systemctl" "$dir/wgreload/networkctl"
    : > "$dir/wgreload-log"
    printf '%s\n' 'AGE-SECRET-KEY-1test' | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/wgreload-log" PATH="$dir/wgreload:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key 2>"$dir/wgreload-err"
    grep -q '^reconfigure wg-uplink$' "$dir/wgreload-log"
    grep -q '^reload$' "$dir/wgreload-log"
    printf '%s\n' 'AGE-SECRET-KEY-1old' > "$dir/secrets/age.key"
    if printf '%s' "" | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/empty-log" PATH="$dir/bin:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key 2>"$dir/empty-err"; then
      echo "an empty age key was installed" >&2
      exit 1
    fi
    if printf '\n' | JANUS_SECRETS_DIR="$dir/secrets" JANUS_LOG="$dir/empty-log" PATH="$dir/bin:$PATH" bash ${../pkgs/janus.sh} secrets install-age-key 2>"$dir/nl-err"; then
      echo "a blank age key was installed" >&2
      exit 1
    fi
    grep -q 'Refusing an age key that has no AGE-SECRET-KEY-1 line.' "$dir/empty-err"
    grep -q 'Refusing an age key that has no AGE-SECRET-KEY-1 line.' "$dir/nl-err"
    printf '%s\n' 'AGE-SECRET-KEY-1old' | cmp - "$dir/secrets/age.key"
    test ! -e "$dir/empty-log"
    python3 - ${../pkgs/janus.sh} "$dir" << 'PY'
    import os, pty, select, subprocess, sys
    script, root = sys.argv[1], sys.argv[2]
    env = os.environ.copy()
    env["JANUS_SECRETS_DIR"] = os.path.join(root, "tty-secrets")
    env["JANUS_LOG"] = os.path.join(root, "tty-log")
    env["PATH"] = os.path.join(root, "bin") + os.pathsep + env["PATH"]
    os.makedirs(env["JANUS_SECRETS_DIR"])
    master, slave = pty.openpty()
    proc = subprocess.Popen(["bash", script, "secrets", "install-age-key"], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    buf = b""
    def pump(timeout):
        global buf
        while True:
            ready, _, _ = select.select([master], [], [], timeout)
            if not ready:
                return
            try:
                chunk = os.read(master, 4096)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
    pump(2)
    if b"Paste the age private key, then press Enter and Ctrl-D." not in buf:
        sys.stderr.write(buf.decode("utf-8", "replace"))
        sys.exit(1)
    os.write(master, b"AGE-SECRET-KEY-1tty\n\x04")
    pump(2)
    rc = proc.wait(timeout=5)
    if rc != 0:
        sys.exit(rc)
    PY
    printf '%s\n' 'AGE-SECRET-KEY-1tty' | cmp - "$dir/tty-secrets/age.key"
    test "$(stat -c %a "$dir/tty-secrets/age.key")" = 600
    cat > "$dir/bin/ssh" << 'EOF'
    #!/bin/sh
    printf '%s\n' "$*" >> "$JANUS_SSH_LOG"
    probe=0
    for arg in "$@"; do
      if [ "$arg" = -n ]; then
        probe=1
      fi
    done
    if [ "$probe" = 1 ]; then
      if [ "''${JANUS_SSH_FAIL:-}" = 1 ]; then
        exit 1
      fi
      exit 0
    fi
    cat > "$JANUS_KEY_OUT"
    EOF
    chmod +x "$dir/bin/ssh"
    JANUS_BUILD_LIB=1
    # shellcheck disable=SC1091
    . ${../pkgs/janus-build.sh}
    test "$(ssh_dest potato)" = root@potato
    test "$(ssh_dest 192.168.10.1)" = root@192.168.10.1
    test "$(ssh_dest 'fd7a:115c:a1e0::1')" = 'root@[fd7a:115c:a1e0::1]'
    test "$(ssh_dest '[fd7a:115c:a1e0::1]')" = 'root@[fd7a:115c:a1e0::1]'
    test "$(ssh_dest 'root@[fd7a:115c:a1e0::1]')" = 'root@[fd7a:115c:a1e0::1]'
    export JANUS_SSH_LOG=$dir/ssh-log JANUS_KEY_OUT=$dir/key-out
    export PATH="$dir/bin:$PATH"
    printf '%s\n' 'AGE-SECRET-KEY-1ssh' | install_age_key_over_ssh 'fd7a:115c:a1e0::1' 2>"$dir/ssh-err"
    test ! -s "$dir/ssh-err"
    printf '%s\n' 'AGE-SECRET-KEY-1ssh' | cmp - "$dir/key-out"
    head -n 1 "$dir/ssh-log" | grep -q -- '-n'
    grep -q 'root@\[fd7a:115c:a1e0::1\] janus secrets install-age-key' "$dir/ssh-log"
    : > "$dir/ssh-log"
    rm -f "$dir/key-out"
    if printf '\n' | install_age_key_over_ssh 192.168.10.1 2>"$dir/ssh-empty"; then
      echo "an empty key was sent over ssh" >&2
      exit 1
    fi
    grep -q 'Refusing an age key that has no AGE-SECRET-KEY-1 line.' "$dir/ssh-empty"
    test ! -e "$dir/key-out"
    test "$(wc -l < "$dir/ssh-log")" -eq 1
    : > "$dir/ssh-log"
    rest=$(printf '%s\n' 'AGE-SECRET-KEY-1keep' | (JANUS_SSH_FAIL=1 install_age_key_over_ssh 192.168.10.1 >/dev/null 2>"$dir/ssh-fail" || true; cat))
    test "$rest" = "AGE-SECRET-KEY-1keep"
    if grep -q 'Paste the age private key' "$dir/ssh-fail"; then
      echo "a failed probe printed the paste prompt" >&2
      exit 1
    fi
    python3 - ${../pkgs/janus-build.sh} "$dir" << 'PY'
    import os, pty, select, subprocess, sys
    script, root = sys.argv[1], sys.argv[2]
    env = os.environ.copy()
    env["JANUS_BUILD_LIB"] = "1"
    env["JANUS_SSH_LOG"] = os.path.join(root, "tty-ssh-log")
    env["JANUS_KEY_OUT"] = os.path.join(root, "tty-remote-key")
    env["PATH"] = os.path.join(root, "bin") + os.pathsep + env["PATH"]
    env.pop("JANUS_SSH_FAIL", None)
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ["bash", "-c", '. "$1"; install_age_key_over_ssh "$2"', "bash", script, "192.168.10.1"],
        stdin=slave, stdout=slave, stderr=slave, env=env,
    )
    os.close(slave)
    buf = b""
    def pump(timeout):
        global buf
        while True:
            ready, _, _ = select.select([master], [], [], timeout)
            if not ready:
                return
            try:
                chunk = os.read(master, 4096)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
    pump(2)
    if b"Paste the age private key, then press Enter and Ctrl-D." not in buf:
        sys.stderr.write(buf.decode("utf-8", "replace"))
        sys.exit(1)
    os.write(master, b"AGE-SECRET-KEY-1tty\n\x04")
    pump(2)
    rc = proc.wait(timeout=5)
    if rc != 0:
        sys.exit(rc)
    PY
    printf '%s\n' 'AGE-SECRET-KEY-1tty' | cmp - "$dir/tty-remote-key"
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
    secretRequires = os.config.systemd.services.janus-web-secret.requires or [];
    secretStart = os.config.systemd.services.janus-web-secret.serviceConfig.ExecStart;
  in
    pkgs.runCommand "eval-web-sops" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -eu
      printf '%s\n' ${lib.escapeShellArg spec} > web.json
      jq -e '.passphraseFile == "/run/secrets/web-router"' web.json >/dev/null
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " requires)} | grep -q janus-web-secret.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " after)} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " secretRequires)} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg secretStart} | grep -q ${lib.escapeShellArg os.config.sops.secrets.web-router.path}
      echo ok > "$out"
    '';
  eval-sops-file-paths = let
    os = mk [
      base
      {
        sops.secrets.pppoe-eval.sopsFile = ./fixtures/sops-placeholder;
        sops.secrets.wg-eval.sopsFile = ./fixtures/sops-placeholder;
        sops.secrets.wg-kept = {
          sopsFile = ./fixtures/sops-placeholder;
          key = "kept";
        };
        sops.secrets.node-eval.sopsFile = ./fixtures/sops-placeholder;
        sops.secrets.web-file.sopsFile = ./fixtures/sops-placeholder;
        janus.network.wans.main = {
          uplink = "wan";
          mode = "pppoe";
          pppoe = {
            username = "alice";
            passwordFile = "/run/secrets/pppoe-eval";
          };
        };
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.remoteAccess.wireguard.uplink = {
          privateKeyFile = "/run/secrets/wg-eval";
          address = "10.9.0.2/32";
          peer.publicKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=";
          peer.allowedIPs = ["0.0.0.0/0"];
        };
        janus.remoteAccess.wireguard.kept = {
          privateKeyFile = "/run/secrets/wg-kept";
          address = "10.9.0.3/32";
          peer.publicKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=";
          peer.allowedIPs = ["0.0.0.0/0"];
        };
        janus.proxy = {
          enable = true;
          nodes.secret = {
            protocol = "trojan";
            server = "203.0.113.10";
            port = 443;
            trojan.passwordFile = "/run/secrets/node-eval";
          };
        };
        janus.access.web = {
          enable = true;
          passphraseFile = "/run/secrets/web-file";
        };
      }
    ];
  in
    pkgs.runCommand "eval-sops-file-paths" {} ''
      set -eu
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.janus-pppoe-main.requires or []))} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.janus-engine-prepare.requires or []))} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.systemd-networkd.after or []))} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.systemd-networkd.wants or []))} | grep -q janus-wireguard-secret-uplink.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.janus-wireguard-secret-uplink.requires or []))} | grep -q sops-install-secrets.service
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.janus-web.requires or []))} | grep -q janus-web-secret.service
      if printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " (os.config.systemd.services.systemd-networkd.requires or []))} | grep -q janus-wireguard-secret-uplink.service; then
        echo "a wireguard key must not be required by all of networkd" >&2
        exit 1
      fi
      test ${lib.escapeShellArg os.config.sops.secrets.wg-eval.key} = value
      test ${lib.escapeShellArg os.config.sops.secrets.wg-kept.key} = kept
      test ${lib.escapeShellArg os.config.sops.secrets.web-file.key} = value
      test ${lib.escapeShellArg os.config.sops.secrets.pppoe-eval.key} = value
      test ${lib.escapeShellArg os.config.sops.secrets.node-eval.key} = ""
      if printf '%s\n' ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (a: a.message) (lib.filter (a: !a.assertion && lib.hasPrefix "A file at /run/secrets/" a.message) os.config.assertions))} | grep -q .; then
        echo "a declared sops path was missing its sopsFile" >&2
        exit 1
      fi
      sed -n '/^password_from_file()/,/^}/p' ${../pkgs/janus-engine.sh} > password.fn
      # The function is sourced for this check. The engine script is not executed.
      . ./password.fn
      printf '%s\n' 'uuid: abc' 'password: "node-secret"' > node.yaml
      test "$(password_from_file node.yaml)" = node-secret
      printf '%s' 'raw-secret' > raw.pw
      test "$(password_from_file raw.pw)" = raw-secret
      echo ok > "$out"
    '';
  eval-sops-path-missing = fail "eval-sops-path-missing" [
    base
    {
      janus.remoteAccess.wireguard.uplink = {
        privateKeyFile = "/run/secrets/wg-missing";
        address = "10.9.0.2/32";
        peer.publicKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=";
        peer.allowedIPs = ["0.0.0.0/0"];
      };
    }
  ];
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
  eval-state-boot = let
    os = mk [base];
    capped = mk [
      base
      {janus.storage.state.maximumSize = "1G";}
    ];
    monthly = mk [
      base
      {
        janus.system.reboot.schedule = "monthly";
        janus.system.reboot.fsck = true;
      }
    ];
    yearly = mk [
      base
      {janus.system.reboot.schedule = "0 4 1 1 *";}
    ];
    padded = mk [
      base
      {janus.system.reboot.schedule = "00 04 08 * *";}
    ];
    recover = os.config.boot.initrd.systemd.services.janus-state-recover;
    full = os.config.boot.initrd.systemd.services.janus-state-fsck-full;
    growSvc = os.config.boot.initrd.systemd.services.janus-grow-state;
    grow = growSvc.script;
    grow1 = capped.config.boot.initrd.systemd.services.janus-grow-state.script;
  in
    pkgs.runCommand "eval-state-boot" {} ''
      test ${lib.escapeShellArg os.config.janus.storage.state.maximumSize} = 4G
      test ${lib.escapeShellArg (toString os.config.janus.system.reboot.schedule)} = ""
      test ${
        if os.config.systemd.timers ? janus-reboot
        then "yes"
        else "no"
      } = no
      test ${lib.escapeShellArg recover.serviceConfig.TimeoutStartSec} = 15min
      test ${lib.escapeShellArg full.serviceConfig.TimeoutStartSec} = infinity
      test ${lib.escapeShellArg full.unitConfig.ConditionPathExists} = /run/janus/full-fsck
      grep -F -q -- '--no-kernel-check' <<'EOF'
      ${recover.script}
      EOF
      if grep -F -q -- 'timeout 30' <<'EOF'
      ${recover.script}
      EOF
      then
        echo "boot fsck still has a 30s timeout" >&2
        exit 1
      fi
      grep -F -q -- 'fsck.f2fs -f' <<'EOF'
      ${full.script}
      EOF
      drop=$(grep -n 'rm -f "$probe/lib/janus/full-fsck"' <<'EOF' | sed -n '1s/:.*//p'
      ${full.script}
      EOF
      )
      fsckat=$(grep -n 'fsck.f2fs -f' <<'EOF' | sed -n '1s/:.*//p'
      ${full.script}
      EOF
      )
      if [ -z "$drop" ] || [ -z "$fsckat" ] || [ "$drop" -ge "$fsckat" ]; then
        echo "the full-fsck request is not dropped before the check" >&2
        exit 1
      fi
      grep -F -q -- 'max_sectors=8388608' <<'EOF'
      ${grow}
      EOF
      grep -F -q -- 'max_sectors=2097152' <<'EOF'
      ${grow1}
      EOF
      bash -n <<'EOF'
      ${grow}
      EOF
      bash -n <<'EOF'
      ${recover.script}
      EOF
      bash -n <<'EOF'
      ${full.script}
      EOF
      awk '
        /sgdisk -e/ { seen = 1 }
        seen && /publish_state/ { published = 1 }
        /exit 0/ && !published { bad = 1 }
        END { if (bad) exit 1 }
      ' <<'EOF'
      ${grow}
      EOF
      wanted=${lib.escapeShellArg (lib.concatStringsSep " " growSvc.wantedBy)}
      required=${lib.escapeShellArg (lib.concatStringsSep " " growSvc.requiredBy)}
      case " $wanted " in
        *" janus-state-recover.service "*) ;;
        *)
          echo "recover does not want grow" >&2
          exit 1
          ;;
      esac
      case " $required " in
        *" janus-state-recover.service "*)
          echo "recover requires grow, so a partx failure skips fsck" >&2
          exit 1
          ;;
      esac
      if grep -F -q -- 'settle --timeout=10 || true' <<'EOF'
      ${grow}
      EOF
      then
        echo "udev settle failure is ignored" >&2
        exit 1
      fi
      awk '
        /partx did not update/ { partx_msg = NR }
        /did not return after the partition reread/ { missing = NR }
        /exit 1/ { exits[++nexit] = NR }
        END {
          if (!partx_msg || !missing || missing < partx_msg) {
            print "partx failure is not followed by the missing-node path" > "/dev/stderr"
            exit 1
          }
          for (i = 1; i <= nexit; i++) {
            if (exits[i] > partx_msg && exits[i] < missing) {
              print "partx failure exits before the node is known to be gone" > "/dev/stderr"
              exit 1
            }
          }
        }
      ' <<'EOF'
      ${grow}
      EOF
      # Every mkfs must sit in the same small window as a missing-node exit.
      check_reformat() {
        awk '
          {
            line[NR] = $0
          }
          END {
            mkfs_n = 0
            for (i = 1; i <= NR; i++) {
              if (line[i] !~ /mkfs\.f2fs/) continue
              mkfs_n++
              guard = 0
              exited = 0
              from = i - 25
              if (from < 1) from = 1
              for (j = i - 1; j >= from; j--) {
                if (line[j] ~ /! -b "\$dev"/) {
                  guard = j
                  break
                }
              }
              if (!guard) {
                print "mkfs has no missing-node test in the preceding window" > "/dev/stderr"
                exit 1
              }
              for (j = guard; j < i; j++) {
                if (line[j] ~ /exit 1/) exited = 1
              }
              if (!exited) {
                print "mkfs is reached when the missing-node branch does not exit" > "/dev/stderr"
                exit 1
              }
            }
            if (mkfs_n < 1) {
              print "reformat command is missing" > "/dev/stderr"
              exit 1
            }
          }
        '
      }
      awk '
        {
          line[NR] = $0
        }
        END {
          calls = 0
          broken = 0
          calls_before = 0
          for (i = 1; i <= NR; i++) {
            if (line[i] ~ /^[[:space:]]*run_fsck[[:space:]]*$/) {
              calls++
              if (!broken) calls_before = calls
            }
            if (line[i] ~ /^[[:space:]]*probe_once[[:space:]]*$/) probes++
            if (!broken && line[i] ~ /action=broken/) broken = i
          }
          if (calls_before < 2 || !broken) {
            print "status 4 or 255 selects reformat without a second fsck" > "/dev/stderr"
            exit 1
          }
          if (probes < 2) {
            print "the probe mount is not repeated" > "/dev/stderr"
            exit 1
          }
        }
      ' <<'EOF'
      ${recover.script}
      EOF
      check_reformat <<'EOF'
      ${recover.script}
      EOF
      awk '
        /fsck\.f2fs -f/ { fsck++ }
        /4\|255\)/ && !case_at { case_at = 1; fsck_before = fsck }
        /^[[:space:]]*probe_rw[[:space:]]*$/ { probes++ }
        END {
          if (fsck_before < 2) {
            print "full fsck status 4 or 255 is not repeated" > "/dev/stderr"
            exit 1
          }
          if (probes < 4) {
            print "full fsck does not retry the mount when the node returns" > "/dev/stderr"
            exit 1
          }
        }
      ' <<'EOF'
      ${full.script}
      EOF
      check_reformat <<'EOF'
      ${full.script}
      EOF
      test ${lib.escapeShellArg monthly.config.systemd.timers.janus-reboot.timerConfig.OnCalendar} = '*-*-01 04:00:00'
      test ${lib.escapeShellArg yearly.config.systemd.timers.janus-reboot.timerConfig.OnCalendar} = '*-01-01 04:00:00'
      test ${lib.escapeShellArg padded.config.systemd.timers.janus-reboot.timerConfig.OnCalendar} = '*-*-08 04:00:00'
      grep -F -q -- 'systemctl reboot' <<'EOF'
      ${monthly.config.systemd.services.janus-reboot.script}
      EOF
      if grep -F -q -- 'full-fsck' <<'EOF'
      ${monthly.config.systemd.services.janus-reboot.script}
      EOF
      then
        echo "the reboot service itself requests a full check" >&2
        exit 1
      fi
      grep -F -q -- '/var/lib/janus/full-fsck' <<'EOF'
      ${monthly.config.systemd.services.janus-reboot-fsck.script}
      EOF
      test ${
        if yearly.config.systemd.services ? janus-reboot-fsck
        then "yes"
        else "no"
      } = no
      echo ok > "$out"
    '';
  eval-state-reboot-fsck = fail "eval-state-reboot-fsck" [
    base
    {janus.system.reboot.fsck = true;}
  ];
  eval-state-reboot-cron = fail "eval-state-reboot-cron" [
    base
    {janus.system.reboot.schedule = "0 4 * * 1";}
  ];
  eval-state-reboot-fields = fail "eval-state-reboot-fields" [
    base
    {janus.system.reboot.schedule = "0 4 1 *";}
  ];
}
