# Processing controls

OpenBlue processes 48 kHz stereo locally. These algorithms define OpenBlue's
behavior; they do not reproduce Logitech's undocumented internal processing.

## Signal path

Input meter → input gain → high-pass filter → noise reduction → noise gate →
three-band parametric EQ → de-esser → de-popper → compressor → output gain →
limiter → full-scale clip → output meter.

Input gain is software gain. It does not move the Yeti's hardware gain control.
The input meter reads before input gain, so increasing gain will not increase
that meter. The output meter reads the final signal. Compressor and limiter
reduction meters display attenuation in dB, excluding compressor makeup gain.
Numeric readouts target five updates per second.

All new processors default to disabled. Each switch bypasses that processor;
the whole-chain bypass also bypasses input and output gain. The chain retains
608 frames (12.67 ms) of delay in every configuration, including bypass, to
align transitions. Device, application, and clock-buffer delay is additional.
Final clipping to ±1 remains active in bypass and is counted in diagnostics.

## Behavior

- **High-pass filter:** second-order Butterworth; frequency is the −3 dB point.
- **Noise reduction:** 512-point spectral suppression with 256-frame hops.
  Noise floor specifies broadband white-noise RMS level, not a peak-meter
  threshold. It is fixed by the user; there is no automatic noise learning.
  Bins near or below this floor are attenuated up to maximum reduction.
  Strong spectral components are retained. Release controls recovery after
  attenuation. Excessive floor or reduction can affect quiet speech and create
  audible modulation; listening evaluation is required.
- **Noise gate:** linked stereo peak detector with 3 dB hysteresis. Attack
  opens the gate; hold and release delay and smooth closing. Maximum reduction
  sets the closed level. It is not necessarily absolute silence.
- **Parametric EQ:** three peaking bands. Frequency is the center; gain boosts
  or cuts there. Higher Q narrows the affected band.
- **De-esser:** reduces the high-pass component above the selected frequency
  when that component exceeds threshold. Maximum reduction caps its attenuation.
- **De-popper:** applies the same dynamic reduction to a low-pass component.
  It responds to level, not speech recognition, and can affect low voices.
  Both band processors have second-order Butterworth extraction filters;
  the threshold refers to that filtered band, not the full-band input meter.
  Audio attenuation uses a separate first-order complementary low/high split,
  so recombining an attenuated target band does not boost steady-state gain.
- **Compressor:** linked peak compression with a 6 dB soft knee. Ratio describes
  the steady-state slope above the knee. Makeup gain follows compression.
- **Limiter:** linked sample-peak limiting with 96 frames (2 ms) of lookahead.
  It is not a true-peak limiter. Ceiling changes follow a 5 ms smoothed value.
  Fully enabled limiting follows that changing ceiling; during enable/disable
  crossfades the dry contribution can exceed it. Full-scale clipping remains.

Peak detectors for gate, compressor, and band reduction have instantaneous rise
and a 20 ms exponential decay before the gain envelope. Attack and release are
the gain envelope's exponential time constants in dB, not the time to reach
the final value. They do not remove all possible signal-dependent distortion.

Enable and bypass changes blend over a 5 ms time constant, and filter
coefficients follow a 10 ms time constant. Gain changes are smoothed as well.
The audio callback receives a complete prepared snapshot at block boundaries.
Audio histories clear on stop/start and input starvation; settings survive.
Output resumes through the fixed delay after a discontinuity.

## Parameter reference

Ranges, defaults, and steps below match the shared DSP/UI parameter table.
A switch uses 0 for disabled and 1 for enabled.

| Processor | Parameter | Unit | Minimum | Maximum | Default | Step |
| --- | --- | --- | --- | --- | --- | --- |
| Gain / bypass | Input gain | dB | -24 | 12 | 0 | 0.5 |
| Gain / bypass | Bypass processing | switch | 0 | 1 | 0 | 1 |
| Gain / bypass | Output gain | dB | -24 | 12 | 0 | 0.5 |
| HPF | High-pass filter | switch | 0 | 1 | 0 | 1 |
| HPF | Frequency | Hz | 20 | 400 | 80 | 1 |
| Noise reduction | Noise reduction | switch | 0 | 1 | 0 | 1 |
| Noise reduction | Noise floor (RMS) | dBFS | -80 | -20 | -55 | 1 |
| Noise reduction | Maximum reduction | dB | 0 | 40 | 12 | 1 |
| Noise reduction | Release | ms | 20 | 1000 | 150 | 10 |
| Noise gate | Noise gate | switch | 0 | 1 | 0 | 1 |
| Noise gate | Threshold | dBFS | -80 | -6 | -45 | 1 |
| Noise gate | Attack | ms | 0.1 | 200 | 5 | 0.1 |
| Noise gate | Hold | ms | 0 | 200 | 50 | 1 |
| Noise gate | Release | ms | 10 | 1000 | 150 | 10 |
| Noise gate | Maximum reduction | dB | 0 | 80 | 60 | 1 |
| EQ | Parametric EQ | switch | 0 | 1 | 0 | 1 |
| EQ | Low frequency | Hz | 20 | 500 | 200 | 1 |
| EQ | Low gain | dB | -12 | 12 | 0 | 0.5 |
| EQ | Low Q | Q | 0.5 | 10 | 1 | 0.1 |
| EQ | Mid frequency | Hz | 400 | 5000 | 1500 | 10 |
| EQ | Mid gain | dB | -12 | 12 | 0 | 0.5 |
| EQ | Mid Q | Q | 0.5 | 10 | 1 | 0.1 |
| EQ | High frequency | Hz | 1000 | 12000 | 5000 | 10 |
| EQ | High gain | dB | -12 | 12 | 0 | 0.5 |
| EQ | High Q | Q | 0.5 | 10 | 1 | 0.1 |
| De-esser | De-esser | switch | 0 | 1 | 0 | 1 |
| De-esser | Frequency | Hz | 1000 | 10000 | 6000 | 10 |
| De-esser | Threshold | dBFS | -50 | 0 | -25 | 1 |
| De-esser | Maximum reduction | dB | 0 | 30 | 12 | 1 |
| De-esser | Attack | ms | 0.1 | 200 | 2 | 0.1 |
| De-esser | Release | ms | 20 | 1000 | 100 | 10 |
| De-popper | De-popper | switch | 0 | 1 | 0 | 1 |
| De-popper | Frequency | Hz | 60 | 1000 | 150 | 1 |
| De-popper | Threshold | dBFS | -50 | 0 | -25 | 1 |
| De-popper | Maximum reduction | dB | 0 | 30 | 12 | 1 |
| De-popper | Attack | ms | 0.1 | 200 | 1 | 0.1 |
| De-popper | Release | ms | 20 | 1000 | 100 | 10 |
| Compressor | Compressor | switch | 0 | 1 | 0 | 1 |
| Compressor | Threshold | dBFS | -40 | 0 | -18 | 1 |
| Compressor | Ratio | :1 | 1 | 20 | 3 | 0.1 |
| Compressor | Attack | ms | 0.1 | 200 | 10 | 0.1 |
| Compressor | Release | ms | 50 | 1000 | 250 | 10 |
| Compressor | Makeup gain | dB | -12 | 12 | 0 | 0.5 |
| Limiter | Limiter | switch | 0 | 1 | 0 | 1 |
| Limiter | Ceiling | dBFS | -12 | 0 | -1 | 0.1 |
| Limiter | Release | ms | 10 | 500 | 100 | 1 |

## Storage and verification

Settings use schema 2 and are saved atomically to a single settings document.
Schema-1 migration preserves the original gain, bypass, and Yeti UID and backs
up the exact source document before its first replacement. Incomplete,
out-of-range, malformed, or unknown-version settings produce an error without
overwriting the source. Launch always starts capture disabled.

The automated signal tests use analytical filter responses, level steps,
impulses, independent stereo signals, and fixed-seed noise. Their passing
results establish the tested numerical behavior, not natural speech quality.
The second slice is accepted for functional behavior. Sound quality is not yet
satisfactory, and quality improvements and runtime optimization remain follow-up
work before version 1.0. This is not a final sound-quality or performance sign-off.

## Implementation references

- [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)
- [Faust filters library](https://faustlibraries.grame.fr/libs/filters/)
- [Apple vDSP FFT](https://developer.apple.com/documentation/accelerate/vdsp_fft_zip)
- [Apple Fourier transform guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/UsingFourierTransforms/UsingFourierTransforms.html)
