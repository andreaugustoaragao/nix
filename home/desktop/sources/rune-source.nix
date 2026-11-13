{ applyPatches, fetchgit }:
applyPatches {
  name = "rune-with-system-fonts";
  src = fetchgit {
    name = "rune-7ead7d6";
    url = "https://github.com/anomalyco/rune";
    rev = "7ead7d63fcf6f9dd9669385a8b90e2ae80015d7b";
    hash = "sha256-e6f1kr0qvTT13YKZIGhiFee33RwydeVX60Yz23j/cQA=";
    fetchSubmodules = true;
  };
  patches = [
    ./rune-font-loading.patch
    ./rune-gles.patch
  ];
}
