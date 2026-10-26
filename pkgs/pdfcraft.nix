{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  cups,
  libglvnd,
  libx11,
  libxcb,
  libxcursor,
  libxi,
  libxkbcommon,
  libxrandr,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  version = "0.13.0";
  sources = {
    aarch64-linux = {
      arch = "aarch64";
      hash = "sha256-Eu++TBjZZcVLK4SKpDIYgLlnNwRDlztCpcpKoNeVkkg=";
    };
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-WYUZ6ivHfGbKmpBiQeH+Psz3RfUGJ84829W15nWkVtM=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
  runtimeLibs = [
    libglvnd
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    libxrandr
    vulkan-loader
    wayland
  ];
in
stdenv.mkDerivation {
  pname = "pdfcraft";
  inherit version;

  src = fetchurl {
    url = "https://github.com/storytold/pdfcraft/releases/download/v${version}/pdfcraft-${version}-linux-${source.arch}.tar.gz";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r bin share "$out/"
    substituteInPlace "$out/share/applications/ai.storyteller.pdfcraft.desktop" \
      --replace-fail 'Exec=pdfcraft %U' "Exec=$out/bin/pdfcraft %U" \
      --replace-fail 'TryExec=pdfcraft' "TryExec=$out/bin/pdfcraft"

    runHook postInstall
  '';

  # Windowing and GPU libraries are loaded with dlopen, so ELF scanning misses them.
  postFixup = ''
    wrapProgram "$out/bin/pdfcraft" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs} \
      --suffix PATH : ${
        lib.makeBinPath [
          cups
          xdg-utils
        ]
      }
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/pdfcraft-cli" --version | grep -F '${version}'
    runHook postInstallCheck
  '';

  meta = {
    description = "Native PDF editor, reader, and workbench";
    homepage = "https://getartcraft.com/apps/pdfcraft";
    license = [
      lib.licenses.mit
      lib.licenses.asl20
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "pdfcraft";
  };
}
