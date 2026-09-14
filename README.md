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
a Share-sheet target for images (`ACTION_SEND`, `image/*`), so a screenshot
can be shared straight in from any app, and includes a barcode/QR scanner
([`flutter_zxing`](https://pub.dev/packages/flutter_zxing), ZXing-cpp, no
Google dependency).

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

**Barcode/QR scanner: shipped, confirmed on-device.** `flutter_zxing`'s
built-in `ReaderWidget` (camera preview + decode loop, no custom camera
code needed), reachable from a scanner icon on the OCR screen's app bar.
Decoded text gets a Copy button, plus an Open button for `http(s)://`
results. It auto-scans continuously (no capture button, by design) but
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
already decode near-instantly either way. Not yet re-tested on-device.

**Barcode/QR detection on the main OCR screen: shipped.** Any photo loaded
into the primary screen (gallery pick, camera capture, or Share-sheet) now
also gets scanned for barcodes/QR codes (`zx.readBarcodesImagePath`,
`tryHarder`+`isMultiScan`), independent of the separate live-camera
`BarcodePage` above. Detected codes get a small tappable outline positioned
directly over the code in the photo (mapped from ZXing's image-pixel
coordinates into the displayed widget's BoxFit.contain letterbox rect, the
same transform Ente's own `TextOverlayWidget` uses); tapping one opens a
bottom sheet with the decoded text, Copy button, and Open button for
`http(s)://` results. Coexists with `mobile_ocr`'s own text-selection UI
underneath since the tap targets are only the small per-code rects, not a
full-screen overlay. This is the "merge barcode into unified view" item
from the roadmap below, done for static photos; the still-open v0.2.0
milestone is specifically about a *live streaming camera* overlay, a
separate and bigger piece of work.

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
the frame. Bumped to 2500px. Physical warping/creasing breaking the
code's finder-pattern grid is a separate, harder problem this doesn't
address -- ZXing does some perspective correction for a tilted-but-flat
code, not true non-planar paper distortion. Not yet re-tested.

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

**v0.2.0 milestone: a working live camera + streaming text-box overlay**
(see below) — the "big" remaining Lens-style feature.

Other Google Lens-style features considered, roughly in order of how
cheap/self-contained they'd be to add:

- **Document scan + perspective crop** — corner detection + perspective
  transform before handing off to OCR; pairs naturally with the existing
  camera capture flow.
- **Live camera + streaming text-box overlay** — the actual Lens
  live-preview trick: run `mobile_ocr`'s *detection* stage only (not full
  recognition, which is heavier) on a throttled camera frame loop via the
  `camera` package, draw boxes with a `CustomPainter`, defer full
  recognition until the user taps/freezes on a box. Bigger lift than the
  above, but the pieces (detection API, overlay rendering) already exist
  in this codebase in some form.
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
