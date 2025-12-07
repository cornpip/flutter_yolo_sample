import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:ffi_plugin_look/ffi_plugin_look.dart' as native_processing;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/detection.dart';

class YoloDetector {
  YoloDetector({
    this.confidenceThreshold = 0.5,
    this.nmsThreshold = 0.2,
    this.debugSaveFrames = true,
  });

  final double confidenceThreshold;
  final double nmsThreshold;
  final bool debugSaveFrames;

  static const _modelPath = 'assets/models/YOLOv11-nano.tflite';
  static const _labelsPath = 'assets/labels/coco_labels.txt';

  bool _isInitialized = false;
  Isolate? _inferenceIsolate;
  SendPort? _inferenceSendPort;
  late List<String> _labels;

  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    final rawLabels = await rootBundle.loadString(_labelsPath);
    _labels = rawLabels
        .split('\n')
        .map((label) => label.trim())
        .where((label) => label.isNotEmpty)
        .toList();

    final modelByteData = await rootBundle.load(_modelPath);
    final modelBytes = Uint8List.fromList(
      modelByteData.buffer.asUint8List(
        modelByteData.offsetInBytes,
        modelByteData.lengthInBytes,
      ),
    );

    final readyPort = ReceivePort();
    final initArgs = [
      readyPort.sendPort,
      TransferableTypedData.fromList([modelBytes]),
      confidenceThreshold,
      nmsThreshold,
      _labels,
      debugSaveFrames,
    ];

    _inferenceIsolate = await Isolate.spawn(
      _yoloIsolateEntry,
      initArgs,
      errorsAreFatal: true,
    );

    _inferenceSendPort = await readyPort.first as SendPort;
    readyPort.close();
    _isInitialized = true;
  }

  Future<List<Detection>> predict(
    CameraImage cameraImage, {
    required int sensorOrientation,
    required CameraLensDirection lensDirection,
  }) async {
    final sendPort = _inferenceSendPort;
    if (!_isInitialized || sendPort == null) {
      throw StateError('YoloDetector has not been initialized.');
    }
    print("#### conf: $confidenceThreshold, nms: $nmsThreshold");

    final responsePort = ReceivePort();
    sendPort.send([
      'predict',
      _serializeCameraImage(
        cameraImage,
        sensorOrientation,
        lensDirection,
      ),
      responsePort.sendPort,
    ]);

    final dynamic result = await responsePort.first;
    responsePort.close();

    if (result is Map && result['error'] != null) {
      final error = result['error'];
      final stackTrace = result['stackTrace'];
      throw StateError('Detection failed: $error\n$stackTrace');
    }

    final List<dynamic> rawDetections = result as List<dynamic>;
    return rawDetections.map((dynamic raw) {
      final data = raw as Map<Object?, Object?>;
      final label = data['label'] as String? ?? 'unknown';
      final confidence = (data['confidence'] as num).toDouble();
      final left = (data['left'] as num).toDouble();
      final top = (data['top'] as num).toDouble();
      final right = (data['right'] as num).toDouble();
      final bottom = (data['bottom'] as num).toDouble();
      return Detection(
        boundingBox: Rect.fromLTRB(left, top, right, bottom),
        confidence: confidence,
        label: label,
      );
    }).toList();
  }

  void close() {
    final sendPort = _inferenceSendPort;
    if (sendPort != null) {
      sendPort.send(['dispose']);
    }
    _inferenceIsolate?.kill(priority: Isolate.immediate);
    _inferenceIsolate = null;
    _inferenceSendPort = null;
    _isInitialized = false;
  }

  Map<String, dynamic> _serializeCameraImage(
    CameraImage cameraImage,
    int sensorOrientation,
    CameraLensDirection lensDirection,
  ) {
    final planes = cameraImage.planes
        .map(
          (plane) => {
            'bytesPerRow': plane.bytesPerRow,
            'bytesPerPixel': plane.bytesPerPixel,
            'bytes': TransferableTypedData.fromList(
              [Uint8List.fromList(plane.bytes)],
            ),
          },
        )
        .toList();

    return {
      'width': cameraImage.width,
      'height': cameraImage.height,
      'sensorOrientation': sensorOrientation,
      'lensDirection': lensDirection.index,
      'planes': planes,
    };
  }
}

void _yoloIsolateEntry(List<dynamic> initialMessage) async {
  final SendPort readyPort = initialMessage[0] as SendPort;
  final TransferableTypedData modelData =
      initialMessage[1] as TransferableTypedData;
  final double confidence =
      (initialMessage[2] as num).toDouble();
  final double nms = (initialMessage[3] as num).toDouble();
  final List<String> labels =
      (initialMessage[4] as List<dynamic>).cast<String>();
  final bool debugSaveFrames = initialMessage[5] as bool;

  final receivePort = ReceivePort();
  readyPort.send(receivePort.sendPort);

  final ByteData modelByteData = modelData.materialize().asByteData();
  final Uint8List modelBytes = modelByteData.buffer.asUint8List(
    modelByteData.offsetInBytes,
    modelByteData.lengthInBytes,
  );

  final handler = _YoloIsolateHandler(
    modelBytes: modelBytes,
    labels: labels,
    confidenceThreshold: confidence,
    nmsThreshold: nms,
    debugSaveFrames: debugSaveFrames,
  );

  await for (final dynamic message in receivePort) {
    if (message is! List || message.isEmpty) {
      continue;
    }
    final command = message[0];
    if (command == 'predict') {
      final payload =
          (message[1] as Map<dynamic, dynamic>).cast<String, dynamic>();
      final SendPort replyTo = message[2] as SendPort;
      try {
        final detections = handler.predict(payload);
        replyTo.send(detections);
      } catch (error, stackTrace) {
        replyTo.send({
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        });
      }
    } else if (command == 'dispose') {
      handler.close();
      receivePort.close();
      break;
    }
  }
}

class _YoloIsolateHandler {
  _YoloIsolateHandler({
    required Uint8List modelBytes,
    required this.labels,
    required this.confidenceThreshold,
    required this.nmsThreshold,
    required this.debugSaveFrames,
  }) {
    final interpreterOptions = InterpreterOptions();
    if (Platform.isAndroid) {
      interpreterOptions.threads =
          math.max(1, Platform.numberOfProcessors ~/ 2);
    }
    _interpreter = Interpreter.fromBuffer(
      modelBytes,
      options: interpreterOptions,
    );
    _inputShape = _interpreter.getInputTensor(0).shape;
    _outputShape = _interpreter.getOutputTensor(0).shape;
    _inputType = _interpreter.getInputTensor(0).type;

    if (_inputShape.length != 4) {
      throw UnsupportedError('Unexpected input shape: $_inputShape');
    }

    _isChannelsLast = _inputShape[3] == 3 || _inputShape[3] == 1;
    if (_isChannelsLast) {
      _inputHeight = _inputShape[1];
      _inputWidth = _inputShape[2];
    } else {
      _inputHeight = _inputShape[2];
      _inputWidth = _inputShape[3];
    }
  }

  final List<String> labels;
  final double confidenceThreshold;
  final double nmsThreshold;
  final bool debugSaveFrames;
  final String _debugFramePath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}yolo_debug_frame.png';
  int _frameCounter = 0;
  double _letterboxScale = 1.0;
  int _letterboxPadX = 0;
  int _letterboxPadY = 0;
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  bool _hasLoggedOutputs = false;

  late final Interpreter _interpreter;
  late final List<int> _inputShape;
  late final List<int> _outputShape;
  late final TensorType _inputType;
  late final bool _isChannelsLast;
  late final int _inputHeight;
  late final int _inputWidth;

  List<Map<String, dynamic>> predict(Map<String, dynamic> payload) {
    final frame = _CameraFrameData.fromMap(payload);
    final rgbImage = _preprocess(frame);
    final inputTensor = _createInputTensor(rgbImage);

    final outputTensor = _interpreter.getOutputTensor(0);
    if (outputTensor.type != TensorType.float32) {
      throw UnsupportedError('Only float32 output tensors are supported.');
    }

    final outputShape = outputTensor.shape;
    // print(outputShape); // [1, 84, 8400]
    final outputLength =
        outputShape.reduce((value, element) => value * element);
    final outputBuffer = _createZeroTensor(outputShape);

    _interpreter.run(inputTensor, outputBuffer);
    final flattenedOutput = _flattenTensor(
      outputBuffer,
      outputShape,
      outputLength,
    );
    final detections = _decodeDetections(flattenedOutput);

    return detections
        .map(
          (detection) => {
            'label': detection.label,
            'confidence': detection.confidence,
            'left': detection.boundingBox.left,
            'top': detection.boundingBox.top,
            'right': detection.boundingBox.right,
            'bottom': detection.boundingBox.bottom,
          },
        )
        .toList();
  }

  void close() {
    _interpreter.close();
  }

  void _maybeSaveDebugFrame(Uint8List rgbBytes) {
    _frameCounter++;
    if (_frameCounter % 2 != 0) {
      return;
    }
    try {
      final img.Image image = img.Image(
        width: _inputWidth,
        height: _inputHeight,
        numChannels: 3,
      );
      var srcIndex = 0;
      for (int y = 0; y < _inputHeight; y++) {
        for (int x = 0; x < _inputWidth; x++) {
          final r = rgbBytes[srcIndex++];
          final g = rgbBytes[srcIndex++];
          final b = rgbBytes[srcIndex++];
          image.setPixelRgb(x, y, r, g, b);
        }
      }
      final file = File(_debugFramePath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(img.encodePng(image), flush: true);
    } catch (_) {
      // Debug-only: ignore any write failures.
    }
  }

  Uint8List _preprocess(_CameraFrameData frame) {
    if (frame.planes.length < 3) {
      throw StateError('Expected at least 3 planes for YUV420 frame.');
    }
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final native_processing.PreprocessResult result =
        native_processing.preprocessCameraFrame(
      yPlane: yPlane.bytes,
      yRowStride: yPlane.bytesPerRow,
      uPlane: uPlane.bytes,
      uRowStride: uPlane.bytesPerRow,
      uPixelStride: uPlane.bytesPerPixel ?? 1,
      vPlane: vPlane.bytes,
      vRowStride: vPlane.bytesPerRow,
      vPixelStride: vPlane.bytesPerPixel ?? 1,
      width: frame.width,
      height: frame.height,
      rotationDegrees: frame.sensorOrientation,
      flipHorizontal: frame.lensDirection == CameraLensDirection.front,
      targetWidth: _inputWidth,
      targetHeight: _inputHeight,
    );

    _letterboxScale = result.scale;
    _letterboxPadX = result.padX;
    _letterboxPadY = result.padY;
    _sourceWidth = result.orientedWidth;
    _sourceHeight = result.orientedHeight;

    final bytes = result.rgbBytes;

    if (debugSaveFrames) {
      _maybeSaveDebugFrame(bytes);
    }

    return bytes;
  }

  Object _createInputTensor(Uint8List rgbBytes) {
    final inputSize = _inputWidth * _inputHeight * 3;
    switch (_inputType) {
      case TensorType.float32:
        final buffer = Float32List(inputSize);
        _fillFloatInput(buffer, rgbBytes);
        return _reshapeToNHWC(buffer, _inputHeight, _inputWidth, 3);
      case TensorType.uint8:
        final buffer = Uint8List(inputSize);
        _fillUint8Input(buffer, rgbBytes);
        return _reshapeToNHWC(buffer, _inputHeight, _inputWidth, 3);
      default:
        throw UnsupportedError('Unsupported input type: $_inputType');
    }
  }

  List<dynamic> _reshapeToNHWC(
    List<num> buffer,
    int height,
    int width,
    int channels,
  ) {
    return List.generate(1, (_) {
      return List.generate(height, (y) {
        return List.generate(width, (x) {
          final index = (y * width + x) * channels;
          return List.generate(channels, (c) => buffer[index + c]);
        }, growable: false);
      }, growable: false);
    }, growable: false);
  }

  void _fillFloatInput(Float32List buffer, Uint8List rgbBytes) {
    final int pixelCount = _inputWidth * _inputHeight;
    if (_isChannelsLast) {
      var srcIndex = 0;
      var dstIndex = 0;
      for (int i = 0; i < pixelCount; i++) {
        buffer[dstIndex++] = rgbBytes[srcIndex++] / 255.0;
        buffer[dstIndex++] = rgbBytes[srcIndex++] / 255.0;
        buffer[dstIndex++] = rgbBytes[srcIndex++] / 255.0;
      }
      return;
    }

    final int planeSize = pixelCount;
    var srcIndex = 0;
    for (int i = 0; i < planeSize; i++) {
      buffer[i] = rgbBytes[srcIndex++] / 255.0;
      buffer[planeSize + i] = rgbBytes[srcIndex++] / 255.0;
      buffer[2 * planeSize + i] = rgbBytes[srcIndex++] / 255.0;
    }
  }

  void _fillUint8Input(Uint8List buffer, Uint8List rgbBytes) {
    final int pixelCount = _inputWidth * _inputHeight;
    if (_isChannelsLast) {
      var srcIndex = 0;
      var dstIndex = 0;
      for (int i = 0; i < pixelCount; i++) {
        buffer[dstIndex++] = rgbBytes[srcIndex++];
        buffer[dstIndex++] = rgbBytes[srcIndex++];
        buffer[dstIndex++] = rgbBytes[srcIndex++];
      }
      return;
    }

    final int planeSize = pixelCount;
    var srcIndex = 0;
    for (int i = 0; i < planeSize; i++) {
      buffer[i] = rgbBytes[srcIndex++];
      buffer[planeSize + i] = rgbBytes[srcIndex++];
      buffer[2 * planeSize + i] = rgbBytes[srcIndex++];
    }
  }

  List<Detection> _decodeDetections(Float32List outputBuffer) {
    if (_outputShape.length < 3) {
      throw UnsupportedError('Unexpected output shape: $_outputShape');
    }

    int boxes = _outputShape[2];
    int channels = _outputShape[1];
    final isChannelFirst = channels < boxes;

    final detections = <Detection>[];
    if (debugSaveFrames && !_hasLoggedOutputs) {
      // Log a few raw boxes to inspect scale (expected either 0~1 or pixel values).
      final sampleCount = math.min(5, boxes);
      for (int i = 0; i < sampleCount; i++) {
        final x = _readChannelFirst(outputBuffer, channels, boxes, 0, i);
        final y = _readChannelFirst(outputBuffer, channels, boxes, 1, i);
        final w = _readChannelFirst(outputBuffer, channels, boxes, 2, i);
        final h = _readChannelFirst(outputBuffer, channels, boxes, 3, i);
        // ignore: avoid_print
        print('YOLO raw box[$i]: x=$x, y=$y, w=$w, h=$h');
      }
      // ignore: avoid_print
      print(
          'YOLO outputShape=$_outputShape (boxes=$boxes, channels=$channels, channelFirst=$isChannelFirst)');
      _hasLoggedOutputs = true;
    }
    for (int i = 0; i < boxes; i++) {
      final xCenter = _readChannelFirst(outputBuffer, channels, boxes, 0, i);
      final yCenter = _readChannelFirst(outputBuffer, channels, boxes, 1, i);
      final width = _readChannelFirst(outputBuffer, channels, boxes, 2, i);
      final height = _readChannelFirst(outputBuffer, channels, boxes, 3, i);

      final expectedWithObj = labels.length + 5; // x,y,w,h,obj + classes
      final expectedWithoutObj = labels.length + 4; // x,y,w,h + classes
      final hasObjectness =
          channels == expectedWithObj || channels > expectedWithObj;
      final objectness = hasObjectness
          ? _sigmoid(
              _readChannelFirst(outputBuffer, channels, boxes, 4, i),
            )
          : 1.0;
      final classStartIndex = hasObjectness ? 5 : 4;

      var bestClassScore = 0.0;
      var bestClassIndex = -1;
      for (int j = classStartIndex; j < channels; j++) {
        final classProb = _sigmoid(
          _readChannelFirst(outputBuffer, channels, boxes, j, i),
        );
        if (classProb > bestClassScore) {
          bestClassScore = classProb;
          bestClassIndex = j - classStartIndex;
        }
      }

      if (bestClassIndex < 0) {
        continue;
      }

      final confidence = objectness * bestClassScore;
      if (confidence < confidenceThreshold) {
        continue;
      }

      final label = bestClassIndex < labels.length
          ? labels[bestClassIndex]
          : 'class $bestClassIndex';
      final rect = _buildBoundingBox(xCenter, yCenter, width, height);
      if (debugSaveFrames && !_hasLoggedOutputs) {
        // ignore: avoid_print
        print(
            'YOLO keep: label=$label conf=${(confidence * 100).toStringAsFixed(2)} '
            'obj=${(objectness * 100).toStringAsFixed(2)} '
            'classProb=${(bestClassScore * 100).toStringAsFixed(2)} '
            'rawBox=($xCenter,$yCenter,$width,$height)');
      }
      detections.add(Detection(
        boundingBox: rect,
        confidence: confidence,
        label: label,
      ));
    }
    _hasLoggedOutputs = _hasLoggedOutputs || (debugSaveFrames && detections.isNotEmpty);

    return _nonMaxSuppression(detections);
  }

  Rect _buildBoundingBox(
    double xCenter,
    double yCenter,
    double width,
    double height,
  ) {
    // Model outputs are typically normalized; if they look like pixel values, normalize them first.
    final bool isPixelSpace =
        xCenter > 2 || yCenter > 2 || width > 2 || height > 2;
    if (isPixelSpace) {
      xCenter /= _inputWidth;
      yCenter /= _inputHeight;
      width /= _inputWidth;
      height /= _inputHeight;
    }

    xCenter *= _inputWidth;
    yCenter *= _inputHeight;
    width *= _inputWidth;
    height *= _inputHeight;

    final double padX = _letterboxPadX.toDouble();
    final double padY = _letterboxPadY.toDouble();
    final double scale = _letterboxScale == 0 ? 1.0 : _letterboxScale;

    double left = xCenter - width / 2;
    double top = yCenter - height / 2;
    double right = xCenter + width / 2;
    double bottom = yCenter + height / 2;

    // Remove letterbox padding.
    left = (left - padX) / scale;
    top = (top - padY) / scale;
    right = (right - padX) / scale;
    bottom = (bottom - padY) / scale;

    // Normalize to original (pre-letterbox) image size.
    final double srcWidth = _sourceWidth == 0 ? _inputWidth.toDouble() : _sourceWidth.toDouble();
    final double srcHeight = _sourceHeight == 0 ? _inputHeight.toDouble() : _sourceHeight.toDouble();

    return Rect.fromLTRB(
      (left / srcWidth).clamp(0.0, 1.0),
      (top / srcHeight).clamp(0.0, 1.0),
      (right / srcWidth).clamp(0.0, 1.0),
      (bottom / srcHeight).clamp(0.0, 1.0),
    );
  }

  double _readChannelFirst(
    Float32List buffer,
    int channels,
    int boxes,
    int channelIndex,
    int boxIndex,
  ) {
    final int idx = channelIndex * boxes + boxIndex;
    if (idx >= buffer.length) {
      return 0.0;
    }
    return buffer[idx];
  }

  List<Detection> _nonMaxSuppression(List<Detection> detections) {
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));
    final results = <Detection>[];

    for (final detection in detections) {
      var shouldSkip = false;
      for (final kept in results) {
        if (detection.label == kept.label &&
            _iou(detection.boundingBox, kept.boundingBox) >
                nmsThreshold) {
          shouldSkip = true;
          break;
        }
      }
      if (!shouldSkip) {
        results.add(detection);
      }
    }

    return results;
  }

  double _iou(Rect a, Rect b) {
    final double intersectionWidth =
        math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));
    final double intersectionHeight =
        math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
    final intersection = intersectionWidth * intersectionHeight;
    final union = a.width * a.height + b.width * b.height - intersection;
    if (union == 0) {
      return 0;
    }
    return intersection / union;
  }

  int _clampToUint8(double value) => value.clamp(0, 255).toInt();

  double _sigmoid(double x) => 1 / (1 + math.exp(-x));

  dynamic _createZeroTensor(List<int> shape, [int depth = 0]) {
    final size = shape[depth];
    if (depth == shape.length - 1) {
      return List<double>.filled(size, 0.0, growable: false);
    }
    return List.generate(
      size,
      (_) => _createZeroTensor(shape, depth + 1),
      growable: false,
    );
  }

  Float32List _flattenTensor(
    dynamic tensor,
    List<int> shape,
    int totalLength, {
    int depth = 0,
    int offset = 0,
    Float32List? target,
  }) {
    final result = target ?? Float32List(totalLength);
    if (depth == shape.length - 1) {
      final List<dynamic> leaf = tensor as List<dynamic>;
      for (int i = 0; i < leaf.length; i++) {
        result[offset + i] = (leaf[i] as num).toDouble();
      }
      return result;
    }

    final stride = shape
        .sublist(depth + 1)
        .fold<int>(1, (value, element) => value * element);
    final List<dynamic> children = tensor as List<dynamic>;
    for (int i = 0; i < children.length; i++) {
      _flattenTensor(
        children[i],
        shape,
        totalLength,
        depth: depth + 1,
        offset: offset + i * stride,
        target: result,
      );
    }
    return result;
  }
}

class _CameraFrameData {
  _CameraFrameData({
    required this.width,
    required this.height,
    required this.sensorOrientation,
    required this.lensDirection,
    required this.planes,
  });

  final int width;
  final int height;
  final int sensorOrientation;
  final CameraLensDirection lensDirection;
  final List<_PlaneBuffer> planes;

  factory _CameraFrameData.fromMap(Map<String, dynamic> map) {
    final planes = (map['planes'] as List<dynamic>)
        .map((dynamic planeData) {
          final planeMap =
              (planeData as Map<dynamic, dynamic>).cast<String, dynamic>();
          final TransferableTypedData bytesData =
              planeMap['bytes'] as TransferableTypedData;
          final ByteData byteData = bytesData.materialize().asByteData();
          final bytes = byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          );
          return _PlaneBuffer(
            bytes: bytes,
            bytesPerRow: planeMap['bytesPerRow'] as int,
            bytesPerPixel: planeMap['bytesPerPixel'] as int?,
          );
        })
        .toList();

    return _CameraFrameData(
      width: map['width'] as int,
      height: map['height'] as int,
      sensorOrientation: map['sensorOrientation'] as int,
      lensDirection:
          CameraLensDirection.values[map['lensDirection'] as int],
      planes: planes,
    );
  }
}

class _PlaneBuffer {
  _PlaneBuffer({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}
