{
  lib,
  stdenvNoCC,
  fetchurl,
  requireFile,
  callPackage,
  makeWrapper,
  python3,
}:
let
  pin = builtins.fromJSON (builtins.readFile ./agent-hub-release.json);
  bun = callPackage ./bun-ahead.nix { };
  archive =
    if pin.url == null then
      requireFile {
        inherit (pin) hash;
        name = "shared-vault-release.tar.gz";
        message = "Copy the pinned private runtime archive from the controller Nix store before building Agent Hub. No Fulcrum checkout is needed.";
      }
    else
      fetchurl {
        inherit (pin) url hash;
        name = "shared-vault-release.tar.gz";
      };
in
stdenvNoCC.mkDerivation {
  pname = "agent-hub";
  version = pin.packageVersion;
  src = archive;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];
  buildPhase = ''
    runHook preBuild
    ${bun}/bin/bun build --target=bun --format=esm --minify \
      --outfile=agent-hub-mcp.js share/vault-services/tools/agent-hub/mcp.ts
    runHook postBuild
  '';
  doCheck = stdenvNoCC.hostPlatform.isLinux;
  checkPhase = ''
    runHook preCheck
    ${bun}/bin/bun test share/vault-services/tools/agent-hub/tests/{registry,protocol,discovery,hooks,adapters,mcp}.test.ts
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/agent-hub" "$out/bin"
    cp -R share/vault-services/tools/agent-hub/. "$out/share/agent-hub/"
    cp agent-hub-mcp.js "$out/share/agent-hub/mcp.js"
    makeWrapper ${bun}/bin/bun "$out/bin/agent-hub" \
      --add-flags "--no-env-file $out/share/agent-hub/main.ts"
    cp ${./agent-hub-release.json} "$out/share/agent-hub-release.json"
    runHook postInstall
  '';
  dontFixup = true;
  doInstallCheck = true;
  installCheckPhase = ''
        "$out/bin/agent-hub" --help >/dev/null
        ${python3}/bin/python3 - "$out/bin/agent-hub" <<'PY'
    import json, os, select, subprocess, sys, tempfile
    with tempfile.TemporaryDirectory() as directory:
        environment = os.environ.copy()
        environment['AGENT_HUB_HOME'] = directory
        process = subprocess.Popen([sys.argv[1], 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        try:
            process.stdin.write(json.dumps({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'nix-package-check','version':'1'}}}) + '\n')
            process.stdin.flush()
            if not select.select([process.stdout], [], [], 10)[0]:
                raise RuntimeError('Packaged Agent Hub MCP did not initialize')
            response = json.loads(process.stdout.readline())
            assert response.get('id') == 1 and 'result' in response, response
        finally:
            process.terminate()
            process.wait(timeout=5)
    PY
  '';
  passthru.sourceRevision = pin.sourceRevision;
  meta = {
    description = "Agent Hub coordinator from a pinned private runtime archive";
    mainProgram = "agent-hub";
    platforms = lib.platforms.unix;
  };
}
