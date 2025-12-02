import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'detector/yolo_detector.dart';
import 'models/detection.dart';
import 'widgets/detection_painter.dart';

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
  final YoloDetector _detector = YoloDetector();

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
        throw StateError('기기에 사용 가능한 카메라가 없습니다.');
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
      throw StateError('기기에 카메라가 없습니다.');
    }
    return widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
  }

  int get _preferredCameraIndex {
    if (widget.cameras.isEmpty) {
      throw StateError('기기에 카메라가 없습니다.');
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
      ResolutionPreset.low,
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

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('YOLOv11 nano realtime'),
      ),
      body: SafeArea(
        child: _errorMessage != null
            ? _buildError()
            : _isInitializing
                ? const Center(child: CircularProgressIndicator())
                : (_isCameraActive &&
                        controller != null &&
                        controller.value.isInitialized)
                    ? _buildCameraPreview(controller)
                    : _buildCameraIdle(),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _errorMessage ?? '알 수 없는 오류가 발생했어요.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  Widget _buildCameraPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    final previewSizeText = previewSize != null
        ? '${previewSize.width.toStringAsFixed(0)} x ${previewSize.height.toStringAsFixed(0)}'
        : '알 수 없음';
    final preview = AspectRatio(
      aspectRatio: 1 / controller.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller),
          Positioned.fill(
            child: CustomPaint(
              painter: DetectionPainter(detections: _detections),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 16,
            child: _buildStatusChip(),
          ),
        ],
      ),
    );

    return Column(
      children: [
        Expanded(child: Center(child: preview)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Model: YOLOv11-nano • Detections: ${_detections.length}\n이미지 크기: $previewSizeText',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
        _buildControlButtons(),
      ],
    );
  }

  Widget _buildCameraIdle() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Text(
              '촬영 버튼을 눌러 카메라를 시작하세요.',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
        _buildControlButtons(),
      ],
    );
  }

  Widget _buildControlButtons() {
    final controller = _cameraController;
    final isControllerReady =
        controller != null && controller.value.isInitialized;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isCameraBusy
                      ? null
                      : () {
                          _toggleCamera();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isCameraActive
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: Icon(
                    _isCameraActive ? Icons.stop : Icons.camera,
                    color: Colors.black,
                  ),
                  label: Text(_isCameraActive ? '촬영 정지' : '촬영 시작'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!_isCameraActive ||
                          !isControllerReady ||
                          _isCameraBusy)
                      ? null
                      : () {
                          _toggleDetection();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isDetectionActive
                        ? Colors.orangeAccent
                        : Colors.blueAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: Icon(
                    _isDetectionActive
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: Colors.black,
                  ),
                  label: Text(
                      _isDetectionActive ? '탐지 정지' : 'YOLO 탐지 시작'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: (widget.cameras.length < 2 ||
                    _isChangingCamera ||
                    _isCameraBusy)
                ? null
                : () {
                    _switchCamera();
                  },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.cameraswitch),
            label: const Text('전면/후면 전환'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.camera_alt, color: Colors.white70, size: 16),
          const SizedBox(width: 6),
          Text(
            _isDetectionActive ? '${_detections.length} objects' : '탐지 대기',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
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
