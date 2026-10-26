{
  graphify,
  python3,
  python3Packages,
  fetchFromGitHub,
}:

let
  version = "0.9.95";
in
graphify.overridePythonAttrs (
  old:
  let
    dependencies = old.dependencies ++ [ python3Packages.pyyaml ];
  in
  {
    inherit version;

    src = fetchFromGitHub {
      owner = "Graphify-Labs";
      repo = "graphify";
      tag = "v${version}";
      hash = "sha256-/OdOq9RXzjflrFY2UFGxYVQBESh9PWUQjZFox0Q59hw=";
    };

    inherit dependencies;

    # Graphify re-execs Python with -m; child processes need its module path too.
    makeWrapperArgs = (old.makeWrapperArgs or [ ]) ++ [
      "--prefix"
      "PYTHONPATH"
      ":"
      "${placeholder "out"}/${python3.sitePackages}:${python3Packages.makePythonPath dependencies}"
    ];

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/graphify" extract --help >/dev/null
      runHook postInstallCheck
    '';

    meta = old.meta // {
      changelog = "https://github.com/Graphify-Labs/graphify/releases/tag/v${version}";
    };
  }
)
