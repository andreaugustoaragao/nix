{ ghostty }:
ghostty.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/ghostty-virgl.patch ];
})
