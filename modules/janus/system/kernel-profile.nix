# SPDX-License-Identifier: Apache-2.0
# janus.system.kernelProfile. docs/08 §1, D-0051.
# standard is the NixOS kernel. compact is one config for every board.
# matched is not a value (D-0052).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types mkIf mkForce;
  cfg = config.janus.system;
  off = lib.kernel.option lib.kernel.no;
  # common-config sets these to y or m. mkForce replaces that.
  # deny is a required n: a later select that turns the symbol back on
  # fails the kernel config. forceOff stays optional for children that
  # disappear once the parent is n; a required answer there is unused.
  deny = names: lib.genAttrs names (_: mkForce lib.kernel.no);
  forceOff = names: lib.genAttrs names (_: mkForce off);
  clear = names: lib.genAttrs names (_: mkForce lib.kernel.unset);
  x86 = pkgs.stdenv.hostPlatform.isx86;
  x86_64 = pkgs.stdenv.hostPlatform.isx86_64;

  # Desktop and 3D GPUs, server BMCs, and compute accelerators.
  # DRM itself stays, and so do simpledrm, virtio, bochs, Rockchip and
  # Meson scanout, panel and bridge drivers, and the small SPI panels.
  # VC4 is not here. It depends on SND, and compact turns SOUND off.
  gpu =
    [
      "DRM_AMDGPU"
      "DRM_RADEON"
      "DRM_NOUVEAU"
      "DRM_XE"
      "DRM_MSM"
      "DRM_V3D"
      "DRM_ETNAVIV"
      "DRM_LIMA"
      "DRM_PANFROST"
      "DRM_PANTHOR"
      "DRM_POWERVR"
      "DRM_TYR"
      "DRM_AST"
      "DRM_MGAG200"
      "DRM_QXL"
      "DRM_VBOXVIDEO"
      "DRM_XEN_FRONTEND"
      "DRM_ASPEED_GFX"
      "DRM_LOONGSON"
      "DRM_KMB_DISPLAY"
      "DRM_ADP"
      "DRM_ACCEL"
      "DRM_ACCEL_AMDXDNA"
      "DRM_ACCEL_HABANALABS"
      "DRM_ACCEL_IVPU"
      "DRM_ACCEL_QAIC"
      "DRM_ACCEL_ROCKET"
    ]
    ++ lib.optionals x86 [
      "DRM_I915"
      "DRM_GMA500"
      "DRM_GMA600"
      "DRM_GMA3600"
      "DRM_VMWGFX"
      "AGP"
      "VGA_SWITCHEROO"
    ]
    ++ lib.optionals x86_64 [
      "DRM_I915_GVT"
      "DRM_I915_GVT_KVMGT"
    ]
    ++ lib.optionals (x86 || pkgs.stdenv.hostPlatform.isAarch64) [
      "DRM_HYPERV"
    ];

  # Children common-config turns on inside the GPU trees above.
  gpuForced =
    [
      "DRM_AMDGPU_SI"
      "DRM_AMDGPU_CIK"
      "DRM_AMDGPU_USERPTR"
      "DRM_AMD_DC_DCN"
      "DRM_AMD_DC_FP"
      "DRM_AMD_DC_HDCP"
      "DRM_AMD_DC_SI"
      "DRM_AMD_ACP"
      "DRM_AMD_SECURE_DISPLAY"
      "DRM_AMD_ISP"
      "DRM_NOUVEAU_GSP_DEFAULT"
      "DRM_NOUVEAU_SVM"
      "DRM_DP_CEC"
      "DRM_DISPLAY_DP_AUX_CEC"
      # No prompt. Nouveau and amdgpu select it; with those off it is not asked.
      "HMM_MIRROR"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.is64bit [
      "HSA_AMD"
      "HSA_AMD_P2P"
    ]
    ++ lib.optionals x86 [
      "DRM_AMD_DC_DCN3_0"
      "DRM_VMWGFX_FBCON"
    ];

  # ALSA, SoC audio, and the Intel SOF machines. hwmon, which backs the
  # INA219, stays.
  sound =
    [
      "SND_DYNAMIC_MINORS"
      "SND_AC97_POWER_SAVE"
      "SND_HDA_INPUT_BEEP"
      "SND_HDA_RECONFIG"
      "SND_HDA_PATCH_LOADER"
      "SND_HDA_CODEC_CS8409"
      "SND_OSSEMUL"
      "SND_USB_CAIAQ_INPUT"
      "SND_USB_AUDIO_MIDI_V2"
    ]
    ++ lib.optionals x86_64 [
      "SND_SOC_INTEL_SOUNDWIRE_SOF_MACH"
      "SND_SOC_INTEL_USER_FRIENDLY_LONG_NAMES"
      "SND_SOC_SOF_INTEL_SOUNDWIRE_LINK"
      "SND_SOC_SOF_TOPLEVEL"
      "SND_SOC_SOF_ACPI"
      "SND_SOC_SOF_PCI"
      "SND_SOC_SOF_APOLLOLAKE"
      "SND_SOC_SOF_APOLLOLAKE_SUPPORT"
      "SND_SOC_SOF_CANNONLAKE"
      "SND_SOC_SOF_CANNONLAKE_SUPPORT"
      "SND_SOC_SOF_COFFEELAKE"
      "SND_SOC_SOF_COFFEELAKE_SUPPORT"
      "SND_SOC_SOF_COMETLAKE"
      "SND_SOC_SOF_COMETLAKE_LP_SUPPORT"
      "SND_SOC_SOF_ELKHARTLAKE"
      "SND_SOC_SOF_ELKHARTLAKE_SUPPORT"
      "SND_SOC_SOF_GEMINILAKE"
      "SND_SOC_SOF_GEMINILAKE_SUPPORT"
      "SND_SOC_SOF_HDA_AUDIO_CODEC"
      "SND_SOC_SOF_HDA_LINK"
      "SND_SOC_SOF_ICELAKE"
      "SND_SOC_SOF_ICELAKE_SUPPORT"
      "SND_SOC_SOF_INTEL_TOPLEVEL"
      "SND_SOC_SOF_JASPERLAKE"
      "SND_SOC_SOF_JASPERLAKE_SUPPORT"
      "SND_SOC_SOF_MERRIFIELD"
      "SND_SOC_SOF_MERRIFIELD_SUPPORT"
      "SND_SOC_SOF_TIGERLAKE"
      "SND_SOC_SOF_TIGERLAKE_SUPPORT"
    ];

  # Cameras, TV tuners, and the infrared and HDMI-CEC remote path.
  # Staging Wi-Fi and the small panel drivers stay.
  media = [
    "MEDIA_DIGITAL_TV_SUPPORT"
    "MEDIA_CAMERA_SUPPORT"
    "MEDIA_CONTROLLER"
    "MEDIA_PCI_SUPPORT"
    "MEDIA_USB_SUPPORT"
    "MEDIA_ANALOG_TV_SUPPORT"
    "VIDEO_STK1160_COMMON"
    "DVB_DYNAMIC_MINORS"
    "MEDIA_ATTACH"
    "STAGING_MEDIA"
    "RC_CORE"
    "RC_DEVICES"
    "RC_DECODERS"
    "LIRC"
    "MEDIA_CEC_RC"
    "MEDIA_CEC_SUPPORT"
    "DRM_VC4_HDMI_CEC"
  ];

  # Fibre Channel, FCoE, iSCSI, SRP, SAS RAID, the SCSI target, and
  # NVMe-oF. AHCI, the NVMe host, USB storage, MMC, and virtio-scsi stay.
  # Legacy parallel SCSI stays; it is not the SAN tree.
  san = [
    "SCSI_FC_ATTRS"
    "SCSI_ISCSI_ATTRS"
    "SCSI_SRP_ATTRS"
    "SCSI_SAS_ATA"
    "ISCSI_TCP"
    "ISCSI_BOOT_SYSFS"
    # ACPI iSCSI boot table selects the sysfs interface.
    "ISCSI_IBFT"
    # PowerVM virtual SCSI selects the SRP transport. These boards are not guests there.
    "SCSI_IBMVSCSI"
    "LIBFC"
    "LIBFCOE"
    "FCOE"
    "FCOE_FNIC"
    "SCSI_BNX2X_FCOE"
    "SCSI_BNX2_ISCSI"
    "BE2ISCSI"
    "SCSI_CXGB3_ISCSI"
    "SCSI_CXGB4_ISCSI"
    "SCSI_QLA_FC"
    "SCSI_QLA_ISCSI"
    "QEDF"
    "QEDI"
    "SCSI_LPFC"
    "SCSI_BFA_FC"
    "SCSI_CHELSIO_FCOE"
    "SCSI_EFCT"
    "SCSI_IBMVFC"
    "ZFCP"
    "NET_FC"
    "FUSION"
    "MEGARAID_NEWGEN"
    "MEGARAID_SAS"
    "SCSI_MPT3SAS"
    "SCSI_MPT2SAS"
    "SCSI_MPI3MR"
    "SCSI_SMARTPQI"
    "SCSI_HPSA"
    "SCSI_AACRAID"
    "SCSI_AIC94XX"
    "AIC94XX_DEBUG"
    "SCSI_ISCI"
    "SCSI_HISI_SAS"
    "SCSI_MVSAS"
    "SCSI_ESAS2R"
    "SCSI_PM8001"
    "SCSI_PMCRAID"
    "SCSI_3W_9XXX"
    "SCSI_3W_SAS"
    "BLK_DEV_3W_XXXX_RAID"
    "SCSI_ARCMSR"
    "SCSI_IPR"
    "SCSI_IPS"
    "SCSI_MYRB"
    "SCSI_MYRS"
    "SCSI_STEX"
    "SCSI_MVUMI"
    "TARGET_CORE"
    "TCM_QLA2XXX"
    "NVME_RDMA"
    "NVME_FC"
    "NVME_TCP"
    "NVME_TCP_TLS"
    "NVME_TARGET"
    "NVME_TARGET_PASSTHRU"
    "NVME_TARGET_AUTH"
    "NVME_TARGET_TCP_TLS"
    "NVME_TARGET_RDMA"
    "NVME_TARGET_FC"
    "NVME_TARGET_TCP"
    "MLX5_CORE_IPOIB"
  ];
in {
  options.janus.system.kernelProfile = mkOption {
    type = types.enum ["standard" "compact"];
    default = "standard";
    description = ''
      Kernel config. standard is the NixOS kernel and keeps the binary
      cache on aarch64 and x86_64. compact is one config for every board.
      It drops sound, desktop and 3D GPUs, compute accelerators, cameras
      and TV, HDMI-CEC and infrared remotes, industrial I/O and Comedi,
      InfiniBand, and SAN. NIC drivers, Wi-Fi, USB, WWAN, Bluetooth, MMC,
      the NVMe host, AHCI, simpledrm, SoC scanout that does not depend
      on ALSA, f2fs, vfat, and virtio stay. Raspberry Pi HDMI depends on
      ALSA and is not in compact. A per-board driver cut is not a value
      of this option (D-0052).
    '';
  };

  # Reading the option here makes a bad value fail in the same pass as
  # the other assertions. The type is what rejects it.
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.kernelProfile == "standard" || cfg.kernelProfile == "compact";
          message = "janus.system.kernelProfile is standard or compact. matched is not a value (D-0052).";
        }
      ];
    }
    (mkIf (cfg.kernelProfile == "compact") {
      boot.kernelPatches = [
        {
          name = "janus-kernel-compact";
          # arm64 defconfig enables HiSilicon SAS and MPT SAS. Those select
          # the SAS transport before its question, and generate-config.pl
          # gets only two passes, so the transport stayed y after the HBAs
          # were turned off. The seed must not select it.
          patch = ./kernel-compact-arm64-defconfig.patch;
          structuredExtraConfig =
            deny [
              # VC4, the Pi HDMI controller, depends on SND. The board
              # consoles are serial. Rockchip and Meson scanout do not.
              "SOUND"
              "IIO"
              "COMEDI"
              "INFINIBAND"
              "MEDIA_SUPPORT"
              "SCSI_SAS_ATTRS"
              "SCSI_SAS_LIBSAS"
            ]
            // forceOff (
              [
                "INFINIBAND_IPOIB"
                "INFINIBAND_IPOIB_CM"
              ]
              ++ gpu
              ++ gpuForced
              ++ sound
              ++ media
              ++ san
            )
            // clear [
              "SND_AC97_POWER_SAVE_DEFAULT"
              "SND_HDA_POWER_SAVE_DEFAULT"
            ];
        }
      ];
    })
  ];
}
