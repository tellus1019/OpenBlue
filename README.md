# OpenBlue

OpenBlue is a native macOS application for the original Blue Yeti.

Its goal is reliable, low-latency, local voice processing and a virtual microphone without Logitech G HUB, using Swift and Apple audio frameworks.

## Build and test

An Apple Silicon Mac with Xcode and its command-line tools is required.
The deployment minimum is macOS 14.
Compatibility with other macOS versions has not been established.
There are no external package dependencies.

```sh
bash Scripts/build.sh debug
bash Scripts/build.sh release
bash Scripts/test.sh
```

Build products are written to `.build/products/debug/` and `.build/products/release/`:

- `OpenBlue.app`
- `OpenBlue.driver`

These commands build and test repository artifacts only.
They do not install or remove software, register services, launch the app, capture microphone audio, change the default audio device, or restart macOS.
Bundles are ad-hoc signed for local development and are not notarized for distribution.

## Installation boundary

The expected installation locations are `/Applications/OpenBlue.app` and `/Library/Audio/Plug-Ins/HAL/OpenBlue.driver`.
The repository does not provide installation, removal, service reload, or restart automation.

G HUB audio replacement devices are not selected as Yeti inputs.
OpenBlue uses the original Yeti through the standard macOS USB audio route.

## Audio workflow

1. Connect the original Blue Yeti through the standard macOS USB audio driver.
2. Set the Yeti format to 48 kHz stereo in Audio MIDI Setup when required.
3. Launch OpenBlue and enable processing.
4. Select OpenBlue as the microphone input in another application.
5. Adjust gain from -24 to +12 dB or enable bypass.
6. Keep OpenBlue running while the virtual microphone is in use.

Capture starts when OpenBlue is enabled and an external process uses the virtual microphone input.
OpenBlue excludes its own process when counting input users.
The virtual input supplies silence when matching audio is unavailable.

The meters update at 60 Hz and interpolate over one display interval.
Their display-only peak envelope uses immediate attack and a 200 dB per second release.
Numeric readouts update five times per second.
Meter smoothing does not alter the audio signal.

Gain, bypass, and the selected Yeti UID are saved atomically in `~/Library/Application Support/OpenBlue/settings.json`.
The enable state is not persisted, so each launch starts disabled.
Invalid or newer settings produce a visible error and are not overwritten with defaults.

## API references

- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Apple TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- `CoreAudio/AudioServerPlugIn.h` in the macOS SDK

Apple's sample supplies silence on input.
OpenBlue's loopback and clock bridge are project code.
