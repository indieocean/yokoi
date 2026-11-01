# dmgbuild settings for Yokoi's DMG window. Called by scripts/release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=path/Yokoi.app -D icon=path/AppIcon.icns \
#            -D background=assets/dmg/background.tiff "Yokoi 1.2" Yokoi-1.2.dmg
# Icon positions must match scripts/make-dmg-background.py.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

format = "UDZO"
icon = defines["icon"]  # noqa: F821  volume icon, shown when mounted
background = defines["background"]  # noqa: F821  multi-resolution TIFF (1x + 2x)

window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (170, 190),
    "Applications": (490, 190),
}
