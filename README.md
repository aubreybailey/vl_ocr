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
broken image-attach dialog for the VLM side specifically.

## Status

The `mtmd`/Qwen2.5-VL vision pipeline is confirmed working, verified
independently via a native `llama.cpp` build and `llama-mtmd-cli` before any
of this app was written. The Flutter/`llama_cpp_dart` wiring itself was
fixed once by CI catching a wrong transcribed type name (`LlamaChat` ->
`EngineChat`) — see git log. The `mobile_ocr` integration is newer and
hasn't been through a CI round yet.

`llama_cpp_dart`'s multimodal support is only published on the `0.9.0-dev`
prerelease track, not the stable `0.2.2` — expect API churn. `mobile_ocr`
isn't on pub.dev yet either, hence the git dependency.

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
