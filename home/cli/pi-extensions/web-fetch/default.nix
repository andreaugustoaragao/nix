# pi extension `web_fetch` — directory-style extension with 78 vendored
# site-specific URL handlers from oh-my-pi. Builds a node_modules tree
# (linkedom + @types/node) once at Nix evaluation, then exposes the
# directory as a derivation that home-manager symlinks into
# ~/.pi/agent/extensions/web-fetch/.
{ lib, buildNpmPackage, ... }:
buildNpmPackage {
  pname = "pi-extension-web-fetch";
  version = "0.1.0";

  src = builtins.path {
    name = "pi-extension-web-fetch-source";
    path = ./.;
    filter =
      _path: type:
      let
        rel = baseNameOf (toString _path);
      in
      type != "directory" || (rel != "node_modules" && rel != "default.nix");
  };

  # Hash of the resolved npm dependency graph. Computed once with
  # `prefetch-npm-deps package-lock.json`; bump by replacing with
  # `lib.fakeHash` and reading the printed value when deps change.
  npmDepsHash = "sha256-Rg8qSjU64z6e8lkO+wzn4AjlBlbhJhuLGfk9DRSG5yk=";

  # No build step — pi extensions are loaded as TS via jiti at runtime.
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    # Copy the whole vendored extension tree plus the populated
    # node_modules built by buildNpmPackage.
    cp -r . $out/
    # Drop the package-lock — it's not needed at runtime and just adds
    # noise in the home-manager-files symlink target.
    rm -f $out/package-lock.json
    runHook postInstall
  '';

  meta = {
    description = "pi web_fetch extension: 78 site-specific URL handlers vendored from oh-my-pi";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
