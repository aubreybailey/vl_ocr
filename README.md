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
can be shared straight in from any app.

## Status

**OCR screen (`mobile_ocr`): working well**, confirmed on-device, including
the Share-sheet path (share an image from any app, it opens straight into
the box-overlay OCR view).

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

Other Google Lens-style features considered, roughly in order of how
cheap/self-contained they'd be to add:

- **Barcode/QR detection** — `flutter_zxing` (wraps ZXing-cpp, no Google
  dependency), fully independent of the OCR pipeline. Easiest win.
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
