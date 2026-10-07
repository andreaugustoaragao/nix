{
  lib,
  stdenvNoCC,
  writeShellApplication,
  symlinkJoin,
  makeWrapper,
  coreutils,
  gnugrep,
  openssl,
  cacert,
  desktopPackage,
  caCertificate,
  caSha256,
  systemCaBundle ? "${cacert}/etc/ssl/certs/ca-bundle.crt",
}:

let
  publicCa = builtins.path {
    name = "fulcrum-local-ca.pem";
    path = caCertificate;
  };
  preflight = writeShellApplication {
    name = "fulcrum-local-tls-preflight";
    runtimeInputs = [
      coreutils
      gnugrep
      openssl
    ];
    text = builtins.readFile ../home/services/fulcrum-local-tls-preflight.sh;
  };
  caBundle = stdenvNoCC.mkDerivation {
    name = "fulcrum-desktop-local-ca-bundle";
    dontUnpack = true;
    buildPhase = ''
      ${preflight}/bin/fulcrum-local-tls-preflight ca \
        ${lib.escapeShellArg "${publicCa}"} ${lib.escapeShellArg caSha256}
    '';
    installPhase = ''
      cat ${lib.escapeShellArg (toString systemCaBundle)} \
        ${lib.escapeShellArg "${publicCa}"} > "$out"
    '';
  };
in
symlinkJoin {
  name = "${desktopPackage.pname or "fulcrum-desktop"}-local-tls";
  paths = [ desktopPackage ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    # GnuTLS in the pinned Nix closure honors this process-local CA bundle.
    # Do not set global/session SSL variables or modify any system trust store.
    wrapProgram "$out/bin/fulcrum-desktop" --set NIX_SSL_CERT_FILE ${caBundle}
    # The upstream desktop entry uses an absolute store path. Point only this
    # wrapper's copy at the CA-scoped executable, not at the unwrapped package.
    rm "$out/share/applications/org.fulcrum.desktop.desktop"
    substitute ${desktopPackage}/share/applications/org.fulcrum.desktop.desktop \
      "$out/share/applications/org.fulcrum.desktop.desktop" \
      --replace-fail ${desktopPackage}/bin/fulcrum-desktop "$out/bin/fulcrum-desktop"
  '';
  passthru = {
    inherit preflight caBundle publicCa;
  };
  meta = {
    description = "Fulcrum Desktop with its dedicated local CA scoped to this application";
    mainProgram = "fulcrum-desktop";
    platforms = lib.platforms.linux;
  };
}
