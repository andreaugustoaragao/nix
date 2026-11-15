# Folio, Vereda, and Vitals releases

The workstation and `prl-dev-vm` install these applications from public
[GitHub binary releases](https://github.com/andrearagao/desktop-releases/releases).
Application source remains private. Installation requires neither a local source
checkout nor GitHub credentials.

Each application has an independent version and two native archives, for
`aarch64-linux` and `x86_64-linux`. The archives contain the executable, desktop
assets, a source-revision manifest, and dependency license notices. Nix patches
the ELF interpreter and library paths and supplies runtime libraries.

`pkgs/desktop-releases.json` pins the application versions, source revisions, and
archive hashes. These are custom package pins. `nix flake update` does not update
them, and the installed applications do not replace themselves.

## Update an application

1. Build the same committed source revision on both native architectures using
   the [release tools](https://github.com/andrearagao/desktop-releases).
2. Publish the two archives together with `publish.py`. Existing release assets
   are never overwritten by that command.
3. Update the Nix pin, for example:

   ```sh
   python3 scripts/update-desktop-release.py folio 0.1.1
   ```

   This command checks both downloads against the release checksums and requires
   matching source revisions before updating the pin file.
4. Run the repository checks, build the affected host, and activate its reviewed
   system closure through normal GUI authentication.

## Desktop integration

Folio keeps the `folio` command and `local.folio.Reader.desktop` identity. It is
the Markdown viewer and opens selected files with `folio -- FILE`. Rune is its
UI implementation. Explicit software rendering remains available through
`folio --software` when the host provides the Lavapipe driver.

Vereda is the directory handler, D-Bus file manager, and file chooser portal.
Vitals includes its own application launcher. None of these launchers invokes
Cargo, Nix, or a development checkout.

The workstation uses native Noctalia with Ghostty as its default terminal. The
VM retains Kitty. Workstation hardware services and existing container workloads
remain configured independently of these application choices.
