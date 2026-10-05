{
  lib,
  pkgs,
  unstable-pkgs,
}:
let
  # Extend the existing shared package set. Python extensions compose with
  # Azure's own packageOverrides instead of replacing its dependency policy.
  runtimePkgs = unstable-pkgs.extend (
    _final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (_pyFinal: pyPrev: {
          urllib3 = pyPrev.urllib3.overridePythonAttrs (old: {
            version = "2.8.0";
            src = prev.fetchurl {
              url = "https://files.pythonhosted.org/packages/e3/05/b17359e1cefb4f909b5e40b1b90a496d987258916dbbf88e842c729f510e/urllib3-2.8.0.tar.gz";
              hash = "sha256-Y78urUyHlCbr8i7yp4HutKo7SueYoENVBvhof9W7m2M=";
            };
            # The original metadata reads src.tag, which fetchurl does not have.
            meta = old.meta // {
              changelog = "https://github.com/urllib3/urllib3/blob/2.8.0/CHANGES.rst";
            };
          });
        })
      ];
    }
  );
  npmSource = lib.getOutput "npm" pkgs.nodejs_22;
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
          node = pkgs.nodejs_22;
          braceVersion = "2.1.7";
        };
      }
      ''
        set -euo pipefail
        ulimit -c 0
        # Refuse unexpected upstream identities before creating the replacement.
        ${pkgs.nodejs_22}/bin/node --max-old-space-size=128 ${npmCheck} original ${npmSource}
        mkdir -p "$out/lib/node_modules" "$out/bin"
        cp -a ${npmSource}/lib/node_modules/npm "$out/lib/node_modules/npm"
        chmod -R u+w "$out/lib/node_modules/npm"
        # A complete replacement prevents old package files from surviving extraction.
        rm -r "$out/lib/node_modules/npm/node_modules/brace-expansion"
        mkdir "$out/lib/node_modules/npm/node_modules/brace-expansion"
        tar -xzf ${braceArchive} --strip-components=1 -C "$out/lib/node_modules/npm/node_modules/brace-expansion"
        ln -s ../lib/node_modules/npm/bin/npm-cli.js "$out/bin/npm"
        ln -s ../lib/node_modules/npm/bin/npx-cli.js "$out/bin/npx"
        ${pkgs.nodejs_22}/bin/node --max-old-space-size=128 ${npmCheck} repaired "$out" ${npmSource}
      '';
in
{
  inherit (runtimePkgs) azure-cli;
  ffmpeg = unstable-pkgs.ffmpeg_9;
  inherit npm;
}
