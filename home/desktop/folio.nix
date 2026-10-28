{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:
let
  launcher = pkgs.writeShellScript "folio" ''
    exec "${config.home.homeDirectory}/projects/personal/folio/result/bin/folio" "$@"
  '';
in
{
  config = lib.mkIf (hostName == "prl-dev-vm") {
    home.file.".local/bin/folio".source = launcher;
    xdg.dataFile."applications/local.folio.Reader.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Folio
      Comment=Read Markdown documents
      Exec=${launcher} %F
      Icon=text-x-generic
      Terminal=false
      Categories=Office;Viewer;
      MimeType=text/markdown;text/x-markdown;
      Keywords=Markdown;Reader;Mermaid;
    '';
  };
}
