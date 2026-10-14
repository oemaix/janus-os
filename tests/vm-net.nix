# SPDX-License-Identifier: Apache-2.0
# Boot the x86_64-test image with a WAN and a LAN. A second guest takes a
# DHCPv4 lease, leaves through NAT, receives a static DNS answer, and sees
# SSH open on the LAN and closed on the WAN. docs/09 §9.
{
  pkgs,
  nixpkgs,
  self,
}: let
  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval";
  os = self.lib.mkRouter {
    name = "net";
    source = self;
    configRevision = self.rev or "unknown";
    modules = [
      ({pkgs, ...}: {
        janus.hardware.board = "x86_64-test";
        janus.access.ssh.authorizedKeys = [key];
        boot.kernelModules = ["tun"];
        janus.network.wans.main = {
          uplink = "wan";
          mode = "dhcp";
        };
        janus.network.lans.lan = {
          members = ["lan"];
          address = "192.168.10.1";
          prefixLength = 24;
        };
        janus.proxy = {
          enable = true;
          mode = "bypass";
        };
        janus.dns.hosts."vm.test" = "192.0.2.53";
        systemd.services.janus-vm-report = {
          description = "Print DHCP and engine state on the serial console";
          wantedBy = ["multi-user.target"];
          after = ["dnsmasq.service" "janus-engine.service" "network-online.target"];
          serviceConfig.Type = "oneshot";
          script = ''
            echo JANUS_ROUTER_UP > /dev/console
            systemctl is-active dnsmasq > /dev/console 2>&1 || true
            systemctl is-active janus-engine > /dev/console 2>&1 || true
            ${pkgs.bind}/bin/dig @127.0.0.1 -p 5353 vm.test A +time=2 +tries=1 +short > /dev/console 2>&1 || true
          '';
        };
      })
    ];
  };
  toplevel = os.config.system.build.toplevel;
  image = os.config.system.build.janusImage;
  client = nixpkgs.lib.nixosSystem {
    modules = [
      (
        {modulesPath, ...}: {
          imports = ["${modulesPath}/installer/netboot/netboot.nix"];
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "26.05";
          netboot.squashfsCompression = "zstd -Xcompression-level 1";
          networking.useNetworkd = true;
          networking.useDHCP = false;
          networking.dhcpcd.enable = false;
          boot.kernelParams = [
            "console=tty0"
            "console=ttyS0,115200"
            "net.ifnames=0"
          ];
          boot.initrd.availableKernelModules = ["virtio_pci" "virtio_net" "virtio_ring"];
          systemd.network.networks.eth0 = {
            matchConfig.Name = "eth0";
            networkConfig.DHCP = "ipv4";
          };
          systemd.services.janus-net-probe = {
            description = "Exercise DHCP, NAT, DNS, and the firewall";
            wantedBy = ["multi-user.target"];
            after = ["systemd-networkd.service"];
            path = [pkgs.iproute2 pkgs.curl pkgs.busybox pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              set -eu
              fail() {
                echo "JANUS_NET_FAIL $1" > /dev/console
                systemctl poweroff
                exit 1
              }
              addr=
              for _ in $(seq 1 90); do
                addr=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -n 1 || true)
                case "$addr" in
                  192.168.10.*) break ;;
                esac
                sleep 1
              done
              case "$addr" in
                192.168.10.*) ;;
                *) fail dhcp ;;
              esac
              echo "JANUS_DHCP_OK $addr" > /dev/console
              if ! curl -fsS --retry 30 --retry-delay 1 --retry-all-errors --max-time 40 \
                http://10.0.2.2:18080/token | grep -q janus-nat-ok; then
                fail nat
              fi
              echo JANUS_NAT_OK > /dev/console
              banner=$(timeout 5 busybox nc 192.168.10.1 22 | head -c 3 || true)
              if [ "$banner" != SSH ]; then
                fail lan-ssh
              fi
              echo JANUS_FW_LAN_OK > /dev/console
              looked=
              for _i in $(seq 1 15); do
                looked=$(busybox nslookup vm.test 192.168.10.1 2>&1 || true)
                if printf '%s\n' "$looked" | grep -q 192.0.2.53; then
                  break
                fi
                sleep 1
              done
              echo "JANUS_DNS_OUT $looked" > /dev/console
              if ! printf '%s\n' "$looked" | grep -q 192.0.2.53; then
                fail dns
              fi
              echo JANUS_DNS_OK > /dev/console
              echo JANUS_NET_OK > /dev/console
              systemctl poweroff
            '';
          };
        }
      )
    ];
  };
  clientKernel = "${client.config.system.build.kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
in
  pkgs.runCommand "vm-x86_64-net" {
    nativeBuildInputs = [pkgs.qemu pkgs.python3 pkgs.coreutils];
  } ''
    set -eu
    params=$(tr '\n' ' ' < ${toplevel}/kernel-params)
    params="$params init=${toplevel}/init"
    cparams=$(tr '\n' ' ' < ${client.config.system.build.toplevel}/kernel-params)
    cparams="$cparams init=${client.config.system.build.toplevel}/init"

    web=$(mktemp -d)
    printf '%s\n' janus-nat-ok > "$web/token"
    python3 -m http.server 18080 --bind 127.0.0.1 --directory "$web" > http.log 2>&1 &
    http_pid=$!
    router_pid=
    client_pid=
    trap 'kill $http_pid $router_pid $client_pid 2>/dev/null || true' EXIT

    qemu-system-x86_64 \
      -m 2048 -smp 2 -no-reboot -display none \
      -machine accel=tcg \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$params" \
      -snapshot \
      -drive if=none,id=disk,format=raw,file=${image}/janus-net.img \
      -device virtio-blk-pci,drive=disk \
      -netdev user,id=wan,hostfwd=tcp:127.0.0.1:2222-:22 \
      -device virtio-net-pci,netdev=wan,mac=52:54:00:12:00:01 \
      -netdev socket,id=lan,listen=127.0.0.1:5234 \
      -device virtio-net-pci,netdev=lan,mac=52:54:00:12:00:02 \
      -serial file:router.log &
    router_pid=$!
    ready=0
    for _i in $(seq 1 180); do
      if grep -q JANUS_ROUTER_UP router.log; then
        ready=1
        break
      fi
      sleep 2
    done
    if [ "$ready" != 1 ]; then
      echo "router did not report ready" >&2
      tail -n 80 router.log >&2 || true
      exit 1
    fi
    qemu-system-x86_64 \
      -m 2048 -smp 1 -no-reboot -display none \
      -machine accel=tcg \
      -kernel ${clientKernel} \
      -initrd ${client.config.system.build.netbootRamdisk}/initrd \
      -append "$cparams" \
      -netdev socket,id=lan,connect=127.0.0.1:5234 \
      -device virtio-net-pci,netdev=lan,mac=52:54:00:12:00:03 \
      -serial file:client.log &
    client_pid=$!

    probed=0
    ok=0
    for _i in $(seq 1 360); do
      if grep -q JANUS_NET_FAIL client.log; then
        break
      fi
      if [ "$probed" = 0 ] && grep -q JANUS_FW_LAN_OK client.log; then
        probed=1
        banner=$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222; head -c 3 <&3' || true)
        if [ "$banner" = SSH ]; then
          echo "WAN accepted an SSH connection" > wan.log
        else
          echo JANUS_FW_WAN_OK > wan.log
        fi
      fi
      if grep -q JANUS_NET_OK client.log && [ -f wan.log ]; then
        ok=1
        break
      fi
      sleep 2
    done

    if [ "$ok" != 1 ] || ! grep -q JANUS_FW_WAN_OK wan.log; then
      echo "--- client ---" >&2
      tail -n 200 client.log >&2 || true
      echo "--- router ---" >&2
      tail -n 200 router.log >&2 || true
      echo "--- wan ---" >&2
      cat wan.log >&2 || true
      echo "--- http ---" >&2
      cat http.log >&2 || true
      exit 1
    fi
    grep -q JANUS_DHCP_OK client.log
    grep -q JANUS_NAT_OK client.log
    grep -q JANUS_DNS_OK client.log
    mkdir -p "$out"
    cp client.log router.log wan.log "$out/"
  ''
