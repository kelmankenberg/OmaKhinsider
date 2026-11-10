# OmaKhinsider

An Omarchy Quickshell plugin for managing KHInsider soundtrack downloads and playlists.

The first increment provides an installable bar widget and panel, with a persistent album URL queue and playlist definitions. The panel can open KHInsider in the system default browser, but does not inspect pages, download audio, import from a browser extension, or play music yet. Those features need the companion/helper integration planned for later milestones.

## Validate and test

```sh
make validate
make test
```

The plugin stores its local queue and playlist definitions in
`$XDG_CONFIG_HOME/omakhinsider.json` (or `~/.config/omakhinsider.json` when
`XDG_CONFIG_HOME` is unset). Writes are atomic. Invalid data is reported and
left untouched.

## Try it locally

Omarchy rejects symlinks inside plugin directories. Copy the project into the
user plugin directory, then validate, enable, and place the widget:

```sh
PLUGIN_ID=kelmankenberg.omakhinsider
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
mkdir -p "$PLUGIN_DIR"
cp -a BarWidget.qml Panel.qml Model.js manifest.json i18n "$PLUGIN_DIR/"
omarchy plugin validate "$PLUGIN_DIR"
omarchy plugin enable "$PLUGIN_ID"
omarchy bar put "$PLUGIN_ID"
```

Open the panel from the bar. It can also be summoned with
`omarchy-shell shell summon kelmankenberg.omakhinsider '{}'`.

## Next milestones

- Inspect albums using an approved browser-assisted access path.
- Add the Chromium browser companion and local queue bridge, then Firefox support.
- Download albums and playlist tracks with resumable state.
- Play downloaded files and generated playlist files through a local media player.
