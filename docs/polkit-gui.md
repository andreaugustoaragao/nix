# Graphical Polkit elevation

## Confirmed runtime fix (2026-11-09)

The rebuild log reported `No authentication agent found`. PID 3538 was
still the old agent from desktop startup, despite the activated Niri
configuration pointing at the registration-retry build. Starting that
build through Niri exposed `Cannot create unix session: No session for
pid`, even inside `session-2.scope`. Logind's D-Bus `GetSessionByPID`
successfully resolved the very same PID to session 2.

`system/security.nix` mounts `/proc` with `hidepid=2`. The unprivileged
agent cannot read `/proc/1/cgroup`. In the pinned systemd 260.4 source,
`cg_pid_get_path_shifted` calls `cg_shift_path`, which determines the
cgroup root with `cg_get_root_path` by reading PID 1. Both
`sd_pid_get_session` and `sd_pid_get_owner_uid` therefore fail, and
Polkit 127's `UnixSessionSubject(pid)` cannot resolve even the caller's
own session. A direct libsystemd probe reproduced the lookup failure.
This is separate from the greetd session-class misconfiguration below.

The agent patch now falls back to logind over the system bus only when
that PID-based constructor fails. It calls `GetSessionByPID(getpid())`,
then reads the returned session object's `Id` property. Missing services,
D-Bus errors, wrong reply types, and empty IDs fail closed. It does not
trust `XDG_SESSION_ID`, choose an arbitrary display session, or change
Polkit policy. Polkit still verifies the registering caller's session.
The existing retry and successful-registration owner watch remain intact.

The patched agent registered successfully when spawned through Niri in
the existing desktop. A transient **user** service then ran
`pkexec --disable-internal-agent /run/current-system/sw/bin/true`:
the GUI dialog appeared, administrator authentication completed, and the
service exited successfully. No terminal authentication fallback or
system modification was involved in this check. The old unregistered
agent was stopped without restarting Niri or greetd.

The package exposes `tests.logind-session`, which compiles the production
resolver and tests it against a mock logind on a private D-Bus daemon.
The tests cover exact PID targeting, unavailable services, lookup and
property errors, malformed reply types, an empty ID, and a misleading
environment session ID. They never contact host logind or Polkit.

The normal Noctalia rebuild was retried after the successful GUI check.
It stopped **during the build**, before any authorization or activation,
on the concurrently modified `yazi-rune` derivation: its Zig setup hook
attempted to create `/homeless-shelter/.cache/zig` and received
`AccessDenied`. That package's owner was notified; its files were left
unchanged by the elevation repair. This is a separate build blocker,
not another GUI authentication failure.

A successful GUI rebuild is still required to persist the updated agent
path in Niri's startup configuration. Niri does not rerun
`spawn-at-startup` on config reload; the live replacement above is what
repairs this existing session. The session-class correction below takes
effect on a fresh greetd session, not on a bar reload.

## Earlier session and registration investigation

The following records the earlier evidence, before the runtime fix.
The autologin configuration is wrong for a logged-in desktop. That
misconfiguration alone does not explain the missing authentication agent.

## Confirmed greetd configuration

Autologin put `niri --session` in greetd `default_session` and ran it as
the desktop user. greetd 0.10.3 starts `default_session` through
`Context::greet` as `SessionClass::Greeter`, which sets
`XDG_SESSION_CLASS=greeter` before PAM opens the session. The live
Wayland session is that greeter class. The configuration in this module
moves autologin to `initial_session`, which `start_user_session` opens
as `SessionClass::User`, and leaves `default_session` as the greeter.
`org.freedesktop.policykit.exec` stays `auth_admin`.

`loginctl show-user` reports `Display=2`. Session 1 is the user service
manager. Session 2 is the active greeter. systemd 260.4
`SESSION_CLASS_CAN_DISPLAY` includes greeter, and Polkit 127
`RegisterAuthenticationAgent` does not reject that class. The elected
display is the greeter session that is already running. A class mismatch
with some other session is not what this evidence shows.

## Agent registration, from pinned code and the bus listing

`hyprpolkitagent` 0.1.3 calls
`Listener::registerListener` and ignores the boolean. It then enters
`QApplication::exec` and `start()` returns true either way.
polkit-qt 0.201.1 logs `Cannot register authentication agent` and
returns false. It does not retry.

Polkit 127 keeps the re-registration watch only after that call
succeeds. `polkit_agent_listener_register_with_options` connects
`notify::owner` on a `Server`, exports the agent on the system bus, then
calls `server_register`. If registration fails, it `server_free`s that
object, which drops the system-bus connection and the owner watch. A
later PolicyKit restart re-registers only a `Server` that survived the
first attempt. This process never calls `registerListener` again.

The system bus listing has no connection for `hyprpolkitagent` PID 3538.
A registered agent holds that connection for the life of the `Server`.
This process is not in the successful-registration state, so the
recorded PolicyKit restarts do not make it register. The warning text
from the first attempt is not in the evidence, and Niri's
`spawn-at-startup` child is not a journal service. Unpatched 0.1.3
therefore stays unregistered after a failed first call. That does not
identify which error the first call returned, and session class alone
is not an explanation of the missing prompt.

`pkgs/hyprpolkitagent-registration.patch` changes that initial failure
only. `QApplication` is created first. `registerListener` is retried
with a new `UnixSessionSubject` while `isValid()` is false or the call
returns false, on a single-shot `QTimer`. The delay starts at 1s,
doubles, and saturates at 30s, so a step never schedules 32s.
The messages contain no credentials. After a true return the timer
stops, and Polkit's existing `notify::owner` handling and the QML
prompt path stay as they are. Niri and Hyprland still spawn
`pkgs.hyprpolkitagent`. At that point PID 3538 was the unpatched binary.
The retry change by itself does not prove the live registration error;
the runtime investigation above establishes the procfs lookup failure
and the additional fallback needed to register.

polkit-qt 0.201.1 leaves `ListenerPrivate::registeredHandle`
uninitialized. Both `Listener` constructors allocate that object and
neither stores a handle before `registerListener`. The agent patch
returns when `isValid()` is false, so `registerListener` can be skipped
for the life of the process. `~Listener` then passes the unset pointer
to `polkit_agent_listener_unregister` during ordinary Qt destruction.
`pkgs/polkit-qt-registration-init.patch` sets that member to `nullptr`
inside `ListenerPrivate`, which covers both constructors. It does not
remove the valid-subject check and does not pass a null subject into
registration. The overlay hands the patched `polkit-qt-1` only to
`hyprpolkitagent` through its `kdePackages` argument. Other KDE and Qt
packages keep the unpatched library.
`pkgs/polkit-qt-listener-init.test.cpp` builds both constructors,
never calls `registerListener`, and lets `QCoreApplication` destroy
them. The worker did not build or run that file.

## What actually starts the new greetd config

The pinned NixOS module sets `systemd.services.greetd.restartIfChanged`
to false. Activation writes the new unit and config and leaves the
running greetd process on the configuration it already loaded. A bar
reload does not talk to greetd. Logout from the current desktop is that
old process handling its own session. That session was
`default_session`, so greetd treats the exit as the greeter ending. The
new `initial_session` is not consulted.

greetd creates `/run/greetd.run` after its first session start.
`initial_session` runs only when that file is absent. The file stays for
the boot, including across a later greetd process. The module leaves
`services.greetd.restart` false when `initial_session` is set, so after
activation an exit of the greetd daemon stays stopped. It is not an
automatic restart, and it does not start the greeter by itself.

While that daemon is still running, a user-session exit with nothing
scheduled starts `default_session`. A greeter-session exit with nothing
scheduled makes greetd return an error and the process stops. An
explicitly started replacement in the same boot sees `/run/greetd.run`
and therefore runs `default_session` (the greeter), not autologin.
Hosts without `initial_session` keep the module default `restart` true;
this configuration does not change that.

A reboot clears `/run` and starts greetd from the activated unit, which
is when `initial_session` runs. A source change does not change the
running session. The earlier investigation did not prove a graphical
`auth_admin` prompt; the successful GUI-only check above now does.
Terminal `sudo` alone would not prove that prompt.

| `autoLogin` | `useDms` | First greetd start of a boot | User session exits while that daemon is still running | greetd daemon exits |
| --- | --- | --- | --- | --- |
| true | false | `initial_session`: owner, `niri --session`, class=user | tuigreet as `greeter` | stays stopped. An explicitly started replacement with `/run/greetd.run` present runs tuigreet, not autologin. |
| true | true | same user session | DMS greeter as `greeter` | stays stopped. An explicitly started replacement with the runfile present runs the DMS greeter, not autologin. |
| false | false | tuigreet as `greeter` | after login, that user-session exit starts tuigreet again. A greeter exit with nothing scheduled stops the daemon. | module default `restart` is true, so systemd can start greetd again and it runs tuigreet |
| false | true | DMS greeter as `greeter` | after login, that user-session exit starts the DMS greeter again. A greeter exit with nothing scheduled stops the daemon. | module default `restart` is true, so a replacement runs the DMS greeter |

The table describes a greetd process started from this configuration. It
does not describe the daemon that is running before that start.
