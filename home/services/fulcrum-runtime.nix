{
  lib,
  pkgs,
  unstable-pkgs,
}:
let
  azureBase = unstable-pkgs.azure-cli;
  azurePython = unstable-pkgs.python3;
  originalHttp = lib.findFirst (
    package: (package.pname or "") == "urllib3"
  ) (throw "Azure CLI has no direct urllib3 dependency") azureBase.propagatedBuildInputs;
  # Override one package without changing Azure's supported dependency set.
  azureHttp = azurePython.pkgs.urllib3.overridePythonAttrs (old: {
    version = "2.8.0";
    src = unstable-pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/e3/05/b17359e1cefb4f909b5e40b1b90a496d987258916dbbf88e842c729f510e/urllib3-2.8.0.tar.gz";
      hash = "sha256-Y78urUyHlCbr8i7yp4HutKo7SueYoENVBvhof9W7m2M=";
    };
    # The original metadata reads src.tag, which fetchurl does not have.
    meta = old.meta // {
      changelog = "https://github.com/urllib3/urllib3/blob/2.8.0/CHANGES.rst";
    };
  });
  azureCheck = pkgs.writeText "fulcrum-azure-check.py" ''
    import json
    import os
    from pathlib import Path
    import re
    import shlex
    import subprocess
    import sys

    output = Path(sys.argv[1])
    original = Path("${azureBase}/bin/az")
    fixed_site = "${azureHttp}/${azurePython.sitePackages}"
    expected_python = Path("${azurePython.interpreter}").resolve()
    pattern = re.compile(r"^export PYTHONPATH='([^'\n]+)'$", re.MULTILINE)

    def python_path(text):
        matches = pattern.findall(text)
        assert len(matches) == text.count('export PYTHONPATH=') == 1, 'Unexpected Azure wrapper layout'
        assert all(re.fullmatch(r"/nix/store/[a-z0-9]{32}-[^/:'\s]+/lib/python[0-9.]+/site-packages", part)
                   for part in matches[0].split(':')), 'Expected literal store paths'
        return matches[0]

    source = original.read_text()
    original_path = python_path(source)
    target = output / 'bin/az'
    target.parent.mkdir(parents=True)
    target.write_text(pattern.sub(lambda _: "export PYTHONPATH='" + fixed_site + ':' + original_path + "'", source))
    target.chmod(original.stat().st_mode & 0o777)
    assert python_path(target.read_text()) == fixed_site + ':' + original_path
    assert target.read_text().replace(fixed_site + ':', "", 1) == source, 'Changed other wrapper settings'

    def interpreter(launcher):
        script = launcher
        for depth in range(4):
            lines = script.read_text().splitlines()
            executable = shlex.split(lines[0].removeprefix('#!'))[0]
            if Path(executable).name.startswith('python'):
                assert Path(executable).resolve() == expected_python, 'Python interpreter changed'
                return executable
            if depth:
                assert not any('PYTHONPATH' in line for line in lines), 'Inner wrapper overrides import precedence'
            targets = [shlex.split(line)[3] for line in lines if line.startswith('exec -a "$0" ')]
            assert len(targets) == 1 and targets[0].startswith('/nix/store/'), 'Unexpected Azure entrypoint'
            script = Path(targets[0])
        raise AssertionError('Azure Python entrypoint not found')

    probe = (
        "import importlib.metadata, json, sys, urllib3, requests\n"
        "assert requests.packages.urllib3 is urllib3\n"
        "assert urllib3.__version__ == importlib.metadata.version('urllib3')\n"
        "print(json.dumps({'python': sys.executable, 'version': urllib3.__version__, "
        "'file': urllib3.__file__, 'requestsAlias': requests.packages.urllib3.__file__}))\n"
    )
    records = []
    for label, launcher, version, package in [
        ('original', original, '${originalHttp.version}', '${originalHttp}'),
        ('fixed', target, '2.8.0', '${azureHttp}'),
    ]:
        scratch = Path(os.environ['TMPDIR']) / ('azure-' + label)
        scratch.mkdir()
        environment = {
            'PATH': os.environ['PATH'], 'TMPDIR': str(scratch),
            'AZURE_CONFIG_DIR': str(scratch / 'config'),
            'AZURE_EXTENSION_DIR': str(scratch / 'extensions'),
            'XDG_CACHE_HOME': str(scratch / 'cache'),
            'AZURE_CORE_COLLECT_TELEMETRY': 'no', 'AZURE_CORE_CHECK_VERSION': 'no',
            'AZURE_CORE_ONLY_SHOW_ERRORS': 'true', 'PYTHONNOUSERSITE': 'true',
            'PYTHONDONTWRITEBYTECODE': '1',
        }
        python = interpreter(launcher)
        imports = subprocess.run([python, '-c', probe], check=True, capture_output=True, text=True, timeout=60,
                                 env=dict(environment, PYTHONPATH=python_path(launcher.read_text())))
        observed = json.loads(imports.stdout)
        assert observed['version'] == version, observed
        assert Path(observed['file']).is_relative_to(package), observed
        assert observed['requestsAlias'] == observed['file'], observed
        assert Path(observed['python']).resolve() == expected_python, observed
        # Trace real CLI execution as well as the wrapper's exact import context.
        result = subprocess.run([str(launcher), 'version', '--output', 'json'], check=True,
                                capture_output=True, text=True, timeout=120,
                                env=dict(environment, PYTHONVERBOSE='1'))
        assert json.loads(result.stdout)['azure-cli'] == '${azureBase.version}'
        assert package + '/${azurePython.sitePackages}/urllib3/' in result.stderr, 'CLI did not load expected urllib3'
        if label == 'fixed':
            assert '${originalHttp}/${azurePython.sitePackages}/urllib3/' not in result.stderr, 'CLI loaded original urllib3'
            subprocess.run([str(launcher), 'self-test'], check=True, env=environment, timeout=120)
        records.append(dict(label=label, **observed))
    print(json.dumps({'azure': '${azureBase.version}', 'imports': records, 'originalClosureRetained': True}))
  '';
  # Preserve the supported entrypoint and every setting except PYTHONPATH.
  # The old urllib3 bytes remain in azureBase's closure but are not imported by
  # this service launcher. Removing the prefix would restore the old runtime.
  azure-cli =
    pkgs.runCommand "fulcrum-azure-cli-${azureBase.version}"
      {
        inherit (azureBase) version meta;
        passthru = {
          basePackage = azureBase;
          httpPackage = azureHttp;
          python = azurePython;
        };
      }
      ''
        ${azurePython.interpreter} ${azureCheck} "$out"
      '';
  # The full Node package is a symlink environment. Copy the real npm output
  # so its launchers cannot resolve back into the unrepaired store tree.
  npmNode = pkgs.nodejs-slim_22;
  npmSource = lib.getOutput "npm" npmNode;
  braceArchive = pkgs.fetchurl {
    url = "https://registry.npmjs.org/brace-expansion/-/brace-expansion-2.1.7.tgz";
    hash = "sha256-b01k/atM3FCW1IU381pruyuLkYq6pL2wgz6SSG9mvvw=";
  };
  npmCheck = pkgs.writeText "fulcrum-npm-check.cjs" ''
    const assert = require('node:assert/strict');
    const fs = require('node:fs');
    const path = require('node:path');
    const { createRequire } = require('node:module');
    const { spawnSync } = require('node:child_process');
    const [mode, root, original] = process.argv.slice(2);
    const packageRoot = path.join(root, 'lib/node_modules/npm');
    const fromNpm = createRequire(path.join(packageRoot, 'package.json'));
    const metadata = name => JSON.parse(fs.readFileSync(path.join(packageRoot, name, 'package.json')));
    for (const name of ['npm', 'npx']) {
      assert(!fs.lstatSync(path.join(packageRoot, 'bin', name + '-cli.js')).isSymbolicLink(), 'npm source must contain real launcher files');
    }
    assert.equal(process.versions.node, '22.23.3');
    assert.equal(metadata('.').version, '10.9.9');
    assert.equal(metadata('node_modules/minimatch').version, '9.0.9');
    const brace = metadata('node_modules/brace-expansion');
    assert.equal(brace.version, mode === 'original' ? '2.0.2' : '2.1.7');
    const semver = fromNpm('semver');
    assert(semver.satisfies(brace.version, metadata('node_modules/minimatch').dependencies['brace-expansion']));
    assert(semver.satisfies(metadata('node_modules/balanced-match').version, brace.dependencies['balanced-match']));
    const nested = '{'.repeat(5000) + 'a,b' + '}'.repeat(5000);
    const expand = fromNpm('brace-expansion');
    assert.deepEqual(expand('{a,b}{1,2}'), ['a1', 'a2', 'b1', 'b2']);
    if (mode === 'original') {
      assert.throws(() => expand(nested), RangeError);
      process.stdout.write('Original nested-brace defect reproduced.\n');
      process.exit(0);
    }
    assert.deepEqual(expand(nested), [nested]);
    assert(fromNpm('minimatch').minimatch('a2', '{a,b}{1,2}'));
    for (const name of ['npm', 'npx']) {
      const cli = path.join(packageRoot, 'bin', name + '-cli.js');
      assert.equal(fs.realpathSync(path.join(root, 'bin', name)), cli);
      assert.equal(fs.readFileSync(cli, 'utf8').split('\n')[0], '#!' + process.execPath);
    }
    function inventory(directory, relative = "") {
      const result = {};
      for (const entry of fs.readdirSync(path.join(directory, relative), { withFileTypes: true })) {
        const name = path.join(relative, entry.name);
        if (name === 'node_modules/brace-expansion') continue;
        const file = path.join(directory, name);
        if (entry.isDirectory()) Object.assign(result, inventory(directory, name));
        else if (entry.isSymbolicLink()) result[name] = ['link', fs.readlinkSync(file)];
        else {
          assert(entry.isFile(), 'Unexpected npm file type');
          result[name] = [fs.statSync(file).mode & 0o111, require('node:crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex')];
        }
      }
      return result;
    }
    assert.deepEqual(inventory(packageRoot), inventory(path.join(original, 'lib/node_modules/npm')));
    const scratch = fs.mkdtempSync(path.join(process.env.TMPDIR, 'fulcrum-npm-'));
    const fixture = path.join(scratch, 'project');
    const dependency = path.join(fixture, 'dependency');
    fs.mkdirSync(dependency, { recursive: true });
    const settings = path.join(scratch, 'empty-npmrc');
    const globalSettings = path.join(scratch, 'empty-global-npmrc');
    fs.writeFileSync(settings, "");
    fs.writeFileSync(globalSettings, "");
    fs.writeFileSync(path.join(fixture, 'package.json'), JSON.stringify({ name: 'fulcrum-npm-fixture', version: '1.0.0', private: true, dependencies: { 'fulcrum-fixture': 'file:./dependency' } }));
    fs.writeFileSync(path.join(dependency, 'package.json'), JSON.stringify({ name: 'fulcrum-fixture', version: '1.0.0', bin: { 'fulcrum-fixture': './cli.js' } }));
    fs.writeFileSync(path.join(dependency, 'cli.js'), '#!' + process.execPath + '\nprocess.stdout.write("fixture-ok\\n");\n', { mode: 0o755 });
    const env = { ...process.env, npm_config_cache: path.join(scratch, 'cache'), npm_config_userconfig: settings,
      npm_config_globalconfig: globalSettings, npm_config_offline: 'true', npm_config_audit: 'false', npm_config_fund: 'false' };
    function command(name, args) {
      const result = spawnSync(path.join(root, 'bin', name), args, { cwd: fixture, env, encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024 });
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    }
    command('npm', ['install', '--ignore-scripts']);
    command('npm', ['ci', '--ignore-scripts']);
    assert.equal(JSON.parse(command('npm', ['ls', '--json'])).dependencies['fulcrum-fixture'].version, '1.0.0');
    const packed = JSON.parse(command('npm', ['pack', '--json', '--ignore-scripts']));
    assert.equal(packed.length, 1);
    assert(fs.statSync(path.join(fixture, packed[0].filename)).size > 0);
    assert.equal(command('npx', ['--offline', '--no-install', 'fulcrum-fixture']).trim(), 'fixture-ok');
    process.stdout.write('Patched npm/npx, unchanged Node interpreter, remaining npm bytes and offline local workflows passed.\n');
  '';
  npm =
    pkgs.runCommand "fulcrum-npm-10.9.9"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnutar
          pkgs.gzip
        ];
        passthru = {
          inherit npmSource;
          node = npmNode;
          braceVersion = "2.1.7";
        };
      }
      ''
        set -euo pipefail
        ulimit -c 0
        # Refuse unexpected upstream identities before creating the replacement.
        ${npmNode}/bin/node --max-old-space-size=128 ${npmCheck} original ${npmSource}
        mkdir -p "$out/lib/node_modules" "$out/bin"
        cp -a ${npmSource}/lib/node_modules/npm "$out/lib/node_modules/npm"
        chmod -R u+w "$out/lib/node_modules/npm"
        # A complete replacement prevents old package files from surviving extraction.
        rm -r "$out/lib/node_modules/npm/node_modules/brace-expansion"
        mkdir "$out/lib/node_modules/npm/node_modules/brace-expansion"
        tar -xzf ${braceArchive} --strip-components=1 -C "$out/lib/node_modules/npm/node_modules/brace-expansion"
        ln -s ../lib/node_modules/npm/bin/npm-cli.js "$out/bin/npm"
        ln -s ../lib/node_modules/npm/bin/npx-cli.js "$out/bin/npx"
        ${npmNode}/bin/node --max-old-space-size=128 ${npmCheck} repaired "$out" ${npmSource}
      '';
in
{
  ffmpeg = unstable-pkgs.ffmpeg_9;
  inherit azure-cli npm;
}
