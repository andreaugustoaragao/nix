{
  hostName,
  inputs,
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  packageLib = unstable-pkgs.lib // {
    maintainers = unstable-pkgs.lib.maintainers // {
      Shangshui0302 = {
        email = "2633740366@qq.com";
        github = "Shangshui0302";
        githubId = 149566800;
        name = "Li Shangshui";
      };
    };
  };
  strataBase =
    unstable-pkgs.callPackage (inputs.strata-package-src + "/pkgs/by-name/st/strata/package.nix")
      {
        lib = packageLib;
      };
  strata = strataBase.overrideAttrs (old: {
    src = inputs.strata-src;
    cargoDeps = unstable-pkgs.rustPlatform.importCargoLock {
      lockFile = inputs.strata-src + "/Cargo.lock";
    };
    # Parallels exposes virgl but no working Vulkan device. GTK otherwise
    # probes RADV repeatedly before falling back to OpenGL.
    preFixup = (old.preFixup or "") + ''
      gappsWrapperArgs+=(--set GSK_RENDERER gl)
    '';
  });
  strataWithGvfs = unstable-pkgs.symlinkJoin {
    name = "strata-${strata.version}-with-gvfs";
    paths = [ strata ];
    nativeBuildInputs = [ unstable-pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/strata" \
        --prefix GIO_EXTRA_MODULES : "${pkgs.gvfs}/lib/gio/modules"

      desktopEntry="$out/share/applications/io.github.lgse.Strata.desktop"
      rm "$desktopEntry"
      install -Dm644 \
        "${strata}/share/applications/io.github.lgse.Strata.desktop" \
        "$desktopEntry"
      substituteInPlace "$desktopEntry" \
        --replace-fail "${strata}/bin/strata" "$out/bin/strata"
    '';
    inherit (strata) meta;
  };
in
lib.mkIf (hostName == "prl-dev-vm") {
  home.packages = [ strataWithGvfs ];

  # Keep "Show in folder" consistent with the inode/directory MIME default.
  # A per-user registration takes precedence over Thunar's packaged service.
  xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
    [D-BUS Service]
    Name=org.freedesktop.FileManager1
    Exec=${strataWithGvfs}/bin/strata --gapplication-service
  '';
}
