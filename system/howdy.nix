{ config, lib, ... }:

# Facial authentication scoped strictly to Noctalia's lockscreen (`noctalia`
# PAM service). Typed passwords authenticate first via pam_unix (`order =
# 12900`) before falling through to Howdy (`order = 12950`), so keyboard unlock
# never blocks on or breaks when the webcam is unavailable.
{
  services.howdy = {
    enable = true;
    settings = {
      core = {
        no_confirmation = true;
        abort_if_lid_closed = false;
        workaround = "off";
      };
      video = {
        device_path = "/dev/video0"; # HD Pro Webcam C920
        timeout = 3;
        warn_no_device = false;
      };
    };
  };

  # Prevent Howdy from propagating to sudo, su, greetd, login, or polkit-1.
  security.pam.howdy.enable = false;

  security.pam.services.noctalia = {
    howdy = {
      enable = true;
      control = "sufficient";
    };
    rules.auth.howdy.order = lib.mkForce (
      config.security.pam.services.noctalia.rules.auth.unix.order + 50
    );
  };
}
