# vl_ocr

On-device, no Google/root/cloud calls once models are loaded. The app opens
straight into a **live camera view** (Lens-style): barcodes/QR codes decode
continuously in the background
([`flutter_zxing`](https://pub.dev/packages/flutter_zxing), ZXing-cpp, no
Google dependency), and amber boxes appear over detected text. From there:

- **Tap a text box, tap the snapshot button, or pick from Gallery** to
  freeze on a photo and enter **photo/analysis mode** — Ente's
  [`mobile_ocr`](https://github.com/ente-io/mobile_ocr) plugin's
  `TextDetectorWidget` (PaddleOCR v5 via ONNX) takes over with its
  box-overlay + tap/swipe-to-select UI, reused as-is from Ente's own example
  app, plus a tappable overlay for any barcode/QR codes in that same photo.
- **"Ask AI"**, only once a photo is loaded: hands that image to a local
  Qwen2.5-VL model via [`llama_cpp_dart`](https://pub.dev/packages/llama_cpp_dart)
  (llama.cpp's `mtmd` path) for cases PaddleOCR can't handle — handwriting,
  unusual layouts, "what does this mean" questions.

Built to replace [Maid](https://github.com/Mobile-Artificial-Intelligence/maid)'s
broken image-attach dialog for the VLM side specifically. Also registers as
a Share-sheet target for images (`ACTION_SEND` and `ACTION_SEND_MULTIPLE`,
`image/*`), so a screenshot can be shared straight in from any app — that,
too, drops straight into photo/analysis mode.

## Status

**Live camera is now the home screen, shipped.** Previously the app
opened on a static "Pick an image" placeholder with Gallery/Camera
buttons, and live scanning was a separate mode behind an app-bar toggle
(`_liveMode`). User feedback: "let's change the order of operations to
start in live mode and have a snapshot button to take the photo and
freeze the analysis... the Ask AI button won't appear at all until the
post-gallery/post-snapshot phase." Reworked so which view shows is
derived purely from whether a photo is loaded (`_imagePath == null` ->
live camera, non-null -> photo/analysis) instead of a separate mode flag
that had to be kept in lockstep with it — the app-bar toggle is gone
entirely, since there's no second mode to toggle into anymore. Two ways
to enter photo/analysis mode from the live view, in a bottom action bar
over the camera preview: a shutter-style **snapshot button** (calls
`takePicture()` on the same live `CameraController` the auto text-scan
cycle already uses, guarded by the same in-flight flag so the two can
never fire concurrent captures) or a **Gallery icon** next to it (plain
`image_picker` pick, same as before). Sharing an image in from another
app keeps working unchanged — already an equivalent "load a static
image" entry point. `ReaderWidget`'s own built-in gallery button is
turned off (`showGallery: false`) since it only ran its own
barcode-only pick-and-decode flow, not this app's full OCR pipeline; its
flash/switch-camera buttons moved to `centerRight` to stay clear of both
the hint banner (top) and the new bottom bar. Ask AI (and the Clear
button) now only ever render once `_imagePath != null`, which falls out
of the same single check rather than needing separate handling. Camera
permission denial (now something a user can hit immediately on first
launch, since live view is the default rather than something opted
into) falls back to a plain message plus a Gallery button rather than a
blank screen.

First on-device test surfaced three real bugs, each confirmed with
evidence rather than fixed on a guess:

- **Shutter button wasn't centered.** Measured directly from a
  screenshot: Gallery and the shutter shared one centered `Row`, so
  centering the *pair* visibly pulled the shutter off true
  screen-center toward the Gallery side. Fixed by making the shutter
  the `Stack`'s one unpositioned child (centered by the `Stack`'s own
  alignment) and pinning Gallery independently via
  `Align(alignment: Alignment.centerLeft)`, so neither affects the
  other's position.
- **Frozen snapshots had far fewer detected text regions than a normal
  photo.** Root cause found via logcat at cold launch, not guessed:
  `ReaderWidget`'s camera session binds `Preview`, `ImageCapture`, and
  `ImageAnalysis` all to `ResolutionPreset.high` -- measured at
  `1280x720` on this device, ~13x fewer pixels than a normal photo
  (`4096x3072`) used in earlier static-photo tests. A 720p frame simply
  doesn't resolve body-text-sized print well enough for the detector.
  Bumped to `ResolutionPreset.max` ("the highest resolution available"
  per `camera_platform_interface`'s own doc comment). Real tradeoff,
  not yet confirmed on-device: this plugin ties all three use cases to
  one shared resolution, so the continuous barcode scan and the
  ~1.2s text-scan cycle now process much bigger frames too, which
  could make live scanning noticeably laggier. If so, try
  `ResolutionPreset.ultraHigh` (~2160p) or `.veryHigh` (~1080p) next
  rather than reverting outright -- left as a one-line constant to
  retune.
- **The manual snapshot button could silently do nothing.** Confirmed
  by tapping it, waiting 3+ seconds, and watching the screen never
  freeze. Root cause: `_takeSnapshot()` checked the same
  `_textScanInFlight` guard the automatic text-scan cycle uses -- and a
  single auto-cycle round trip measured ~1.7-1.8s in practice, longer
  than its own ~1.2s tick interval, so that flag is true roughly 75% of
  the time. A tap landing then was silently dropped. Fixed by having
  the manual snapshot cancel the auto-scan timer outright and call
  `takePicture()` directly, without waiting on the shared flag; CameraX's
  own `ImageCapture` use case already queues/serializes concurrent
  `takePicture()` calls internally (logcat: `TakePictureManagerImpl:
  Issue the next TakePictureRequest`), so this is safe even if an
  auto-cycle capture happens to already be in flight. If the capture
  itself fails, the auto-scan timer resumes rather than staying stopped.

Not yet re-tested on-device after these three fixes.

**OCR screen (`mobile_ocr`): working well**, confirmed on-device. The
Share-sheet path works from Photos/Gallery and screenshots; sharing
directly from the stock Camera app's own post-capture screen doesn't show
us — confirmed via `dumpsys package` that our `ACTION_SEND`/`image/*`
intent-filter is correctly registered at the OS level, so this isn't a bug
on our end. Many camera apps show a small curated quick-share row instead
of deferring to the full system share sheet; workaround is sharing from
Gallery/Photos instead, or checking for a "More"/"See all" option on the
Camera app's own share screen.

**Barcode/QR scanning: shipped and merged into the main screen,
confirmed on-device.** `flutter_zxing`'s built-in `ReaderWidget` (camera
preview + decode loop, no custom camera code needed) now lives inline in
`OcrPage` behind an app-bar toggle, instead of a separate `BarcodePage`
route (deleted). User feedback: "not sure i like having a separate
barcode mode at the top but we can merge after it works fully" — this is
that merge, done once the static-photo path (below) was solid. Toggling
swaps the whole screen body between the static-photo view and the live
scanner (same Scaffold/app bar); a live-scanned code reuses the exact
same bottom-sheet result UI (Copy, Open for `http(s)://`) as the
static-photo overlay rather than a second copy of that logic. Decoded
text gets a Copy button, plus an Open button for `http(s)://` results.
Live scanning auto-scans continuously (no capture button, by design) but
originally gave no indication of that — just a live feed with a subtle
corner-bracket target frame and nothing else, which read as broken.
Fixed with an on-screen hint ("Point at a barcode or QR code — it scans
automatically"). 1D barcodes decode near-instantly; QR (especially dense
ones like Matter pairing codes) was slow/unreliable live and failed
outright from a gallery image. Root cause: `ReaderWidget`'s `tryHarder`
defaults to `false` — camera scanning compensates by getting many cheap
retries per second, but a gallery image only gets one decode attempt with
no retry loop to fall back on. Set `tryHarder: true`; trades a little
per-attempt speed for reliability, shouldn't affect barcodes since those
already decode near-instantly either way.

**Barcode/QR detection on the static photo view: shipped.** Any photo
loaded into the primary screen (gallery pick, camera capture, or
Share-sheet) also gets scanned for barcodes/QR codes
(`zx.readBarcodes`, `tryHarder`+`isMultiScan`). Detected codes get a
small tappable outline positioned directly over the code in the photo
(mapped from ZXing's image-pixel coordinates into the displayed widget's
BoxFit.contain letterbox rect, the same transform Ente's own
`TextOverlayWidget` uses); tapping one opens the same bottom sheet the
live scanner uses. Coexists with `mobile_ocr`'s own text-selection UI
underneath since the tap targets are only the small per-code rects, not a
full-screen overlay.

**v0.2.0 milestone (live streaming text-box overlay): shipped.** The live camera view now also draws amber boxes over
detected text, alongside the existing teal barcode boxes -- the actual
Lens live-preview trick. `mobile_ocr`'s `detectTextRegions()` is a
detector-only call (no recognition, cheaper than the full pipeline) but
it's a `MethodChannel` API that only accepts a file path -- no raw
in-memory frame buffer support the way `flutter_zxing`'s synchronous FFI
decode gets for barcodes. Hand-rolling a YUV->JPEG frame converter to feed
it raw camera frames was the "proper" option but real engineering risk
(color-space/orientation bugs) for a feature meant to ship in a handful of
iterations, so instead: a `Timer.periodic` (every 1200ms, tunable
constant) calls `CameraController.takePicture()` for a real
hardware-encoded JPEG, then `detectTextRegions()` on that file -- the same
file-based call `TextDetectorWidget` already relies on for full
recognition. Tapping an amber box freezes on the exact frame that produced
it (already a file on disk) and feeds it into the same full-recognition
pipeline a picked/shared photo goes through -- no new recognition code,
`detectTextRegions()` only ever says *where* text is, not what it says.
Known, accepted tradeoff: `takePicture()` triggers Android's shutter
sound each cycle (not disableable via public API in most locales), so
live mode clicks audibly roughly once every 1.2s while scanning for text.
If that's too annoying in practice, a future iteration could lengthen the
interval or make it tap-to-scan instead of automatic -- left as an easy
constant to change (`_textScanInterval`) rather than solved preemptively.

First on-device test: text detection worked, but boxes never settled --
they visibly jumped between different text blocks cycle to cycle rather
than tracking the same block the way face detection does, giving an
impression of the view "toggling between modes". Investigated with an
on-device logcat capture rather than guessing: CameraX issued clean,
evenly-spaced `takePicture()` calls with zero errors/dropped-frame
warnings overlapping the barcode scanner's own concurrent frame stream --
not camera hardware contention. Checked the native detector too:
`TextRegionDetector.kt`'s `MAX_REGIONS = 1000`, nowhere near a 5-region
cap. The actual cause was simpler: each cycle's `setState` did
`_liveTextRegions = result.regions`, a full replace with zero memory of
the previous cycle. A real scene has some roughly-fixed number of text
blocks, but *which* specific ones clear the detector's confidence
threshold varies cycle to cycle (hand shake, refocus, fresh JPEG
re-encode noise on each capture) -- with no continuity, that reads
exactly like random flicker between blocks. Fixed with a small
IoU-based tracker (`_TrackedTextRegion`, `_updateTrackedTextRegions`):
match each cycle's detections to the previous cycle's tracked boxes by
intersection-over-union (threshold 0.3), carry a matched box's position
forward under the same identity, and give an unmatched box up to 2
missed cycles of grace (~2.4s at the current interval) before dropping
it, rather than vanishing the instant one cycle doesn't confirm it. Not
motion-predicted/Kalman-filtered -- plain box overlap plus hysteresis is
enough for a mostly-still camera pointed at a page, and matches the
scope of similar fixes already shipped here. Not yet re-tested.

On-device testing also surfaced that detected boxes had no actual text
to show ("not extracting... the text in the box, which is kind of the
whole point of ID-ing a text region") -- a separate complaint from the
frozen-snapshot resolution bug fixed above (that one was mistaken for a
detection-quality problem but was really about capture resolution).
`detectTextRegions()` is detection-only by design (see
above) -- it was never going to grow recognized text on its own. Added a
second, independently-throttled pass (`_runTextRecognitionCycle`, every
3000ms, its own in-flight guard -- deliberately not sharing one with the
1200ms detection cycle, since that exact sharing pattern is what made the
manual snapshot button silently swallow taps, fixed above) that calls
`MobileOcr().detectText()` -- the same full recognition call
`TextDetectorWidget` uses, run here against whatever still the detection
cycle most recently captured rather than taking a fresh photo -- and
matches the returned blocks against currently-tracked regions by the same
IoU logic the tracker itself uses. A match caches its recognized text
onto that tracked region permanently (cheap: recognition only needs to
happen once per tracked box, not every cycle) and swaps its rendering
from an empty amber outline to a small readable label showing the actual
text -- satisfying the "extract and magnify" ask without a literal
magnifier, since legible recognized text is more useful than a zoomed
camera crop would be. Tapping an already-recognized box shows it
instantly via a Copy sheet instead of freezing into photo mode; tapping
one that isn't recognized yet still freezes as before. Not yet
re-tested on-device.

On-device testing surfaced a real duplicate-tracking bug once recognized
labels made the overlay dense enough to actually scrutinize: amber boxes
piled up into an overlapping cluster over just a handful of real lines,
and green recognized labels sat visibly offset from both the unrecognized
boxes and the real text underneath. Root cause: `_updateTrackedTextRegions`
only ever compares a tracked box against *new* detections each cycle, never
against other tracked boxes -- so two tracked entries that independently
drift (or get independently spawned for the same line, since a fresh
`takePicture()` capture's own detection isn't perfectly consistent run to
run) can coexist indefinitely, each accruing its own separate missed-cycle
count instead of ever being recognized as duplicates of each other. Fixed
with a merge pass (`_mergeOverlappingTrackedRegions`, run after every
update) that collapses any two tracked regions overlapping above a looser
threshold than the match one (0.15 vs. 0.3 -- two boxes only need to
clearly be "the same line", not a tight positional match, to justify
merging), always keeping a completed recognition over an empty outline
when merging a pair. Separately, some residual lag between a box and the
real text underneath is expected and not fully fixable by this: each
box's position is only as fresh as its last successful detection cycle
(~1.2s, or up to the ~2.4s missed-cycle grace window), so a camera that's
moving (not just held imperfectly still) will always show boxes trailing
slightly behind real position. Removing that lag entirely would need the
continuous raw-frame-stream architecture explicitly deferred earlier in
favor of the simpler throttled-still approach. Not yet re-tested.

That merge pass made things visibly worse on the next on-device test:
the same recognized text appeared repeated across many boxes clustered
at the top of the frame. Real bug, found by re-reading the recognition
cycle rather than guessing: `_runTextRecognitionCycle`'s block-matching
loop had no `claimed` guard on `result.blocks` (unlike the detection
cycle's `_updateTrackedTextRegions`, which already correctly prevents
one new detection from being claimed by more than one tracked region).
Several tracked regions that each overlap one real line well enough
individually -- but not each other enough to have been merged by the
pass above -- were all independently finding that same line as their
own best match and all caching the identical string. Fixed by adding the
same claimed[] pattern to the recognition side. The separately-reported
"takes a long time after startup to start recognizing" turned out to
already be resolved by one of the fixes above (confirmed by the user
before the next build even shipped) -- not chased further since it's no
longer reproducing.

User also asked to remove `ReaderWidget`'s grey corner-bracket target
box, since it visually collided with the amber/green text boxes and the
app now wants detection across the whole frame, not just a centered
region. Checked the widget's own source before touching it rather than
assuming `showScannerOverlay: false` alone would do it: that guide only
renders when `cropPercent != 0`, and `cropPercent` isn't purely cosmetic
-- it also actually restricts real barcode decoding to that centered
crop (default 0.5, i.e. the middle 50%). This widget's other way to zero
that crop, `isMultiScan`, is only set on the static-photo decode path,
not here, so live barcode scanning had been silently limited to the
center square the whole time the grey box was up, not just visually
suggesting it. Set `cropPercent: 0` (`DecodeParams`' own doc comment:
0 means "entire image") instead of just hiding the overlay -- removes
the box and actually extends live barcode scanning to the full frame to
match text detection, rather than leaving an invisible restriction in
place. Not yet re-tested.

User then asked why recognition was slow and whether the system was
overloaded. Checked rather than guessed: sampled CPU (`top -p <pid>`)
across several detection/recognition cycles -- real spikes to
450-490% (of 800% max across this device's 8 cores) while a cycle runs,
dropping to ~110% between cycles -- and checked
`dumpsys thermalservice` and `scaling_cur_freq` against
`cpuinfo_max_freq`: all eight core temperature sensors reported
`mStatus=0` (no throttling) at 38-43°C, and every core was still
clocked at its maximum frequency, not reduced. So the hardware is
working hard during a cycle but isn't overloaded or thermally
throttled -- the actual cause of the delay was something else entirely,
found in `mobile_ocr`'s own native logcat tag (`OnnxOcrDebug`): a
detected region kept logging `Recognition produced no results...
bestRecognitionScore=0.60` (also saw 0.27, 0.56, 0.28) every ~3s for
50+ seconds straight, zero successes. Caveat on that specific capture:
the phone wasn't actually pointed at real text at the time (caught
after the fact), so those particular low scores may partly reflect the
detector flagging something text-shaped that wasn't, rather than purely
motion blur on real text -- the mechanism this fix addresses is still
real and confirmed regardless (`detectText()`'s default confidence gate
of 0.8, per its own doc comment, silently discards anything under it),
but whether a live handheld capture of *actual* text clears 0.8 as
consistently as a deliberate still photo does is genuinely untested,
not just downplayed. Set `includeAllConfidenceScores: true`, widening
the gate to
`mobile_ocr`'s documented floor of 0.5 -- real tradeoff being accepted
rather than solved further: some lower-confidence (0.5-0.8) recognitions
may occasionally be a little off, but a usually-right live preview beats
a usually-empty one, and tapping a box that's wrong or still unrecognized
always falls back to the full accurate static-photo recognition anyway.
Deliberately did not shorten `_textScanInterval`/`_textRecognitionInterval`
to chase the same complaint -- the CPU data above says cycles are
already substantial work per iteration, so shortening the interval would
add contention/heat/battery cost without addressing the confirmed actual
cause. Not yet re-tested.

User then suspected some of the box misplacement was down to a
completely different mechanism: the phone silently reading a barcode
that wasn't visible in the framing they saw, discovered by deliberately
testing for it (framing a code just outside what the screen showed,
confirmed on request). Checked `dumpsys media.camera`: this device's
back camera reports `LOGICAL_MULTI_CAMERA`, Android's mechanism for
presenting several physical lenses (main + ultrawide here) as one
continuous logical stream, with the OS/HAL free to route between them.
Watching it happen live nailed the exact cause, not just the general
capability: tapping a box to freeze visibly zoomed the preview *out*
right before capturing, revealing codes that had been outside the
frame a moment earlier. Traced to `ReaderWidget`'s own source rather
than staying at "logical multi-camera can do this in general": its
setup sets the working zoom to the device's *minimum* zoom level
(`_scaleFactor = _minZoomLevel`), not 1.0. On a logical-multi-camera
phone, minimum zoom is below 1.0x specifically because that range hands
off to the ultrawide sensor -- so every camera bind was deterministically
starting scanning zoomed into ultrawide, not a rare/conditional HAL
decision. Fixed by forcing zoom back to 1.0 (the primary sensor's native
framing, which is what the preview visually represents to the user)
right after the controller is created, and turning off `allowPinchZoom`
since it's the only other thing in the widget that could move zoom away
from that and serves no purpose for scanning text/codes. This should
also remove a source of the "yellow box coordinate hallucination"
complaint above: a tracked box's cached position was computed from
whatever frame the capture cycle got, and if that frame's field of view
silently changed between cycles (ultrawide one moment, primary the
next), the same pixel coordinates would map to different real-world
locations, which the IoU tracker has no way to account for. Not yet
re-tested; the tracker fixes above address a real, separate problem
either way and aren't being unwound.

First on-device test found text detection working well but the barcode
overlay untappable. Root cause: `flutter_zxing`'s convenience
`readBarcodesImagePath` decodes via `package:image`, which leaves EXIF
orientation as metadata instead of baking it into the pixel buffer --
a portrait photo's raw sensor buffer is landscape, so the `Position` it
reports back is in that unrotated frame while the photo is displayed (and
the overlay is drawn) correctly rotated. The box ended up geometrically
offset from the actual code. Fixed by decoding the file ourselves,
calling `package:image`'s `bakeOrientation()`, then feeding the corrected
raw bytes to `zx.readBarcodes` directly instead of the path-based
convenience method. Confirmed on-device: a screenshot of a QR code now
detects and taps correctly (fast). A QR on a crumpled paper receipt still
isn't detected at all -- two compounding causes, one fixed here: the
convenience path's default 768px downscale can shrink a small code's
modules below decodable well before crumpling becomes a factor, on a
full-size 3000-4000px receipt photo where the code is a small fraction of
the frame. Bumped to 2500px, still failed. Pulled the actual failing
photo off-device via adb and measured it directly rather than guessing
again: at this device's full 4096x3072 sensor resolution the printed QR
was only ~400x400px, ~8-9px/module, and visually the code itself was
sharp and only lightly creased at one edge -- not the "too warped to
read" case it looked like. 2500px was already shrinking that to
~5px/module, on the edge of surviving JPEG compression and camera noise.
Raised the cap to 4096 (this device's own resolution, as a ceiling
against a shared photo from some other phone's 100+MP sensor, not a
target) since ZXing has no real performance reason to be scanned this
small -- mobile_ocr's much heavier ONNX inference already runs fast on
the same full-resolution photo. Not yet re-tested; genuine non-planar
paper warping (folded hard enough to break the finder-pattern grid, as
opposed to this receipt's light single crease) remains a separate, harder
problem this doesn't address.

**Multiple-image sharing: shipped, not yet re-tested on-device.** Added
an `ACTION_SEND_MULTIPLE`/`image/*` manifest intent-filter alongside the
existing single-image `ACTION_SEND` one, so vl_ocr shows up in the share
sheet for a Gallery multi-select too (previously it would've been hidden
from that share sheet entirely, since Android only offers a target app
for the specific action its intent-filters declare). `receive_sharing_intent`'s
`getMediaStream()`/`getInitialMedia()` already return a `List` regardless
of which action fired, so no API change was needed there -- this screen
still only reasons about one photo at a time, so it opens the first image
and tells you via a snackbar ("Shared N images -- opened the first one")
rather than silently dropping the rest.

**"Ask AI" screen: known broken, pinned for now.** Every model tried
(Qwen2.5-VL-3B, Gemma 3 4B, Qwen2-VL-2B) hits an identical
`MultimodalException: mtmd_tokenize failed: rc=2 (preprocessing error)` the
moment an image is sent — but every one of those same model+image
combinations works flawlessly through a native `llama-mtmd-cli` build
outside the Android app sandbox. Ruled out so far: image content/size,
llama.cpp version (built at `llama_cpp_dart`'s exact pinned commit),
rendered chat-template text (both correct and deliberately wrong versions
tested), the AAR's actual build flags (`GGML_OPENMP=OFF`/`GGML_NATIVE=OFF`,
matched and tested), `android:largeHeap`, and model size (down to 2B).
The bug is real, reproducible, and isolated to something specific to
running inside the Android app process — root cause not yet found. Next
step under consideration: build a custom `.aar` with debug logging patched
into `mtmd.cpp`'s exception path (`llama.cpp`'s own `LOG_ERR` doesn't reach
Android logcat), via Android NDK in CI. Deliberately not filing this
upstream — well-characterized enough to hand off if we ever decide to,
but that's a call for a human to make, not something done autonomously.

**NNAPI acceleration for the OCR path: shipped and confirmed faster
on-device.** Ente's `mobile_ocr` ran ONNX Runtime with only
`setOptimizationLevel(BASIC_OPT)` — no NNAPI/QNN/any hardware
acceleration, pure CPU. Forked (`aubreybailey/mobile_ocr`) to add
`SessionOptions.addNnapi()` (Java/Kotlin-level ONNX Runtime API, no NDK
needed, already bundled in the AAR). Noticeably snappier in real use on
this device; NNAPI driver quality still varies by OEM/SoC, so this isn't
guaranteed to hold on every device, but it's a confirmed win here.

`llama_cpp_dart`'s multimodal support is only published on the `0.9.0-dev`
prerelease track, not the stable `0.2.2` — expect API churn. `mobile_ocr`
isn't on pub.dev yet either, hence the git dependency.

## Roadmap / ideas not yet started

The v0.2.0 milestone (live camera + streaming text-box overlay) is done
-- see Status above. Remaining Google Lens-style features considered,
roughly in order of how cheap/self-contained they'd be to add:

- **Document scan + perspective crop** — corner detection + perspective
  transform before handing off to OCR; pairs naturally with the existing
  camera capture flow.
- **General "what is this?" scene/object questions** — falls out of the
  Ask AI screen for free once its crash is fixed; same code path as OCR,
  just a different prompt. Not a separate feature to build.
- Explicitly out of scope: anything needing a cloud call (shopping/product
  search, web-connected translation) — against the whole point of this app.

## Models

Not bundled. Point the in-app file pickers at:
- a base model `.gguf` (tested with `Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf`)
- its matching `mmproj-*.gguf` vision projector

Both from [`ggml-org/Qwen2.5-VL-3B-Instruct-GGUF`](https://huggingface.co/ggml-org/Qwen2.5-VL-3B-Instruct-GGUF)
on Hugging Face.

## Building

CI (`.github/workflows/release.yml`) builds a release APK on every `vX.Y.Z`
tag push and attaches it to a GitHub Release — point
[Obtainium](https://github.com/ImranR98/Obtainium) at this repo to track it.

To build locally you'll need a Flutter install with native assets enabled
(`flutter config --enable-native-assets`) since `llama_cpp_dart` bundles its
prebuilt Android libraries through that mechanism.

## License

MIT.
