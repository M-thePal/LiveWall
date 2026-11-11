# LiveWall

A tiny, battery-friendly live wallpaper app for macOS. It plays a video on your desktop, and can set a different video on the lock screen.

~300 lines of Swift, no dependencies, lives in the menu bar (🎞).

## Features

- Loops a muted video behind your desktop icons, on every display and Space
- **Pauses itself** when it can't be seen or isn't worth the power: desktop covered by windows, screen asleep, or running on battery (toggle in the menu)
- **Separate lock screen video**, chosen independently from the desktop one
- Launch at login
- Drop any `.mp4` / `.mov` into `~/Movies/LiveWall` and it shows up in the menu

## Requirements

macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

## Build and install

```bash
./build.sh
cp -R LiveWall.app /Applications/
open /Applications/LiveWall.app
```

The app is ad-hoc signed and not notarized, so the first time macOS may refuse to open it: right-click it ▸ **Open**, or run `xattr -cr /Applications/LiveWall.app`.

## Usage

Click 🎞 in the menu bar:

| Item | What it does |
|---|---|
| video list | Set the desktop wallpaper |
| Lock screen ▸ | Set the lock screen video |
| Open videos folder | Opens `~/Movies/LiveWall` (created on first launch) |
| Choose file… | Use a video from anywhere |
| Pause / Resume | Manual pause |
| Pause on battery | Stop playback when unplugged (on by default) |
| Launch at login | Start with your Mac |

## How the lock screen works

macOS has no public API for a custom lock screen video, and the lock screen shows the system wallpaper. LiveWall therefore registers your video as a custom "aerial" in the wallpaper manifest and points the system wallpaper at it. Your desktop video window sits on top, so the desktop and lock screen can differ.

- Files touched: `~/Library/Application Support/com.apple.wallpaper/aerials/{videos,thumbnails,manifest/entries.json}` and `.../Store/Index.plist`
- Some macOS versions store a separate `Desktop` and `Idle` (lock screen / screen saver) config instead of one `Linked` config. LiveWall writes to all of them, but that layout is untested, so please open an issue if the lock screen doesn't change
- Clips shorter than 30 s are repeated into a longer file first, because the lock screen player freezes at the loop point of very short clips
- To undo, pick any wallpaper in System Settings ▸ Wallpaper
- This relies on undocumented macOS internals. It was developed and tested on macOS 27.2 (Apple Silicon); other versions may not work. If it fails, LiveWall shows an error. Back up `Index.plist` and `entries.json` from that folder first if you want to be safe.
- When LiveWall is paused, the desktop shows the system wallpaper, which is the lock screen video.

## Command line

```bash
LiveWall.app/Contents/MacOS/LiveWall --lock path/to/video.mp4   # set the lock screen and exit
LIVEWALL_DEBUG=1 LiveWall.app/Contents/MacOS/LiveWall           # ignore the "is it visible" pause check
```

## Known limits

- Power state is polled every 10 s instead of using notifications
- Video is decoded at its native resolution; a 4K clip on a 1080p display costs more than it needs to. Re-encode to the display size to save power.
- The build is universal (arm64 + x86_64) but only tested on Apple Silicon
- No notarized release; build from source

## License

MIT, see [LICENSE](LICENSE).
