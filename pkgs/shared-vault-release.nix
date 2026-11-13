{
  lib,
  stdenv,
  fetchurl,
  requireFile,
  jq,
  python3,
  binutils,
  autoPatchelfHook,
  openssl,
  zlib,
  libxcb,
  url,
  hash,
  packageVersion,
  sourceRevision,
}:
let
  # Match the committed Rust SDK flake.lock. The host's nixpkgs may carry
  # ICU 78.3 from a different derivation, which is not the build provider.
  sdkPkgs =
    import
      (builtins.fetchTree {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
        rev = "4fe25e12eb9f4c744966dd3de5a05246cf098601";
        narHash = "sha256-WrSODdZFVIs/Hh2NzC0bY+ROByi0bATg8WfePX8dPj8=";
      })
      {
        system = stdenv.hostPlatform.system;
        config = { };
        overlays = [ ];
      };
  sdkIcu = sdkPkgs.icu;
  artifact =
    if url == null then
      requireFile {
        inherit hash;
        name = "shared-vault-release.tar.gz";
        message = "Import the retained certified runtime with shared-vault-bootstrap.py --archive PATH --archive-only before building this local release.";
      }
    else
      fetchurl {
        inherit url hash;
        name = "shared-vault-release.tar.gz";
      };
  elfMachine =
    {
      x86_64-linux = 62;
      aarch64-linux = 183;
    }
    .${stdenv.hostPlatform.system} or null;
  onnxArchitecture = if stdenv.hostPlatform.isx86_64 then "x64" else "arm64";
  onnxSha256 =
    if stdenv.hostPlatform.isx86_64 then
      "ffb75a925ba05e47b235bb66e3e3911714a80b328a9c9425539feb204aa32a23"
    else
      "1f549d46250b005580b597f4164984aaf75b3bcb9f3aeb07c7f8a8fe60b23c76";
in
assert builtins.match "[a-f0-9]{40}" sourceRevision != null;
assert stdenv.hostPlatform.isLinux;
assert lib.getVersion sdkIcu == "78.3";
stdenv.mkDerivation {
  pname = "shared-vault-release";
  version = packageVersion;
  src = artifact;
  strictDeps = true;
  nativeBuildInputs = [
    jq
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    python3
    binutils
  ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    sdkPkgs.stdenv.cc.cc.lib
    openssl
    zlib
    libxcb
    sdkIcu
  ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  doInstallCheck = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a ./. "$out/"
    chmod -R u+w "$out"

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      # The certified archive contains every installed dependency. ELF objects
      # for another CPU or musl cannot load on this glibc host; remove only
      # those native files before autoPatchelf checks the retained closure.
      python3 - "$out/share/vault-services/node_modules" "$out/bin/bun" ${toString elfMachine} <<'PY'
      import filecmp, pathlib, struct, subprocess, sys

      root = pathlib.Path(sys.argv[1])
      bun = pathlib.Path(sys.argv[2])
      target = int(sys.argv[3])
      if not root.is_dir():
          raise SystemExit("Missing installed dependency tree")
      selected = []
      pruned = 0
      for path in root.rglob("*"):
          if not path.is_file():
              continue
          with path.open("rb") as source:
              header = source.read(20)
          if len(header) < 20 or header[:4] != b"\x7fELF":
              continue
          if header[5] not in (1, 2):
              raise SystemExit("Unsupported ELF byte order")
          machine = struct.unpack(("<" if header[5] == 1 else ">") + "H", header[18:20])[0]
          if machine != target:
              if path == root / "bun/bin/bun.exe":
                  raise SystemExit("Pinned Bun cannot run on the target CPU")
              path.unlink()
              pruned += 1
              continue
          dynamic = subprocess.run(["readelf", "-d", str(path)], capture_output=True, check=True).stdout
          program = subprocess.run(["readelf", "-l", str(path)], capture_output=True, check=True).stdout
          if (b"libc.musl-" in dynamic or b"Shared library: [libc.so]" in dynamic
                  or b"ld-musl-" in program or any("musl" in part for part in path.parts)):
              if path == root / "bun/bin/bun.exe":
                  raise SystemExit("Pinned Bun uses an incompatible libc")
              path.unlink()
              pruned += 1
          else:
              selected.append(path)
      for path in (bun, root / "bun/bin/bun.exe"):
          if not path.is_file() or path not in selected and path != bun:
              raise SystemExit("Pinned Bun is missing from the selected runtime")
          with path.open("rb") as source:
              header = source.read(20)
          if len(header) < 20 or header[:4] != b"\x7fELF":
              raise SystemExit("Pinned Bun is not an ELF executable")
          machine = struct.unpack(("<" if header[5] == 1 else ">") + "H", header[18:20])[0]
          if machine != target:
              raise SystemExit("Pinned Bun cannot run on the target CPU")
      if not filecmp.cmp(bun, root / "bun/bin/bun.exe", shallow=False):
          raise SystemExit("Pinned Bun differs from the certified dependency copy")
      print("native ELF selection: retained=" + str(len(selected)) + " pruned=" + str(pruned))
      PY
    ''}

    # The archive is fixed-output and must carry its own reviewed identity.
    # Do not synthesize a revision from the Nix checkout or its Git metadata.
    test -z "$(find "$out" -type l -print -quit)"
    for executable in vault-service shared-vault shared-vault-grammar vault-client vault-mcp bun; do
      test -f "$out/bin/$executable" && test -x "$out/bin/$executable"
    done
    patchShebangs --host "$out/bin/vault-service" "$out/bin/vault-client" "$out/bin/vault-mcp"
    test -f "$out/share/vault-services/scripts/automation-runner-bootstrap.ts"
    test -f "$out/share/vault-services/release.json"
    jq -e --arg version ${lib.escapeShellArg packageVersion} \
      --arg revision ${lib.escapeShellArg sourceRevision} '
        type == "object" and (keys == ["packageVersion", "source"])
        and .packageVersion == $version
        and (.source | type == "object"
          and (keys == ["kind", "revision"])
          and .kind == "artifact" and .revision == $revision)
      ' "$out/share/vault-services/release.json" >/dev/null
    runHook postInstall
  '';

  # autoPatchelf runs after postFixup, so restore the certified native bytes
  # once every fixup hook has completed. The service supplies the managed
  # library search path needed by the unmodified ONNX library.
  installCheckPhase = ''
    runHook preInstallCheck
    for architecture in x64 arm64; do
      runtime="share/vault-services/node_modules/onnxruntime-node/bin/napi-v6/linux/$architecture/libonnxruntime.so.1"
      if test -f "$out/$runtime"; then
        cp -f --remove-destination "./$runtime" "$out/$runtime"
        chmod 0644 "$out/$runtime"
        cmp "./$runtime" "$out/$runtime"
      fi
    done
    for executable in shared-vault shared-vault-grammar; do
      cp -f --remove-destination "./bin/$executable" "$out/bin/$executable"
      chmod 0755 "$out/bin/$executable"
      cmp "./bin/$executable" "$out/bin/$executable"
    done
    printf '%s  %s\n' ${lib.escapeShellArg onnxSha256} \
      "$out/share/vault-services/node_modules/onnxruntime-node/bin/napi-v6/linux/${onnxArchitecture}/libonnxruntime.so.1" | sha256sum -c -
    "$out/bin/shared-vault" --check-complete
    test -x "$out/bin/shared-vault-grammar"
    test -s "$out/share/vault-services/services/shared-vault/helpers/document-extraction.ts"
    ! grep -F 'scripts/vault-service.ts' "$out/bin/vault-service"
    grep -F 'bin/shared-vault' "$out/bin/vault-service"
    test -s "$out/share/vault-services/src/index.ts"
    FULCRUM_PACKAGE_ROOT="$out/share/vault-services" "$out/bin/bun" --no-env-file --eval '
      const root = process.env.FULCRUM_PACKAGE_ROOT;
      const pkg = await Bun.file(root + "/package.json").json();
      const release = await Bun.file(root + "/release.json").json();
      if (pkg.version !== release.packageVersion) throw new Error("Application package version differs from its release manifest");
      const { snapshotWebArtifact } = await import(root + "/scripts/web-artifact.ts");
      const artifact = await snapshotWebArtifact(root);
      if (!artifact.files.length) throw new Error("Packaged application has no web assets");
      console.log("Verified packaged application " + pkg.version + ": " + artifact.files.length + " web assets");
    '
    runHook postInstallCheck
  '';

  passthru = {
    sharedVaultSourceRevision = sourceRevision;
    sharedVaultArchiveHash = hash;
    sharedVaultSdkIcu = sdkIcu;
    sharedVaultSdkCcLib = sdkPkgs.stdenv.cc.cc.lib;
  };
  meta = {
    description = "Hash-pinned shared vault service, CLI and MCP release";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
