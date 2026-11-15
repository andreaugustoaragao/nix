{
  config,
  lib,
  pkgs,
  ...
}:
let
  directories = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir ./portable-skills);
  sources = lib.mapAttrs (
    name: _:
    builtins.path {
      name = "${name}-skill";
      path = ./portable-skills + "/${name}";
    }
  ) directories;
  roots = [
    ".agents/skills"
    ".cursor/skills"
    "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/opencode/skills"
  ];
in
{
  home.file = lib.listToAttrs (
    lib.concatMap (
      root:
      lib.mapAttrsToList (name: source: {
        name = "${root}/${name}";
        value = {
          inherit source;
          force = true;
        };
      }) sources
    ) roots
  );

  # Preserve pre-Nix copies before Home Manager adopts these exact names.
  home.activation.portableSkillsBackup = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
    lib.concatMapStringsSep "\n" (
      root:
      lib.concatMapStringsSep "\n" (name: ''
        dst=${lib.escapeShellArg "${config.home.homeDirectory}/${root}/${name}"}
        backup=${lib.escapeShellArg "${config.xdg.stateHome}/nix-skill-adoption/${root}/${name}"}
        if [ -e "$dst" ] && [ ! -L "$dst" ] && [ ! -e "$backup" ]; then
          run ${pkgs.coreutils}/bin/mkdir -p "$(dirname "$backup")"
          run ${pkgs.coreutils}/bin/cp -a -- "$dst" "$backup"
        fi
      '') (builtins.attrNames sources)
    ) roots
  );
}
