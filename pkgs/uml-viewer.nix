{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  runCommand,
  clojure,
  jdk21,
  makeWrapper,
  tmux,
  bash,
  gitMinimal,
}:
let
  src = fetchFromGitHub {
    owner = "unclebob";
    repo = "uml-viewer";
    rev = "f65dafe93b3cb1b4e6bb02dbe41503ed05bd9ebf";
    hash = "sha256-Fb/i3neXytrgOJGe7HD7UwENHIzB/d2ZadapxMglx2Q=";
  };
  jars =
    runCommand "uml-viewer-jars"
      {
        nativeBuildInputs = [
          clojure
          jdk21
        ];
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-KjpBjEkIB5TZ5tTfOogFyf5NwMirWepx8ItlcGbM2mU=";
      }
      ''
        export CLJ_CONFIG="$TMPDIR/clojure"
        export JAVA_TOOL_OPTIONS="-Duser.home=$TMPDIR"
        clojure -Srepro -Sdeps '{:deps {org.clojure/clojure {:mvn/version "1.12.0"}
                                      quil/quil {:mvn/version "4.3.1563"}}}' -Spath
        mkdir -p "$out/share/java"
        find "$TMPDIR/.m2" -name '*.jar' -exec cp -t "$out/share/java" {} +
      '';
in
stdenvNoCC.mkDerivation {
  pname = "uml-viewer";
  version = "0-unstable-f65dafe";
  inherit src;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/uml-viewer" "$out/bin"
    cp -r src examples "$out/share/uml-viewer/"
    makeWrapper ${jdk21}/bin/java "$out/bin/uml-viewer" \
      --add-flags '-Dapple.awt.UIElement=true' \
      --add-flags "-cp $out/share/uml-viewer/src:${jars}/share/java/*" \
      --add-flags 'clojure.main -m uml-viewer.main.uml-viewer' \
      --suffix PATH : ${
        lib.makeBinPath [
          tmux
          bash
          gitMinimal
        ]
      }
    makeWrapper ${jdk21}/bin/java "$out/bin/uml-ir" \
      --add-flags "-cp $out/share/uml-viewer/src:${jars}/share/java/*" \
      --add-flags 'clojure.main -m uml-viewer.main.ir-generator'
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/uml-viewer" --help
    runHook postInstallCheck
  '';
  meta = {
    description = "Interactive UML diagrams and source-to-EDN generation";
    homepage = "https://github.com/unclebob/uml-viewer";
    license = lib.licenses.unfree;
    mainProgram = "uml-viewer";
    platforms = lib.platforms.unix;
  };
}
