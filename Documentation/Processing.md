# Processing controls

OpenBlue processes 48 kHz stereo locally. These algorithms define OpenBlue's
behavior; they do not reproduce Logitech's undocumented internal processing.

## Signal path

Input meter → input gain → high-pass filter → noise reduction → noise gate →
three-band parametric EQ → de-esser → de-popper → compressor pre gain →
compression → compressor post gain → limiter boost → limiter → master output
and mute → full-scale clip → output meter.

Input gain is software gain. It does not move the Yeti's hardware gain control.
The input meter reads before input gain. The output meter reads the final signal.
Reduction meters show attenuation in dB, excluding independent gain controls.
The band reduction meters show center-frequency attenuation; their detector
curves show the selected frequency and width, not the current output spectrum.
Numeric readouts target five updates per second.

A new user preset starts with all processors disabled. Factory presets have
individual processing settings; the initial selection is Broadcaster 1.
Each processor switch bypasses that processor and its associated gain controls.
Whole-chain bypass skips input gain and all processors. Master output and mute
remain active after bypass. Standard NR retains 992 frames (20.67 ms) of delay:
512 frames for spectral processing and 480 frames for limiter lookahead.
Advanced NR retains 2880 frames (60 ms) in the DSP plus a bounded worker buffer.
The buffer is the output callback size rounded up to 480 frames, plus 960 frames;
for 128-frame callbacks the total is 4320 frames (90 ms).
The processing window shows the active total. Turning NR off or bypassing preserves
that mode's delay. Switching methods rebuilds the audio path and clears its history.
Device and clock-buffer delay is additional.
Final clipping to ±1 remains active and is counted in diagnostics.

## Behavior

- **High-pass filter:** second-order Butterworth; frequency is the −3 dB point.
- **Standard noise reduction:** 512-point spectral suppression with 256-frame hops.
  Minima-controlled candidates initialize a separate noise estimate in each bin.
  A fixed-prior speech-presence estimator then tracks background independently
  of the suppression gain, with a bounded update during sustained high speech
  probability. DC and Nyquist use real-valued likelihoods. A decision-directed
  Wiener gain uses matched frequency averages of signal and noise power.
  Onset protection also requires current-frame energy, so stale speech energy
  cannot keep a bin open after a phrase ends. Gain smoothing and recovery vary
  continuously with speech probability. Stereo channels share the stronger
  bin's gain to preserve balance. Digital silence does not enter the noise statistics.
  Sensitivity increases attenuation where speech is uncertain; Bias raises the
  estimated noise power for suppression without changing background learning.
  Maximum reduction limits each bin's attenuation.
  Release controls recovery, with faster recovery for likely speech onsets.
  After reset, suppression stays off for 256 ms of non-silent spectral frames
  and ramps in over the following 256 ms while noise statistics accumulate.
  Prominent tonal components are excluded from initialization, including some
  tonal noise. This is a statistical suppressor, not speech recognition: strong reduction can affect
  quiet speech, and nonstationary noise may remain.
- **Advanced noise reduction:** the bundled DPDFNet8 HR FP32 model processes
  48 kHz audio with 960-point transforms and 480-frame hops. Core ML runs the
  optimized recurrent model on the CPU; Accelerate handles real DFTs. The two
  channels retain independent model states. No network service or model download
  is required. Maximum reduction blends the aligned original with the enhanced
  signal using an original-signal fraction of `10^(-dB/20)`. At 0 dB the original
  is retained; larger values retain less residual sound. This is a blend-based
  limit for removed components, not an absolute per-bin or per-sample amplitude
  guarantee. Changes are smoothed. Standard NR's sensitivity, bias and release
  remain saved but do not affect the advanced method.
- **Noise gate:** linked stereo peak detector with 3 dB hysteresis. Attack
  opens the gate; hold and release delay and smooth closing. Maximum reduction
  sets the closed level. It is not necessarily absolute silence.
- **Parametric EQ:** three peaking bands. Frequency is the center; gain boosts
  or cuts there. Higher Q narrows the affected band.
- **De-esser and de-popper:** a normalized band-pass detector controls dynamic
  bell attenuation at the selected center frequency. Higher Q narrows both
  detection and attenuation. Threshold refers to the filtered band, not the
  input meter. Maximum reduction caps center-frequency attenuation. A
  topology-preserving state-variable filter maintains unity gain when no
  attenuation is required. These processors respond to level, not recognized
  consonants, and can affect wanted speech in the selected band.
- **Compressor:** linked peak compression with a 6 dB soft knee. Pre gain changes
  the level entering both detector and audio processing; Post gain follows
  compression. Ratio describes the steady-state slope above the knee.
- **Limiter:** linked sample-peak limiting with 480 frames (10 ms) of lookahead.
  Boost precedes detection and limiting. Attack selects a 0–10 ms advance window
  and gain descent; zero gives immediate gain reduction. A final sample bound
  enforces the ceiling when limiting is fully enabled. It is not a true-peak
  limiter. Ceiling changes follow a 5 ms smoothed value. During enable/disable
  crossfades the dry contribution can exceed the ceiling. Full-scale clipping
  remains after Master output.

Peak detectors for gate, compressor, and band reduction have instantaneous rise
and a 20 ms exponential decay before the gain envelope. Their attack and release
are exponential time constants in dB; zero attack is instantaneous. They do not
remove all possible signal-dependent distortion.

Individually disabled processors stop updating their processing state after
fade-out, while delay buffers continue advancing. Re-enabling a sleeping
processor initializes it with the current settings and prepares it before
fading in: 768 frames (16 ms) for standard NR, 2400 frames (50 ms) for advanced NR,
481 frames (about 10 ms) for
the limiter, and 2400 frames (50 ms) for the other processors. Standard NR's statistics
continue to accumulate during its subsequent suppression startup period.
During preparation audio bypasses that processor without changing chain delay.

Processor crossfades and whole-chain bypass changes use a 5 ms time constant.
Active filter coefficients follow a 10 ms time constant; waking filters start
with current coefficients. Independent gain controls and mute are smoothed.
Whole-chain bypass suspends advanced neural inference after fading out; other
individually enabled processors keep running. Model loading and warm-up happen
off the UI thread, and inference runs on a dedicated non-realtime worker.
The audio callback only exchanges samples through preallocated bounded rings;
it never waits for inference. Processing receives a complete prepared parameter
snapshot at block boundaries. A model error, missed worker deadline, or input
starvation in advanced mode emits silence and enters the engine's recovery path;
it does not fall back to unprocessed audio. Histories clear on rebuild; settings
survive. Standard mode clears its history and resumes through its fixed delay
after input starvation.

Each preset holds separate Standard NR parameters and an Advanced maximum
reduction. Factory presets use 40 dB for Advanced NR. Switching methods retains
both sets of values and does not create a user copy or enable a disabled processor.
The method choice is saved per preset; factory choices are stored separately from
the immutable factory values. Changing a parameter or toggle on a factory preset
creates a user copy with both sets of values and the current method.
Existing schema 4 presets without NR fields load as Standard with an advanced
maximum reduction of 40 dB. Missing factory method choices default to Standard;
existing user presets retain their saved method and values.
Switching presets within the same method updates
parameters without rebuilding; switching between methods rebuilds the engine.
Third-party notices are bundled under `ThirdPartyLicenses` and are accessible
from **About OpenBlue → Third-Party Licenses** in a read-only, scrollable
view within the app. The text can be selected and copied.

## Parameter reference

Ranges, defaults, and steps below match the shared DSP/UI parameter table.
These defaults apply to new user presets. A switch uses 0 for disabled and 1 for enabled.

| Processor | Parameter | Unit | Minimum | Maximum | Default | Step |
| --- | --- | --- | --- | --- | --- | --- |
| Gain / bypass | Input gain | dB | -24 | 12 | 0 | 0.5 |
| Gain / bypass | Bypass processing | switch | 0 | 1 | 0 | 1 |
| Gain / bypass | Master output | dB | -80 | 0 | 0 | 0.5 |
| Gain / bypass | Mute output | switch | 0 | 1 | 0 | 1 |
| HPF | High-pass filter | switch | 0 | 1 | 0 | 1 |
| HPF | Frequency | Hz | 20 | 400 | 80 | 1 |
| Noise reduction | Noise reduction | switch | 0 | 1 | 0 | 1 |
| Noise reduction | Sensitivity | dB | 0 | 40 | 6 | 1 |
| Noise reduction | Bias | dB | 0 | 5 | 1 | 0.25 |
| Noise reduction | Maximum reduction | dB | 0 | 60 | 12 | 1 |
| Noise reduction | Release | ms | 0 | 1000 | 150 | 10 |
| Advanced NR | Maximum reduction | dB | 0 | 60 | 40 | 1 |
| Noise gate | Noise gate | switch | 0 | 1 | 0 | 1 |
| Noise gate | Threshold | dBFS | -80 | -6 | -45 | 1 |
| Noise gate | Attack | ms | 0 | 200 | 5 | 0.1 |
| Noise gate | Hold | ms | 0 | 200 | 50 | 1 |
| Noise gate | Release | ms | 10 | 1000 | 150 | 10 |
| Noise gate | Maximum reduction | dB | 0 | 80 | 60 | 1 |
| EQ | Parametric EQ | switch | 0 | 1 | 0 | 1 |
| EQ | Low frequency | Hz | 5 | 500 | 200 | 1 |
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
| De-esser | Width | Q | 0.25 | 20 | 2 | 0.25 |
| De-esser | Threshold | dBFS | -50 | 0 | -25 | 1 |
| De-esser | Maximum reduction | dB | 0 | 60 | 12 | 1 |
| De-esser | Attack | ms | 0 | 200 | 2 | 0.1 |
| De-esser | Release | ms | 20 | 1000 | 100 | 10 |
| De-popper | De-popper | switch | 0 | 1 | 0 | 1 |
| De-popper | Frequency | Hz | 60 | 1000 | 150 | 1 |
| De-popper | Width | Q | 0.25 | 20 | 1 | 0.25 |
| De-popper | Threshold | dBFS | -50 | 0 | -25 | 1 |
| De-popper | Maximum reduction | dB | 0 | 60 | 12 | 1 |
| De-popper | Attack | ms | 0 | 200 | 1 | 0.1 |
| De-popper | Release | ms | 20 | 1000 | 100 | 10 |
| Compressor | Compressor | switch | 0 | 1 | 0 | 1 |
| Compressor | Pre gain | dB | -12 | 12 | 0 | 0.5 |
| Compressor | Threshold | dBFS | -40 | 0 | -18 | 1 |
| Compressor | Ratio | :1 | 1 | 20 | 3 | 0.1 |
| Compressor | Attack | ms | 0 | 200 | 10 | 0.1 |
| Compressor | Release | ms | 50 | 1000 | 250 | 10 |
| Compressor | Post gain | dB | -12 | 12 | 0 | 0.5 |
| Limiter | Limiter | switch | 0 | 1 | 0 | 1 |
| Limiter | Boost | dB | -20 | 20 | 0 | 0.5 |
| Limiter | Attack | ms | 0 | 10 | 2 | 0.1 |
| Limiter | Ceiling | dBFS | -12 | 0 | -1 | 0.1 |
| Limiter | Release | ms | 10 | 500 | 100 | 1 |

## Storage

Schema 4 stores user presets, factory NR method choices, factory catalog revision,
selection, and shared Yeti UID atomically. Backups include these method choices.
The 13 factory originals are bundled and cannot be renamed,
deleted, or overwritten. The first parameter edit creates one editable user
copy; subsequent edits update that copy. Method selection and writes of unchanged
values do not create copies. User copies retain their complete
values and source factory ID/revision. Deleting a user preset selects
Broadcaster 1. New and Duplicate explicitly create user presets.
Flat provides an unprocessed starting point with all processors disabled, input
and master output gains at 0 dB, and mute and bypass off.
Catalog revision 2 adds Flat while retaining revision 1 settings, user presets,
and selection. Existing user presets named Flat remain in the User group.

Valid schema 1–3 settings reset their legacy test presets to Broadcaster 1 and
retain device selection. Their original bytes are backed up before replacement.
If a migration backup already contains different data, a unique suffix preserves
both originals rather than replacing the earlier backup.
Invalid documents, newer schemas, and unsupported catalog revisions are preserved.
Backup exports the user library and selection together with the catalog revision
and device setting. Restore validates the replacement and preserves the previous
document before replacing it. Launch starts enabled, subject to microphone
permission and valid settings; restore leaves capture disabled.

## Implementation references

- [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)
- [Cytomic trapezoidal state-variable filter](https://cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf)
- [Cohen, improved minima controlled recursive averaging](https://www.ee.technion.ac.il/Sites/People/IsraelCohen/Publications/SAP_Sep2003.pdf)
- [Gerkmann and Hendriks, fixed-prior noise power estimation](https://www.inf.uni-hamburg.de/en/inst/ab/sp/publications/taslp12noisepsd.html)
- [Apple vDSP FFT](https://developer.apple.com/documentation/accelerate/vdsp_fft_zip)
- [Apple Fourier transform guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/UsingFourierTransforms/UsingFourierTransforms.html)

## Neural model checks

After a Release build, `bash Scripts/test-neural.sh` checks the bundled model
with synthetic audio, including reset reproducibility, channel isolation,
in-place processing, silence, and invalid input. It does not open audio devices.
A different compiled model path can be passed as its first argument.
