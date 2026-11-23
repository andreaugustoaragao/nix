{
  config,
  lib,
  pkgs,
  ...
}:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  directories = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir ./portable-skills);
  sources = lib.mapAttrs (
    name: _:
    let
      src = builtins.path {
        name = "${name}-skill-src";
        path = ./portable-skills + "/${name}";
      };
    in
    pkgs.runCommand "${name}-skill" { } ''
      cp -r ${src} "$out"
      chmod -R u+w "$out"
      ${lib.getExe python} ${./make-explicit-skill.py} "$out"
    ''
  ) directories;
  retireBackup = pkgs.writeShellScript "retire-portable-skill-backup" ''
    set -eu
    umask 077
    canonical=$1
    parent=$2
    old="$canonical.hm-backup"
    if [ -L "$canonical" ] && { [ -e "$old" ] || [ -L "$old" ]; }; then
      case "$(${pkgs.coreutils}/bin/readlink -f "$canonical")" in
        /nix/store/*)
          ${pkgs.coreutils}/bin/install -d -m 0700 "$parent"
          archived=$(${pkgs.coreutils}/bin/mktemp -d "$parent/backup.XXXXXX")
          ${pkgs.coreutils}/bin/mv -- "$old" "$archived/backup"
          ;;
      esac
    fi
  '';
  roots = [
    ".agents/skills"
    ".cursor/skills"
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
  home.activation.retirePortableSkillBackups = lib.hm.dag.entryAfter [ "linkGeneration" ] (
    lib.concatMapStringsSep "\n" (
      root:
      lib.concatMapStringsSep "\n" (name: ''
        run ${retireBackup} \
          ${lib.escapeShellArg "${config.home.homeDirectory}/${root}/${name}"} \
          ${lib.escapeShellArg "${config.xdg.stateHome}/nix-skill-adoption/hm-backups/${root}/${name}"}
      '') (builtins.attrNames sources)
    ) roots
  );
}
