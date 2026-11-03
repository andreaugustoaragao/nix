{
  lib,
  fetchFromGitHub,
  gitMinimal,
  babashka,
  zsh,
  coreutils,
  python3,
  python3Packages,
}:
let
  testPython = python3.withPackages (ps: [
    ps.coverage
    ps.pytest
  ]);
  makeTool =
    {
      pname,
      rev,
      hash,
      description,
      extraDependencies ? [ ],
    }:
    python3Packages.buildPythonPackage {
      inherit pname;
      version = "0.1.0-unstable-${builtins.substring 0 7 rev}";
      pyproject = true;
      src = fetchFromGitHub {
        owner = "unclebob";
        repo = pname;
        inherit rev hash;
      };
      build-system = [ python3Packages.setuptools ];
      dependencies = [
        python3Packages.tree-sitter
        python3Packages.tree-sitter-language-pack
      ]
      ++ extraDependencies;
      nativeCheckInputs = [
        python3Packages.pytestCheckHook
        gitMinimal
      ]
      ++ lib.optionals (pname == "crapper") [
        babashka
        zsh
      ];
      # Keep project virtualenv selection; use a complete Nix environment only
      # for the fallback interpreter, without injecting libraries into the venv.
      postPatch =
        lib.optionalString (pname == "crapper") ''
          substituteInPlace src/crapper/runners.py \
            --replace-fail 'return "python3"' 'return "${testPython}/bin/python3"'
        ''
        + lib.optionalString (pname == "mutator") ''
          substituteInPlace src/mutator/runner.py \
            --replace-fail 'return sys.executable' 'return "${testPython}/bin/python3"'
          substituteInPlace tests/test_runner.py \
            --replace-fail /bin/echo ${coreutils}/bin/echo \
            --replace-fail '[sys.executable, "-m", "unittest", "discover"]' \
              '["${testPython}/bin/python3", "-m", "unittest", "discover"]'
        '';
      # Upstream excludes paths containing a directory named "build".
      preCheck = ''
        export TMPDIR=$(mktemp -d /tmp/ub-tools.XXXXXX)
      ''
      + lib.optionalString (pname == "crapper") ''
        patchShebangs uml
      '';
      pythonImportsCheck = [ pname ];

      makeWrapperArgs = [
        "--suffix"
        "PATH"
        ":"
        (lib.makeBinPath [
          gitMinimal
          python3
        ])
      ];

      meta = {
        inherit description;
        homepage = "https://github.com/unclebob/${pname}";
        license = lib.licenses.bsd0;
        mainProgram = pname;
        platforms = python3Packages.tree-sitter-language-pack.meta.platforms;
      };
    };
  crapper = makeTool {
    pname = "crapper";
    rev = "6fd92c4c9bcc56efb64a2f8743d5a2993bcfd42d";
    hash = "sha256-/iogUpO3Se+fuzvmH9Nqmc/Wf+mj3dF2WU6Ij6eVycg=";
    description = "Complexity and coverage analysis using the CRAP metric";
  };
in
{
  inherit crapper;
  dryer = makeTool {
    pname = "dryer";
    rev = "66ff6d21a42c04afcad89c78a80066176d1294b0";
    hash = "sha256-EwoP89k6YllcN6dmn/rxbeqDoAMOQsKfjpzfykD6PKA=";
    description = "Structural duplicate code detection";
  };
  mutator = makeTool {
    pname = "mutator";
    rev = "a5a0cb803b66e0cdb8bf471b3b08af701d424a41";
    hash = "sha256-WFzJX4nnPYpQv91iGbm/O24d5ab+RuxLjdxXR7YNfE0=";
    description = "Mutation testing with isolated project copies";
    extraDependencies = [ crapper ];
  };
}
