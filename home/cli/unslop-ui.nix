{
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  upstream = pkgs.fetchFromGitHub {
    owner = "felipebasurto";
    repo = "unslop-ui";
    rev = "bf709166f91cf46f254b8acbe8dc75d4c83efa66";
    hash = "sha256-q9xdqYnVq9GTSWrHB5dfnz21N771QdGOwmeBTn+c7Jg=";
  };

  unslopUiSkill = pkgs.runCommand "unslop-ui-skill-1.0.1" { } ''
    cp -r ${upstream}/skills/unslop-ui "$out"
    chmod -R u+w "$out"
    cp ${upstream}/LICENSE "$out/LICENSE"
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"
  '';
in
{
  # Explicit-only across OMP, Codex, Pi (.agents/skills) and Cursor (.cursor/skills).
  home.file = {
    ".agents/skills/unslop-ui".source = unslopUiSkill;
    ".cursor/skills/unslop-ui".source = unslopUiSkill;
  };
}
