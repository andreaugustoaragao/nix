{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  nodejs_22,
}:

let
  version = "0.2.7";
  binaries = {
    aarch64-linux = {
      target = "linux-arm64";
      hash = "sha256-TxfSpRZpP1VkGftrhJjBzJAyW6gYOutj6H/nYJyInOk=";
    };
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-l1J8DLyzYwpTVKXXrUaTscCdhd0UL6kXFmgDKzqSq/w=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-MKJahYzLGPxfxix3hCAxzdRe2v/i/aq30P8aSP2pXjI=";
    };
    x86_64-darwin = {
      target = "darwin-x64";
      hash = "sha256-EEeI2A648eVo4F0Uk4oIVMoWroga1vRlew0VST9DLNo=";
    };
  };
  binary = binaries.${stdenv.hostPlatform.system};
  nativeCli = fetchurl {
    url = "https://github.com/SawyerHood/dev-browser/releases/download/v${version}/dev-browser-${binary.target}";
    inherit (binary) hash;
  };

  # Complete production dependency closure of the published 0.2.7 bundle.
  # Pin QuickJS's transitive packages as well as its root semver range.
  # Playwright's optional fsevents dependency is not needed for browser control.
  runtimePackages = [
    {
      name = "playwright";
      version = "1.58.2";
      hash = "sha512-vA30H8Nvkq/cPBnNw4Q8TWz1EJyqgpuinBcHET0YVJVFldr8JDNiU9LaWAE1KqSkRYazuaBhTpB5ZzShOezQ6A==";
    }
    {
      name = "playwright-core";
      version = "1.58.2";
      hash = "sha512-yZkEtftgwS8CsfYo7nm0KE8jsvm6i/PTgVtB8DL726wNf6H2IMsDuxCpJj59KDaxCtSnrWan2AeDqM7JBaultg==";
    }
    {
      name = "quickjs-emscripten";
      version = "0.32.0";
      hash = "sha512-So0Sqw869y/S2oE3Nuc0uT3Dhqgvsj8FSrwBdsuTosVsG8ME5/OcudU1GxsrIFdFABgy17GHnTVO9TYV/bLQcA==";
    }
    {
      name = "quickjs-emscripten-core";
      version = "0.32.0";
      hash = "sha512-QFnPfjFey8EqknSrSxe1hZrf1/8z7/6s1QzGOmKo6++02r7QRRX7ZoyNaZh7JuVjWsVW87KnQrbZqnHkOAzUyg==";
    }
    {
      name = "@jitl/quickjs-ffi-types";
      version = "0.32.0";
      hash = "sha512-v9T+GQpmk43VDJ7d72sf0Nexhk+ArvtUihW27dy7lqAl0zBObFKtSBBIm5RBjwIhE8VwsPPm9PNuvPvNqLWUEg==";
    }
    {
      name = "@jitl/quickjs-wasmfile-debug-asyncify";
      version = "0.32.0";
      hash = "sha512-EX8zbXwGqCgAE764M+qvkHtyXDi/FUoMBea0JnES7vCM3P7a2+EOZOjGv85wtZ2sJhI1oJ+nekmqpOODFDY+hw==";
    }
    {
      name = "@jitl/quickjs-wasmfile-debug-sync";
      version = "0.32.0";
      hash = "sha512-LeYWrPGC1uNCTBWvibo3ZLJj0CSVNYUXvJpXMCmuQ5Sap2cCACc3uvGvYV4homHHBAzfw5akoTqMMS4YFRtw+Q==";
    }
    {
      name = "@jitl/quickjs-wasmfile-release-asyncify";
      version = "0.32.0";
      hash = "sha512-3oSwPfja12ICz4aIblB58cuY8JlEq5Txt8Cut4VLo+LH47QN+mzCnSgnbB03hWzg1LBcc+VyyI9UOag7a1NF+Q==";
    }
    {
      name = "@jitl/quickjs-wasmfile-release-sync";
      version = "0.32.0";
      hash = "sha512-BKNDI/TPBfGlLNGYpLrhcDGXmIk4xHm4MRAisOBnOzpXVn9HZWsfmMAc9WMBrAHjvvds6HOikKeaOBKdPdpVrg==";
    }
  ];
  installRuntimePackage =
    package:
    let
      archive = fetchurl {
        url = "https://registry.npmjs.org/${package.name}/-/${baseNameOf package.name}-${package.version}.tgz";
        inherit (package) hash;
      };
    in
    ''
      mkdir -p "$runtime/node_modules/${package.name}"
      tar -xzf ${archive} --strip-components=1 -C "$runtime/node_modules/${package.name}"
    '';
in
stdenv.mkDerivation {
  pname = "dev-browser";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/dev-browser/-/dev-browser-${version}.tgz";
    hash = "sha512-XikUANysgCBrTPbew+KUPZv+ecq14VBTNv/hduFfLjOVlXLTvdMdV75z7avqwvJmKvUOsLSPWRwWLRFoRJ0NSQ==";
  };

  nativeBuildInputs = [ makeWrapper ] ++ lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;
  buildInputs = lib.optional stdenv.hostPlatform.isLinux stdenv.cc.cc.lib;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    runtime="$out/libexec/dev-browser"
    install -Dm755 ${nativeCli} "$runtime/dev-browser"
    install -Dm644 package.json "$runtime/package.json"
    install -Dm644 daemon/dist/daemon.bundle.mjs "$runtime/daemon/dist/daemon.bundle.mjs"
    install -Dm644 daemon/dist/sandbox-client.js "$runtime/daemon/dist/sandbox-client.js"
    install -Dm644 LICENSE "$out/share/licenses/dev-browser/LICENSE"
    ${lib.concatMapStringsSep "\n" installRuntimePackage runtimePackages}

    # The native CLI otherwise extracts to ~/.dev-browser and expects an
    # imperative npm install there. Point it directly at the immutable bundle.
    # Existing-browser access uses --connect; no browser downloads are needed.
    makeWrapper "$runtime/dev-browser" "$out/bin/dev-browser" \
      --prefix PATH : ${lib.makeBinPath [ nodejs_22 ]} \
      --set DEV_BROWSER_DAEMON "$runtime/daemon/dist/daemon.bundle.mjs" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/dev-browser" --help >/dev/null
    ${nodejs_22}/bin/node --check "$out/libexec/dev-browser/daemon/dist/daemon.bundle.mjs"
    ${nodejs_22}/bin/node --input-type=module - "$out/libexec/dev-browser/daemon/dist/daemon.bundle.mjs" <<'JS'
    import assert from 'node:assert/strict';
    import { createRequire } from 'node:module';
    import { access } from 'node:fs/promises';
    const require = createRequire(process.argv[2]);
    assert.equal(typeof require('playwright').chromium.connectOverCDP, 'function');
    assert.equal(typeof require('playwright-core').chromium.connectOverCDP, 'function');
    await access(require.resolve('playwright-core/package.json'));
    const quickjs = await require('quickjs-emscripten').getQuickJS();
    const context = quickjs.newContext();
    const result = context.evalCode('21 * 2');
    assert.equal(context.dump(result.value), 42);
    result.value.dispose();
    context.dispose();
    JS
    runHook postInstallCheck
  '';

  meta = {
    description = "Browser automation CLI with a pinned daemon and QuickJS runtime";
    homepage = "https://github.com/SawyerHood/dev-browser";
    license = lib.licenses.mit;
    sourceProvenance = [
      lib.sourceTypes.binaryNativeCode
      lib.sourceTypes.fromSource
    ];
    platforms = builtins.attrNames binaries;
    mainProgram = "dev-browser";
  };
}
