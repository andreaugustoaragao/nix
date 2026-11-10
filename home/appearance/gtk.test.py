"""Parse generated stylesheets with the actual GTK3 and GTK4 CSS engines."""

import ctypes as c
import json
from pathlib import Path
import sys

data = json.loads(Path(sys.argv[1]).read_text())


class Error(c.Structure):
    _fields_ = [("domain", c.c_uint), ("code", c.c_int), ("message", c.c_char_p)]


def verify(version, library):
    gtk = c.CDLL(library)
    gtk.gtk_css_provider_new.restype = c.c_void_p
    gtk.gtk_css_provider_load_from_data.argtypes = [c.c_void_p, c.c_char_p, c.c_ssize_t] + ([c.POINTER(c.c_void_p)] if version == "gtk3" else [])
    gtk.gtk_css_provider_load_from_data.restype = c.c_int if version == "gtk3" else None
    provider = gtk.gtk_css_provider_new()
    errors = []
    callback_type = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p)

    @callback_type
    def parsing_error(provider, section, error, user_data):
        errors.append(c.cast(error, c.POINTER(Error)).contents.message.decode())

    gtk.g_signal_connect_data.argtypes = [c.c_void_p, c.c_char_p, callback_type, c.c_void_p, c.c_void_p, c.c_uint]
    gtk.g_signal_connect_data(provider, b"parsing-error", parsing_error, None, None, 0)
    for mode in ("dark", "light"):
        css = data["toolkit"][mode][version].encode()
        if version == "gtk3":
            error = c.c_void_p()
            result = gtk.gtk_css_provider_load_from_data(provider, css, len(css), c.byref(error))
            assert result, (version, mode, errors)
        else:
            gtk.gtk_css_provider_load_from_data(provider, css, len(css))
        assert not errors, (version, mode, errors)
    print(version + ": dark and light CSS parsed successfully")


verify(sys.argv[2], sys.argv[3])
