{
  config,
  lib,
  pkgs,
  unstable-pkgs,
  hostName,
  isVm ? false,
  ...
}:

let
  trackerBrowserTrust = pkgs.writeShellApplication {
    name = "tracker-browser-trust";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.nssTools
      pkgs.openssl
    ];
    text = ''
      database=''${1:?Expected NSS database directory}
      certificate=${../../certs/tracker-local-ca.pem}
      nickname=tracker-local-vm-ca
      expected_fingerprint=16666DC0116CEB3FFA0C56B2A4D1D4AFF7378F36938AD44817097C847C9F6EE1
      if [[ "$database" != /* || "$database" == / ]]; then
        echo 'Expected an absolute NSS database directory' >&2
        exit 1
      fi
      fingerprint() {
        openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
      }
      if [[ "$(fingerprint < "$certificate")" != "$expected_fingerprint" ]]; then
        echo 'Tracker CA changed; review the public certificate before updating trust' >&2
        exit 1
      fi
      openssl verify -CAfile "$certificate" "$certificate" >/dev/null
      umask 077
      if [[ ! -d "$database" ]]; then
        install -d -m 700 "$database"
      fi
      if [[ ! -f "$database/cert9.db" ]]; then
        if [[ -e "$database/key4.db" || -e "$database/cert8.db" || -e "$database/key3.db" ]]; then
          echo 'Existing NSS database needs explicit migration; leaving it unchanged' >&2
          exit 1
        fi
        certutil -N --empty-password -d "sql:$database"
      fi
      current_trust=$(certutil -L -d "sql:$database" | awk -v name="$nickname" '$1 == name {print $2}')
      if [[ -n "$current_trust" ]]; then
        current_fingerprint=$(certutil -L -d "sql:$database" -n "$nickname" -a | fingerprint)
        if [[ "$current_fingerprint" != "$expected_fingerprint" ]]; then
          echo 'Managed Tracker NSS nickname contains another certificate; leaving it unchanged' >&2
          exit 1
        fi
        if [[ "$current_trust" == 'C,,' ]]; then
          exit 0
        fi
        certutil -M -d "sql:$database" -n "$nickname" -t 'C,,'
      else
        certutil -A -d "sql:$database" -n "$nickname" -t 'C,,' -i "$certificate"
      fi
      actual_fingerprint=$(certutil -L -d "sql:$database" -n "$nickname" -a | fingerprint)
      actual_trust=$(certutil -L -d "sql:$database" | awk -v name="$nickname" '$1 == name {print $2}')
      if [[ "$actual_fingerprint" != "$expected_fingerprint" || "$actual_trust" != 'C,,' ]]; then
        echo 'Tracker CA trust verification failed' >&2
        exit 1
      fi
    '';
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

  # nixpkgs restructured the brave recipe: make-brave.nix is now a
  # curried function (callPackage's makeOverridable wrapper is consumed
  # by the first argument set), so `pkgs.brave` is a plain derivation
  # with no `.override`. home-manager's chromium module calls
  # `cfg.package.override { commandLineArgs = ...; }` whenever
  # `commandLineArgs != []`, which fails with "attribute 'override'
  # missing". Bake the switches in here instead, appending to the same
  # gappsWrapperArgs the recipe uses (so our flags land after the
  # wrapper's own --enable-features/--disable-features and win the
  # last-value-wins switch map), and leave programs.brave.commandLineArgs
  # empty so home-manager passes the package through untouched.
  # Linux-only module — the Darwin brave build wraps with makeWrapper
  # and has no gappsWrapperArgs, but home/desktop is never imported
  # on mac-work.
  bravePackage = unstable-pkgs.brave.overrideAttrs (old: {
    preFixup = old.preFixup + ''
      gappsWrapperArgs+=(
        --add-flags ${lib.escapeShellArg (builtins.concatStringsSep " " commandLineArgs)}
      )
    '';
  });
in
{
  home.activation.trackerBrowserTrust = lib.mkIf (hostName == "prl-dev-vm") (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Chromium uses the legacy NSS directory when present, otherwise XDG.
      tracker_nss_database=${lib.escapeShellArg "${config.xdg.dataHome}/pki/nssdb"}
      if [ -d ${lib.escapeShellArg "${config.home.homeDirectory}/.pki/nssdb"} ]; then
        tracker_nss_database=${lib.escapeShellArg "${config.home.homeDirectory}/.pki/nssdb"}
      fi
      run ${trackerBrowserTrust}/bin/tracker-browser-trust "$tracker_nss_database"
    ''
  );

  # Brave Browser configuration using unstable version
  programs.brave = {
    enable = true;
    package = bravePackage;
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
