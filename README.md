# vl_ocr

Proof of concept: pick an image (e.g. a screenshot), run it through a local
Qwen2.5-VL model via [`llama_cpp_dart`](https://pub.dev/packages/llama_cpp_dart)
(llama.cpp's `mtmd` multimodal path), and get the text back. Everything runs
on-device — no Google, no root, no cloud calls once the model files are
loaded.

Built to replace [Maid](https://github.com/Mobile-Artificial-Intelligence/maid)'s
broken image-attach dialog for this specific use case.

## Status

Early PoC, untested end-to-end. The `mtmd`/Qwen2.5-VL vision pipeline itself
is confirmed working (verified independently via a native `llama.cpp` build
and `llama-mtmd-cli`, not through this app), but this Flutter app has not
yet been built or run — see `lib/main.dart`'s top comment for the specific
part of the `llama_cpp_dart` API that needs verifying first.

`llama_cpp_dart`'s multimodal support is only published on the `0.9.0-dev`
prerelease track, not the stable `0.2.2` — expect API churn.

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
