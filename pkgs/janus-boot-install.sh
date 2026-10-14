# Install or restore the FAT boot entry for one system closure. docs/09 §8.2.
# The bootloader loads /boot/vmlinuz and /boot/initrd, and the kernel command
# line carries init=<closure>/init. The profile symlink alone does not boot.
# install-slot updates the inactive A/B entry and then the boot-side toggle.
# docs/09 §8.4.
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

rewrite_extlinux() {
  slot=$1
  params=$2
  src=$3
  dest=$4
  current=""
  : > "$dest"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      DEFAULT*)
        printf 'DEFAULT slot-%s\n' "$slot" >> "$dest"
        ;;
      "LABEL slot-a")
        current=a
        printf '%s\n' "$line" >> "$dest"
        ;;
      "LABEL slot-b")
        current=b
        printf '%s\n' "$line" >> "$dest"
        ;;
      *APPEND*)
        if [ "$current" = "$slot" ]; then
          printf '  APPEND %s\n' "$params" >> "$dest"
        else
          printf '%s\n' "$line" >> "$dest"
        fi
        ;;
      *)
        printf '%s\n' "$line" >> "$dest"
        ;;
    esac
  done < "$src"
}

limine_prefer() {
  slot=$1
  params=$2
  src=$3
  dest=$4
  header=$(mktemp)
  block_a=$(mktemp)
  block_b=$(mktemp)
  current=""
  : > "$header"
  : > "$block_a"
  : > "$block_b"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      /slot-a) current=a ;;
      /slot-b) current=b ;;
    esac
    if [ -z "$current" ]; then
      printf '%s\n' "$line" >> "$header"
      continue
    fi
    if [ "$current" = a ]; then
      out=$block_a
    else
      out=$block_b
    fi
    case "$line" in
      *cmdline:*)
        if [ -n "$params" ] && [ "$current" = "$slot" ]; then
          printf '    cmdline: %s\n' "$params" >> "$out"
        else
          printf '%s\n' "$line" >> "$out"
        fi
        ;;
      *)
        printf '%s\n' "$line" >> "$out"
        ;;
    esac
  done < "$src"
  if [ "$slot" = b ]; then
    cat "$header" "$block_b" "$block_a" > "$dest"
  else
    cat "$header" "$block_a" "$block_b" > "$dest"
  fi
  rm -f "$header" "$block_a" "$block_b"
}

require_slot_entries() {
  if [ -f "${boot}/extlinux.conf" ] && ! grep -q '^LABEL slot-b$' "${boot}/extlinux.conf"; then
    echo "janus-boot-install: extlinux has no slot-b entry. Flash an image built with janus.storage.slots.enable." >&2
    exit 1
  fi
  if [ -f "${boot}/limine.conf" ] && ! grep -q '^/slot-b$' "${boot}/limine.conf"; then
    echo "janus-boot-install: limine has no slot-b entry. Flash an image built with janus.storage.slots.enable." >&2
    exit 1
  fi
}

install_slot() {
  closure=$1
  slot=$2
  case "$slot" in
    a | b) ;;
    *)
      echo "janus-boot-install: slot must be a or b" >&2
      exit 2
      ;;
  esac
  store=${JANUS_SLOT_STORE:-}
  if [ -z "$store" ]; then
    echo "janus-boot-install: JANUS_SLOT_STORE is not set" >&2
    exit 1
  fi
  rel=${closure#/nix}
  src="${store}${rel}"
  if [ ! -e "${src}/kernel" ] || [ ! -e "${src}/initrd" ] || [ ! -f "${src}/kernel-params" ]; then
    echo "janus-boot-install: ${closure} is not in the slot store" >&2
    exit 1
  fi
  require_slot_entries
  remount_boot
  mkdir -p "$state"
  if [ -f "${boot}/slot" ]; then
    cp -a "${boot}/slot" "${state}/slot-previous"
  else
    printf 'a\n' > "${state}/slot-previous"
  fi
  params=$(tr '\n' ' ' < "${src}/kernel-params")
  params=${params%" "}
  params="${params} init=${closure}/init janus.slot=${slot}"
  if [ "$slot" = b ]; then
    cp -L "${src}/kernel" "${boot}/vmlinuz-b"
    cp -L "${src}/initrd" "${boot}/initrd-b"
    kern=vmlinuz-b
  else
    cp -L "${src}/kernel" "${boot}/vmlinuz"
    cp -L "${src}/initrd" "${boot}/initrd"
    kern=vmlinuz
  fi
  printf '%s\n' "$params" > "${boot}/cmdline-${slot}.txt"
  printf '%s\n' "$params" > "${boot}/cmdline.txt"
  if [ -f "${boot}/extlinux.conf" ]; then
    rewrite_extlinux "$slot" "$params" "${boot}/extlinux.conf" "${boot}/extlinux.conf.new"
    mv "${boot}/extlinux.conf.new" "${boot}/extlinux.conf"
  fi
  if [ -f "${boot}/extlinux/extlinux.conf" ]; then
    rewrite_extlinux "$slot" "$params" "${boot}/extlinux/extlinux.conf" "${boot}/extlinux/extlinux.conf.new"
    mv "${boot}/extlinux/extlinux.conf.new" "${boot}/extlinux/extlinux.conf"
  fi
  if [ -f "${boot}/limine.conf" ]; then
    limine_prefer "$slot" "$params" "${boot}/limine.conf" "${boot}/limine.conf.new"
    mv "${boot}/limine.conf.new" "${boot}/limine.conf"
  fi
  if [ -f "${boot}/config.txt" ]; then
    sed -i "s/^kernel=.*/kernel=${kern}/" "${boot}/config.txt"
  fi
  printf '%s\n' "$slot" > "${boot}/slot"
  sync || true
}

restore_slot() {
  if [ ! -f "${state}/slot-previous" ]; then
    return 0
  fi
  slot=$(tr -d '[:space:]' < "${state}/slot-previous")
  case "$slot" in
    a | b) ;;
    *) return 0 ;;
  esac
  remount_boot
  if [ -f "${boot}/cmdline-${slot}.txt" ]; then
    cp -a "${boot}/cmdline-${slot}.txt" "${boot}/cmdline.txt"
  fi
  if [ "$slot" = b ]; then
    kern=vmlinuz-b
  else
    kern=vmlinuz
  fi
  if [ -f "${boot}/extlinux.conf" ]; then
    sed -i "s/^DEFAULT .*/DEFAULT slot-${slot}/" "${boot}/extlinux.conf"
  fi
  if [ -f "${boot}/extlinux/extlinux.conf" ]; then
    sed -i "s/^DEFAULT .*/DEFAULT slot-${slot}/" "${boot}/extlinux/extlinux.conf"
  fi
  if [ -f "${boot}/limine.conf" ]; then
    limine_prefer "$slot" "" "${boot}/limine.conf" "${boot}/limine.conf.new"
    mv "${boot}/limine.conf.new" "${boot}/limine.conf"
  fi
  if [ -f "${boot}/config.txt" ]; then
    sed -i "s/^kernel=.*/kernel=${kern}/" "${boot}/config.txt"
  fi
  printf '%s\n' "$slot" > "${boot}/slot"
  sync || true
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
  install-slot)
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "janus-boot-install install-slot <closure> <a|b>" >&2
      exit 2
    fi
    install_slot "$2" "$3"
    ;;
  restore-slot) restore_slot ;;
  *)
    echo "janus-boot-install install <closure> | restore | install-slot <closure> <a|b> | restore-slot" >&2
    exit 2
    ;;
esac
