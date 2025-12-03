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
  const YoloCameraPage({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  State<YoloCameraPage> createState() => _YoloCameraPageState();
}

class _YoloCameraPageState extends State<YoloCameraPage>
    with WidgetsBindingObserver {
  final YoloDetector _detector = YoloDetector(
    confidenceThreshold: 0.7,
    nmsThreshold: 0.1,
  );

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

  @override
  void initState() {
    super.initState();
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
      await previousController.dispose();
    }
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _cameraController = controller;

    try {
      await controller.initialize();
      if (_isDetectionActive) {
        await controller.startImageStream(_processCameraImage);
      }
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
    }
  }

  void _processCameraImage(CameraImage cameraImage) {
    final controller = _cameraController;
    if (_isProcessingFrame ||
        controller == null ||
        !controller.value.isStreamingImages ||
        !_detector.isInitialized) {
      return;
    }

    _isProcessingFrame = true;
    _detector
        .predict(
      cameraImage,
      sensorOrientation: controller.description.sensorOrientation,
      lensDirection: controller.description.lensDirection,
    )
        .then((detections) {
      if (mounted) {
        setState(() {
          _detections = detections;
        });
      }
    }).catchError((Object error) {
      if (mounted) {
        setState(() {
          _errorMessage ??= '$error';
        });
      } else {
        _errorMessage ??= '$error';
      }
    }).whenComplete(() {
      _isProcessingFrame = false;
    });
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
      controller.dispose();
      _cameraController = null;
      _isCameraActive = false;
      _isDetectionActive = false;
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
    final isCameraAvailable = _isCameraActive &&
        controller != null &&
        controller.value.isInitialized;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

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
                            padding: EdgeInsets.only(bottom: 12.h, top: 12.h),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: CameraPreviewView(
                                controller: controller,
                                detections: _detections,
                                statusChip: DetectionStatusChip(
                                  detectionCount: _detections.length,
                                  isDetectionActive: _isDetectionActive,
                                ),
                                controls: _buildControlButtons(),
                                isCameraAvailable: isCameraAvailable,
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
        });
      } else {
        _isCameraActive = true;
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
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _detections = const [];
      }
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
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
      _cameraController = null;
      _isProcessingFrame = false;
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _isDetectionActive = false;
          _detections = const [];
        });
      } else {
        _isCameraActive = false;
        _isDetectionActive = false;
        _detections = const [];
      }
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
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
        _isProcessingFrame = false;
        if (mounted) {
          setState(() {
            _isDetectionActive = false;
            _detections = const [];
          });
        } else {
          _isDetectionActive = false;
          _detections = const [];
        }
      } on CameraException catch (error) {
        if (mounted) {
          setState(() {
            _errorMessage ??=
                'Detection stop error: ${error.description ?? error.code}';
          });
        } else {
          _errorMessage ??=
              'Detection stop error: ${error.description ?? error.code}';
        }
      }
      return;
    }

    try {
      await controller.startImageStream(_processCameraImage);
      if (mounted) {
        setState(() {
          _isDetectionActive = true;
        });
      } else {
        _isDetectionActive = true;
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
    if (widget.cameras.length < 2 || _isChangingCamera || _isCameraBusy) {
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
