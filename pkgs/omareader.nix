{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  fontconfig,
  runtimeShell,
}:
let
  version = "0.4.2";
  extensionId = "mhglniaepbokfgnpeennihlifandcgjh";
  hostName = "com.bhp.omareader";

  crx = fetchurl {
    url = "https://github.com/badenpiland/omareader/releases/download/v${version}/omareader.crx";
    hash = "sha256-l0ywhFDAiueoZMyELdQD4WJrF11DGsN08EFAUsqkk9g=";
  };

  hostScript = fetchurl {
    url = "https://raw.githubusercontent.com/badenpiland/omareader/v${version}/host/omareader-host";
    hash = "sha256-kUPxa2JDWunphDzX+drPyqsm4SJnaacKVAMKvArr0Cw=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "omareader";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm644 ${crx} "$out/share/omareader/omareader.crx"
    install -Dm755 ${hostScript} "$out/libexec/omareader-host"
    # Upstream calls inotify_rm_watch() inside Watcher.reset(), which queues
    # IN_IGNORED and retriggers reset()+publish()+fc-match every 200ms forever.
    # DELETE_SELF/MOVE_SELF are already in WATCH_MASK.
    substituteInPlace "$out/libexec/omareader-host" \
      --replace-fail \
        'if mask & (IN_Q_OVERFLOW | IN_IGNORED | WATCH_MASK):' \
        'if mask & (IN_Q_OVERFLOW | WATCH_MASK):'

    mkdir -p "$out/bin"
    {
      printf '#!%s\n' '${runtimeShell}'
      printf 'export OMAREADER_STATE_DIR="''${OMAREADER_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/omareader}"\n'
      printf 'export OMAREADER_FONTCONFIG_DIR="''${OMAREADER_FONTCONFIG_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig}"\n'
      printf 'export OMAREADER_FC_MATCH="''${OMAREADER_FC_MATCH:-%s}"\n' '${fontconfig}/bin/fc-match'
      printf 'exec %q %q "$@"\n' '${lib.getExe python3}' "$out/libexec/omareader-host"
    } > "$out/bin/omareader-host"
    chmod 755 "$out/bin/omareader-host"

    mkdir -p "$out/etc/chromium/native-messaging-hosts"
    cat > "$out/etc/chromium/native-messaging-hosts/${hostName}.json" <<EOF
    {
      "name": "${hostName}",
      "description": "Omareader theme host",
      "path": "$out/bin/omareader-host",
      "type": "stdio",
      "allowed_origins": [
        "chrome-extension://${extensionId}/"
      ]
    }
    EOF

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe python3} - "$out/bin/omareader-host" <<'PY'
    import json, os, struct, subprocess, sys, tempfile, time
    from pathlib import Path

    host = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        root = base / "state"
        theme_dir = root / "current/theme"
        theme_dir.mkdir(parents=True)
        font_dir = base / "fontconfig"
        font_dir.mkdir()
        dark = base / "dark.toml"
        light = base / "light.toml"
        dark.write_text('mode = "dark"\nbackground = "#282828"\nforeground = "#ebdbb2"\n')
        light.write_text('mode = "light"\nbackground = "#fbf1c7"\nforeground = "#3c3836"\n')
        (theme_dir / "colors.toml").symlink_to(dark)
        (root / "current/theme.name").write_text("Gruvbox Dark\n")

        fc_log = base / "fc.log"
        fc_stub = base / "fc-match"
        fc_stub.write_text(f"#!/bin/sh\necho x >> {fc_log}\nprintf 'Mono\\nMono Regular\\nMono-Regular\\n'\n")
        fc_stub.chmod(0o755)

        env = dict(
            os.environ,
            OMAREADER_STATE_DIR=str(root),
            OMAREADER_FONTCONFIG_DIR=str(font_dir),
            OMAREADER_FC_MATCH=str(fc_stub),
        )
        proc = subprocess.Popen([host], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        try:
            def read_msg():
                hdr = proc.stdout.read(4)
                assert len(hdr) == 4, "short header"
                size = struct.unpack("<I", hdr)[0]
                return json.loads(proc.stdout.read(size))

            first = read_msg()
            assert first["mode"] == "dark" and first["background"] == "#282828", first

            tmp_link = theme_dir / ".colors.toml.tmp"
            tmp_link.symlink_to(light)
            os.replace(tmp_link, theme_dir / "colors.toml")

            second = read_msg()
            assert second["mode"] == "light" and second["background"] == "#fbf1c7", second

            time.sleep(1.0)
            calls = len(fc_log.read_text().splitlines())
            assert calls == 2, f"expected 2 fc-match calls (idle loop regression?), got {calls}"
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)
    PY
    runHook postInstallCheck
  '';

  passthru = {
    inherit extensionId hostName;
  };

  meta = {
    description = "Chromium extension and native host that repaints web pages in the active desktop color scheme";
    homepage = "https://github.com/badenpiland/omareader";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
