{ zed-editor }:
zed-editor.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/zed-virgl.patch ];
})
