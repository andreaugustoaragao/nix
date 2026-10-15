{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  fetchFromGitHub,
  xar,
  cpio,
  gzip,
  apple-sdk_15,
}:

let
  # nixpkgs' Swift 5.10 cannot compile FluidAudio's Swift 6 package. Keep
  # this compiler private to the worker, independent of installed Xcode.
  compiler = stdenvNoCC.mkDerivation {
    pname = "record-call-swift-toolchain";
    version = "6.2.4";
    src = fetchurl {
      url = "https://download.swift.org/swift-6.2.4-release/xcode/swift-6.2.4-RELEASE/swift-6.2.4-RELEASE-osx.pkg";
      hash = "sha256-nJRjf9qDEpAaCOVyplHDoYpnJomthn+WySV7Q3dRWek=";
    };
    nativeBuildInputs = [
      xar
      cpio
      gzip
    ];
    unpackPhase = ''
      xar -xf "$src"
      mkdir payload
      cd payload
      gzip -dc ../swift-6.2.4-RELEASE-osx-package.pkg/Payload | cpio -idm --quiet
    '';
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out"
      mv usr "$out/"
    '';
    dontFixup = true;
    meta.platforms = lib.platforms.darwin;
  };
  fluidAudio = fetchFromGitHub {
    owner = "FluidInference";
    repo = "FluidAudio";
    rev = "19600a485baa4998812e4654b70d2bab8f2c9949";
    hash = "sha256-/KTcZLu4G7W+NAOIKLi+SRDq4IpuRw+wwxdTDyPQ2hE=";
  };
  # Swift adds this compatibility-library search path to executables. Retain
  # the small runtime library rather than the entire compiler toolchain.
  swiftRuntime = stdenvNoCC.mkDerivation {
    pname = "record-call-swift-runtime";
    inherit (compiler) version;
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out/lib"
      cp ${compiler}/usr/lib/swift-6.2/macosx/*.dylib "$out/lib/"
    '';
    dontFixup = true;
  };
in
stdenv.mkDerivation {
  pname = "record-call-diarizer";
  version = "0.1.0";
  src = builtins.path {
    name = "record-call-diarizer-source";
    path = ./.;
  };
  nativeBuildInputs = [ apple-sdk_15 ];
  disallowedReferences = [ compiler ];
  postPatch = ''
    substituteInPlace Package.swift \
      --replace-fail '.package(url: "https://github.com/FluidInference/FluidAudio.git",' \
        '.package(name: "FluidAudio", path: "${fluidAudio}"' \
      --replace-fail 'revision: "19600a485baa4998812e4654b70d2bab8f2c9949"' ""
  '';
  buildPhase = ''
    runHook preBuild
    export CLANG_MODULE_CACHE_PATH="$TMPDIR/clang-module-cache"
    export SDKROOT="${apple-sdk_15.sdkroot}"
    ${compiler}/usr/bin/swift build \
      --disable-sandbox --configuration release --jobs 2 \
      --cache-path "$TMPDIR/swift-cache" \
      --config-path "$TMPDIR/swift-config" \
      --security-path "$TMPDIR/swift-security" \
      --sdk "$SDKROOT" --product record-call-diarizer
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m755 .build/release/record-call-diarizer "$out/bin/"
    install_name_tool -rpath ${compiler}/usr/lib/swift-6.2/macosx \
      ${swiftRuntime}/lib "$out/bin/record-call-diarizer"
    runHook postInstall
  '';
  meta = {
    description = "Offline speaker diarization for recorded calls, without a second ASR pass";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "record-call-diarizer";
  };
}
