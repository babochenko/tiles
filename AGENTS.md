# Agent Instructions

- After every rebuild, run `./scripts/install.sh` so the latest build replaces `/Applications/Tiles.app` and is launched.
- If the installed app reports that Accessibility access is missing even though Tiles is enabled in System Settings, reset the stale app-specific permission with `tccutil reset Accessibility dev.babochenko.tiles`, relaunch `/Applications/Tiles.app`, then ask the user to enable Tiles again under Privacy & Security → Accessibility. Never reset Accessibility permissions globally.
