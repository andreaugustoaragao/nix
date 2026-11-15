{ stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation {
  pname = "pi-vim";
  version = "1.7.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/@burneikis/pi-vim/-/pi-vim-1.7.0.tgz";
    hash = "sha512-T2lwdGHah/hAHYGtFoXDXIbc2/dv4CPGiosFBcmXYL1h3WDj3LNOtWwOtNpIpaT+nCIhc1IxVNjmFTxKH0ZI6A==";
  };
  dontBuild = true;
  installPhase = ''
    mkdir -p "$out/share/pi-vim"
    cp -R . "$out/share/pi-vim/"
  '';
}
