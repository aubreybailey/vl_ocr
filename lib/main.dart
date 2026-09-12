// PoC: pick a screenshot, ask a local Qwen2.5-VL model (via llama_cpp_dart)
// what it says. No network calls once the model files are loaded.
//
// NOTE: the exact LlamaEngine/Chat API below is transcribed from
// llama_cpp_dart's published docs (0.9.0-dev series) but has not yet been
// verified against the real package source in a build. Treat the contents
// of _LlamaService as the first thing to fix if `flutter pub get` /
// `flutter analyze` disagree with it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

void main() => runApp(const VlOcrApp());

class VlOcrApp extends StatelessWidget {
  const VlOcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VL OCR PoC',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _service = _LlamaService();
  final _promptController = TextEditingController(text: 'Read the text in this image, verbatim.');
  final _scrollController = ScrollController();

  String? _modelPath;
  String? _mmprojPath;
  String? _imagePath;
  bool _modelReady = false;
  bool _busy = false;
  String _output = '';
  String _status = 'Pick model + mmproj files to begin.';

  @override
  void dispose() {
    _service.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickModelFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select the base model .gguf',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _modelPath = path);
  }

  Future<void> _pickMmprojFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select the mmproj .gguf',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _mmprojPath = path);
  }

  Future<void> _loadModel() async {
    if (_modelPath == null || _mmprojPath == null) return;
    setState(() {
      _busy = true;
      _status = 'Loading model (this can take a while on first load)...';
    });
    try {
      await _service.load(modelPath: _modelPath!, mmprojPath: _mmprojPath!);
      setState(() {
        _modelReady = true;
        _status = 'Model loaded.';
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
      final stream = _service.ask(prompt: _promptController.text, imagePath: _imagePath!);
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
      appBar: AppBar(title: const Text('VL OCR PoC')),
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
                    onPressed: _busy ? null : _pickModelFile,
                    child: Text(_modelPath == null ? 'Pick model .gguf' : 'Model: ${_shortName(_modelPath!)}'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _pickMmprojFile,
                    child: Text(_mmprojPath == null ? 'Pick mmproj .gguf' : 'mmproj: ${_shortName(_mmprojPath!)}'),
                  ),
                  FilledButton(
                    onPressed: (_busy || _modelPath == null || _mmprojPath == null) ? null : _loadModel,
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
              decoration: const InputDecoration(labelText: 'Prompt', border: OutlineInputBorder()),
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
                    onPressed: _modelReady && !_busy && _imagePath != null ? _send : null,
                    child: _busy ? const CircularProgressIndicator() : const Text('Send'),
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

/// Thin wrapper around llama_cpp_dart so the API surface we're unsure about
/// lives in one place.
class _LlamaService {
  LlamaEngine? _engine;
  LlamaChat? _chat;

  Future<void> load({required String modelPath, required String mmprojPath}) async {
    _engine = await LlamaEngine.spawn(
      modelParams: ModelParams(path: modelPath, gpuLayers: 0),
      contextParams: const ContextParams(nCtx: 4096),
      multimodalParams: MultimodalParams(mmprojPath: mmprojPath),
    );
    _chat = await _engine!.createChat();
  }

  Stream<String> ask({required String prompt, required String imagePath}) async* {
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
