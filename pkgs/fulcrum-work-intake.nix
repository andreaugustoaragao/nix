# Nix package derivation for the external Fulcrum Work Intake CLI service (ADR-0006).
{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  src,
}:
let
  srcRoot = toString src;
  intakeSrc = builtins.path {
    name = "fulcrum-work-intake-src";
    path = src;
    filter =
      path: _type:
      let
        rel = lib.removePrefix "${srcRoot}/" path;
      in
      (rel == "services" || rel == "services/work-intake" || lib.hasPrefix "services/work-intake/" rel)
      && !(lib.hasInfix "__pycache__" rel)
      && !(lib.hasSuffix ".pyc" rel)
      && !(lib.hasPrefix "services/work-intake/fixtures/t004" rel);
  };
in
stdenvNoCC.mkDerivation {
  pname = "fulcrum-work-intake";
  version = "0.2.0";
  src = intakeSrc;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/work-intake"
    cp -a services/work-intake/. "$out/share/work-intake/"
    chmod +x "$out/share/work-intake/intake.py" "$out/share/work-intake/bin/work-intake"
    makeWrapper "${python3}/bin/python3" "$out/bin/work-intake" \
      --add-flags "$out/share/work-intake/intake.py"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/work-intake" --help >/dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "External Fulcrum Work Intake deterministic pipeline CLI";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
