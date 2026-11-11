{ noctalia }:

noctalia.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/noctalia-discreet-notification-actions.patch ];
})
