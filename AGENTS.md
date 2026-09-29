# Agent Instructions

- After every rebuild, run `./scripts/install.sh` so the latest build replaces `/Applications/Tiles.app` and is launched.
- If the installed app reports that Accessibility access is missing even though Tiles is enabled in System Settings, reset the stale app-specific permission with `tccutil reset Accessibility app.tiles.windowmanager`, relaunch `/Applications/Tiles.app`, then ask the user to enable Tiles again under Privacy & Security → Accessibility. Never reset Accessibility permissions globally.
- Keep `Tests/TilesCoreTests` updated when changing testable snapping, layout, margin, preview, haptic, input, or linked-resize behavior. The manual test entry point is `./scripts/test.sh`.
