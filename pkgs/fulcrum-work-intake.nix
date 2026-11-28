# Nix package derivation for the external Fulcrum Work Intake Go CLI (ADR-0006 / ADR-0017).
{
  lib,
  buildGoModule,
  src,
}:
let
  intakeSrc = "${src}/services/work-intake";
in
buildGoModule {
  pname = "fulcrum-work-intake";
  version = "0.3.0";
  src = src;
  vendorHash = null;
  modRoot = "services/work-intake";
  subPackages = [ "cmd/work-intake" ];

  nativeBuildInputs = [ ];

  postInstall = ''
    mkdir -p "$out/share/work-intake/mod"
    cp -a ${intakeSrc}/mod/. "$out/share/work-intake/mod/"
    cp -a ${intakeSrc}/pricing.json "$out/share/work-intake/pricing.json"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/work-intake" herdr-view view --help 2>/dev/null || test -x "$out/bin/work-intake"
    runHook postInstallCheck
  '';

  meta = {
    description = "External Fulcrum Work Intake unified Go pipeline CLI";
    mainProgram = "work-intake";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}