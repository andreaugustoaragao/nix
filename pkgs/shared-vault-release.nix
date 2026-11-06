{
  lib,
  stdenv,
  fetchurl,
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
  artifact = fetchurl {
    inherit url hash;
    name = "shared-vault-release.tar.gz";
  };
  elfMachine =
    {
      x86_64-linux = 62;
      aarch64-linux = 183;
    }
    .${stdenv.hostPlatform.system} or null;
in
assert builtins.match "[a-f0-9]{40}" sourceRevision != null;
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
    for executable in vault-service vault-client vault-mcp bun; do
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

  passthru = {
    sharedVaultSourceRevision = sourceRevision;
    sharedVaultArchiveHash = hash;
  };
  meta = {
    description = "Hash-pinned shared vault service, CLI and MCP release";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
