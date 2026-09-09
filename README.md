# OpenBlue
OpenBlue is a native macOS application for the original Blue Yeti.
Its goal is local voice processing and a virtual microphone without Logitech G HUB.

## Development status

The first slice implements capture, gain, bypass, meters, settings persistence,
and a virtual microphone. Installed-hardware acceptance is in progress.
It is not a production release or a complete Blue VO!CE replacement.

The application uses SwiftUI and two HAL audio units. A C AudioServerPlugIn
exposes a stereo input and output at 48 kHz. The application writes processed
audio to the output; other applications read the input. A timestamped buffer
inside the plug-in connects them. No background daemon or external audio
service is installed.

## Build and test

An Apple Silicon Mac with Xcode and its command-line tools is required.
The deployment minimum is macOS 14; current builds are checked with SDK 26.5.
Compatibility with other OS versions has not been established.
There are no external package dependencies.

```sh
bash Scripts/build.sh debug
bash Scripts/build.sh release
bash Scripts/test.sh
```

Build products are in `.build/products/debug/` and `.build/products/release/`:

- `OpenBlue.app`
- `OpenBlue.driver`

These commands only build and test local artifacts. They do not install or
remove software, register services, launch the app, capture a microphone,
change the default audio device, or restart anything.
Bundles are ad-hoc signed for local development, not notarized for distribution.

## Installation boundary

Installation is a separate, explicitly approved operation. The intended
locations are `/Applications/OpenBlue.app` and
`/Library/Audio/Plug-Ins/HAL/OpenBlue.driver`.
The repository provides no installer, uninstaller, service-reload, or reboot
script. Apple's sample documents restarting macOS after installing a HAL
plug-in; save work and perform any restart manually.

G HUB's audio override must not replace the Yeti's standard USB audio route.
OpenBlue deliberately does not select `LogiGamingAudio` replacement devices.
Any change to G HUB is separate from building or installing OpenBlue and may
affect other Logitech peripherals.

## Intended first-slice workflow

1. Connect the original Yeti through the standard macOS USB audio driver.
2. Set its format to 48 kHz stereo in Audio MIDI Setup if needed. OpenBlue does
   not change the hardware format automatically.
3. Open the installed application and explicitly enable OpenBlue. It requests
   microphone access, not access to Documents or other personal folders.
4. Select **OpenBlue** as the microphone input in another application.
5. Adjust gain between -24 and +12 dB, or bypass gain. Peaks above full scale
   are clipped and counted. Bypass does not bypass clock alignment or clipping.
6. Keep OpenBlue running. Closing the window leaves it in the menu bar;
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

Gain, bypass, and the selected Yeti UID are saved atomically in
`~/Library/Application Support/OpenBlue/settings.json`. Enable state is not
persisted; every launch starts disabled. Invalid or newer settings produce a
visible error and are not overwritten with defaults.

## Verification boundaries

Offline tests cover gain and bypass, starvation recovery, clock mismatch of
±1000 ppm with scheduling jitter, timestamped stereo loopback, concurrent
readers, driver property and client lifecycle contracts, and settings integrity.
They do not prove that macOS loads the installed plug-in or that real clients
receive Yeti audio.

On the tested Apple Silicon host running macOS 26.6.2, the installed driver
was discovered and QuickTime recorded and played back Yeti audio. Gain, bypass,
settings after app restart, simultaneous QuickTime and Meet input, continued
Meet input after QuickTime quit, and capture stopping after Meet closed were
verified interactively.

With the app window visible and one external input process active, sampled
app CPU usage was approximately 10–14% of one core and physical memory footprint
was approximately 33–37 MB. The displayed underrun and overrun counters stayed
at zero during the observation. One dual-input correlation measurement found
55.125 ms additional delay relative to direct Yeti input (correlation 0.90868,
0.125 ms search grid). This is a software-path comparison, not acoustic
end-to-end latency or a guarantee for other hardware and workloads.

Reconnect acceptance failed in a hardware test and is under investigation.
Numeric display-cadence measurement remains pending.
The user accepted the meter's visual response; its 60 Hz timer target is not
an independently measured rendering frame rate.

## API references

- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Apple TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- `CoreAudio/AudioServerPlugIn.h` in the macOS SDK

Apple's sample supplies silence on input. OpenBlue's loopback and clock bridge
are project code, not an Apple-provided loopback implementation.
