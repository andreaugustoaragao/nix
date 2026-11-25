{
  lib,
  pkgs,
  ...
}:

let
  version = "1.0.2";
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  bun = pkgs.callPackage ../../pkgs/bun-ahead.nix { };

  tarball = pkgs.fetchurl {
    url = "https://registry.npmjs.org/modern-web-guidance/-/modern-web-guidance-${version}.tgz";
    hash = "sha256-jDRt8XjJYoSmUWkg4YL3B4nUZB8PuKyyITZCWVNsUA0=";
  };

  modernWebGuidance = pkgs.stdenvNoCC.mkDerivation {
    pname = "modern-web-guidance";
    inherit version;
    src = tarball;

    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/modern-web-guidance/skills" "$out/bin"
      cp -r skills/modern-web-guidance "$out/share/modern-web-guidance/skills/"
      cp LICENSE THIRD_PARTY_NOTICES README.md package.json "$out/share/modern-web-guidance/"
      makeWrapper ${lib.getExe bun} "$out/bin/modern-web-guidance" \
        --add-flags "$out/share/modern-web-guidance/skills/modern-web-guidance/modern-web.mjs" \
        --set-default DISABLE_TELEMETRY 1
      runHook postInstall
    '';

    meta = {
      description = "Modern Web Guidance CLI and curated web-platform guides";
      homepage = "https://developer.chrome.com/docs/modern-web-guidance";
      license = with lib.licenses; [
        asl20
        cc-by-40
      ];
      mainProgram = "modern-web-guidance";
    };
  };

  rewriteSkillScript = pkgs.writeText "rewrite-modern-web-guidance-skill.py" ''
    import re
    import sys
    from pathlib import Path

    skill_md = Path(sys.argv[1]) / "SKILL.md"
    text = skill_md.read_text(encoding="utf-8")

    text, npx_cmd_count = re.subn(
        r"npx -y modern-web-guidance@latest ",
        "modern-web-guidance ",
        text,
    )
    if npx_cmd_count < 3:
        raise SystemExit(f"Expected >= 3 npx command replacements, got {npx_cmd_count}")

    text, intro_count = re.subn(
        r"Run `modern-web-guidance` directly with `npx` using",
        "Run the installed `modern-web-guidance` CLI directly using",
        text,
    )
    if intro_count != 1:
        raise SystemExit(f"Expected 1 intro npx replacement, got {intro_count}")

    replacement_section = (
        "## Local Nix CLI\n\n"
        "- `modern-web-guidance` is installed locally on `PATH` via Nix Home Manager "
        "(pinned v${version}, executed via Bun with `DISABLE_TELEMETRY=1`).\n"
        "- Search, retrieve, and legacy-scan work completely offline; do not fetch `@latest` "
        "from npm.\n\n"
        "## Guidelines"
    )
    text, section_count = re.subn(
        r"## Using npx / pnpx\n.*?## Guidelines",
        replacement_section,
        text,
        flags=re.DOTALL,
    )
    if section_count != 1:
        raise SystemExit(f"Expected 1 npx/pnpx section replacement, got {section_count}")

    if "npx" in text.lower():
        raise SystemExit("Unexpected residual npx reference in patched SKILL.md")

    skill_md.write_text(text, encoding="utf-8")
  '';

  modernWebGuidanceSkill = pkgs.runCommand "modern-web-guidance-skill-${version}" { } ''
    mkdir -p "$out"
    cp -r ${modernWebGuidance}/share/modern-web-guidance/skills/modern-web-guidance/SKILL.md \
      ${modernWebGuidance}/share/modern-web-guidance/skills/modern-web-guidance/guides \
      ${modernWebGuidance}/share/modern-web-guidance/skills/modern-web-guidance/skill-version.txt \
      "$out/"
    cp ${modernWebGuidance}/share/modern-web-guidance/LICENSE \
      ${modernWebGuidance}/share/modern-web-guidance/THIRD_PARTY_NOTICES \
      "$out/"
    chmod -R u+w "$out"
    ${lib.getExe python} ${rewriteSkillScript} "$out"
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"
  '';
in
{
  home.packages = [ modernWebGuidance ];

  # Explicit-only across OMP, Codex, Pi (.agents/skills) and Cursor (.cursor/skills).
  home.file = {
    ".agents/skills/modern-web-guidance".source = modernWebGuidanceSkill;
    ".cursor/skills/modern-web-guidance".source = modernWebGuidanceSkill;
  };
}
