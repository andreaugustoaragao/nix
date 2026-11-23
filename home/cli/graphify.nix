{
  lib,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  graphify = unstable-pkgs.callPackage ../../pkgs/graphify.nix { };
  graphifySkill = pkgs.runCommand "graphify-skill" { } ''
    cp -r ${./graphify} "$out"
    chmod -R u+w "$out"
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"
  '';
in
{
  home.packages = [ graphify ];

  home.file = {
    ".agents/skills/graphify".source = graphifySkill;
    ".cursor/skills/graphify".source = graphifySkill;
  };
}
