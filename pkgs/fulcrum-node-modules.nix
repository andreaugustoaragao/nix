# Two-stage production node_modules package for Fulcrum:
#   1. Fixed-Output Derivation (depsFod): runs `bun install --production --frozen-lockfile`,
#      verifies installed production dependencies and maintained patches, and strips
#      caches. Keyed only on package.json dependency/patch fields (without `version`
#      or `scripts`), bun.lock, and patches/ so normal Fulcrum code/version releases
#      hit the Nix store cache in 0s.
#   2. Normal derivation: prunes foreign-architecture and musl ELFs and runs
#      autoPatchelfHook on the retained glibc native addons.
{
  lib,
  stdenv,
  writeText,
  callPackage,
  autoPatchelfHook,
  cacert,
  python3,
  binutils,
  openssl,
  zlib,
  libxcb,
  src,
  fulcrumBun ? callPackage ./fulcrum-bun.nix { },
  fodHashes ? builtins.fromJSON (builtins.readFile ./fulcrum-node-modules-hash.json),
}:
let
  pkg = builtins.fromJSON (builtins.readFile "${src}/package.json");
  # Omit `version` and `scripts` so routine releases do not invalidate the FOD.
  depsManifest = writeText "fulcrum-deps-package.json" (
    builtins.toJSON (
      builtins.removeAttrs pkg [
        "version"
        "scripts"
      ]
    )
  );
  srcRoot = toString src;
  depsSrc = builtins.path {
    name = "fulcrum-deps-src";
    path = src;
    filter =
      path: _type:
      let
        rel = lib.removePrefix "${srcRoot}/" path;
      in
      rel == "bun.lock"
      || rel == "patches"
      || lib.hasPrefix "patches/" rel
      || rel == "scripts"
      || rel == "scripts/verify-installed-dependencies.ts"
      || rel == "scripts/verify-installed-patches.ts";
  };
  elfMachine =
    {
      x86_64-linux = 62;
      aarch64-linux = 183;
    }
    .${stdenv.hostPlatform.system} or null;
  outputHash =
    fodHashes.${stdenv.hostPlatform.system}
      or (throw "Unsupported system for fulcrum-node-modules: ${stdenv.hostPlatform.system}");

  depsFod = stdenv.mkDerivation {
    pname = "fulcrum-node-modules-fod";
    version = "1";
    src = depsSrc;

    nativeBuildInputs = [
      fulcrumBun
      cacert
    ];

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    inherit outputHash;

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      cp ${depsManifest} package.json
      export HOME="$TMPDIR/home"
      export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"

      bun install --production --frozen-lockfile --no-progress
      bun --no-env-file scripts/verify-installed-dependencies.ts --production

      # Verify every maintained patch installed in production node_modules.
      bun --no-env-file --eval '
        import { existsSync, readFileSync } from "node:fs";
        import { join } from "node:path";
        import { patchHunks, verifyHunks } from "./scripts/verify-installed-patches.ts";
        const manifest = JSON.parse(readFileSync("package.json", "utf8"));
        let checked = 0;
        for (const [spec, patchPath] of Object.entries(manifest.patchedDependencies ?? {})) {
          const sep = spec.lastIndexOf("@");
          const name = spec.slice(0, sep), version = spec.slice(sep + 1);
          const pkgRoot = join("node_modules", name);
          if (!existsSync(join(pkgRoot, "package.json"))) {
            if (Object.hasOwn(manifest.dependencies ?? {}, name)) {
              throw new Error("Missing required production patched package: " + spec);
            }
            continue;
          }
          const meta = JSON.parse(readFileSync(join(pkgRoot, "package.json"), "utf8"));
          if (meta.name !== name || meta.version !== version) {
            throw new Error("Installed patch version mismatch: " + spec);
          }
          verifyHunks(patchHunks(readFileSync(String(patchPath), "utf8")), f => readFileSync(join(pkgRoot, f), "utf8"));
          checked++;
        }
        if (!checked) throw new Error("No production patches verified");
        console.log("Verified production patches: " + checked);
      '

      rm -rf node_modules/.cache
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a node_modules "$out/node_modules"
      runHook postInstall
    '';
  };
in
assert stdenv.hostPlatform.isLinux;
assert elfMachine != null;
stdenv.mkDerivation {
  pname = "fulcrum-node-modules";
  version = "1";
  dontUnpack = true;
  strictDeps = true;

  nativeBuildInputs = [
    autoPatchelfHook
    python3
    binutils
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    zlib
    libxcb
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a "${depsFod}/node_modules" "$out/node_modules"
    chmod -R u+w "$out/node_modules"

    # Remove foreign-architecture or musl ELF objects before autoPatchelf checks
    # the retained glibc native addon closure.
    python3 - "$out/node_modules" ${toString elfMachine} <<'PY'
    import pathlib, struct, subprocess, sys

    root = pathlib.Path(sys.argv[1])
    target = int(sys.argv[2])
    retained = 0
    pruned = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as source:
            header = source.read(20)
        if len(header) < 20 or header[:4] != b"\x7fELF":
            continue
        if header[5] not in (1, 2):
            raise SystemExit(f"Unsupported ELF byte order: {path}")
        machine = struct.unpack(("<" if header[5] == 1 else ">") + "H", header[18:20])[0]
        if machine != target:
            path.unlink()
            pruned += 1
            continue
        dynamic = subprocess.run(["readelf", "-d", str(path)], capture_output=True, check=True).stdout
        program = subprocess.run(["readelf", "-l", str(path)], capture_output=True, check=True).stdout
        if (b"libc.musl-" in dynamic or b"Shared library: [libc.so]" in dynamic
                or b"ld-musl-" in program or any("musl" in part for part in path.parts)):
            path.unlink()
            pruned += 1
        else:
            retained += 1
    print(f"fulcrum-node-modules ELF selection: retained={retained} pruned={pruned}")
    PY
    runHook postInstall
  '';

  passthru = {
    inherit depsFod;
  };

  meta = {
    description = "Production node_modules closure for Fulcrum";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
