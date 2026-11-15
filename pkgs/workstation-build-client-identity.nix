{
  writeShellScript,
  writeShellScriptBin,
  coreutils,
  inetutils,
  nix,
}:
let
  stateDirectory = "/var/lib/workstation-build-client";
  secretKey = "${stateDirectory}/cache.sec";
  initialise = writeShellScript "workstation-build-client-initialise" ''
    set -eu
    umask 077
    test "$(${coreutils}/bin/id -u)" = 0
    machine=$(${inetutils}/bin/hostname)
    case "$machine" in workstation|prl-dev-vm) ;; *) exit 1 ;; esac
    test ! -L ${stateDirectory}
    test ! -L ${secretKey}
    ${coreutils}/bin/install -d -o root -g root -m 0700 ${stateDirectory}
    if [ ! -s ${secretKey} ]; then
      ${nix}/bin/nix --extra-experimental-features nix-command key generate-secret \
        --key-name "$machine-build-client-1" > ${secretKey}.new
      ${coreutils}/bin/mv ${secretKey}.new ${secretKey}
    fi
    test "$(${coreutils}/bin/stat -c %u ${secretKey})" = 0
    ${coreutils}/bin/chmod 0600 ${secretKey}
    ${nix}/bin/nix --extra-experimental-features nix-command key convert-secret-to-public < ${secretKey}
  '';
in
{
  inherit stateDirectory secretKey initialise;
  client = writeShellScriptBin "workstation-build-client-identity" ''
    exec /run/wrappers/bin/pkexec --disable-internal-agent ${initialise}
  '';
}
