{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildNpmPackage,
  makeWrapper,
  autoPatchelfHook,
  nodejs_26,
  ripgrep,
  fd,
  zlib,
  libxcb,
}:
let
  releases = builtins.fromJSON (builtins.readFile ./releases.json);
  system = stdenv.hostPlatform.system;
  cursorSource = releases.cursor.sources.${system};
in
{
  codex = stdenvNoCC.mkDerivation {
    pname = "codex";
    inherit (releases.codex) version;
    src = fetchurl releases.codex.sources.${system};
    launcher = fetchurl {
      url = "https://registry.npmjs.org/@openai/codex/-/codex-${releases.codex.version}.tgz";
      hash = "sha512-KhzYlkKPxoNssR8CEm45IjqnFWn7UtlF4CiD3tOJPea51xBs7MaHy0UQG9GSbCqk6Lrjn5QdJDV0QD1/FgWlGw==";
    };
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/codex" "$out/bin"
      cp -R vendor "$out/lib/codex/"
      tar -xzf "$launcher" --strip-components=1 -C "$out/lib/codex"
      makeWrapper ${nodejs_26}/bin/node "$out/bin/codex" \
        --add-flags "$out/lib/codex/bin/codex.js" \
        --prefix PATH : ${lib.makeBinPath [ ripgrep ]}
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/codex" --version | grep -Fx 'codex-cli ${releases.codex.version}'
    '';
    meta.platforms = builtins.attrNames releases.codex.sources;
  };

  pi = buildNpmPackage {
    pname = "pi-coding-agent";
    inherit (releases.pi) version npmDepsHash;
    src = builtins.path {
      name = "pi-install-lock";
      path = ./.;
      filter =
        path: _type:
        builtins.elem (baseNameOf path) [
          "package.json"
          "package-lock.json"
        ];
    };
    nodejs = nodejs_26;
    nativeBuildInputs = [
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ libxcb ];
    dontNpmBuild = true;
    npmRebuildFlags = [ "--ignore-scripts" ];
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$out/bin"
      cp -R node_modules "$out/lib/"
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        find "$out/lib/node_modules/@earendil-works/pi-tui/native/linux/prebuilds" -mindepth 1 -maxdepth 1 -type d \
          ! -name '${if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"}' -exec rm -r {} +
      ''}
      ${lib.optionalString stdenv.hostPlatform.isDarwin ''
        rm -rf "$out/lib/node_modules/@earendil-works/pi-tui/native/linux"
      ''}
      makeWrapper ${nodejs_26}/bin/node "$out/bin/pi" \
        --add-flags "$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
        --prefix NODE_PATH : "$out/lib/node_modules" \
        --prefix PATH : ${
          lib.makeBinPath [
            ripgrep
            fd
          ]
        }
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/pi" --version | grep -Fx '${releases.pi.version}'
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        env -u LD_LIBRARY_PATH ${nodejs_26}/bin/node -e 'require(process.argv[1])' \
          "$out/lib/node_modules/@earendil-works/pi-tui/native/linux/prebuilds/${
            if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"
          }/linux-platform-x11.node"
      ''}
    '';
    meta.platforms = lib.platforms.unix;
  };

  cursor-agent = stdenv.mkDerivation {
    pname = "cursor-agent";
    inherit (releases.cursor) version;
    src = fetchurl cursorSource;
    nativeBuildInputs = [
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      zlib
      stdenv.cc.cc.lib
    ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/cursor-agent" "$out/bin"
      cp -R . "$out/share/cursor-agent/"
      makeWrapper "$out/share/cursor-agent/cursor-agent" "$out/bin/cursor-agent" \
        --set AGENT_CLI_UPDATE_CHECK_URL ${
          lib.escapeShellArg (
            "data:application/json,"
            + builtins.toJSON {
              inherit (releases.cursor) version;
              inherit (cursorSource) url;
            }
          )
        }
      ln -s cursor-agent "$out/bin/agent"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/cursor-agent" --version | grep -Fx '${releases.cursor.version}'
    '';
    meta = {
      platforms = builtins.attrNames releases.cursor.sources;
      license = lib.licenses.unfree;
    };
  };
}
