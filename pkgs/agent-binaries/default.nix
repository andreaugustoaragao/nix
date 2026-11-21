{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildNpmPackage,
  makeWrapper,
  autoPatchelfHook,
  nodejs_26,
  ripgrep,
  fd,
  zlib,
  libxcb,
}:
let
  releases = builtins.fromJSON (builtins.readFile ./releases.json);
  system = stdenv.hostPlatform.system;
  cursorSource = releases.cursor.sources.${system};
in
{
  codex = stdenvNoCC.mkDerivation {
    pname = "codex";
    inherit (releases.codex) version;
    src = fetchurl releases.codex.sources.${system};
    launcher = fetchurl {
      url = "https://registry.npmjs.org/@openai/codex/-/codex-${releases.codex.version}.tgz";
      hash = "sha512-KhzYlkKPxoNssR8CEm45IjqnFWn7UtlF4CiD3tOJPea51xBs7MaHy0UQG9GSbCqk6Lrjn5QdJDV0QD1/FgWlGw==";
    };
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/codex" "$out/bin"
      cp -R vendor "$out/lib/codex/"
      tar -xzf "$launcher" --strip-components=1 -C "$out/lib/codex"
      makeWrapper ${nodejs_26}/bin/node "$out/bin/codex" \
        --add-flags "$out/lib/codex/bin/codex.js" \
        --prefix PATH : ${lib.makeBinPath [ ripgrep ]}
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/codex" --version | grep -Fx 'codex-cli ${releases.codex.version}'
    '';
    meta.platforms = builtins.attrNames releases.codex.sources;
  };

  pi = buildNpmPackage {
    pname = "pi-coding-agent";
    inherit (releases.pi) version npmDepsHash;
    src = builtins.path {
      name = "pi-install-lock";
      path = ./.;
      filter =
        path: _type:
        builtins.elem (baseNameOf path) [
          "package.json"
          "package-lock.json"
        ];
    };
    nodejs = nodejs_26;
    nativeBuildInputs = [
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ libxcb ];
    dontNpmBuild = true;
    npmRebuildFlags = [ "--ignore-scripts" ];
    installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib" "$out/bin"
        cp -R node_modules "$out/lib/"
        ${lib.optionalString stdenv.hostPlatform.isLinux ''
          find "$out/lib/node_modules/@earendil-works/pi-tui/native/linux/prebuilds" -mindepth 1 -maxdepth 1 -type d \
            ! -name '${if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"}' -exec rm -r {} +
        ''}
        ${lib.optionalString stdenv.hostPlatform.isDarwin ''
          rm -rf "$out/lib/node_modules/@earendil-works/pi-tui/native/linux"
        ''}
        read_js="$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/read.js"
        bundle_js="$(${ripgrep}/bin/rg -l 'async function\*readLocalFileChunks' "$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/chunks" --glob '*.js')"
        test "$(printf '%s\n' "$bundle_js" | wc -l)" -eq 1
        substituteInPlace "$read_js" \
          --replace-fail '    const handle = await fsOpen(path, "r");' '    if (signal?.aborted) throw new DOMException("Operation cancelled", "AbortError");
      const handle = await fsOpen(path, "r");' \
          --replace-fail '        const stats = await handle.stat();' '        if (signal?.aborted) throw new DOMException("Operation cancelled", "AbortError");
          const stats = await handle.stat();' \
          --replace-fail '        yield* handle.createReadStream({ end, signal, autoClose: false });' '        if (signal?.aborted) throw new DOMException("Operation cancelled", "AbortError");
          const stream = handle.createReadStream({ end, signal, autoClose: false });
          stream.on("error", () => {});
          yield* stream;'
        substituteInPlace "$bundle_js" \
          --replace-fail 'async function*readLocalFileChunks(path11,{signal}){let handle=await fsOpen(path11,"r");try{let stats=await handle.stat(),end=stats.isFile()&&stats.size>0?stats.size-1:void 0;yield*handle.createReadStream({end,signal,autoClose:!1})}finally{await handle.close()}}' 'async function*readLocalFileChunks(path11,{signal}){if(signal?.aborted)throw new DOMException("Operation cancelled","AbortError");let handle=await fsOpen(path11,"r");try{if(signal?.aborted)throw new DOMException("Operation cancelled","AbortError");let stats=await handle.stat(),end=stats.isFile()&&stats.size>0?stats.size-1:void 0;if(signal?.aborted)throw new DOMException("Operation cancelled","AbortError");let stream=handle.createReadStream({end,signal,autoClose:!1});stream.on("error",()=>{});yield*stream}finally{await handle.close()}}'
        ! ${ripgrep}/bin/rg 'yield\*\s*handle\.createReadStream' "$read_js" "$bundle_js"
        makeWrapper ${nodejs_26}/bin/node "$out/bin/pi" \
          --add-flags "$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
          --prefix NODE_PATH : "$out/lib/node_modules" \
          --prefix PATH : ${
            lib.makeBinPath [
              ripgrep
              fd
            ]
          }
        runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/pi" --version | grep -Fx '${releases.pi.version}'
      ${nodejs_26}/bin/node --input-type=module - "$out/lib/node_modules" <<'JS'
      import assert from "node:assert/strict";
      import { readFile, readdir, mkdtemp, writeFile, rm, open as fsOpen } from "node:fs/promises";
      import { tmpdir } from "node:os";
      import { join } from "node:path";
      import { pathToFileURL } from "node:url";
      import { createHash } from "node:crypto";
      const modules = process.argv[2];
      const agent = join(modules, "@earendil-works/pi-coding-agent");
      const { createReadTool } = await import(pathToFileURL(join(agent, "dist/core/tools/read.js")));
      const { CodemodeSandbox, loadQuickJSWasm } = await import(pathToFileURL(join(modules, "@earendil-works/pi-codemode/dist/index.js")));
      const wasmModule = await loadQuickJSWasm();
      const errors = [];
      const uncaught = error => errors.push({ kind: "uncaughtException", message: String(error) });
      const rejected = error => errors.push({ kind: "unhandledRejection", message: String(error) });
      process.on("uncaughtException", uncaught); process.on("unhandledRejection", rejected);
      const dir = await mkdtemp(join(tmpdir(), "t029-native-read-fixture-"));
      const file = join(dir, "large.txt"); await writeFile(file, "line\n".repeat(100000));
      const bundleDir = join(agent, "dist/bundle/chunks");
      const bundles = [];
      for (const name of await readdir(bundleDir)) {
        if (!name.endsWith(".js")) continue;
        const path = join(bundleDir, name), text = await readFile(path, "utf8");
        if (text.includes("async function*readLocalFileChunks")) bundles.push(path);
      }
      assert.equal(bundles.length, 1);
      function extract(text) {
        const match = /async function\*\s*readLocalFileChunks\([\s\S]*?\)\s*\{/.exec(text);
        assert.ok(match);
        let depth = 1, end = match.index + match[0].length;
        for (; end < text.length && depth; end++) {
          if (text[end] === "{") depth++; else if (text[end] === "}") depth--;
        }
        assert.equal(depth, 0);
        return text.slice(match.index, end);
      }
      const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
      const fdCount = async () => process.platform === "linux" ? (await readdir("/proc/self/fd")).length : null;
      const drain = async iterator => { for await (const chunk of iterator) assert.ok(chunk.length > 0); };
      const warmWorkers = [];
      const warm = new CodemodeSandbox({ wasm: wasmModule, onWorkerStarted: promise => warmWorkers.push(promise) });
      assert.equal((await warm.execute("return 1")).ok, true);
      await warm.close(); await Promise.all(warmWorkers);
      const baseline = await fdCount();
      try {
        for (const sourcePath of [join(agent, "dist/core/tools/read.js"), ...bundles]) {
          const source = extract(await readFile(sourcePath, "utf8"));
          assert.match(source, /stream\.on\("error"/);
          assert.equal((source.match(/signal\?\.aborted/g) ?? []).length, 3);
          const nativeRead = new Function("fsOpen", source + "; return readLocalFileChunks;")(fsOpen);
          const delayedRead = new Function("fsOpen", source + "; return readLocalFileChunks;")(
            async (...args) => { const handle = await fsOpen(...args); await sleep(10); return handle; });
          for (let iteration = 0; iteration < 50; iteration++) {
            const pre = new AbortController(); pre.abort();
            await assert.rejects(drain(nativeRead(file, { signal: pre.signal })), { name: "AbortError" });
            const reads = [], workers = [];
            const sandbox = new CodemodeSandbox({ wasm: wasmModule, onWorkerStarted: promise => workers.push(promise),
              tools: [{ name: "read", execute(_args, ctx) {
                const operation = drain(delayedRead(file, { signal: ctx.signal })); reads.push(operation);
                return operation;
              } }] });
            const result = await sandbox.execute('tools.read({}); return "finished";');
            assert.equal(result.ok, true); assert.equal(result.calls.length, 1);
            assert.equal(result.calls[0].status, "cancelled");
            await Promise.allSettled(reads); await sandbox.close(); await Promise.all(workers);
            const mid = new AbortController(), iterator = nativeRead(file, { signal: mid.signal });
            assert.equal((await iterator.next()).done, false); mid.abort();
            await assert.rejects(iterator.next(), { name: "AbortError" });
            await assert.rejects(drain(nativeRead(join(dir, "missing"), { signal: undefined })), { code: "ENOENT" });
            await assert.rejects(drain(nativeRead(dir, { signal: undefined })), { code: "EISDIR" });
            const readTool = createReadTool(dir);
            for (const path of ["missing", "."]) {
              const outcome = await readTool.execute("t029-io", { path }, undefined);
              assert.equal(outcome.isError, true);
              assert.match(outcome.content.find(item => item.type === "text")?.text ?? "", path === "." ? /EISDIR|directory/ : /ENOENT|not found/);
            }
          }
          console.log(JSON.stringify({ check: "A4", source: sourcePath, sha256: createHash("sha256").update(source).digest("hex"), triggers: 5, iterations: 50 }));
        }
        await sleep(25); assert.deepEqual(errors, []); assert.equal(await fdCount(), baseline);
      } finally {
        await rm(dir, { recursive: true, force: true });
        process.off("uncaughtException", uncaught); process.off("unhandledRejection", rejected);
      }
      JS
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        env -u LD_LIBRARY_PATH ${nodejs_26}/bin/node -e 'require(process.argv[1])' \
          "$out/lib/node_modules/@earendil-works/pi-tui/native/linux/prebuilds/${
            if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"
          }/linux-platform-x11.node"
      ''}
    '';
    meta = {
      platforms = lib.platforms.unix;
      mainProgram = "pi";
    };
  };

  cursor-agent = stdenv.mkDerivation {
    pname = "cursor-agent";
    inherit (releases.cursor) version;
    src = fetchurl cursorSource;
    nativeBuildInputs = [
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      zlib
      stdenv.cc.cc.lib
    ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/cursor-agent" "$out/bin"
      cp -R . "$out/share/cursor-agent/"
      makeWrapper "$out/share/cursor-agent/cursor-agent" "$out/bin/cursor-agent" \
        --set AGENT_CLI_UPDATE_CHECK_URL ${
          lib.escapeShellArg (
            "data:application/json,"
            + builtins.toJSON {
              inherit (releases.cursor) version;
              inherit (cursorSource) url;
            }
          )
        }
      ln -s cursor-agent "$out/bin/agent"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/cursor-agent" --version | grep -Fx '${releases.cursor.version}'
    '';
    meta = {
      platforms = builtins.attrNames releases.cursor.sources;
      license = lib.licenses.unfree;
    };
  };
}
