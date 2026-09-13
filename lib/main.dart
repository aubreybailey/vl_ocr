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
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:url_launcher/url_launcher.dart';

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
  late final StreamSubscription<List<SharedMediaFile>> _shareSub;

  @override
  void initState() {
    super.initState();
    // Warm start: app already running, image shared in from another app.
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      if (files.isEmpty || !mounted) return;
      setState(() => _imagePath = files.first.path);
    });
    // Cold start: app launched fresh via a share.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty && mounted) {
        setState(() => _imagePath = files.first.path);
      }
      ReceiveSharingIntent.instance.reset();
    });
  }

  @override
  void dispose() {
    _shareSub.cancel();
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

  void _openBarcodeScanner() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const BarcodePage()));
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
          IconButton(
            tooltip: 'Scan barcode / QR code',
            icon: const Icon(Icons.qr_code_scanner_outlined),
            onPressed: _openBarcodeScanner,
          ),
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
      // Diagnostic: ChatTemplate.apply() uses llama.cpp's legacy
      // llama_chat_apply_template() (pattern-matches known template
      // families) rather than actually executing the model's embedded
      // Jinja -- unconfirmed whether that renders this specific
      // Qwen2.5-VL template correctly. Show the real rendered prompt so
      // a failure tells us definitively instead of guessing again.
      final rendered = _service.debugRenderPrompt(_promptController.text);
      if (rendered != null) {
        setState(
          () => _output = '--- rendered prompt ---\n$rendered\n--- end ---\n\n',
        );
      }
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
                  // Loading is automatic once both files are picked (see
                  // _maybeAutoLoad) -- a permanent "Load model" button here
                  // was confusing since it did nothing most of the time.
                  // Only offer it as an explicit retry after a failure.
                  if (_status.startsWith('Failed to load model'))
                    FilledButton(
                      onPressed:
                          (_busy ||
                              _modelPath == null ||
                              _mmprojPath == null)
                          ? null
                          : _loadModel,
                      child: const Text('Retry load'),
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
      // mtmd_context_params_default()'s n_threads=4 with no substitution
      // logic on either side. Worth keeping explicit regardless, but this
      // was NOT the fix for the mtmd_tokenize rc=2 crash -- confirmed by a
      // real device test after this change shipped, same crash, same
      // trace. The terminal crash from a patched llama-mtmd-cli forcing
      // n_threads=0 that seemed to confirm this was most likely an
      // unrelated resource/OOM crash in that Termux session, not a
      // controlled reproduction -- don't trust that as evidence.
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

  /// Renders the exact same prompt EngineChat.generate() would build
  /// internally, using the same manual marker-prepend logic as
  /// EngineChat.addUser(). ChatTemplate.apply() calls llama.cpp's legacy
  /// llama_chat_apply_template() (pattern-matches known template families
  /// like ChatML/Qwen) rather than executing the model's actual embedded
  /// Jinja -- unconfirmed whether that's correct for Qwen2.5-VL's specific
  /// template (namespace()-based image_count tracking, content-type
  /// dispatch). This exposes the real rendered string so a failure shows
  /// us definitively rather than guessing blind again.
  String? debugRenderPrompt(String userPrompt) {
    final engine = _engine;
    final template = engine?.modelChatTemplate;
    if (template == null) return '(no embedded chat template on this model)';
    final content = '<__media__>\n$userPrompt';
    try {
      // LlamaLibrary's loaded-bindings state is per-isolate, not actually
      // process-wide despite the class doc comment -- LlamaEngine.spawn()
      // only loads it inside the worker isolate it creates. Calling
      // ChatTemplate.apply() from here (the main/UI isolate) needs its own
      // load() first. Idempotent, so safe to call every time.
      LlamaLibrary.load(path: LlamaLibrary.defaultFileName());
      return ChatTemplate.apply(
        template: template,
        messages: [ChatMessage(role: 'user', content: content)],
        addAssistant: true,
      );
    } catch (e) {
      return '(debugRenderPrompt failed: $e)';
    }
  }

  void dispose() {
    _engine?.dispose();
  }
}

/// Barcode/QR scanning via flutter_zxing's ReaderWidget (camera preview +
/// decode loop, built in -- no need to drive the camera ourselves). Wraps
/// ZXing-cpp; zero Google dependency, unlike ML Kit's barcode scanner.
class BarcodePage extends StatefulWidget {
  const BarcodePage({super.key});

  @override
  State<BarcodePage> createState() => _BarcodePageState();
}

class _BarcodePageState extends State<BarcodePage> {
  Code? _result;

  static final _urlPattern = RegExp(r'^https?://', caseSensitive: false);

  void _onScanSuccess(Code? code) {
    if (code == null || !code.isValid) return;
    setState(() => _result = code);
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied')));
  }

  Future<void> _openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode / QR')),
      body: result != null
          ? _ResultView(
              text: result.text ?? '',
              isUrl: _urlPattern.hasMatch(result.text ?? ''),
              onScanAgain: () => setState(() => _result = null),
              onCopy: _copyToClipboard,
              onOpen: _openUrl,
            )
          : Stack(
              children: [
                ReaderWidget(
                  onScan: _onScanSuccess,
                  onScanFailure: (_) {},
                  scanDelay: const Duration(milliseconds: 500),
                  resolution: ResolutionPreset.high,
                  lensDirection: CameraLensDirection.back,
                  flashOnIcon: const Icon(Icons.flash_on),
                  flashOffIcon: const Icon(Icons.flash_off),
                  flashAlwaysIcon: const Icon(Icons.flash_on),
                  flashAutoIcon: const Icon(Icons.flash_auto),
                  galleryIcon: const Icon(Icons.photo_library),
                  toggleCameraIcon: const Icon(Icons.switch_camera),
                ),
                // ReaderWidget auto-scans continuously (no capture button by
                // design) but gave zero indication of that -- just a live
                // camera feed with a subtle corner-bracket target frame and
                // nothing else. User feedback: looked broken / like
                // something was missing to tap. This is the fix: say what's
                // happening and where to point.
                Positioned(
                  top: 24,
                  left: 24,
                  right: 24,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Point at a barcode or QR code — it scans '
                        'automatically, no need to tap anything',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.text,
    required this.isUrl,
    required this.onScanAgain,
    required this.onCopy,
    required this.onOpen,
  });

  final String text;
  final bool isUrl;
  final VoidCallback onScanAgain;
  final void Function(String) onCopy;
  final void Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onCopy(text),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
              ),
              if (isUrl) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => onOpen(text),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.qr_code_scanner_outlined),
            label: const Text('Scan again'),
          ),
        ],
      ),
    );
  }
}
