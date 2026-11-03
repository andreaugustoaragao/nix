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
    xdg.mimeApps.defaultApplications."text/x-markdown" = "local.folio.Reader.desktop";
    home.file.".local/bin/folio".source = launcher;
    xdg.dataFile."applications/local.folio.Reader.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Folio
      Comment=Read Markdown documents
      Exec=${launcher} %F
      Icon=local.folio.Reader
      Terminal=false
      Categories=Office;Viewer;
      MimeType=text/markdown;text/x-markdown;
      Keywords=Markdown;Reader;Mermaid;
    '';
    xdg.dataFile."icons/hicolor/scalable/apps/local.folio.Reader.svg".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/projects/personal/folio/result/share/icons/hicolor/scalable/apps/local.folio.Reader.svg";
  };
}
