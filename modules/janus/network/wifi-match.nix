# SPDX-License-Identifier: Apache-2.0
# Rename one USB Wi-Fi netdev. docs/10 §4.4, D-0071.
{lib}: rec {
  vendor = id: builtins.substring 0 4 id;
  product = id: builtins.substring 5 4 id;
  # KERNEL=="wlan*" leaves a virtual interface that already has its name.
  # KERNELS is the USB port. ATTR{address} is the stick.
  renameRule = {
    id,
    name,
    usbPath ? null,
    mac ? null,
  }: let
    port =
      if usbPath == null
      then ""
      else '', KERNELS=="${usbPath}"'';
    addr =
      if mac == null
      then ""
      else '', ATTR{address}=="${lib.toLower mac}"'';
  in ''
    SUBSYSTEM=="net", ACTION=="add", KERNEL=="wlan*", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}"${port}${addr}, NAME="${name}"
  '';
}
