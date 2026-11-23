# Nix package derivation for the Fulcrum Bun web application:
#   - Stages runtime source (src/, web/, config/, scripts/, package.json, docs/README.md)
#   - Links production node_modules from fulcrum-node-modules (cached across releases)
#   - Builds minified web assets via `bun scripts/build-web.ts`
#   - Emits release.json bound to the pinned flake input revision
#   - Verifies packaged release.json and built web artifact manifest in installCheckPhase
{
  lib,
  stdenvNoCC,
  callPackage,
  jq,
  src,
  sourceRevision,
  fulcrumNodeModules ? callPackage ./fulcrum-node-modules.nix { inherit src; },
  fulcrumBun ? callPackage ./fulcrum-bun.nix { },
}:
let
  pkg = builtins.fromJSON (builtins.readFile "${src}/package.json");
  packageVersion = pkg.version;
  srcRoot = toString src;
  appSrc = builtins.path {
    name = "fulcrum-app-src";
    path = src;
    filter =
      path: _type:
      let
        rel = lib.removePrefix "${srcRoot}/" path;
      in
      rel == "package.json"
      || rel == "bun.lock"
      || rel == "src"
      || lib.hasPrefix "src/" rel
      || rel == "web"
      || lib.hasPrefix "web/" rel
      || rel == "config"
      || lib.hasPrefix "config/" rel
      || rel == "scripts"
      || lib.hasPrefix "scripts/" rel
      || rel == "docs"
      || rel == "docs/README.md";
  };
  releaseManifest = builtins.toJSON {
    inherit packageVersion;
    source = {
      kind = "artifact";
      revision = sourceRevision;
    };
  };
in
assert builtins.match "[a-f0-9]{40}" sourceRevision != null;
assert (pkg.packageManager or null) == "bun@${fulcrumBun.version}";
stdenvNoCC.mkDerivation {
  pname = "fulcrum-app";
  version = packageVersion;
  src = appSrc;
  strictDeps = true;

  nativeBuildInputs = [
    fulcrumBun
    jq
  ];

  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    ln -s "${fulcrumNodeModules}/node_modules" node_modules
    bun scripts/build-web.ts
    rm node_modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/vault-services"
    cp -a . "$out/share/vault-services/"
    chmod -R u+w "$out/share/vault-services"
    ln -s "${fulcrumNodeModules}/node_modules" "$out/share/vault-services/node_modules"
    printf '%s\n' ${lib.escapeShellArg releaseManifest} > "$out/share/vault-services/release.json"
    ln -s "${fulcrumBun}/bin/bun" "$out/bin/bun"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -s "$out/share/vault-services/src/index.ts"
    test -f "$out/share/vault-services/scripts/automation-runner-bootstrap.ts"
    jq -e --arg version ${lib.escapeShellArg packageVersion} \
      --arg revision ${lib.escapeShellArg sourceRevision} '
        type == "object" and (keys == ["packageVersion", "source"])
        and .packageVersion == $version
        and (.source | type == "object"
          and (keys == ["kind", "revision"])
          and .kind == "artifact" and .revision == $revision)
      ' "$out/share/vault-services/release.json" >/dev/null
    FULCRUM_PACKAGE_ROOT="$out/share/vault-services" "$out/bin/bun" --no-env-file --eval '
      const root = process.env.FULCRUM_PACKAGE_ROOT;
      const pkg = await Bun.file(root + "/package.json").json();
      const release = await Bun.file(root + "/release.json").json();
      if (pkg.version !== release.packageVersion) throw new Error("Application package version differs from its release manifest");
      const { snapshotWebArtifact } = await import(root + "/scripts/web-artifact.ts");
      const artifact = await snapshotWebArtifact(root);
      if (!artifact.files.length) throw new Error("Packaged application has no web assets");
      console.log("Verified packaged Fulcrum app " + pkg.version + ": " + artifact.files.length + " web assets");
    '
    runHook postInstallCheck
  '';

  passthru = {
    inherit sourceRevision packageVersion;
    nodeModules = fulcrumNodeModules;
  };

  meta = {
    description = "Fulcrum web application built directly from pinned source and cached production node_modules";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
