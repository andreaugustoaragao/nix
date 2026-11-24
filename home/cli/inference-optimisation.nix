{
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  upstream = pkgs.fetchFromGitHub {
    owner = "sybil-solutions";
    repo = "inference-optimisation-skill";
    rev = "fda968e7fc1996aa23c67139c755fe541c9d4be0";
    hash = "sha256-TD84WHgM9gCZtOmdSpqFxHKSFrnaUH58Kcxy6qETaAA=";
  };

  inferenceOptimisationSkill = pkgs.runCommand "inference-optimisation-skill" { } ''
    cp -r ${upstream}/skills/inference-optimisation "$out"
    chmod -R u+w "$out"
    cp ${upstream}/LICENSE "$out/LICENSE"
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"
  '';
in
{
  # Explicit-only across OMP, Codex, Pi (.agents/skills) and Cursor (.cursor/skills).
  home.file = {
    ".agents/skills/inference-optimisation".source = inferenceOptimisationSkill;
    ".cursor/skills/inference-optimisation".source = inferenceOptimisationSkill;
  };
}
