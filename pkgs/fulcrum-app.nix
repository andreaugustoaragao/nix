# Nix package derivation for the Fulcrum v2 Bun + React/@ui-sdk/react application:
#   - Stages Fulcrum v2 server, importer, React/@ui-sdk/react web SPA, config, scripts, docs/README.md
#   - Links cached production node_modules (fulcrum-node-modules) for server runtime
#   - Builds React SPA (v2/web/dist) offline via cached fulcrum-v2-web-node-modules
#   - Emits release.json bound to the pinned flake input revision
#   - Verifies release.json, v2/server/src/main.ts, and built v2/web/dist assets in installCheckPhase
{
  lib,
  stdenvNoCC,
  callPackage,
  jq,
  src,
  sourceRevision,
  fulcrumNodeModules ? callPackage ./fulcrum-node-modules.nix { inherit src; },
  fulcrumV2WebNodeModules ? callPackage ./fulcrum-v2-web-node-modules.nix { inherit src; },
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
      (
        rel == "package.json"
        || rel == "bun.lock"
        || rel == "v2"
        || lib.hasPrefix "v2/" rel
        || rel == "config"
        || lib.hasPrefix "config/" rel
        || rel == "scripts"
        || rel == "scripts/verify-live-v2.ts"
        || rel == "docs"
        || rel == "docs/README.md"
      )
      && !(lib.hasPrefix "v2/web/node_modules" rel)
      && !(lib.hasPrefix "v2/web/dist" rel);
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

  buildPhase = ''
    runHook preBuild
    ln -s "${fulcrumV2WebNodeModules}/node_modules" v2/web/node_modules
    (cd v2/web && bun node_modules/vite/bin/vite.js build)
    rm v2/web/node_modules
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
    test -s "$out/share/vault-services/v2/server/src/main.ts"
    test -s "$out/share/vault-services/v2/importer/src/cli.ts"
    test -s "$out/share/vault-services/v2/web/dist/index.html"
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
      const { resolveReleaseIdentity } = await import(root + "/v2/server/src/http/version.ts");
      const id = resolveReleaseIdentity({ packageRoot: root, webDistDir: root + "/v2/web/dist" });
      if (id.version !== ${builtins.toJSON packageVersion}) throw new Error("version mismatch: " + id.version);
      if (id.revision !== ${builtins.toJSON sourceRevision}) throw new Error("revision mismatch: " + id.revision);
      if (!id.webAssetsSha256 || id.webAssetCount < 2) throw new Error("missing built v2 web assets");
      console.log("Verified packaged Fulcrum v2 " + id.version + " (" + id.revision.slice(0, 8) + "): " + id.webAssetCount + " web assets, sha256=" + id.webAssetsSha256);
    '
    runHook postInstallCheck
  '';

  passthru = {
    inherit sourceRevision packageVersion;
    nodeModules = fulcrumNodeModules;
    webNodeModules = fulcrumV2WebNodeModules;
  };

  meta = {
    description = "Fulcrum v2 application (idiomatic pi-durable + React/@ui-sdk/react) built from pinned source";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
