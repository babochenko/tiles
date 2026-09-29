# Tiles

A lightweight macOS window manager with edge snapping, linked resizing, layout previews, and haptic feedback.

## Install

1. Open `Tiles.dmg`.
2. Drag **Tiles** into **Applications**.
3. Open Tiles and grant Accessibility permission when macOS asks.

Use the `▦` menu-bar icon to enable **Launch at startup**.

## Create the DMG

```bash
./scripts/package.sh
```

The installer is written to `dist/Tiles.dmg`.

To rebuild from source and install it automatically, replacing an existing installation:

```bash
./scripts/install.sh
```
