import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:yolo/common/colors.dart';

import '../detector/yolo_detector.dart';
import '../models/detection.dart';
import '../widget/camera_control_buttons.dart';
import '../view/camera_error_view.dart';
import '../view/camera_preview_view.dart';
import '../widget/detection_status_chip.dart';

class YoloCameraPage extends StatefulWidget {
  const YoloCameraPage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<YoloCameraPage> createState() => _YoloCameraPageState();
}

class _YoloCameraPageState extends State<YoloCameraPage>
    with WidgetsBindingObserver {
  static const Duration _cameraFpsUpdateInterval =
      Duration(milliseconds: 200);
  late YoloDetector _detector;

  CameraController? _cameraController;
  List<Detection> _detections = const [];
  String? _errorMessage;
  bool _isProcessingFrame = false;
  bool _isInitializing = true;
  bool _isCameraActive = false;
  bool _isDetectionActive = false;
  int _currentCameraIndex = 0;
  bool _isChangingCamera = false;
  bool _isCameraBusy = false;
  bool _useGpuDelegate = false;
  bool _isDetectorInitializing = false;
  double _confidenceThreshold = 0.6;
  double _nmsThreshold = 0.1;
  double _cameraFps = 0;
  double _detectionFps = 0;
  DateTime? _lastCameraFrameTime;
  DateTime? _lastCameraFpsUpdateTime;

  @override
  void initState() {
    super.initState();
    _detector = YoloDetector(
      confidenceThreshold: _confidenceThreshold,
      nmsThreshold: _nmsThreshold,
      enableGpuDelegate: _useGpuDelegate,
    );
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (widget.cameras.isEmpty) {
        throw StateError('No available cameras on this device.');
      }
      _currentCameraIndex = _preferredCameraIndex;
      await _detector.initialize();
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = '$error';
        });
      } else {
        _errorMessage = '$error';
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  CameraDescription get _preferredCamera {
    if (widget.cameras.isEmpty) {
      throw StateError('No cameras found on this device.');
    }
    return widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
  }

  int get _preferredCameraIndex {
    if (widget.cameras.isEmpty) {
      throw StateError('No cameras found on this device.');
    }
    final index = widget.cameras.indexWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
    return index == -1 ? 0 : index;
  }

  CameraDescription get _currentCamera => widget.cameras[_currentCameraIndex];

  Future<void> _initializeCamera(CameraDescription description) async {
    final previousController = _cameraController;
    if (previousController != null) {
      if (previousController.value.isStreamingImages) {
        await previousController.stopImageStream();
      }
      if (mounted) {
        setState(() {
          _cameraController = null;
        });
      } else {
        _cameraController = null;
      }
      await previousController.dispose();
    }
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // IOS NV12 preprocess handles it
    );

    _cameraController = controller;

    try {
      await controller.initialize();
      _clearCameraFps();
      _clearDetectionFps();
      await _startImageStreamIfNeeded();
      if (mounted) {
        setState(() {});
      }
    } on CameraException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Camera error: ${error.description ?? error.code}';
        });
      } else {
        _errorMessage = 'Camera error: ${error.description ?? error.code}';
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Camera stream error: $error';
        });
      } else {
        _errorMessage = 'Camera stream error: $error';
      }
    }
  }

  void _processCameraImage(CameraImage cameraImage) {
    _updateCameraFps(DateTime.now());
    final controller = _cameraController;
    if (controller == null || !controller.value.isStreamingImages) {
      return;
    }
    if (!_isDetectionActive || !_detector.isInitialized) {
      return;
    }
    if (_isProcessingFrame) {
      return;
    }

    _isProcessingFrame = true;
    final detectionStart = DateTime.now();
    final rotationDegrees = Platform.isIOS
        ? 0 // iOS preview is already oriented; avoid double rotation on boxes
        : controller.description.sensorOrientation;
    _detector
        .predict(
          cameraImage,
          sensorOrientation: rotationDegrees,
          lensDirection: controller.description.lensDirection,
        )
        .then((detections) {
          if (!mounted || !_isDetectionActive) {
            return;
          }
          final detectionEnd = DateTime.now();
          final durationMicros =
              detectionEnd.difference(detectionStart).inMicroseconds;
          final detectionFps =
              durationMicros > 0 ? 1000000.0 / durationMicros : 0.0;
          if (mounted) {
            setState(() {
              _detections = detections;
              _detectionFps = detectionFps;
            });
          }
        })
        .catchError((Object error) {
          if (mounted) {
            setState(() {
              _errorMessage ??= '$error';
            });
          } else {
            _errorMessage ??= '$error';
          }
        })
        .whenComplete(() {
          _isProcessingFrame = false;
        });
  }

  void _updateCameraFps(DateTime timestamp) {
    final previousTimestamp = _lastCameraFrameTime;
    _lastCameraFrameTime = timestamp;
    if (previousTimestamp == null) {
      return;
    }
    final elapsedMicros =
        timestamp.difference(previousTimestamp).inMicroseconds;
    if (elapsedMicros <= 0) {
      return;
    }
    final fps = 1000000.0 / elapsedMicros;
    final lastUpdate = _lastCameraFpsUpdateTime;
    if (lastUpdate != null &&
        timestamp.difference(lastUpdate) < _cameraFpsUpdateInterval) {
      return;
    }
    _lastCameraFpsUpdateTime = timestamp;
    if (mounted) {
      setState(() {
        _cameraFps = fps;
      });
    } else {
      _cameraFps = fps;
    }
  }

  void _clearCameraFps() {
    _lastCameraFrameTime = null;
    _lastCameraFpsUpdateTime = null;
    _cameraFps = 0;
  }

  void _clearDetectionFps() {
    _detectionFps = 0;
  }

  Future<void> _startImageStreamIfNeeded() async {
    final controller = _cameraController;
    if (controller == null || controller.value.isStreamingImages) {
      return;
    }
    await controller.startImageStream(_processCameraImage);
  }

  Future<void> _onAcceleratorToggle(bool value) async {
    if (_useGpuDelegate == value) {
      return;
    }
    setState(() {
      _useGpuDelegate = value;
    });
    await _reconfigureDetector();
  }

  Future<void> _onConfidenceChangeEnd(double value) async {
    await _reconfigureDetector();
  }

  Future<void> _onNmsChangeEnd(double value) async {
    await _reconfigureDetector();
  }

  Future<void> _reconfigureDetector() async {
    if (_isDetectorInitializing) {
      return;
    }
    setState(() {
      _isDetectorInitializing = true;
      _detections = const [];
      _detectionFps = 0;
    });
    final controller = _cameraController;
    final bool wasDetectionActive = _isDetectionActive;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    _isProcessingFrame = false;
    if (mounted) {
      setState(() {
        _isDetectionActive = false;
      });
    } else {
      _isDetectionActive = false;
    }

    _detector.close();
    _detector = YoloDetector(
      confidenceThreshold: _confidenceThreshold,
      nmsThreshold: _nmsThreshold,
      enableGpuDelegate: _useGpuDelegate,
    );
    try {
      await _detector.initialize();
      if (wasDetectionActive) {
        await _startImageStreamIfNeeded();
        if (mounted) {
          setState(() {
            _isDetectionActive = true;
          });
        } else {
          _isDetectionActive = true;
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = '$error';
        });
      } else {
        _errorMessage = '$error';
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDetectorInitializing = false;
        });
      } else {
        _isDetectorInitializing = false;
      }
    }
  }

  Widget _buildAcceleratorRow(String acceleratorLabel) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Accelerator',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              acceleratorLabel,
              style: const TextStyle(color: Colors.black87),
            ),
          ],
        ),
        Switch(
          value: _useGpuDelegate,
          onChanged: (_isDetectorInitializing || _isCameraBusy)
              ? null
              : (value) => _onAcceleratorToggle(value),
        ),
      ],
    );
  }

  Widget _buildConfidenceSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Confidence threshold: ${_confidenceThreshold.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Slider(
          value: _confidenceThreshold,
          min: 0.1,
          max: 0.9,
          divisions: 40,
          label: _confidenceThreshold.toStringAsFixed(2),
          onChanged: (value) {
            setState(() {
              _confidenceThreshold = value;
            });
          },
          onChangeEnd: (value) {
            if (!_isDetectorInitializing) {
              _onConfidenceChangeEnd(value);
            }
          },
        ),
      ],
    );
  }

  Widget _buildNmsSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'NMS threshold: ${_nmsThreshold.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Slider(
          value: _nmsThreshold,
          min: 0.1,
          max: 0.9,
          divisions: 40,
          label: _nmsThreshold.toStringAsFixed(2),
          onChanged: (value) {
            setState(() {
              _nmsThreshold = value;
            });
          },
          onChangeEnd: (value) {
            if (!_isDetectorInitializing) {
              _onNmsChangeEnd(value);
            }
          },
        ),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      if (controller.value.isStreamingImages) {
        controller.stopImageStream();
      }
      if (mounted) {
        setState(() {
          _cameraController = null;
          _isCameraActive = false;
          _isDetectionActive = false;
        });
      } else {
        _cameraController = null;
        _isCameraActive = false;
        _isDetectionActive = false;
      }
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (_isCameraActive) {
        _initializeCamera(_currentCamera);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final isCameraAvailable =
        _isCameraActive && controller != null && controller.value.isInitialized;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final acceleratorLabel =
        _useGpuDelegate ? 'GPU delegate' : 'XNNPack (default)';

    return Scaffold(
      backgroundColor: DEFAULT_BG,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        elevation: 0,
        backgroundColor: DEFAULT_BG,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "YOLOv11n realtime",
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _errorMessage != null
            ? CameraErrorView(
                message: _errorMessage ?? 'An unknown error occurred.',
              )
            : _isInitializing
                ? const Center(child: CircularProgressIndicator())
                : AnimatedPadding(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    padding: EdgeInsets.only(bottom: bottomInset),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      width: double.infinity,
                      height: double.infinity,
                      decoration: const BoxDecoration(color: DEFAULT_BG),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            padding:
                                EdgeInsets.only(bottom: 12.h, top: 12.h),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CameraPreviewView(
                                    controller: controller,
                                    detections: _detections,
                                    acceleratorLabel: acceleratorLabel,
                                    cameraFps: _cameraFps,
                                    detectionFps: _detectionFps,
                                    statusChip: DetectionStatusChip(
                                      detectionCount: _detections.length,
                                      isDetectionActive: _isDetectionActive,
                                    ),
                                    controls: _buildControlButtons(),
                                    isCameraAvailable: isCameraAvailable,
                                  ),
                                  SizedBox(height: 20.h),
                                  _buildAcceleratorRow(acceleratorLabel),
                                  SizedBox(height: 12.h),
                                  _buildConfidenceSlider(),
                                  SizedBox(height: 12.h),
                                  _buildNmsSlider(),
                                  if (_isDetectorInitializing)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 12),
                                      child: Text(
                                        'Reconfiguring accelerator...',
                                        style:
                                            TextStyle(color: Colors.black54),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _buildControlButtons() {
    final controller = _cameraController;
    final isControllerReady =
        controller != null && controller.value.isInitialized;
    return CameraControlButtons(
      isCameraActive: _isCameraActive,
      isDetectionActive: _isDetectionActive,
      isControllerReady: isControllerReady,
      isCameraBusy: _isCameraBusy,
      isChangingCamera: _isChangingCamera,
      camerasLength: widget.cameras.length,
      onToggleCamera: _toggleCamera,
      onToggleDetection: _toggleDetection,
      onSwitchCamera: _switchCamera,
    );
  }

  Future<void> _toggleCamera() async {
    if (_isCameraBusy) {
      return;
    }
    if (_isCameraActive) {
      await _stopCamera();
    } else {
      await _startCamera();
    }
  }

  Future<void> _startCamera() async {
    if (_isCameraBusy || _isCameraActive) {
      return;
    }
    if (mounted) {
      setState(() {
        _isCameraBusy = true;
      });
    } else {
      _isCameraBusy = true;
    }
    try {
      await _initializeCamera(_currentCamera);
      if (mounted) {
        setState(() {
          _isCameraActive = true;
          _clearCameraFps();
          _clearDetectionFps();
        });
      } else {
        _isCameraActive = true;
        _clearCameraFps();
        _clearDetectionFps();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCameraBusy = false;
        });
      } else {
        _isCameraBusy = false;
      }
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    if (controller == null || !_isCameraActive) {
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _isDetectionActive = false;
          _detections = const [];
          _clearCameraFps();
          _clearDetectionFps();
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _detections = const [];
        _clearCameraFps();
        _clearDetectionFps();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isCameraBusy = true;
        _isCameraActive = false;
        _isDetectionActive = false;
        _detections = const [];
        _clearCameraFps();
        _clearDetectionFps();
      });
    } else {
      _isCameraBusy = true;
      _isCameraActive = false;
      _isDetectionActive = false;
      _detections = const [];
      _clearCameraFps();
      _clearDetectionFps();
    }

    _cameraController = null;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
      _isProcessingFrame = false;
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage ??= '$error';
        });
      } else {
        _errorMessage ??= '$error';
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCameraBusy = false;
        });
      } else {
        _isCameraBusy = false;
      }
    }
  }

  Future<void> _toggleDetection() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isCameraBusy) {
      return;
    }
    if (_isDetectionActive) {
      _isProcessingFrame = false;
      if (mounted) {
        setState(() {
          _isDetectionActive = false;
          _detections = const [];
          _clearDetectionFps();
        });
      } else {
        _isDetectionActive = false;
        _detections = const [];
        _clearDetectionFps();
      }
      return;
    }

    try {
      await _startImageStreamIfNeeded();
      if (mounted) {
        setState(() {
          _isDetectionActive = true;
          _clearDetectionFps();
        });
      } else {
        _isDetectionActive = true;
        _clearDetectionFps();
      }
    } on CameraException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Detection start error: ${error.description ?? error.code}';
        });
      } else {
        _errorMessage =
            'Detection start error: ${error.description ?? error.code}';
      }
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2 ||
        _isChangingCamera ||
        _isCameraBusy ||
        !_isCameraActive) {
      return;
    }
    final nextIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    if (mounted) {
      setState(() {
        _isChangingCamera = true;
        _currentCameraIndex = nextIndex;
      });
    } else {
      _isChangingCamera = true;
      _currentCameraIndex = nextIndex;
    }

    try {
      if (_isCameraActive) {
        await _initializeCamera(widget.cameras[nextIndex]);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isChangingCamera = false;
        });
      } else {
        _isChangingCamera = false;
      }
    }
  }
}
