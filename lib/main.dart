import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
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
        throw Exception('No camera found on this device.');
      }

      final back = _cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );

      final selected = back.isNotEmpty ? back.first : _cameras.first;
      await _openCamera(selected);
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

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _savedPath = null;
      });
    }

    CameraController? newController;

    try {
      newController = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await newController.initialize();

      final deviceMin = await newController.getMinZoomLevel();
      final deviceMax = await newController.getMaxZoomLevel();

      // Prefer 1x as the starting zoom when the camera supports it.
      final startZoom = 1.0.clamp(deviceMin, deviceMax).toDouble();

      if (!mounted) {
        await newController.dispose();
        return;
      }

      _controller = newController;
      setState(() {
        _minZoom = deviceMin;
        _maxZoom = deviceMax < 5.0 ? deviceMax : 5.0;
        _zoom = startZoom;
        _loading = false;
      });

      await newController.setZoomLevel(startZoom);
    } catch (e) {
      await newController?.dispose();

      if (!mounted) return;
      setState(() {
        _error = 'Could not open camera: $e';
        _loading = false;
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_switching || _processing) return;

    final targetDirection = _isFrontCamera
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    final matching = _cameras.where((c) => c.lensDirection == targetDirection);

    if (matching.isEmpty) {
      _showMessage('This camera is not available on your device.');
      return;
    }

    setState(() => _switching = true);

    try {
      await _openCamera(matching.first);
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
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
        throw Exception('Could not read captured photo.');
      }

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

      // Save the enhanced image to the phone's gallery.
      await Gal.putImage(outputFile.path);

      if (!mounted) return;

      setState(() => _savedPath = outputFile.path);
      _showMessage('Enhanced photo saved to Gallery!');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not save photo: $e');
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      appBar: AppBar(
        title: const Text('SnapEnhance'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Switch front/back camera',
            onPressed: _loading || _switching || _processing
                ? null
                : _switchCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: controller != null && controller.value.isInitialized
                      ? ClipRect(
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio,
                              child: CameraPreview(controller),
                            ),
                          ),
                        )
                      : const Center(child: Text('Camera unavailable.')),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Zoom ${_zoom.toStringAsFixed(1)}×',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (_maxZoom < 5.0)
                            const Text(
                              'Device zoom limit',
                              style: TextStyle(fontSize: 12),
                            ),
                        ],
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _zoomButton('1×', 1.0),
                          if (!_isFrontCamera && _minZoom <= 0.6)
                            _zoomButton('0.6×', 0.6),
                          _zoomButton('2×', 2.0),
                          _zoomButton('5×', 5.0),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _processing ? null : _captureAndEnhance,
                          icon: const Icon(Icons.camera_alt),
                          label: Text(
                            _processing ? 'Enhancing...' : 'Capture & Enhance',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'On-device processing • No cloud photo upload',
                        textAlign: TextAlign.center,
                      ),
                      if (_savedPath != null) ...[
                        const SizedBox(height: 12),
                        const Text('Enhanced photo preview'),
                        const SizedBox(height: 8),
                        Image.file(
                          File(_savedPath!),
                          height: 140,
                          fit: BoxFit.contain,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _zoomButton(String label, double value) {
    final available = value >= _minZoom && value <= _maxZoom;

    return TextButton(
      onPressed: available ? () => _changeZoom(value) : null,
      child: Text(label),
    );
  }
}
