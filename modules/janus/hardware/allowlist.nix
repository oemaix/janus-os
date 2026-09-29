# SPDX-License-Identifier: Apache-2.0
# USB and I²C identities from docs/10-hardware-support.md §4.3.
# `modes` is copied from that table. A row with more than one mode does
# not pick one: janus.hardware.peripherals.<name>.wwan.mode = "auto" is
# rejected until the user names a mode.
{
  usb = {
    "0bda:8153" = {class = "nic";};
    "0bda:8156" = {class = "nic";};
    "0b95:1790" = {class = "nic";};
    "0e8d:7612" = {
      class = "wifi";
      capabilities = ["ap" "sta"];
    };
    "0e8d:7961" = {
      class = "wifi";
      capabilities = ["ap" "sta"];
    };
    "0bda:8812" = {
      class = "wifi";
      unsupported = true;
    };
    "0bda:8176" = {
      class = "wifi";
      capabilities = ["ap" "sta"];
    };
    "05c6:90b6" = {
      class = "wwan";
      modes = ["ecm" "ncm" "rndis"];
    };
    "19d1:0001" = {
      class = "wwan";
      modes = ["ecm" "ncm" "rndis"];
    };
    "12d1:14dc" = {
      class = "wwan";
      modes = ["ecm" "rndis"];
    };
    "12d1:1f01" = {
      class = "wwan";
      modes = ["ecm" "rndis"];
    };
    "12d1:1506" = {
      class = "wwan";
      modes = ["ncm"];
    };
    "2c7c:0125" = {
      class = "wwan";
      modes = ["qmi"];
    };
    "2c7c:0512" = {
      class = "wwan";
      modes = ["qmi"];
    };
    "19d2:1405" = {
      class = "wwan";
      modes = ["rndis"];
    };
    "0a12:0001" = {class = "bluetooth";};
  };

  # INA219 profiles. docs/10 §4.5. Address 0x43 stays unarmed.
  i2c = {
    "0x40" = {
      class = "power";
      dischargeSign = "negative";
      armShutdown = true;
    };
    "0x43" = {
      class = "power";
      dischargeSign = null;
      armShutdown = false;
    };
  };
}
