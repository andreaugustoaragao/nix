{
  lib,
  stdenvNoCC,
  nodejs,
  makeWrapper,
}:
stdenvNoCC.mkDerivation {
  pname = "herdr-agent-preview";
  version = "1.0.0";
  src = ../home/desktop/herdr/mods/preview;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    ${nodejs}/bin/node --test lib/read-agent.test.mjs
  '';
  installPhase = ''
    mkdir -p "$out/share/herdr-preview" "$out/bin"
    cp -r integrations lib "$out/share/herdr-preview/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/herdr-agent-preview" \
      --add-flags "$out/share/herdr-preview/lib/read-agent.mjs"
  '';
  meta = {
    description = "Herdr agent transcript readers and Pi preview publisher";
    mainProgram = "herdr-agent-preview";
    platforms = lib.platforms.unix;
  };
}
