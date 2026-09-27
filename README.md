# OpenBlue
OpenBlue is a native macOS application for the original Blue Yeti.
Its goal is local voice processing and a virtual microphone without Logitech G HUB.

## Build and test

An Apple Silicon Mac with Xcode 26 or later and its command-line tools is required.
The deployment minimum is macOS 15; current builds are checked with SDK 27.0.
The app is built with the OpenBlue Xcode scheme; internal modules use local Swift packages.
Compatibility with other OS versions has not been established.
There are no external package dependencies. Advanced noise reduction bundles a
DPDFNet8 HR model and runs locally with Core ML and Accelerate. Third-party
notices are available from **About OpenBlue → Third-Party Licenses**.

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
3. Open the installed application. OpenBlue starts enabled in the menu bar,
   without a window or Dock icon. It requests microphone access, not access to
   Documents or other personal folders. Choose **Show OpenBlue** from the menu
   bar to display the processing window and Dock icon.
4. Select **OpenBlue** as the microphone input in another application.
5. Adjust **Input gain** from -24 to +12 dB and **Master output** from -80
   to 0 dB. Master output and **Mute output** act after the limiter. Expand a
   processor to adjust its parameters and switch it on or off. Factory presets
   have individual settings; new user presets start with processors disabled.
   Noise reduction offers **Standard** and **Advanced** methods. Advanced NR
   has a separate maximum-reduction control and needs no network connection.
   See [Processing controls](Documentation/Processing.md).
6. Use **Bypass all processing** to compare with the unprocessed signal.
   Master output and mute remain active. Standard NR adds 992 frames (20.67 ms
   at 48 kHz). Advanced NR adds 2880 frames (60 ms) of DSP delay plus worker
   buffering: 90 ms total with 128-frame output callbacks. The processing window
   displays the active total. Each method retains its delay during bypass;
   device and clock-buffer delay are additional. Clock alignment and final
   clipping remain active.
7. Keep OpenBlue running. Closing the window also removes its Dock icon while
   leaving it in the menu bar; disabling or quitting it stops capture. Turn on
   **Launch at login** under **Startup** in the processing window to start it
   automatically at login, without a window or Dock icon. This option is off
   until registered; macOS may require approval in Login Items settings.

Capture runs only when enabled and an external input process is using the virtual
device. Activity comes from Core Audio process objects and input activity
notifications, excluding OpenBlue itself. The displayed count is processes,
not windows or browser tabs. Do not select its output for system playback:
it is the feed into the virtual microphone, not a speaker.
The virtual input supplies silence when no matching audio is available.

While the processing window is visible, meter bars target 60 updates per second
with three-frame linear interpolation in both directions. Input and output bars
use the latest rendered block peaks; their numeric readouts use an immediate-attack,
200 dB/second release envelope and update five times per second. Display polling
stops when the window is not visible. These are level indicators, not calibrated
loudness meters. Meter smoothing does not alter audio.

## Presets and recovery

Choose a preset above the processing controls. The factory library includes
**AM**, **Bass Boost**, **Broadcaster 1**, **Broadcaster 2**, **Classic Radio**,
**Crisp and Warm**, **FM**, **High Voice - Loud**, **High Voice - Soft**,
**Low Voice - Loud**, **Low Voice - Soft**, and **Warm and Vintage**.
These use OpenBlue's processing; they do not reproduce G HUB's output exactly.
The initial selection is **Broadcaster 1**.

Factory originals cannot be overwritten, renamed, or deleted. Editing gain,
bypass, or a processor first creates an editable user copy; further edits save
to that copy automatically. **New** creates a user preset with default values
and processors disabled. **Duplicate** copies the selected preset's values.
Enter a unique name and choose **Save**. **Rename** and **Delete** apply to user
presets; deletion asks for confirmation and selects **Broadcaster 1**.

Switching presets within the same NR method updates processing without restarting
the engine. Changing between Standard and Advanced rebuilds the audio path.
The NR method and advanced maximum reduction are saved with each user preset;
existing schema 4 presets without these fields retain their values and use
Standard. Factory originals remain Standard. The selected Yeti is shared by all
presets. User presets,
factory selection and catalog revision, and Yeti UID are saved atomically in
`~/Library/Application Support/OpenBlue/settings.json` using schema 4.
Enable state is not persisted; every launch starts enabled, subject to microphone
permission and valid settings.

Valid schema 1, 2, and 3 settings reset their old test presets to **Broadcaster 1**
and retain device selection. Before the first save, the original bytes are
preserved in `settings.json.schema1-backup`, `settings.json.schema2-backup`, or
`settings.json.schema3-backup`. User copies in schema 4 store their complete
values and source revision independently of the factory originals.
If that backup name already contains different data, the new backup gets a unique
suffix so both originals remain available.

**Back Up** exports the user preset library, selection, factory catalog revision,
and device setting to JSON. **Restore** validates a backup before asking to
replace the current library. It preserves the previous settings file as
`settings.json.before-restore-<unique ID>.json`, then restores the backup and
disables audio. Enable OpenBlue again when ready. Restore replaces the library;
it does not merge presets. Restoring legacy files performs the same preset
reset described above. Unsupported catalog revisions are preserved as errors.

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
