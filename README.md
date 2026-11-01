# Filer

Filer is a two-pane file manager for macOS. It is designed to make working between folders easier, with file operations, a built-in terminal and a notes panel in one window.

## Features

- **Two-pane file browsing** — view two folders side by side and navigate each pane independently.
- **Copy and move** — transfer selected files and folders between panes.
- **Drag and drop** — move items between folders and panes, or drag items to the Trash.
- **File management** — create folders, send items to the Trash and undo supported actions.
- **Hidden files** — show or hide hidden files when needed.
- **Built-in terminal** — run shell commands from within Filer.
- **Notes panel** — keep notes alongside your file-browsing workspace. Notes are saved locally on your Mac.

## Requirements

- macOS 13 Ventura or later.

## Download and install

1. Open the **Releases** section of this repository.
2. Download the latest `Filer-*.pkg` installer.
3. Open the downloaded package and follow the Installer steps.
4. Open **Filer** from your Applications folder.

macOS may ask you to grant Filer access to folders or files. Allow the relevant permissions for the locations you want to browse. If access is denied, review **System Settings → Privacy & Security**.

## Notes storage

Filer stores its notes locally at:

```text
~/Library/Application Support/Filer/Notes.txt
```

Notes are not stored in this GitHub repository.

## Signing and notarisation

The currently published build is ad-hoc signed and has not been notarised by Apple. macOS may therefore show a security notice when you first open the installer or application. Developer ID signing and Apple notarisation are recommended before broad public distribution.

## Releases

Download installers from the [Releases](../../releases) page. Each release should include its version number and a summary of changes.
