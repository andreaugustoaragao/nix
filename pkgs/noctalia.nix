{ noctalia }:

noctalia.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./patches/noctalia-discreet-notification-actions.patch
    ./patches/noctalia-slider-refresh.patch
  ];
})
