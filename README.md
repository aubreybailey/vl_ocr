# vl_ocr

Two OCR paths on one image, on-device, no Google/root/cloud calls once
models are loaded:

- **Primary screen**: Ente's [`mobile_ocr`](https://github.com/ente-io/mobile_ocr)
  plugin's `TextDetectorWidget` — PaddleOCR v5 via ONNX, with the
  box-overlay + tap/swipe-to-select UI reused as-is from Ente's own example
  app. This is the good, proven UX; nothing here reimplements it.
- **"Ask AI" screen**: the same image handed to a local Qwen2.5-VL model via
  [`llama_cpp_dart`](https://pub.dev/packages/llama_cpp_dart) (llama.cpp's
  `mtmd` path) for cases PaddleOCR can't handle — handwriting, unusual
  layouts, "what does this mean" questions.

Built to replace [Maid](https://github.com/Mobile-Artificial-Intelligence/maid)'s
broken image-attach dialog for the VLM side specifically. Also registers as
a Share-sheet target for images (`ACTION_SEND` and `ACTION_SEND_MULTIPLE`,
`image/*`), so a screenshot can be shared straight in from any app, and
includes barcode/QR scanning
([`flutter_zxing`](https://pub.dev/packages/flutter_zxing), ZXing-cpp, no
Google dependency) merged into the same screen — a toggle in the app bar
switches between the static photo view and a live camera scanner, no
separate route. The live scanner also draws boxes over detected text in
real time (Lens-style), tap one to freeze and read it.

## Status

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

**v0.2.0 milestone (live streaming text-box overlay): shipped, not yet
tested on-device.** The live camera view now also draws amber boxes over
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
