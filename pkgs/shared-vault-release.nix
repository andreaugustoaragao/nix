{
  lib,
  pkgs,
  stdenv,
  fetchurl,
  requireFile,
  makeWrapper,
  jq,
  python3,
  binutils,
  autoPatchelfHook,
  openssl,
  zlib,
  libxcb,
  onnxruntime ? pkgs.onnxruntime,
  bubblewrap ? pkgs.bubblewrap,
  poppler-utils ? pkgs.poppler-utils,
  tesseract ? pkgs.tesseract,
  url,
  hash,
  packageVersion,
  sourceRevision,
  nativeBinaries ? null,
}:
let
  # Match the committed Rust SDK flake.lock so shared libraries for certified
  # native binaries stay pinned to the exact toolchain that built them.
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
        localSystem = stdenv.hostPlatform.system;
        config = { };
        overlays = [ ];
      };
  nativeRuntimeLibs = lib.makeLibraryPath [
    sdkPkgs.stdenv.cc.cc.lib
    zlib
    openssl
  ];
  artifact =
    if url == null then
      requireFile {
        inherit hash;
        name = "shared-vault-release.tar.gz";
        message = "Import the certified runtime archive produced by shared-vault-release.py via shared-vault-bootstrap.py --archive PATH before building this release.";
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
  nativeBinaryNames = [
    "shared-vault"
    "vault-extract"
    "ai-task-scheduler"
  ];
  nativeChecks = lib.optionalString (nativeBinaries != null) (
    lib.concatMapStringsSep "\n" (
      name:
      let
        expectedSha = nativeBinaries.${name};
      in
      assert builtins.match "[a-f0-9]{64}" expectedSha != null;
      ''
        printf '%s  %s\n' ${lib.escapeShellArg expectedSha} "$out/bin/${name}" | sha256sum -c -
      ''
    ) nativeBinaryNames
  );
in
assert builtins.match "[a-f0-9]{40}" sourceRevision != null;
assert stdenv.hostPlatform.isLinux;
assert
  nativeBinaries == null
  || lib.attrNames nativeBinaries == lib.sort builtins.lessThan nativeBinaryNames;
stdenv.mkDerivation {
  pname = "shared-vault-release";
  version = packageVersion;
  src = artifact;
  strictDeps = true;
  nativeBuildInputs = [
    jq
    makeWrapper
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
    for executable in vault-service shared-vault vault-extract ai-task-scheduler bun; do
      test -f "$out/bin/$executable" && test -x "$out/bin/$executable"
    done
    patchShebangs --host "$out/bin/vault-service"
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

  # autoPatchelf runs after postFixup, so restore the exact certified native
  # ELF bytes once fixup completes, verify their certified SHA-256 digests, and
  # then wrap them with Nix runtime environment defaults without altering ELF bytes.
  installCheckPhase = ''
    runHook preInstallCheck
    for executable in shared-vault vault-extract ai-task-scheduler; do
      cp -f --remove-destination "./bin/$executable" "$out/bin/$executable"
      chmod 0755 "$out/bin/$executable"
      cmp "./bin/$executable" "$out/bin/$executable"
    done
    ${nativeChecks}

    wrapProgram "$out/bin/shared-vault" \
      --prefix LD_LIBRARY_PATH : "${nativeRuntimeLibs}" \
      --set-default FULCRUM_ONNXRUNTIME_LIBRARY "${onnxruntime}/lib/libonnxruntime.so"

    wrapProgram "$out/bin/vault-extract" \
      --set-default FULCRUM_BWRAP_EXEC "${bubblewrap}/bin/bwrap" \
      --set-default FULCRUM_PDFTOTEXT_EXEC "${poppler-utils}/bin/pdftotext" \
      --set-default FULCRUM_PDFTOPPM_EXEC "${poppler-utils}/bin/pdftoppm" \
      --set-default FULCRUM_OCR_EXEC "${tesseract}/bin/tesseract" \
      --set-default TESSDATA_PREFIX "${tesseract}/share/tessdata"

    wrapProgram "$out/bin/ai-task-scheduler" \
      --set-default FULCRUM_BWRAP_EXEC "${bubblewrap}/bin/bwrap"

    for executable in shared-vault vault-extract ai-task-scheduler; do
      cmp "./bin/$executable" "$out/bin/.$executable-wrapped"
      "$out/bin/$executable" --help >/dev/null
    done
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
    sharedVaultSdkCcLib = sdkPkgs.stdenv.cc.cc.lib;
  };
  meta = {
    description = "Hash-pinned Fulcrum v2 runtime, shared-vault, vault-extract, and ai-task-scheduler release";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
