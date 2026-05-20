{
  pkgs,
  lib,
  inputs,
  isVm ? false,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # IMPORTANT: Chromium's command-line parser stores switches in a map
  # keyed by switch name, so passing --enable-features= (or
  # --disable-features=) multiple times silently drops all but the
  # last value. The nixpkgs brave wrapper already prepends two
  # --enable-features= switches (AcceleratedVideoDecodeLinuxGL +
  # AcceleratedVideoEncoder + WaylandWindowDecorations, then
  # UseOzonePlatform) and one --disable-features= (OutdatedBuildDetector
  # + UseChromeOSDirectVideoDecoder). Anything we add here overrides
  # them — so consolidate everything we want into a single
  # --enable-features and a single --disable-features below.
  #
  # Per-host gating via isVm: the prl-dev-vm has virgl, which exposes
  # OpenGL 4.0 but no Vulkan ICD and only VAProfileNone:VideoProc
  # via the gallium VAAPI shim (i.e. no hardware decode profiles).
  # The workstation (AMD RX 7900 XT, Mesa RADV) and hp-laptop (Intel
  # iGPU, ANV + iHD) both expose real Vulkan and real VAAPI VLD
  # profiles, so they get the extra acceleration features.
  enableFeaturesCommon = [
    "UseOzonePlatform"
    "AcceleratedVideoDecodeLinuxGL"
    "AcceleratedVideoEncoder"
    "WaylandWindowDecorations"
  ];
  enableFeaturesBareMetal = [
    # Without these, Brave on AMD/Intel falls back to the GL decode
    # path (which works but isn't UVD/VCN/QuickSync). Adding them is
    # pure win on bare metal. On the VM they're harmless because
    # VAAPI exposes no VLD profiles for Brave to use.
    "VaapiVideoDecoder"
    "VaapiVideoEncoder"
  ];

  disableFeaturesCommon = [
    "BraveRewards"
    "OutdatedBuildDetector"
    "UseChromeOSDirectVideoDecoder"
  ];
  disableFeaturesVm = [
    # virgl exposes no Vulkan ICD on the VM. Without this, every
    # launch spends time trying to load libvulkan.so.1, falling back
    # to GL, and logging three errors to brave://gpu. WebGPU's Vulkan
    # path was already landing on SwiftShader (CPU) and getting
    # blocklisted, so nothing of value is lost. Do NOT add Vulkan
    # here on bare metal — it kills Skia Graphite and real WebGPU.
    "Vulkan"
  ];

  enableFeatures = enableFeaturesCommon ++ lib.optionals (!isVm) enableFeaturesBareMetal;
  disableFeatures = disableFeaturesCommon ++ lib.optionals isVm disableFeaturesVm;
  commaJoin = builtins.concatStringsSep ",";
in
{
  # Brave Browser configuration using unstable version
  programs.brave = {
    enable = true;
    package = pkgs-unstable.brave;
    commandLineArgs = [
      "--enable-features=${commaJoin enableFeatures}"
      "--disable-features=${commaJoin disableFeatures}"
      "--ozone-platform=wayland"
      "--disable-brave-ads"
      "--disable-background-mode"
      "--password-store=gnome-libsecret"
      # Out-of-process canvas rasterization. Default-on in modern
      # Chromium but worth being explicit; cuts main-thread paint cost
      # for sites heavy on 2D canvas (YouTube thumbnails, Meet's tile
      # compositor).
      "--enable-oop-rasterization"
      # Zero-copy texture upload. Safe on virgl (guest GBM handles
      # dmabuf import) and on bare metal (native dmabuf support).
      "--enable-zero-copy"
    ]
    ++ lib.optionals isVm [
      # virgl sometimes lands on Chromium's driver-bug blocklist
      # depending on the Mesa version advertised to the renderer.
      # Force features on regardless — safe because the only "GPU"
      # in this VM is virgl, with no real driver bugs to work around.
      # Do NOT enable on bare metal: the blocklist exists to protect
      # against real AMD/Intel driver bugs that --ignore-gpu-blocklist
      # would re-expose.
      "--ignore-gpu-blocklist"
    ];
    # Soft extension installs: a JSON manifest is dropped into Brave's
    # External Extensions/ dir, so the extension shows up on first
    # profile creation but the user can disable or remove it later.
    # The force-installed daily drivers (Bitwarden, Vimium, Markdown
    # Viewer) live in system/browsers.nix instead — those use the
    # ExtensionSettings policy, which auto-installs them, blocks
    # uninstall, and force-pins their toolbar icon across both
    # profiles.
    extensions = [
      # Claude in Chrome
      {
        id = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
      }
    ];
  };

}
