# Personal VM project moved

The personal VM `prl-dev-psl-vm` is now managed by the independent
[`nix-personal` repository](../../nix-personal/README.md), locally at
`/home/aragao/projects/personal/nix-personal`.

This repository no longer exports that host or its old installer. The initial
VM was deleted and has not been recreated. Previous installer media is obsolete
and must not be used; it had an unencrypted disk, DMS, and no setup SSH.

See the new repository's `docs/prl-dev-psl-vm.md` for the agreed choices,
current baseline, and outstanding setup review. Other hosts remain here until
explicitly migrated. Existing inactive personal-only module gates are retained
for a later focused cleanup; they do not create a second host definition.
