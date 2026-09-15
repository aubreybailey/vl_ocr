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
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:mobile_ocr/mobile_ocr.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:image/image.dart' as imglib;
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const VlOcrApp());

/// A live text region carried across detection cycles so its on-screen box
/// stays put instead of popping to a new position/identity every cycle --
/// see [_OcrPageState._updateTrackedTextRegions] for why this exists.
class _TrackedTextRegion {
  _TrackedTextRegion(this.box);

  Rect box;
  int missedCycles = 0;
  // Cached once a recognition pass (see _runTextRecognitionCycle) matches
  // this tracked box to a TextBlock's recognized text. Set-once: a tracked
  // region that already has text is never re-recognized, since the point
  // is avoiding the heavier detectText() call for text we already know.
  // Implicitly cleared when the tracked region itself is dropped (missed
  // too many cycles) -- there's no separate cache to invalidate.
  String? recognizedText;
}

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

  // Barcodes/QR codes found in the currently-loaded static photo (separate
  // from the live camera scan below). Static images only get one decode
  // attempt each, same reliability concern tryHarder fixes for both.
  static final _barcodeUrlPattern = RegExp(r'^https?://', caseSensitive: false);
  List<Code> _barcodes = const [];

  // Live camera view is now the app's home state rather than a toggled
  // mode: whether we're showing it or the static-photo/analysis view is
  // derived purely from _imagePath (null -> live, non-null -> photo)
  // instead of a separate bool that had to be kept in lockstep with it.
  // User feedback: "let's change the order of operations to start in live
  // mode and have a snapshot button to take the photo and freeze the
  // analysis... the Ask AI button won't appear at all until the
  // post-gallery/post-snapshot phase" -- both fall out for free once
  // there's only one source of truth for which view is showing.
  //
  // Reference to the live camera controller ReaderWidget creates
  // internally, captured via onControllerCreated purely so the manual
  // snapshot button can call takePicture() on the same controller the
  // auto text-scan cycle already uses, rather than standing up a second
  // camera resource.
  CameraController? _liveController;
  // Set when onControllerCreated reports a non-null error (e.g. camera
  // permission denied) so the live view can fall back to a plain message
  // + Gallery button instead of a blank/broken screen.
  Exception? _liveCameraError;
  // Guards against ReaderWidget's continuous scan loop trying to open a
  // second bottom sheet on top of one already showing a live-scanned code.
  bool _liveResultShowing = false;

  // Live text-region detection, layered on top of the same live-camera view
  // as barcode scanning. mobile_ocr's detectTextRegions() is a detector-only
  // (no recognition) call, but it's a MethodChannel API that only accepts a
  // file path -- no raw in-memory frame buffer support, unlike zxing's
  // synchronous FFI decode used for the barcode side above. Rather than
  // hand-rolling YUV->JPEG frame conversion (real engineering risk:
  // color-space/orientation bugs, for a feature meant to ship in a handful
  // of iterations) this uses CameraController.takePicture() on a timer to
  // get real hardware-encoded JPEGs -- the same file-based call
  // TextDetectorWidget already relies on for full recognition. Accepted
  // tradeoff: each cycle triggers Android's shutter sound (not disableable
  // via public API in most locales), so live mode clicks audibly roughly
  // once per _textScanInterval while scanning for text. If that's
  // unacceptably annoying in practice, a future iteration could lengthen
  // the interval or make it tap-to-scan instead of automatic.
  static const _textScanInterval = Duration(milliseconds: 1200);
  Timer? _textScanTimer;
  bool _textScanInFlight = false;
  Size? _liveTextRegionsImageSize;
  String? _liveTextRegionsImagePath;

  // Separate, slower pass that runs mobile_ocr's full detectText() (real
  // recognition, not just detection) against the same still the detection
  // cycle above already captured -- no extra takePicture() call, so no
  // extra shutter click. Deliberately its own timer with its own in-flight
  // guard rather than folding into _runTextScanCycle: sharing one flag
  // between two independently-paced jobs is exactly the bug that made the
  // manual snapshot button silently do nothing (see _takeSnapshot), and
  // detectText() is heavier than detectTextRegions() -- running it every
  // 1.2s would make the detection cycle's own latency problem worse, not
  // better. Slower cadence is fine here since recognized text is cached
  // per tracked region once found (see _TrackedTextRegion.recognizedText)
  // rather than needed every cycle.
  static const _textRecognitionInterval = Duration(milliseconds: 3000);
  Timer? _textRecognitionTimer;
  bool _textRecognitionInFlight = false;

  // Each detectTextRegions() cycle is an independent snapshot with no
  // memory of the last one -- replacing the shown boxes wholesale every
  // cycle made whichever blocks cleared the confidence threshold *this*
  // particular frame (subject to hand shake, refocus, fresh JPEG
  // re-encode noise) look like they were randomly flickering between
  // different text blocks, never settling. Tracked instead: match new
  // detections to the previous cycle's by IoU, carry a matched box's
  // identity forward, and give an unmatched one a few missed cycles of
  // grace before it disappears -- the same idea face-tracking APIs use,
  // scaled down to plain box overlap since true motion prediction is
  // overkill here.
  static const _textRegionIouMatchThreshold = 0.3;
  static const _textRegionMaxMissedCycles = 2;
  // Looser than the match threshold above on purpose: two tracked boxes
  // only need to clearly be "the same line of text" to justify collapsing
  // them, not a tight positional match. See _mergeOverlappingTrackedRegions.
  static const _textRegionMergeIouThreshold = 0.15;
  List<_TrackedTextRegion> _trackedTextRegions = [];

  @override
  void initState() {
    super.initState();
    // Warm start: app already running, image(s) shared in from another app.
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      if (files.isEmpty || !mounted) return;
      _setSharedImages(files);
    });
    // Cold start: app launched fresh via a share.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty && mounted) {
        _setSharedImages(files);
      }
      ReceiveSharingIntent.instance.reset();
    });
  }

  // This screen works on one photo at a time, so an ACTION_SEND_MULTIPLE
  // share (e.g. multi-select in Gallery) just loads the first image --
  // matches how "Ask AI" and the barcode overlay already only ever reason
  // about a single _imagePath. Told via a snackbar rather than silently
  // dropping the rest, since picking "first" silently would read as the
  // share having lost images.
  void _setSharedImages(List<SharedMediaFile> files) {
    _setImagePath(files.first.path);
    if (files.length > 1) {
      _showSnackBar('Shared ${files.length} images -- opened the first one');
    }
  }

  void _setImagePath(String path) {
    setState(() {
      _imagePath = path;
      _barcodes = const [];
      _stopLiveTextScan();
    });
    _scanBarcodes(path);
  }

  Future<void> _scanBarcodes(String path) async {
    try {
      // Not using zx.readBarcodesImagePath: it decodes via package:image's
      // decodeImage, which leaves EXIF orientation as metadata rather than
      // baking it into the pixel buffer. A portrait photo's raw sensor
      // buffer is landscape, so the Position it reports back is in that
      // unrotated frame -- while TextDetectorWidget displays (and this
      // screen's overlay is positioned against) the correctly-rotated
      // image. Boxes ended up geometrically offset from the actual code,
      // which read as "tapping does nothing". Decode+bake+resize ourselves
      // and feed raw bytes to zx.readBarcodes instead.
      //
      // maxSize deliberately near-unbounded (well past readBarcodesImagePath's
      // default of 768, and past this project's own earlier bump to 2500).
      // Measured directly against a real crumpled-receipt photo that failed
      // to decode: at this device's full 4096x3072 sensor resolution the
      // printed QR itself was only ~400x400px, ~8-9px/module -- 2500 already
      // shrank that to ~5px/module, on the edge of what survives JPEG
      // compression and camera noise. mobile_ocr's much heavier ONNX
      // inference already runs "pretty fast" on the same full-resolution
      // photo, so there's no real performance reason to be this aggressive
      // for a native decoder. Cap at this device's own resolution rather
      // than truly unbounded, as a guard against a shared photo from some
      // other phone's 100+MP sensor ballooning decode time/memory.
      final fileBytes = await File(path).readAsBytes();
      final decoded = imglib.decodeImage(fileBytes);
      if (decoded == null || !mounted || _imagePath != path) return;
      final oriented = imglib.bakeOrientation(decoded);
      final resized = resizeToMaxSize(oriented, 4096);
      final codes = zx.readBarcodes(
        rgbBytes(resized),
        DecodeParams(
          imageFormat: ImageFormat.rgb,
          width: resized.width,
          height: resized.height,
          tryHarder: true,
          isMultiScan: true,
        ),
      );
      // The picture may have been cleared/replaced while this was running.
      if (!mounted || _imagePath != path) return;
      setState(() {
        _barcodes = codes.codes
            .where((c) => c.isValid && c.position != null)
            .toList();
      });
    } catch (_) {
      // Best-effort overlay; a decode failure shouldn't break the OCR flow.
    }
  }

  /// Maps a barcode's position (in the source image's pixel space) to a
  /// screen [Rect] within [containerSize], matching mobile_ocr's own
  /// TextOverlayWidget BoxFit.contain letterbox math so the overlay lines up
  /// with what TextDetectorWidget is actually displaying underneath.
  Rect? _barcodeScreenRect(Code code, Size containerSize) {
    final pos = code.position;
    if (pos == null) return null;
    final imageSize = Size(
      pos.imageWidth.toDouble(),
      pos.imageHeight.toDouble(),
    );
    if (imageSize.width <= 0 || imageSize.height <= 0) return null;

    final fitted = applyBoxFit(BoxFit.contain, imageSize, containerSize);
    final displaySize = fitted.destination;
    final offsetX = (containerSize.width - displaySize.width) / 2;
    final offsetY = (containerSize.height - displaySize.height) / 2;
    final scaleX = displaySize.width / imageSize.width;
    final scaleY = displaySize.height / imageSize.height;

    final xs = [pos.topLeftX, pos.topRightX, pos.bottomLeftX, pos.bottomRightX];
    final ys = [pos.topLeftY, pos.topRightY, pos.bottomLeftY, pos.bottomRightY];
    final minX = xs.reduce(min).toDouble();
    final maxX = xs.reduce(max).toDouble();
    final minY = ys.reduce(min).toDouble();
    final maxY = ys.reduce(max).toDouble();

    // A little touch-target padding beyond the code's own quiet zone --
    // ZXing's reported corners hug the symbol tightly, which is a tiny
    // fingertip target otherwise.
    const pad = 12.0;
    return Rect.fromLTRB(
      offsetX + minX * scaleX - pad,
      offsetY + minY * scaleY - pad,
      offsetX + maxX * scaleX + pad,
      offsetY + maxY * scaleY + pad,
    );
  }

  // Shared by the barcode result sheet and the recognized-live-text result
  // sheet below -- generic clipboard copy, nothing barcode-specific about
  // it despite living next to _openBarcodeUrl.
  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showSnackBar('Copied');
  }

  Future<void> _openBarcodeUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _showSnackBar('Could not open link');
  }

  /// Handles a code from the live camera scanner. Reuses the same
  /// bottom-sheet result UI as the static-photo overlay rather than
  /// BarcodePage's now-deleted standalone copy.
  void _onLiveScan(Code? code) {
    if (code == null || !code.isValid || _liveResultShowing) return;
    _liveResultShowing = true;
    _showBarcodeResult(code, onDismissed: () => _liveResultShowing = false);
  }

  void _onLiveCameraController(CameraController? controller, Exception? error) {
    _textScanTimer?.cancel();
    _textRecognitionTimer?.cancel();
    _liveController = controller;
    _liveResultShowing = false;
    if (controller == null) {
      // Camera permission denied, or the controller otherwise failed to
      // initialize -- surface a fallback instead of a blank live view.
      if (mounted) setState(() => _liveCameraError = error);
      return;
    }
    if (_liveCameraError != null && mounted) {
      setState(() => _liveCameraError = null);
    }
    // Best-effort: warms mobile_ocr's model cache so the first detection
    // cycle isn't silently stuck behind a first-run download with no
    // feedback. Ignored on failure -- detectTextRegions() below will just
    // retry (and download if needed) on its own on a later cycle either way.
    unawaited(() async {
      try {
        await MobileOcr().prepareModels();
      } catch (_) {}
    }());
    _textScanTimer = Timer.periodic(
      _textScanInterval,
      (_) => _runTextScanCycle(controller),
    );
    _textRecognitionTimer = Timer.periodic(
      _textRecognitionInterval,
      (_) => _runTextRecognitionCycle(),
    );
  }

  Future<void> _runTextScanCycle(CameraController controller) async {
    if (_textScanInFlight || _imagePath != null || !mounted) return;
    if (!controller.value.isInitialized) return;
    _textScanInFlight = true;
    try {
      final xfile = await controller.takePicture();
      if (!mounted || _imagePath != null) return;
      final result = await MobileOcr().detectTextRegions(
        imagePath: xfile.path,
      );
      if (!mounted || _imagePath != null) return;
      setState(() {
        _updateTrackedTextRegions(result.regions);
        _liveTextRegionsImageSize = result.imageSize;
        _liveTextRegionsImagePath = xfile.path;
      });
    } catch (_) {
      // Best-effort, same spirit as _scanBarcodes: camera mid-teardown,
      // model still downloading, or takePicture() conflicting with
      // ReaderWidget's own concurrent startImageStream() barcode loop --
      // skip this cycle and try again next tick rather than surfacing an
      // error.
    } finally {
      _textScanInFlight = false;
    }
  }

  /// Slower recognition pass, layered on top of the detection cycle above.
  /// Runs mobile_ocr's full detectText() (detection + recognition together,
  /// for the whole frame in one call -- not a per-region API) against
  /// whatever still the detection cycle most recently captured, then
  /// matches the returned TextBlocks against currently-tracked regions by
  /// IoU (reusing the same helper the tracker itself uses) so a stable box
  /// picks up real recognized text instead of staying an empty outline.
  Future<void> _runTextRecognitionCycle() async {
    if (_textRecognitionInFlight || _imagePath != null || !mounted) return;
    final path = _liveTextRegionsImagePath;
    if (path == null) return;
    // Nothing to do if every currently-tracked box already has cached text,
    // or there's nothing tracked at all -- skip the heavier call entirely.
    if (_trackedTextRegions.isEmpty ||
        _trackedTextRegions.every((region) => region.recognizedText != null)) {
      return;
    }
    _textRecognitionInFlight = true;
    try {
      final result = await MobileOcr().detectText(imagePath: path);
      if (!mounted || _imagePath != null) return;
      // Each recognized block may be claimed by at most one tracked region --
      // without this, several tracked regions that overlap the same real
      // line well enough individually, but not each other enough to have
      // been merged, all independently pick that line as their own "best"
      // match and all cache the identical text, rendering as the same
      // recognized string repeated across multiple boxes. Mirrors the
      // claimed[] guard _updateTrackedTextRegions already uses for the
      // same reason on the detection side.
      final claimed = List<bool>.filled(result.blocks.length, false);
      var changed = false;
      for (final region in _trackedTextRegions) {
        if (region.recognizedText != null) continue;
        var bestIou = 0.0;
        var bestIndex = -1;
        for (var i = 0; i < result.blocks.length; i++) {
          if (claimed[i]) continue;
          final iou = _iou(region.box, result.blocks[i].boundingBox);
          if (iou > bestIou) {
            bestIou = iou;
            bestIndex = i;
          }
        }
        if (bestIndex != -1 &&
            bestIou >= _textRegionIouMatchThreshold &&
            result.blocks[bestIndex].text.isNotEmpty) {
          region.recognizedText = result.blocks[bestIndex].text;
          claimed[bestIndex] = true;
          changed = true;
        }
      }
      if (changed) setState(() {});
    } catch (_) {
      // Best-effort, same spirit as the detection cycle above -- skip this
      // pass and try again next tick rather than surfacing an error.
    } finally {
      _textRecognitionInFlight = false;
    }
  }

  /// Manual snapshot button: takes a still on the same controller the auto
  /// text-scan cycle uses, and freezes straight into photo/analysis mode
  /// via the same entry point a tapped live text-region box or a gallery
  /// pick already uses.
  ///
  /// Deliberately does NOT wait on _textScanInFlight. Measured on-device:
  /// a single auto-cycle takePicture()+detectTextRegions() round trip takes
  /// ~1.7-1.8s in practice, longer than its own ~1.2s tick interval -- so
  /// that flag is true roughly 75% of the time, and a tap landing then
  /// previously did nothing at all (confirmed: tapped, waited 3+ seconds,
  /// screen never froze). Cancel the auto-cycle outright instead of
  /// deferring to it. CameraX's own ImageCapture use case already queues/
  /// serializes concurrent takePicture() calls internally (logcat:
  /// "TakePictureManagerImpl: Issue the next TakePictureRequest"), so it's
  /// safe for this call to queue behind an already-in-flight auto-cycle
  /// capture at the CameraX level even without waiting on the Dart-side
  /// flag ourselves.
  Future<void> _takeSnapshot() async {
    final controller = _liveController;
    if (controller == null) return;
    if (!controller.value.isInitialized) return;
    _textScanTimer?.cancel();
    _textRecognitionTimer?.cancel();
    try {
      final xfile = await controller.takePicture();
      if (!mounted) return;
      _setImagePath(xfile.path);
    } catch (_) {
      if (mounted) _showSnackBar('Could not capture photo');
      // Freeze didn't happen -- still in live mode, so resume both live
      // scanning jobs rather than leaving them permanently stopped.
      if (mounted && _imagePath == null && _liveController != null) {
        _textScanTimer = Timer.periodic(
          _textScanInterval,
          (_) => _runTextScanCycle(_liveController!),
        );
        _textRecognitionTimer = Timer.periodic(
          _textRecognitionInterval,
          (_) => _runTextRecognitionCycle(),
        );
      }
    }
  }

  void _stopLiveTextScan() {
    _textScanTimer?.cancel();
    _textScanTimer = null;
    _textRecognitionTimer?.cancel();
    _textRecognitionTimer = null;
    _liveController = null;
    _trackedTextRegions = [];
    _liveTextRegionsImageSize = null;
    _liveTextRegionsImagePath = null;
  }

  /// Reconciles a fresh detection cycle's regions against the tracked boxes
  /// from previous cycles instead of replacing them outright -- see the
  /// comment on [_trackedTextRegions] for why.
  void _updateTrackedTextRegions(List<TextRegion> newRegions) {
    final newBoxes = newRegions.map((r) => r.boundingBox).toList();
    final claimed = List<bool>.filled(newBoxes.length, false);

    for (final tracked in _trackedTextRegions) {
      var bestIou = 0.0;
      var bestIndex = -1;
      for (var i = 0; i < newBoxes.length; i++) {
        if (claimed[i]) continue;
        final iou = _iou(tracked.box, newBoxes[i]);
        if (iou > bestIou) {
          bestIou = iou;
          bestIndex = i;
        }
      }
      if (bestIndex != -1 && bestIou >= _textRegionIouMatchThreshold) {
        tracked.box = newBoxes[bestIndex];
        tracked.missedCycles = 0;
        claimed[bestIndex] = true;
      } else {
        tracked.missedCycles++;
      }
    }

    _trackedTextRegions.removeWhere(
      (tracked) => tracked.missedCycles > _textRegionMaxMissedCycles,
    );

    for (var i = 0; i < newBoxes.length; i++) {
      if (!claimed[i]) {
        _trackedTextRegions.add(_TrackedTextRegion(newBoxes[i]));
      }
    }

    _mergeOverlappingTrackedRegions();
  }

  /// Collapses tracked regions that visibly overlap each other into one.
  ///
  /// Matching above only ever compares a tracked box against *new*
  /// detections, never against other tracked boxes -- so two tracked
  /// entries that independently drift (or get independently spawned) to
  /// nearly the same spot can coexist indefinitely, each accruing its own
  /// missed-cycle count instead of being recognized as duplicates.
  /// Confirmed on-device: a dense pile of amber boxes over just a
  /// handful of real lines, with recognized (green) labels visibly
  /// offset from both the unrecognized boxes and the real text
  /// underneath, since only one of several near-identical tracked
  /// entries for the same line was actually current. Runs after every
  /// update so duplicates never survive more than one frame.
  void _mergeOverlappingTrackedRegions() {
    var i = 0;
    while (i < _trackedTextRegions.length) {
      var mergedAny = false;
      var j = i + 1;
      while (j < _trackedTextRegions.length) {
        final a = _trackedTextRegions[i];
        final b = _trackedTextRegions[j];
        if (_iou(a.box, b.box) >= _textRegionMergeIouThreshold) {
          // Never discard a completed recognition; between two unrecognized
          // (or two recognized) entries, keep whichever has been tracked
          // more reliably.
          final keepA = a.recognizedText != null
              ? true
              : b.recognizedText != null
              ? false
              : a.missedCycles <= b.missedCycles;
          if (!keepA) {
            _trackedTextRegions[i] = b;
          }
          _trackedTextRegions.removeAt(j);
          mergedAny = true;
        } else {
          j++;
        }
      }
      if (!mergedAny) i++;
    }
  }

  /// Intersection-over-union of two rects, in the same coordinate space
  /// (here, the source photo's pixel space both come from). 0 for
  /// non-overlapping or degenerate rects.
  double _iou(Rect a, Rect b) {
    final intersection = a.intersect(b);
    if (intersection.width <= 0 || intersection.height <= 0) return 0;
    final intersectionArea = intersection.width * intersection.height;
    final unionArea =
        a.width * a.height + b.width * b.height - intersectionArea;
    if (unionArea <= 0) return 0;
    return intersectionArea / unionArea;
  }

  /// Maps a detector-only text region's bounding box (in the source photo's
  /// pixel space) to a screen [Rect] within [containerSize] -- same
  /// BoxFit.contain letterbox math as [_barcodeScreenRect], just starting
  /// from an already-axis-aligned [Rect] instead of four corner points.
  Rect? _textRegionScreenRect(Rect box, Size imageSize, Size containerSize) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return null;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, containerSize);
    final displaySize = fitted.destination;
    final offsetX = (containerSize.width - displaySize.width) / 2;
    final offsetY = (containerSize.height - displaySize.height) / 2;
    final scaleX = displaySize.width / imageSize.width;
    final scaleY = displaySize.height / imageSize.height;
    const pad = 4.0;
    return Rect.fromLTRB(
      offsetX + box.left * scaleX - pad,
      offsetY + box.top * scaleY - pad,
      offsetX + box.right * scaleX + pad,
      offsetY + box.bottom * scaleY + pad,
    );
  }

  /// Tapping a live text-region box freezes on the frame that produced it --
  /// already a real file on disk from takePicture() -- and feeds it into
  /// the exact same pipeline a picked/shared photo goes through. No new
  /// recognition code needed: detectTextRegions() only ever told us *where*
  /// text is, never what it says.
  void _freezeOnLiveTextRegion() {
    final path = _liveTextRegionsImagePath;
    if (path == null) return;
    _setImagePath(path);
  }

  void _showBarcodeResult(Code code, {VoidCallback? onDismissed}) {
    final text = code.text ?? '';
    final isUrl = _barcodeUrlPattern.hasMatch(text);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                code.format?.name ?? 'Barcode',
                style: Theme.of(sheetContext).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copyToClipboard(text),
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copy'),
                    ),
                  ),
                  if (isUrl) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _openBarcodeUrl(text),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) => onDismissed?.call());
  }

  /// Tapping a live text-region box that already has cached recognized
  /// text (see _runTextRecognitionCycle) shows it immediately instead of
  /// freezing into full photo mode -- the whole point of pre-recognizing
  /// it. Adapted from _showBarcodeResult's layout, minus the format label
  /// and URL-open button, which are barcode-specific.
  void _showRecognizedTextResult(String text) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _copyToClipboard(text),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shareSub.cancel();
    _controller.dispose();
    _textScanTimer?.cancel();
    _textRecognitionTimer?.cancel();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() => _isPickingImage = true);
    try {
      final file = await _picker.pickImage(source: source);
      if (file == null) return;
      if (!mounted) return;
      _setImagePath(file.path);
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

  // Which view is showing is derived from _imagePath alone (null -> live
  // camera, non-null -> photo/analysis) rather than a separate mode flag --
  // see the comment on _liveController for why. Ask AI and Clear only ever
  // apply once there's a photo, so they fall out of the same check.
  @override
  Widget build(BuildContext context) {
    final path = _imagePath;
    return Scaffold(
      appBar: AppBar(
        title: Text(path == null ? 'vl_ocr — live scan' : 'vl_ocr'),
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
              onPressed: () => setState(() {
                _imagePath = null;
                _barcodes = const [];
              }),
            ),
        ],
      ),
      body: path == null ? _buildLiveScanBody() : _buildPhotoBody(path),
    );
  }

  Widget _buildPhotoBody(String path) {
    return Stack(
      fit: StackFit.expand,
      children: [
        TextDetectorWidget(
          key: ValueKey(path),
          imagePath: path,
          backgroundColor: Colors.transparent,
          enableSelectionPreview: true,
          controller: _controller,
          onTextCopied: (text) => _showSnackBar(
            text.isEmpty ? 'Copied empty text' : 'Copied text (${text.length} chars)',
          ),
        ),
        // Barcode/QR overlay: only covers the small rects around detected
        // codes, so taps everywhere else fall straight through to
        // TextDetectorWidget's own selection gestures underneath.
        if (_barcodes.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                for (final code in _barcodes)
                  if (_barcodeScreenRect(code, constraints.biggest)
                      case final rect?)
                    Positioned.fromRect(
                      rect: rect,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showBarcodeResult(code),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.tealAccent,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(6),
                            color: Colors.teal.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  // Live camera scanning, formerly the separate BarcodePage route --
  // ReaderWidget already provides the camera preview + continuous decode
  // loop, flash/gallery/switch-camera controls, no custom camera code
  // needed here either. Now the app's home state (see the comment on
  // _liveController), with its own snapshot + gallery bar at the bottom
  // for entering photo/analysis mode on purpose, in addition to a tapped
  // text-region box freezing there automatically.
  Widget _buildLiveScanBody() {
    if (_liveCameraError != null) {
      // Camera permission denied or the controller otherwise failed to
      // initialize -- keep the app usable via Gallery rather than showing
      // a blank preview with no way forward.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                'Camera unavailable (permission denied?). '
                'You can still pick a photo from Gallery.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _isPickingImage
                    ? null
                    : () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
              ),
            ],
          ),
        ),
      );
    }
    final textImageSize = _liveTextRegionsImageSize;
    return Stack(
      children: [
        ReaderWidget(
          onScan: _onLiveScan,
          onScanFailure: (_) {},
          onControllerCreated: _onLiveCameraController,
          scanDelay: const Duration(milliseconds: 500),
          // ResolutionPreset.high (the unset default) measured via logcat
          // at 1280x720 on this device -- ~13x fewer pixels than a normal
          // photo (4096x3072), which directly starved post-freeze text
          // detection of detail on body-text-sized print. max ("the
          // highest resolution available" per camera_platform_interface's
          // own doc comment) fixes that, but this plugin ties Preview/
          // ImageCapture/ImageAnalysis to one shared resolution, so the
          // continuous barcode-scan and ~1.2s text-scan cycles now process
          // much bigger frames too -- not yet confirmed on-device whether
          // that makes live scanning noticeably laggier. If so, try
          // ResolutionPreset.ultraHigh (~2160p) or .veryHigh (~1080p) next
          // rather than reverting outright.
          resolution: ResolutionPreset.max,
          lensDirection: CameraLensDirection.back,
          // Defaults to false. User feedback (from when this lived in the
          // now-deleted BarcodePage): QR, especially dense ones like
          // Matter pairing codes, was slow/unreliable live. tryHarder
          // trades a bit of per-attempt speed for reliability; barcodes
          // already decode near-instantly so shouldn't be hurt by it.
          tryHarder: true,
          // ReaderWidget's own built-in gallery button runs its own
          // pick-and-barcode-decode flow -- not what we want now that
          // Gallery is a real entry point into full photo/analysis mode
          // (below), not just a barcode-only shortcut. Its flash/
          // switch-camera buttons stay, moved out of the way of both the
          // hint banner (top) and our own bar (bottom).
          showGallery: false,
          actionButtonsAlignment: Alignment.centerRight,
          flashOnIcon: const Icon(Icons.flash_on),
          flashOffIcon: const Icon(Icons.flash_off),
          flashAlwaysIcon: const Icon(Icons.flash_on),
          flashAutoIcon: const Icon(Icons.flash_auto),
          toggleCameraIcon: const Icon(Icons.switch_camera),
        ),
        // Live text-region overlay (v0.2.0 milestone): mobile_ocr's
        // detector-only call is throttled (see _textScanInterval) since,
        // unlike zxing's free synchronous FFI decode above, it's a
        // file-based MethodChannel call -- each cycle is a real
        // takePicture() + detectTextRegions() round trip. Tapping a box
        // freezes on the frame that produced it and hands off to the same
        // full-recognition pipeline a picked/shared photo already uses.
        if (_trackedTextRegions.isNotEmpty && textImageSize != null)
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                for (final region in _trackedTextRegions)
                  if (_textRegionScreenRect(
                        region.box,
                        textImageSize,
                        constraints.biggest,
                      )
                      case final rect?)
                    Positioned.fromRect(
                      rect: rect,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // A box with cached recognized text (see
                        // _runTextRecognitionCycle) shows it immediately
                        // instead of freezing into full photo mode -- no
                        // reason to re-run recognition from scratch on
                        // something already known.
                        onTap: region.recognizedText != null
                            ? () =>
                                  _showRecognizedTextResult(
                                    region.recognizedText!,
                                  )
                            : _freezeOnLiveTextRegion,
                        child: region.recognizedText == null
                            ? Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.amberAccent,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                  color: Colors.amber.withValues(alpha: 0.12),
                                ),
                              )
                            // Recognized: swap the empty outline for the
                            // actual text, legible at a glance instead of
                            // needing to freeze/zoom to read it -- this is
                            // the "magnify" ask, satisfied by just showing
                            // the real recognized string.
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.lightGreenAccent,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                  color: Colors.black.withValues(alpha: 0.72),
                                ),
                                child: Text(
                                  region.recognizedText!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                      ),
                    ),
              ],
            ),
          ),
        // ReaderWidget auto-scans continuously (no capture button by
        // design) but gave zero indication of that on its own -- just a
        // live camera feed with a subtle corner-bracket target frame and
        // nothing else, which read as broken.
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
                'Barcodes/QR scan automatically. Amber boxes are text — '
                'tap one to read it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        // Manual entry into photo/analysis mode: a snapshot button
        // (freezes the current view, same as tapping a text-region box)
        // plus a Gallery icon for loading an existing photo instead. Ask
        // AI only appears once one of these (or a tapped text box, or a
        // Share-sheet image) has set _imagePath -- see build().
        //
        // Gallery and the shutter are positioned independently rather than
        // as a centered Row -- a Row centers the *pair*, which visibly
        // pulls the shutter button off true screen-center toward the
        // Gallery side (confirmed via an on-device screenshot). The
        // shutter needs to land dead-center regardless of Gallery's own
        // position, so it's the Stack's one unpositioned child (centered
        // by the Stack's own alignment) while Gallery is independently
        // pinned to the left via Align.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.6,
                            ),
                            padding: const EdgeInsets.all(14),
                          ),
                          onPressed: _isPickingImage
                              ? null
                              : () => _pickImage(ImageSource.gallery),
                          icon: const Icon(
                            Icons.photo_library_outlined,
                            color: Colors.white,
                          ),
                          tooltip: 'Pick from Gallery',
                        ),
                      ),
                    ),
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white,
                        padding: const EdgeInsets.all(20),
                        shape: const CircleBorder(),
                      ),
                      onPressed: _liveController == null
                          ? null
                          : _takeSnapshot,
                      icon: const Icon(
                        Icons.camera,
                        color: Colors.black,
                        size: 32,
                      ),
                      tooltip: 'Take photo',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
