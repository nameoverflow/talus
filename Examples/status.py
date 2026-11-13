#!/usr/bin/env python3
"""Example: render a whole Talus menu item from the supplied status JSON."""
import json
import os

state = json.loads(os.environ.get("TALUS_STATUS_JSON", "{}"))
spaces = state.get("spaces") or []
labels = []
for index, space in enumerate(spaces, 1):
    label = str(index) + ("•" if space.get("isFullscreen") else "")
    if space.get("isCurrent"):
        labels.append(f"<fc=#10201E,#89CFC2> {label} </fc>")
    else:
        labels.append(label)
layout = "Paused" if state.get("paused") else state.get("layout", "?")
# Layout is produced by Talus; replace angle brackets in external data before
# placing it in markup to prevent it from becoming a formatting tag.
layout = str(layout).replace("<", "‹").replace(">", "›")
print(" ".join(labels) + "  <fc=#89CFC2>" + layout + "</fc>")
