{
  stdenv,
  fetchurl,
  lkl,
}:
stdenv.mkDerivation {
  pname = "worker-image-cptofs";
  inherit (lkl) version;
  src = fetchurl {
    url = "https://raw.githubusercontent.com/lkl/linux/9c51103caa1481493ebbbaf858f016e7f25ab921/tools/lkl/cptofs.c";
    hash = "sha256-NnUj8hHCk3U4hT9PmbK3tNPQE0AZJeUMjq0kaOwSkGk=";
  };
  dontUnpack = true;
  buildInputs = [ lkl ];
  buildPhase = ''
    cp "$src" cptofs.c
    substituteInPlace cptofs.c --replace-fail 'mem=100M' 'mem=1024M'
    $CC -O2 -I${lkl.dev}/include cptofs.c -L${lkl.lib}/lib -llkl -lpthread -ldl -o cptofs
  '';
  installPhase = ''
    install -Dm755 cptofs "$out/bin/cptofs"
  '';
}
