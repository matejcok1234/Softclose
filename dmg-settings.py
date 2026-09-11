# Layout for the install window, read by dmgbuild.
#
# dmgbuild writes the .DS_Store directly rather than asking the Finder to
# arrange the window over AppleScript. That matters: the Finder route needs
# Automation permission, behaves differently when the screen is locked, and
# hangs often enough to be a poor fit for a release script.
#
# Coordinates are measured from the top-left of the window's content area, and
# line up with the glow and the ring drawn into the background image.

import os.path

application = defines.get("app", "build/Softclose.app")
appname = os.path.basename(application)

format = "UDZO"
size = None
files = [application]
symlinks = {"Applications": "/Applications"}

background = "build/dmg-background.tiff"      # carries 1x and 2x
# dmgbuild's window_rect is the window frame, title bar included, so it has to
# be 28pt taller than the 600x400 background for the content area to match it.
# Set equal and the background overflows by exactly the title bar's height,
# which the Finder answers with a scrollbar.
window_rect = ((240, 180), (600, 428))
default_view = "icon-view"
icon_size = 128
text_size = 12
icon_locations = {
    appname: (165, 165),        # over the glow
    "Applications": (435, 165),  # inside the ring
}

# Nothing but the two icons: no toolbar, sidebar, or status bar.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False
