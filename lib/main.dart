import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const SnapEnhanceApp());
}

class SnapEnhanceApp extends StatelessWidget {
  const SnapEnhanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapEnhance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
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
  bool _loading = true;
  bool _processing = false;
  String? _error;
  String? _savedPath;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        throw Exception('No camera found on this device.');
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await controller.initialize();

      final minZoom = await controller.getMinZoomLevel();
      final maxZoom = await controller.getMaxZoomLevel();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _minZoom = minZoom;
        _maxZoom = maxZoom < 5.0 ? maxZoom : 5.0;
        _zoom = minZoom;
        _loading = false;
      });

      await controller.setZoomLevel(_zoom);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _changeZoom(double value) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() => _zoom = value);

    try {
      await controller.setZoomLevel(value);
    } catch (e) {
      debugPrint('Zoom error: $e');
    }
  }

  Future<void> _captureAndEnhance() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized || _processing) {
      return;
    }

    setState(() {
      _processing = true;
      _savedPath = null;
    });

    try {
      final XFile photo = await controller.takePicture();
      final Uint8List bytes = await photo.readAsBytes();

      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw Exception('Could not read the captured photo.');
      }

      // Basic automatic enhancement for the first version.
      final enhanced = img.adjustColor(
        decoded,
        brightness: 0.04,
        contrast: 1.08,
        saturation: 1.05,
      );

      final outputBytes = img.encodeJpg(enhanced, quality: 92);
      final directory = await getApplicationDocumentsDirectory();

      final fileName =
          'snapenhance_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final outputFile = File(p.join(directory.path, fileName));

      await outputFile.writeAsBytes(outputBytes);

      if (!mounted) return;

      setState(() {
        _savedPath = outputFile.path;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enhanced photo saved on this device.')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Photo processing failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(title: const Text('SnapEnhance'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Camera error:\n$_error'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: controller != null && controller.value.isInitialized
                        ? AspectRatio(
                            aspectRatio: controller.value.aspectRatio,
                            child: CameraPreview(controller),
                          )
                        : const Text('Camera is unavailable.'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Zoom: ${_zoom.toStringAsFixed(1)}×'
                        '${_maxZoom < 5 ? ' (device limit)' : ''}',
                      ),
                      Slider(
                        min: _minZoom,
                        max: _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
                        value: _zoom.clamp(
                          _minZoom,
                          _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
                        ),
                        onChanged: _maxZoom > _minZoom ? _changeZoom : null,
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _processing ? null : _captureAndEnhance,
                          icon: const Icon(Icons.camera_alt),
                          label: Text(
                            _processing
                                ? 'Enhancing photo...'
                                : 'Capture & Enhance',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'On-device processing • No cloud photo upload',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                if (_savedPath != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const Text('Enhanced photo'),
                        const SizedBox(height: 8),
                        Image.file(
                          File(_savedPath!),
                          height: 180,
                          fit: BoxFit.contain,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
