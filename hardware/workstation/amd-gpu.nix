# AMD RX 7900 GRE GPU Configuration for Workstation
{
  config,
  pkgs,
  lib,
  owner,
  ...
}: {
  # AMD GPU kernel and boot configuration
  boot = {
    initrd.kernelModules = ["amdgpu"];
    kernelParams = [
      # Enable all AMD GPU power features for RDNA3
      "amdgpu.ppfeaturemask=0xffffffff"
    ];
  };

  # Graphics drivers
  services.xserver.videoDrivers = ["amdgpu"];

  # Enhanced hardware acceleration for RX 7900 GRE
  hardware.graphics = {
    enable = lib.mkForce true;
    enable32Bit = lib.mkForce true;
    extraPackages = with pkgs; [
      # Video acceleration
      libvdpau-va-gl # VDPAU to VA-API translation
      vaapiVdpau # VA-API VDPAU driver

      # ROCm and OpenCL for compute workloads
      rocmPackages.clr.icd # OpenCL support
      rocmPackages.rocminfo # ROCm system info
      rocmPackages.rocm-smi # System management interface
    ];
    extraPackages32 = with pkgs.driversi686Linux; [
      libvdpau-va-gl
      #vaapiVdpau
    ];
  };

  # ROCm HIP library symbolic link
  systemd.tmpfiles.rules = [
    "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}"
  ];

  # Environment variables for RDNA3 optimization
  environment = {
    variables = {
      # ROCm support
      ROC_ENABLE_PRE_VEGA = "1";
      # RDNA3 compatibility for AI/ML workloads
      HSA_OVERRIDE_GFX_VERSION = "11.0.0";
      # Prefer Mesa RADV Vulkan driver (better performance than AMDVLK)
      AMD_VULKAN_ICD = "RADV";
    };

    systemPackages = with pkgs; [
      # GPU monitoring and control
      lact # Linux AMD Control Tool - modern GPU control
      radeontop # GPU activity monitor
      amdgpu_top # Tool to display AMDGPU usage

      # Graphics and compute verification tools
      clinfo # OpenCL information utility
      vulkan-tools # vulkaninfo, vkcube for Vulkan testing
      mesa-demos # glxinfo, glxgears for OpenGL testing

      # Video tools with GPU acceleration
      ffmpeg-full # Full FFmpeg build with hardware acceleration

      # ROCm utilities for workstation compute tasks
      rocmPackages.rocm-smi # GPU monitoring CLI
      rocmPackages.rocminfo # ROCm platform info
    ];
  };

  # GPU control service for fan curves, overclocking, etc.
  #services.lact.enable = true;

  # Device permissions for GPU access
  services.udev.extraRules = ''
    # DRM devices for graphics
    SUBSYSTEM=="drm", GROUP="video", MODE="0664"
    # ROCm/OpenCL devices for compute workloads
    SUBSYSTEM=="kfd", KERNEL=="kfd", TAG+="uaccess", GROUP="video"
  '';

  # Add user to video group for GPU access
  users.users.${owner.name}.extraGroups = ["video"];
}
