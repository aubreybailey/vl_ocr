// Primary flow: pick an image, get Ente's mobile_ocr box-overlay + tap/swipe
// -to-select UI (PaddleOCR v5 via ONNX, fully on-device). That's the proven,
// good UX -- reused as-is via the package's own TextDetectorWidget rather
// than reimplemented.
//
// Secondary flow ("Ask AI"): hand the same image to a local Qwen2.5-VL model
// via llama_cpp_dart for the cases PaddleOCR can't handle (handwriting,
// unusual layouts, "what does this mean" questions). Separate screen, only
// loads the (large) model on demand.
//
// LlamaEngine/EngineChat API verified against llama_cpp_dart 0.9.0-dev.12's
// actual source (lib/src/isolate/engine.dart) after the first CI build
// caught a wrong type name (LlamaChat -> EngineChat) transcribed from docs.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:mobile_ocr/mobile_ocr.dart';

void main() => runApp(const VlOcrApp());

class VlOcrApp extends StatelessWidget {
  const VlOcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VL OCR PoC',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const OcrPage(),
    );
  }
}

/// Primary screen: Ente's box-overlay OCR, essentially their own example
/// app's flow (see ente-io/mobile_ocr/example/lib/main.dart).
class OcrPage extends StatefulWidget {
  const OcrPage({super.key});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  final ImagePicker _picker = ImagePicker();
  final TextDetectorController _controller = TextDetectorController();
  String? _imagePath;
  bool _isPickingImage = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() => _isPickingImage = true);
    try {
      final file = await _picker.pickImage(source: source);
      if (file == null) return;
      if (!mounted) return;
      setState(() => _imagePath = file.path);
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  void _openVlmChat() {
    final path = _imagePath;
    if (path == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VlmChatPage(initialImagePath: path)),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final path = _imagePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('vl_ocr'),
        actions: [
          if (path != null)
            IconButton(
              tooltip: 'Ask AI (Qwen2.5-VL) about this image',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: _openVlmChat,
            ),
          if (path != null)
            IconButton(
              tooltip: 'Clear image',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _imagePath = null),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: path == null
                ? Center(
                    child: Text(
                      'Pick an image to run OCR',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      TextDetectorWidget(
                        key: ValueKey(path),
                        imagePath: path,
                        backgroundColor: Colors.transparent,
                        enableSelectionPreview: true,
                        controller: _controller,
                        onTextCopied: (text) => _showSnackBar(
                          text.isEmpty
                              ? 'Copied empty text'
                              : 'Copied text (${text.length} chars)',
                        ),
                      ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isPickingImage
                          ? null
                          : () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Gallery'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isPickingImage
                          ? null
                          : () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Camera'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Secondary screen: local Qwen2.5-VL chat for images the fast PaddleOCR
/// path can't handle well.
class VlmChatPage extends StatefulWidget {
  const VlmChatPage({super.key, this.initialImagePath});

  final String? initialImagePath;

  @override
  State<VlmChatPage> createState() => _VlmChatPageState();
}

class _VlmChatPageState extends State<VlmChatPage> {
  final _service = _LlamaService();
  final _promptController = TextEditingController(
    text: 'Read the text in this image, verbatim.',
  );
  final _scrollController = ScrollController();

  String? _modelPath;
  String? _mmprojPath;
  String? _imagePath;
  bool _modelReady = false;
  bool _busy = false;
  // Neither pick button disabled the other while a pick was in flight, so a
  // fast second tap hit file_picker's single-active-picker limit and threw
  // an uncaught PlatformException(already_active) -- caught via logcat.
  bool _pickingFile = false;
  String _output = '';
  String _status = 'Pick model + mmproj files to begin.';

  @override
  void initState() {
    super.initState();
    _imagePath = widget.initialImagePath;
  }

  @override
  void dispose() {
    _service.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickModelFile() async {
    if (_pickingFile) return;
    setState(() => _pickingFile = true);
    try {
      // file_picker 12.x: pickFile() is the single-file call now (returns
      // PlatformFile? directly), replacing the old
      // pickFiles()/FilePickerResult pair this was first written against.
      final file = await FilePicker.pickFile(
        dialogTitle: 'Select the base model .gguf',
      );
      final path = file?.path;
      if (path == null) return;
      setState(() => _modelPath = path);
      _maybeAutoLoad();
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  Future<void> _pickMmprojFile() async {
    if (_pickingFile) return;
    setState(() => _pickingFile = true);
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Select the mmproj .gguf',
      );
      final path = file?.path;
      if (path == null) return;
      setState(() => _mmprojPath = path);
      _maybeAutoLoad();
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  // User feedback: having to tap "Load model" as a separate step after
  // picking both files wasn't obvious -- once both paths are set, just go.
  void _maybeAutoLoad() {
    if (_modelPath != null && _mmprojPath != null && !_modelReady && !_busy) {
      _loadModel();
    }
  }

  Future<void> _loadModel() async {
    if (_modelPath == null || _mmprojPath == null) return;
    setState(() {
      _busy = true;
      _status = 'Loading model (this can take a while on first load)...';
    });
    try {
      await _service.load(modelPath: _modelPath!, mmprojPath: _mmprojPath!);
      // mtmd_tokenize can return rc=2 ("preprocessing error" per our own
      // error message) for two very different reasons: an actual native
      // exception, OR simply ctx_v being null -- i.e. the vision encoder
      // never initialized, even though the engine reported loading fine.
      // Surface supportsVision so a failed "Ask AI" send tells us which.
      setState(() {
        _modelReady = true;
        _status = _service.supportsVision
            ? 'Model loaded. Vision: yes.'
            : 'Model loaded. Vision: NO -- image prompts will fail.';
      });
    } catch (e) {
      setState(() => _status = 'Failed to load model: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() => _imagePath = picked.path);
  }

  Future<void> _send() async {
    if (!_modelReady || _imagePath == null || _busy) return;
    setState(() {
      _busy = true;
      _output = '';
    });
    try {
      final stream = _service.ask(
        prompt: _promptController.text,
        imagePath: _imagePath!,
      );
      await for (final token in stream) {
        setState(() => _output += token);
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      setState(() => _output += '\n[error: $e]');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ask AI (Qwen2.5-VL)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_modelReady) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: (_busy || _pickingFile) ? null : _pickModelFile,
                    child: Text(
                      _modelPath == null
                          ? 'Pick model .gguf'
                          : 'Model: ${_shortName(_modelPath!)}',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: (_busy || _pickingFile)
                        ? null
                        : _pickMmprojFile,
                    child: Text(
                      _mmprojPath == null
                          ? 'Pick mmproj .gguf'
                          : 'mmproj: ${_shortName(_mmprojPath!)}',
                    ),
                  ),
                  FilledButton(
                    onPressed:
                        (_busy || _modelPath == null || _mmprojPath == null)
                        ? null
                        : _loadModel,
                    child: const Text('Load model'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Text(_status, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (_imagePath != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: Image.file(File(_imagePath!)),
              ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SelectableText(_output),
                ),
              ),
            ),
            const Divider(),
            TextField(
              controller: _promptController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _modelReady && !_busy ? _pickImage : null,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Attach image'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _modelReady && !_busy && _imagePath != null
                        ? _send
                        : null,
                    child: _busy
                        ? const CircularProgressIndicator()
                        : const Text('Send'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _shortName(String path) => path.split('/').last;
}

/// Thin wrapper around llama_cpp_dart so the API surface lives in one place.
class _LlamaService {
  LlamaEngine? _engine;
  EngineChat? _chat;

  bool get supportsVision => _engine?.supportsVision ?? false;

  Future<void> load({
    required String modelPath,
    required String mmprojPath,
  }) async {
    _engine = await LlamaEngine.spawn(
      modelParams: ModelParams(path: modelPath, gpuLayers: 0),
      contextParams: const ContextParams(nCtx: 4096),
      // useGpu:false matches the native llama-mtmd-cli spike that proved
      // Qwen2.5-VL's vision path works on this hardware (--no-mmproj-offload
      // there); the default is useGpu:true, an untested config this app
      // has never actually verified.
      //
      // nThreads: MultimodalParams defaults this to 0 ("let the runtime
      // pick" per its own doc comment), but MultimodalContext.init() passes
      // it straight through as a literal override of
      // mtmd_context_params_default()'s n_threads=4 -- native code never
      // gets a chance to substitute a sane value for 0. Confirmed via a
      // patched llama-mtmd-cli build that forcing n_threads=0 crashes hard
      // (took down the whole shell, not a catchable exception) -- the
      // mtmd_tokenize rc=2 this app hits is almost certainly this same
      // zero-threads path, manifesting as a catchable exception here
      // instead of a hard crash for whatever reason (different libc/build
      // than the Termux spike, most likely).
      multimodalParams: MultimodalParams(
        mmprojPath: mmprojPath,
        useGpu: false,
        nThreads: Platform.numberOfProcessors,
      ),
    );
    _chat = await _engine!.createChat();
  }

  Stream<String> ask({
    required String prompt,
    required String imagePath,
  }) async* {
    final chat = _chat;
    if (chat == null) throw StateError('Model not loaded');
    chat.addUser(prompt, media: [LlamaMedia.imageFile(imagePath)]);
    await for (final event in chat.generate(maxTokens: 512)) {
      if (event is TokenEvent) yield event.text;
    }
  }

  void dispose() {
    _engine?.dispose();
  }
}
