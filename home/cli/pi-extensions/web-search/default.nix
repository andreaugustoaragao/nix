# pi extension `web_search` — multi-provider web search chain forked
# from oh-my-pi. Active providers: Anthropic (api-key via the
# `web_search_20250305` server tool, restored locally), plus the
# env-key chain (Tavily, Perplexity, Brave, Jina, Kimi, Z.AI, Kagi,
# Synthetic, SearXNG). Gemini, Codex, Exa-MCP, and Parallel remain
# disabled — they require vendoring pi-ai's OAuth machinery.
{ lib, buildNpmPackage, ... }:
buildNpmPackage {
  pname = "pi-extension-web-search";
  version = "0.1.0";

  src = builtins.path {
    name = "pi-extension-web-search-source";
    path = ./.;
    filter =
      _path: type:
      let
        rel = baseNameOf (toString _path);
      in
      type != "directory" || (rel != "node_modules");
  };

  npmDepsHash = "sha256-Uta7zf4n9CRurcN6+OV7dYjt8CsnRS8FBKwdzcxj5Vc=";

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    rm -f $out/package-lock.json
    runHook postInstall
  '';

  meta = {
    description = "pi web_search extension: multi-provider chain vendored from oh-my-pi";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
