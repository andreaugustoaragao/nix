{ noctalia }:

noctalia.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./patches/noctalia-discreet-notification-actions.patch
    ./patches/noctalia-slider-refresh.patch
    ./patches/noctalia-capsule-bands.patch
    ./patches/noctalia-pam-helper-stdout.patch
  ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dpam_service=noctalia" ];
})
