{
  services.samba = {
    enable = true;
    smbd.enable = true;
    nmbd.enable = false;
    winbindd.enable = false;
    openFirewall = false;
    settings = {
      global = {
        workgroup = "FARAGAO";
        "server string" = "maui";
        "netbios name" = "maui";
        "use sendfile" = "yes";
        "aio read size" = 1;
        "aio write size" = 1;
        "min receivefile size" = 16384;
        #max protocol = smb2
        # note: localhost is the ipv6 localhost ::1
        "hosts allow" = "192.168.10. 192.168.20. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "server min protocol" = "SMB3_11";
        "smb ports" = "445";
        "guest account" = "nobody";
        "map to guest" = "bad user";
      };
      timemachine = {
        path = "/data/timemachine";
        "valid users" = "backup";
        public = "no";
        writeable = "yes";
        guestOk = false;
        comment = "Time machine backup for all macs";
        #"force user" = "username";
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "fruit:model" = "MacSamba";
        "fruit:time machine max size" = "3T";
        "vfs objects" = "catia fruit streams_xattr";
      };
    };
  };
  systemd.services.samba-smbd = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };
  services.avahi.enable = true;
  services.avahi.openFirewall = true;
  services.avahi.settings = {
    publish.disable-publishing = false;
    server.domain-name = "faragao.net";
  };
}
