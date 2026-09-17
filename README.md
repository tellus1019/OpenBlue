# OpenBlue
OpenBlue is a native macOS application for the original Blue Yeti.
Its goal is local voice processing and a virtual microphone without Logitech G HUB.

## Build and test

An Apple Silicon Mac with Xcode and its command-line tools is required.
The deployment minimum is macOS 14; current builds are checked with SDK 26.5.
Compatibility with other OS versions has not been established.
There are no external package dependencies.

```sh
bash Scripts/build.sh debug
bash Scripts/build.sh release
bash Scripts/test.sh
bash Scripts/benchmark.sh
```

Build products are in `.build/products/debug/` and `.build/products/release/`:

- `OpenBlue.app`
- `OpenBlue.driver`

These commands only build and test local artifacts. They do not install or
remove software, register services, launch the app, capture a microphone,
change the default audio device, or restart anything.
Bundles are ad-hoc signed for local development, not notarized for distribution.

## Installation boundary

Installation is separate from building and testing. The supported locations
are `/Applications/OpenBlue.app` and
`/Library/Audio/Plug-Ins/HAL/OpenBlue.driver`.
The repository provides no installer, uninstaller, service-reload, or reboot
script. Apple's sample documents restarting macOS after installing a HAL
plug-in; save work and perform any restart manually.

G HUB's audio override must not replace the Yeti's standard USB audio route.
OpenBlue deliberately does not select `LogiGamingAudio` replacement devices.
Any change to G HUB is separate from building or installing OpenBlue and may
affect other Logitech peripherals.

## Processing workflow

1. Connect the original Yeti through the standard macOS USB audio driver.
2. Set its format to 48 kHz stereo in Audio MIDI Setup if needed. OpenBlue does
   not change the hardware format automatically.
3. Open the installed application and explicitly enable OpenBlue. It requests
   microphone access, not access to Documents or other personal folders.
4. Select **OpenBlue** as the microphone input in another application.
5. Adjust input and output gain between -24 and +12 dB. Expand a processor
   to adjust its parameters and use its switch to enable it. All new processors
   start disabled. See [Processing controls](Documentation/Processing.md).
6. Use **Bypass all processing** to compare with the unprocessed signal.
   The chain adds 608 frames (12.67 ms at 48 kHz), including when bypassed.
   Bypass retains clock alignment, fixed delay, and final full-scale clipping.
7. Keep OpenBlue running. Closing the window leaves it in the menu bar;
   disabling or quitting it stops capture. It does not launch at login.

Capture runs only when enabled and an external input process is using the virtual
device. Activity comes from Core Audio process objects and input activity
notifications, excluding OpenBlue itself. The displayed count is processes,
not windows or browser tabs. Do not select its output for system playback:
it is the feed into the virtual microphone, not a speaker.
The virtual input supplies silence when no matching audio is available.

Meters target 60 updates per second with one-frame linear interpolation.
Their display-only peak envelope has immediate attack and a 200 dB/second
release; numeric readouts update five times per second. These are level
indicators, not calibrated loudness meters. Meter smoothing does not alter audio.

## Presets and recovery

Choose a preset above the processing controls. **New** starts with the default
processing values; **Duplicate** copies every value from the selected preset.
Enter a unique name and choose **Save**. **Rename** changes the selected name;
**Delete** asks for confirmation and selects the first remaining preset.
The last preset cannot be deleted.

Edits to gain, bypass, and processor controls are saved automatically to the
selected preset. Switching presets applies all of its processing values together
without restarting the audio engine. The selected Yeti is shared by all presets.

Presets, selection, and Yeti UID are saved atomically in
`~/Library/Application Support/OpenBlue/settings.json`. Enable state is not
persisted; every launch starts disabled. Schema 1 and schema 2 migrate to schema 3
as a single **Current Settings** preset, preserving existing values and device
selection. Schema-1 processors start disabled with output gain at 0 dB.
The first save preserves the original bytes in `settings.json.schema1-backup`
or `settings.json.schema2-backup` before writing schema 3.

**Back Up** exports the entire preset library, selection, and device setting to
a JSON file. **Restore** validates a backup before asking to replace the current
library. It preserves the previous settings file as
`settings.json.before-restore-<unique ID>.json`, then restores the backup and
disables audio. Enable OpenBlue again when ready. Restore replaces the library;
it does not merge presets. Legacy settings files can also be restored.

Invalid or newer settings show an error and are not overwritten by ordinary
saving. Use **Restore** to recover a known-good backup, or **Settings Folder** to
locate the preserved file. For a newer schema, use a compatible OpenBlue version.
If no valid backup exists, quit OpenBlue, keep a copy of the original outside the
active settings path, and relaunch to create defaults. Never delete the only copy
of a damaged or newer configuration.

## API references

- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Apple TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- `CoreAudio/AudioServerPlugIn.h` in the macOS SDK

Apple's sample supplies silence on input. OpenBlue's loopback and clock bridge
are project code, not an Apple-provided loopback implementation.
