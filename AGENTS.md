# Agent Instructions

- After every rebuild, run `./scripts/install.sh` so the latest build replaces `/Applications/Tiles.app` and is launched.
- If the installed app reports that Accessibility access is missing even though Tiles is enabled in System Settings, reset the stale app-specific permission with `tccutil reset Accessibility app.tiles.windowmanager`, relaunch `/Applications/Tiles.app`, then ask the user to enable Tiles again under Privacy & Security → Accessibility. Never reset Accessibility permissions globally.
- Keep `Tests/TilesCoreTests` updated when changing testable snapping, layout, margin, preview, haptic, input, or linked-resize behavior. For non-documentation changes, run `./scripts/test.sh` before `./scripts/install.sh`.

## Current Product Behavior

- Tiles is a menu-bar macOS window manager implemented in `Sources/Tiles/main.swift`, with testable geometry/state in `Sources/TilesCore`.
- Layouts currently support at most three managed windows. One side-snapped window occupies a half, two windows use halves, and three windows use thirds. A fourth edge-snapped window replaces the window at that edge.
- The top snap target is the top 30 points and takes priority at both top corners.
- The right snap target is the rightmost 60 points below the top target.
- The left snap target intentionally avoids the Stage Manager strip. It is a 240×240-point square at the bottom, starting 140 points from the physical left edge. Do not assume the entire left edge is a snap target.
- Starting a mouse sequence inside the leftmost 140 points is intentionally ignored to avoid intercepting Stage Manager interactions.
- Dropping a third window between two tiled windows is supported. The insertion target is within 30 points of their divider, gives haptic feedback, shows an 8-point vertical strip rather than a region preview, inserts the dragged window in the middle, and redistributes all three windows into thirds.
- Existing tiled windows can be reordered through insertion boundaries. External insertion into an already full three-window layout is intentionally not offered.
- Dragging an unmanaged window over the top quarter of an existing tiled window offers replacement. It gives haptic feedback, highlights the target's exact frame, assigns that exact slot to the dragged window, and minimizes the displaced window. Insertion strips and physical screen-edge targets take priority over replacement targets.
- Divider dragging and linked resizing operate only on adjacent windows in the active layout.

## Stage Manager Model

- macOS has no public Stage Manager group identifier. Tiles approximates a group from the set of currently visible standard windows on each physical display.
- A window identity is `(CGWindowID, owner PID)`. Group observations require two stable samples. Exact signatures are restored directly; otherwise a unique Jaccard match of at least 0.5 is reused.
- Layout slots are stored independently per synthetic Stage Manager group and display for the lifetime of the Tiles process. They are not persisted across app restarts.
- All previews, snapping, palette actions, auto-tiling, linked resizing, divider interactions, and AX frame writes must remain scoped to a current `StageGroupContext`.
- `setFrame(_:for:in:)` is the final safety gate: it rejects stale contexts and windows not in the current visible group. Do not bypass it for normal layout operations.
- During an ambiguous group transition, Tiles clears active overlays and refuses frame writes rather than risking changes to a hidden group.
- Visibility comes from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` paired with standard, non-minimized AX windows. Windows centered in the leftmost 140-point Stage Manager strip are excluded as thumbnail candidates.
- The frontmost focused AX window is merged directly into the visibility snapshot because some apps do not provide reliable CG/AX pairing metadata.
- A dragged window is resolved once after movement begins and its identity remains fixed for that mouse sequence. This avoids changing CG matches during longer drags.
- Be extremely careful when relaxing visibility matching: accepting Stage Manager thumbnails can make hidden windows expose divider cursors and can resize those hidden windows.

## Known Limitation: Safari

- Regular Safari is currently unsupported/unreliable. The user confirmed that both menu-based tiling and drag snapping still do not work in Safari.
- Do not state that Safari support is fixed based only on unit tests. Any future Safari work must be verified manually in regular Safari before being called complete.
- Several attempted mitigations are already present: wider CG/AX decoration tolerance, nearest-frame fallback when `AXWindowNumber` is absent, exact-number matching, direct injection of the frontmost focused AX window, and stable dragged-window identity. These did not produce confirmed Safari support.
- Apple Notes was reported to snap to the top but not the sides before the stable-drag-identity change. That last behavior has not yet been manually reconfirmed.
- If Safari support is revisited, collect real diagnostics from the trusted Tiles process rather than continuing to guess. Useful data includes AX focused-window result codes, role/subrole, `AXWindowNumber`, AX position/size, same-PID on-screen CG windows, the selected CG ID, active group signature, and whether the global mouse sequence was ignored.

## Important Implementation Areas

- `Sources/Tiles/main.swift`: AX/CG discovery, Stage Manager visibility snapshots, input monitoring, overlays, frame writes, and app integration.
- `Sources/TilesCore/WindowManagement.swift`: synthetic Stage Manager groups, layout filtering, visible-window matching, and auto-tiling models.
- `Sources/TilesCore/TilingGeometry.swift`: snap zones, Stage Manager strip geometry, insertion targets, slot ordering, margins, and linked layout frames.
- `Tests/TilesCoreTests/WindowManagementTests.swift`: Stage Manager store/layout and CG/AX matching coverage.
- `Tests/TilesCoreTests/TilingGeometryTests.swift`: snap-target, insertion, layout, margin, and Stage Manager strip coverage.
- The current suite contains 106 tests and was passing at commit `e918bb8`.

## Recent Context

- `a60553a`: introduced per-Stage-Manager-group layouts and guarded frame writes.
- `319c613`: retained unnumbered AX windows while actively dragging.
- `cfd20f9`: added insertion between tiled windows.
- `a9a04b0`: rejected hidden Stage Manager thumbnail frame matches.
- `89850eb`, `127df6a`, and `76d82e0`: attempted Safari matching improvements; Safari remained unconfirmed/non-working.
- `e918bb8`: stopped re-resolving the dragged window ID on every mouse-drag event.
