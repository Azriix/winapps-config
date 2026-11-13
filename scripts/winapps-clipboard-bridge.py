#!/usr/bin/env python3
"""Passerelle d'images du presse-papiers (lancée par winapps-freerdp).

Le sdl-freerdp d'Ubuntu ne transmet que du BMP ; les outils de capture ne publient que du PNG.
Quand le presse-papiers ne contient qu'une image sans BMP, elle est republiée avec une variante BMP.
Une seule instance ; s'arrête quand plus aucun sdl-freerdp ne tourne. WINAPPS_BRIDGE_DEBUG=1 : traces sur stderr.
"""

import fcntl
import os
import sys

# X11 et non Wayland : sans fenêtre active, GNOME interdit de publier dans le presse-papiers Wayland.
os.environ["GDK_BACKEND"] = "x11"

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402

BMP = "image/bmp"
# Par ordre de préférence.
SOURCE_TYPES = ("image/png", "image/jpeg", "image/webp", "image/tiff")
MAX_PIXELS = 64_000_000  # au-delà, BMP de plus de 190 Mo
IDLE_CHECK_SECONDS = 15
DEBUG = os.environ.get("WINAPPS_BRIDGE_DEBUG") == "1"


def log(message):
    if DEBUG:
        print("winapps-clipboard-bridge:", message, file=sys.stderr, flush=True)


def freerdp_running():
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                with open(f"/proc/{pid}/comm") as comm:
                    if comm.read().strip() == "sdl-freerdp":
                        return True
            except OSError:
                pass
    return False


def to_bmp(data):
    """Image -> BMP 24 bits, ou None si illisible ou trop grande."""
    loader = GdkPixbuf.PixbufLoader()
    try:
        loader.write_bytes(data)
        loader.close()
    except GLib.Error as error:
        log(f"image illisible : {error.message}")
        return None
    pixbuf = loader.get_pixbuf()
    if pixbuf is None or pixbuf.get_width() * pixbuf.get_height() > MAX_PIXELS:
        return None
    if pixbuf.get_has_alpha():
        # Pas de transparence en BMP : fond blanc.
        pixbuf = pixbuf.composite_color_simple(
            pixbuf.get_width(), pixbuf.get_height(),
            GdkPixbuf.InterpType.NEAREST, 255, 8, 0xFFFFFF, 0xFFFFFF,
        )
    saved, bmp = pixbuf.save_to_bufferv("bmp", [], [])
    return GLib.Bytes.new(bmp) if saved else None


class Bridge:
    def __init__(self, loop):
        self.loop = loop
        self.serial = 0  # pour ignorer les lectures périmées
        self.idle_checks = 0
        self.clipboard = Gdk.Display.get_default().get_clipboard()
        self.clipboard.connect("changed", self.on_changed)
        self.on_changed(self.clipboard)  # image déjà copiée avant notre démarrage
        GLib.timeout_add_seconds(IDLE_CHECK_SECONDS, self.on_idle_check)

    def on_changed(self, clipboard):
        self.serial += 1
        if clipboard.is_local():
            return
        mimes = clipboard.get_formats().get_mime_types() or []
        source = next((m for m in SOURCE_TYPES if m in mimes), None)
        # Image seule uniquement : avec du texte (navigateur, tableur), on ne touche à rien.
        if source is None or BMP in mimes or any(m.startswith("text/") for m in mimes):
            return
        log(f"image sans BMP ({source}), lecture")
        clipboard.read_async([source], GLib.PRIORITY_DEFAULT, None, self.on_stream, (self.serial, source))

    def on_stream(self, clipboard, result, context):
        try:
            stream, _mime = clipboard.read_finish(result)
        except GLib.Error as error:
            log(f"lecture impossible : {error.message}")
            return
        output = Gio.MemoryOutputStream.new_resizable()
        flags = Gio.OutputStreamSpliceFlags.CLOSE_SOURCE | Gio.OutputStreamSpliceFlags.CLOSE_TARGET
        output.splice_async(stream, flags, GLib.PRIORITY_DEFAULT, None, self.on_data, context)

    def on_data(self, output, result, context):
        serial, source = context
        try:
            output.splice_finish(result)
        except GLib.Error as error:
            log(f"lecture interrompue : {error.message}")
            return
        if serial != self.serial:
            return  # le presse-papiers a changé entre-temps
        original = output.steal_as_bytes()
        bmp = to_bmp(original)
        if bmp is None:
            return
        log(f"republication : {source} {original.get_size()} octets + {BMP} {bmp.get_size()} octets")
        self.clipboard.set_content(
            Gdk.ContentProvider.new_union(
                [
                    Gdk.ContentProvider.new_for_bytes(source, original),
                    Gdk.ContentProvider.new_for_bytes(BMP, bmp),
                ]
            )
        )

    def on_idle_check(self):
        # Deux contrôles sans sdl-freerdp avant l'arrêt : laisse le temps à une session de démarrer.
        self.idle_checks = 0 if freerdp_running() else self.idle_checks + 1
        if self.idle_checks >= 2:
            log("plus de session FreeRDP, arrêt")
            self.loop.quit()
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE


def main():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    lock = open(os.path.join(runtime_dir, "winapps-clipboard-bridge.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # déjà en cours
    if not Gtk.init_check():
        print("winapps-clipboard-bridge: pas d'affichage X11 disponible", file=sys.stderr)
        return 1
    loop = GLib.MainLoop()
    Bridge(loop)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
