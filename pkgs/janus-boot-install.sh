# Install or restore the FAT boot entry for one system closure. docs/09 §8.2.
# The bootloader loads /boot/vmlinuz and /boot/initrd, and the kernel command
# line carries init=<closure>/init. The profile symlink alone does not boot.
set -eu
boot=${JANUS_BOOT_DIR:-/boot}
state=${JANUS_STATE_DIR:-/var/lib/janus}
prev="${state}/boot-previous"

remount_boot() {
  if [ "$boot" = /boot ]; then
    mount -o remount,rw /boot || true
  fi
}

save_previous() {
  rm -rf "$prev"
  mkdir -p "$prev"
  for name in vmlinuz initrd cmdline.txt extlinux.conf limine.conf; do
    if [ -f "${boot}/${name}" ]; then
      cp -a "${boot}/${name}" "${prev}/${name}"
    fi
  done
  if [ -f "${boot}/extlinux/extlinux.conf" ]; then
    mkdir -p "${prev}/extlinux"
    cp -a "${boot}/extlinux/extlinux.conf" "${prev}/extlinux/extlinux.conf"
  fi
}

write_extlinux() {
  dest=$1
  {
    printf '%s\n' "DEFAULT janus" "LABEL janus" "  LINUX /vmlinuz" "  INITRD /initrd"
    printf '  APPEND %s\n' "$params"
    if [ -n "$fdt" ]; then
      printf '  FDT %s\n' "$fdt"
    fi
  } > "$dest"
}

install_closure() {
  closure=$1
  if [ ! -e "${closure}/kernel" ] || [ ! -e "${closure}/initrd" ] || [ ! -f "${closure}/kernel-params" ]; then
    echo "janus-boot-install: ${closure} is not a system closure" >&2
    exit 1
  fi
  remount_boot
  save_previous
  cp -L "${closure}/kernel" "${boot}/vmlinuz"
  cp -L "${closure}/initrd" "${boot}/initrd"
  params=$(tr '\n' ' ' < "${closure}/kernel-params")
  params=${params%" "}
  params="${params} init=${closure}/init"
  printf '%s\n' "$params" > "${boot}/cmdline.txt"
  fdt=""
  src_ext=""
  if [ -f "${prev}/extlinux.conf" ]; then
    src_ext=${prev}/extlinux.conf
  fi
  if [ -n "$src_ext" ]; then
    fdt=$(sed -n 's/^[[:space:]]*FDT[[:space:]]*//p' "$src_ext" | head -n 1)
    write_extlinux "${boot}/extlinux.conf"
    if [ -f "${prev}/extlinux/extlinux.conf" ] || [ -d "${boot}/extlinux" ]; then
      mkdir -p "${boot}/extlinux"
      cp "${boot}/extlinux.conf" "${boot}/extlinux/extlinux.conf"
    fi
  fi
  if [ -f "${prev}/limine.conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *cmdline:*) printf '    cmdline: %s\n' "$params" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "${prev}/limine.conf" > "${boot}/limine.conf"
  fi
}

restore_boot() {
  if [ ! -d "$prev" ]; then
    return 0
  fi
  remount_boot
  for name in vmlinuz initrd cmdline.txt extlinux.conf limine.conf; do
    if [ -f "${prev}/${name}" ]; then
      cp -a "${prev}/${name}" "${boot}/${name}"
    fi
  done
  if [ -f "${prev}/extlinux/extlinux.conf" ]; then
    mkdir -p "${boot}/extlinux"
    cp -a "${prev}/extlinux/extlinux.conf" "${boot}/extlinux/extlinux.conf"
  fi
}

cmd=${1:-}
case "$cmd" in
  install)
    if [ -z "${2:-}" ]; then
      echo "janus-boot-install install <closure>" >&2
      exit 2
    fi
    install_closure "$2"
    ;;
  restore) restore_boot ;;
  *)
    echo "janus-boot-install install <closure> | restore" >&2
    exit 2
    ;;
esac
