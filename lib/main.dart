import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const Color glassWhite = Color(0xDFFFFFFF);
const Color glassBorder = Color(0x38FFFFFF);
const Color accentBlue = Color(0xFFB8D8FF);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SnapEnhanceApp());
}

class SnapEnhanceApp extends StatelessWidget {
  const SnapEnhanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapEnhance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF08090D),
        colorScheme: ColorScheme.fromSeed(
          seedColor: accentBlue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  bool _loading = true;
  bool _processing = false;
  bool _switching = false;

  String? _error;
  String? _savedPath;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;

  bool get _isFrontCamera =>
      _controller?.description.lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    _initializeCameraList();
  }

  Future<void> _initializeCameraList() async {
    try {
      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        throw Exception('No camera was found on this device.');
      }

      final backCameras = _cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );

      await _openCamera(
        backCameras.isNotEmpty ? backCameras.first : _cameras.first,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openCamera(CameraDescription camera) async {
    final oldController = _controller;
    _controller = null;

    if (oldController != null) {
      await oldController.dispose();
    }

    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    CameraController? nextController;

    try {
      nextController = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await nextController.initialize();

      final deviceMin = await nextController.getMinZoomLevel();
      final deviceMax = await nextController.getMaxZoomLevel();

      final startZoom = 1.0.clamp(deviceMin, deviceMax).toDouble();

      if (!mounted) {
        await nextController.dispose();
        return;
      }

      _controller = nextController;

      setState(() {
        _minZoom = deviceMin;
        _maxZoom = deviceMax < 5.0 ? deviceMax : 5.0;
        _zoom = startZoom;
        _loading = false;
      });

      await nextController.setZoomLevel(startZoom);
    } catch (e) {
      await nextController?.dispose();

      if (!mounted) return;

      setState(() {
        _error = 'Could not open camera: $e';
        _loading = false;
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_switching || _processing || _loading) return;

    final target = _isFrontCamera
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    final candidates = _cameras.where(
      (camera) => camera.lensDirection == target,
    );

    if (candidates.isEmpty) {
      _message('This camera is not available.');
      return;
    }

    setState(() => _switching = true);

    try {
      await _openCamera(candidates.first);
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  Future<void> _changeZoom(double value) async {
    final camera = _controller;

    if (camera == null ||
        !camera.value.isInitialized ||
        value < _minZoom ||
        value > _maxZoom) {
      return;
    }

    try {
      await camera.setZoomLevel(value);

      if (mounted) {
        setState(() => _zoom = value);
      }
    } catch (e) {
      _message('Could not change zoom: $e');
    }
  }

  Future<void> _captureAndEnhance() async {
    final camera = _controller;

    if (camera == null ||
        !camera.value.isInitialized ||
        _processing ||
        _loading) {
      return;
    }

    setState(() {
      _processing = true;
      _savedPath = null;
    });

    try {
      // Capture a real photo from the camera.
      final XFile photo = await camera.takePicture();
      final Uint8List originalBytes = await photo.readAsBytes();

      if (originalBytes.isEmpty) {
        throw Exception('The camera returned an empty photo.');
      }

      final decoded = img.decodeImage(originalBytes);

      if (decoded == null || decoded.width == 0 || decoded.height == 0) {
        throw Exception('Could not decode the captured photo.');
      }

      // Apply subtle enhancement to the actual captured image.
      final enhanced = img.adjustColor(
        decoded,
        brightness: 0.025,
        contrast: 1.06,
        saturation: 1.04,
      );

      final Uint8List outputBytes = Uint8List.fromList(
        img.encodeJpg(enhanced, quality: 95),
      );

      // Verify the output before attempting to save it.
      final check = img.decodeImage(outputBytes);

      if (check == null || check.width == 0 || check.height == 0) {
        throw Exception('The enhanced photo is invalid.');
      }

      final directory = await getTemporaryDirectory();
      final filename =
          'snapenhance_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final outputFile = File(p.join(directory.path, filename));

      await outputFile.writeAsBytes(outputBytes, flush: true);

      // Verify the written file, not just the in-memory bytes.
      final writtenBytes = await outputFile.readAsBytes();
      final writtenImage = img.decodeImage(writtenBytes);

      if (writtenImage == null ||
          writtenImage.width == 0 ||
          writtenImage.height == 0) {
        throw Exception('The saved image file could not be verified.');
      }

      // Save the verified enhanced photo to Android Gallery.
      await Gal.putImage(outputFile.path);

      if (!mounted) return;

      setState(() => _savedPath = outputFile.path);
      _message('Photo saved to Gallery successfully.');
    } catch (e) {
      if (!mounted) return;
      _message('Photo save failed: $e');
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  void _message(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _controller;

    return Scaffold(
      backgroundColor: const Color(0xFF08090D),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                    )
                  : camera != null && camera.value.isInitialized
                  ? _buildCameraPreview(camera)
                  : const Center(child: Text('Camera unavailable.')),
            ),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: accentBlue, size: 25),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'SnapEnhance',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.6,
              ),
            ),
          ),
          _glassButton(
            icon: Icons.cameraswitch_rounded,
            onTap: _loading || _switching || _processing ? null : _switchCamera,
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(CameraController camera) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the camera's aspect ratio; never stretch its image.
        final previewRatio = camera.value.aspectRatio;

        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;

        final fittedHeight = availableWidth / previewRatio;

        return ClipRect(
          child: Center(
            child: SizedBox(
              width: availableWidth,
              height: fittedHeight <= availableHeight
                  ? fittedHeight
                  : availableHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: CameraPreview(camera),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x0008090D), Color(0xCC08090D), Color(0xFF08090D)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'ZOOM',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 2,
                  color: Colors.white60,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${_zoom.toStringAsFixed(1)}×',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accentBlue,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: accentBlue.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              min: _minZoom,
              max: _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
              value: _zoom.clamp(
                _minZoom,
                _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
              ),
              onChanged: _maxZoom > _minZoom ? _changeZoom : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_isFrontCamera && _minZoom <= 0.6) _zoomPill('0.6×', 0.6),
              _zoomPill('1×', 1.0),
              _zoomPill('2×', 2.0),
              _zoomPill('5×', 5.0),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const SizedBox(width: 54),
              Expanded(
                child: GestureDetector(
                  onTap: _processing || _loading ? null : _captureAndEnhance,
                  child: AnimatedOpacity(
                    opacity: _processing || _loading ? 0.55 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.75),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accentBlue.withValues(alpha: 0.12),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFFFFFF), Color(0xFFD7E5F7)],
                          ),
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: Center(
                          child: _processing
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF24384F),
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome,
                                  color: Color(0xFF24384F),
                                  size: 28,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 54,
                child: _savedPath == null
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        onTap: () => _showSavedPhoto(),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(_savedPath!),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.photo),
                          ),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _processing ? 'Enhancing photo…' : 'CAPTURE & ENHANCE',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.shield_outlined, size: 14, color: Colors.white54),
              SizedBox(width: 6),
              Text(
                'On-device processing · No cloud upload',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _zoomPill(String label, double value) {
    final available = value >= _minZoom && value <= _maxZoom;
    final selected = (_zoom - value).abs() < 0.08;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: _glassButton(
        label: label,
        selected: selected,
        onTap: available ? () => _changeZoom(value) : null,
      ),
    );
  }

  Widget _glassButton({
    IconData? icon,
    String? label,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: selected
              ? accentBlue.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.07),
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: selected
                      ? accentBlue.withValues(alpha: 0.7)
                      : glassBorder,
                ),
              ),
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 22, color: glassWhite)
                    : Text(
                        label ?? '',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : Colors.white70,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSavedPhoto() {
    final path = _savedPath;
    if (path == null) return;

    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF17191F),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(File(path)),
              ),
              const SizedBox(height: 12),
              const Text('Enhanced photo saved to Gallery'),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
