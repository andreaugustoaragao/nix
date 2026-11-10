#!/usr/bin/env python3
"""Source regressions for greetd autologin session class.

These checks read the Nix modules. They do not evaluate the flake, start a
session, or exercise a Polkit prompt.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
DISPLAY_MANAGER = ROOT / "system" / "display-manager.nix"
NIRI = ROOT / "home" / "desktop" / "niri.nix"
HYPRLAND = ROOT / "home" / "desktop" / "hyprland.nix"
DOC = ROOT / "docs" / "polkit-gui.md"
PATCH = ROOT / "pkgs" / "hyprpolkitagent-registration.patch"
POLKIT_QT_PATCH = ROOT / "pkgs" / "polkit-qt-registration-init.patch"
POLKIT_QT_TEST = ROOT / "pkgs" / "polkit-qt-listener-init.test.cpp"


def _block(text, name):
    match = re.search(
        rf"{name} = \{{(.*?)\n\s*\}};",
        text,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing {name} block")
    return match.group(1)


class DisplayManagerSessionClassTests(unittest.TestCase):
    def setUp(self):
        self.source = DISPLAY_MANAGER.read_text()
        self.niri = NIRI.read_text()
        self.hyprland = HYPRLAND.read_text()
        self.doc = DOC.read_text()
        self.patch = PATCH.read_text()
        self.polkit_qt_patch = POLKIT_QT_PATCH.read_text()
        self.polkit_qt_test = POLKIT_QT_TEST.read_text()

    def test_autologin_is_initial_user_session_not_greeter(self):
        self.assertNotIn("if autoLogin then", self.source)
        initial = _block(self.source, "initial_session")
        self.assertIn('command = "${unstable-pkgs.niri}/bin/niri --session"', initial)
        self.assertIn("user = owner.name", initial)
        self.assertIn("lib.optionalAttrs autoLogin {", self.source)
        self.assertLess(
            self.source.index("lib.optionalAttrs autoLogin {"),
            self.source.index("initial_session = {"),
        )

    def test_default_session_stays_greeter_for_every_combination(self):
        default = _block(self.source, "default_session")
        self.assertIn('user = "greeter"', default)
        self.assertNotIn("owner.name", default)
        self.assertNotIn("initial_session", default)
        # tuigreet is the !useDms fallback after the autologin user session
        # exits while greetd is still running. Daemon exit stays stopped.
        self.assertIn("lib.optionalAttrs (!useDms)", default)
        self.assertIn("tuigreet", default)
        self.assertIn("niri --session", default)

    def test_dms_greeter_fallback_covers_autologin(self):
        self.assertIn(
            "imports = lib.optionals useDms [ inputs.dank-greeter.nixosModules.default ];",
            self.source,
        )
        self.assertNotIn("useDms && !autoLogin", self.source)
        self.assertIn("lib.optionalAttrs useDms {", self.source)
        self.assertIn("programs.dms-greeter", self.source)

    def test_combination_gates_are_independent(self):
        """autoLogin adds the user session; useDms only selects the greeter."""
        auto_login = self.source.split("lib.optionalAttrs autoLogin {", 1)[1]
        self.assertIn("initial_session = {", auto_login)
        self.assertNotIn("default_session = {", auto_login)
        use_dms_command = _block(self.source, "default_session")
        self.assertIn("lib.optionalAttrs (!useDms)", use_dms_command)
        self.assertNotIn("autoLogin", use_dms_command)
        # DMS greeter import is not disabled for autologin hosts.
        self.assertNotIn("!autoLogin", self.source)

    def test_authentication_is_not_weakened(self):
        for source in (self.source, self.niri):
            self.assertNotIn("security.polkit.extraConfig", source)
            self.assertNotIn("auth_admin_keep", source)
        self.assertNotRegex(self.source, r"polkit\.(extraConfig|debug)")
        self.assertIn("security.polkit.enable = true;", self.source)
        self.assertNotRegex(self.source, r"services\.greetd\.restart\s*=")

    def test_compositor_still_owns_the_auth_agent(self):
        self.assertIn(
            'spawn-at-startup "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"',
            self.niri,
        )
        self.assertIn("graphical logind session", self.niri)
        self.assertIn("logind D-Bus fallback", self.niri)
        self.assertNotIn("polkit refuses auth-agent listeners", self.niri)
        self.assertIn(
            '"uwsm app -- ${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"',
            self.hyprland,
        )

    def test_registration_patch_retries_only_the_failed_initial_call(self):
        self.assertIn("prev.hyprpolkitagent.override {", self.source)
        self.assertIn("hyprpolkitagent-registration.patch", self.source)
        self.assertLess(
            self.source.index("prev.hyprpolkitagent.override {"),
            self.source.index("hyprpolkitagent-registration.patch"),
        )
        self.assertIn("(old.patches or [ ]) ++ [", self.source)
        self.assertIn("../pkgs/hyprpolkitagent-registration.patch", self.source)
        self.assertIn("gnome-keyring = prev.gnome-keyring.overrideAttrs", self.source)
        self.assertEqual(self.source.count("nixpkgs.overlays = ["), 1)
        for phrase in (
            "QTimer",
            "setSingleShot(true)",
            "callOnTimeout",
            "sessionSubject->isValid()",
            "registerListener",
            "registrationTimer.stop()",
            "authentication agent registration failed",
        ):
            self.assertIn(phrase, self.patch)
        self.assertNotIn("password", self.patch.lower())
        self.assertNotIn("auth_admin", self.patch)
        self.assertIn("QTimer", self.doc)
        self.assertIn("does not prove the live registration error", self.doc)
        self.assertIn("saturates at 30s", self.doc)

    def test_logind_lookup_preserves_proc_hardening_and_authentication(self):
        self.assertIn("logindSessionForProcess(getpid())", self.patch)
        self.assertIn("org.freedesktop.login1.Manager", self.patch)
        self.assertIn("GetSessionByPID", self.patch)
        self.assertIn("org.freedesktop.DBus.Properties", self.patch)
        self.assertIn('QStringLiteral("Id")', self.patch)
        self.assertIn("QDBusConnection::systemBus()", self.patch)
        self.assertIn("QDBusReply<QDBusObjectPath>", self.patch)
        self.assertIn("QDBusReply<QDBusVariant>", self.patch)
        self.assertIn("QMetaType::QString", self.patch)
        self.assertNotIn("qEnvironmentVariable", self.patch)
        self.assertNotIn("setSessionId", self.patch)
        self.assertIn("tests.logind-session", self.source)
        self.assertIn('"/proc".options = [ "hidepid=2" ];',
                      (ROOT / "system/security.nix").read_text())

    def test_retry_delay_saturates_at_cap(self):
        self.assertIn("#include <algorithm>", self.patch)
        self.assertNotIn("delayMs < 30000 ? delayMs * 2", self.patch)
        initial = int(re.search(r"int delayMs = (\d+);", self.patch).group(1))
        cap = int(re.search(
            r"delayMs = std::min\(delayMs \* 2, (\d+)\);",
            self.patch,
        ).group(1))
        delay = initial
        scheduled = []
        for _ in range(8):
            scheduled.append(delay)
            delay = min(delay * 2, cap)
        self.assertEqual(scheduled, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000])
        self.assertLessEqual(max(scheduled), cap)
        self.assertEqual(cap, 30000)

    def test_doc_records_pending_relogin(self):
        for phrase in (
            "initial_session",
            "class=user",
            "auth_admin",
            "source change does not change the",
            "graphical",
            "is not an explanation",
            "registerListener",
            "Display=2",
            "PID 3538",
            "/run/greetd.run",
            "restartIfChanged",
            "reload does not talk to greetd",
            "stays stopped",
            "explicitly started",
            "while that daemon is still running",
        ):
            self.assertIn(phrase, self.doc)
        self.assertNotIn("passwordless", self.doc.lower())
        self.assertNotIn("If that process later exits", self.doc)

    def test_listener_handle_starts_null_only_for_the_agent(self):
        overlay = self.source.split("nixpkgs.overlays", 1)[1]
        self.assertEqual(overlay.count("kdePackages = prev.kdePackages //"), 1)
        self.assertLess(
            overlay.index("prev.hyprpolkitagent.override {"),
            overlay.index("kdePackages = prev.kdePackages //"),
        )
        self.assertIn(
            "polkit-qt-1 = prev.kdePackages.polkit-qt-1.overrideAttrs",
            overlay,
        )
        self.assertEqual(overlay.count("nixpkgs.overlays"), 0)
        self.assertIn("agent/polkitqt1-agent-listener.cpp", self.polkit_qt_patch)
        self.assertIn("void *registeredHandle = nullptr;", self.polkit_qt_patch)
        self.assertNotIn("polkit_agent_listener_register", self.polkit_qt_patch)
        self.assertNotIn("password", self.polkit_qt_patch.lower())
        self.assertIn("QCoreApplication", self.polkit_qt_test)
        self.assertNotRegex(self.polkit_qt_test, r"registerListener\s*\(")
        self.assertNotRegex(self.polkit_qt_test, r"(?<!Core)QApplication")
        self.assertNotIn("QGuiApplication", self.polkit_qt_test)
        self.assertIn("registeredHandle", self.doc)
        self.assertIn("does not pass a null subject", self.doc)

    def test_greeter_fallback_requires_a_living_daemon(self):
        self.assertIn("while this greetd process is still running", self.source)
        self.assertIn("daemon exit stays stopped", self.source)
        self.assertIn("explicitly started greetd", self.source)
        self.assertNotIn("this greetd process still has a login", self.source)
        self.assertIn("stays stopped", self.doc)
        self.assertIn("user-session exit", self.doc)
        self.assertNotRegex(self.source, r"services\.greetd\.restart\s*=")


if __name__ == "__main__":
    unittest.main()
