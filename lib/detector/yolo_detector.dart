import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/detection.dart';

class YoloDetector {
  YoloDetector({
    this.confidenceThreshold = 0.45,
    this.nmsThreshold = 0.4,
  });

  final double confidenceThreshold;
  final double nmsThreshold;

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

  img.Image _preprocess(_CameraFrameData frame) {
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final width = frame.width;
    final height = frame.height;
    final imageBuffer = img.Image(
      width: width,
      height: height,
      numChannels: 3,
    );

    for (int y = 0; y < height; y++) {
      final uvRow = y ~/ 2;
      for (int x = 0; x < width; x++) {
        final uvColumn = x ~/ 2;

        final yIndex = y * yPlane.bytesPerRow + x;
        final uIndex = uvRow * uPlane.bytesPerRow +
            uvColumn * (uPlane.bytesPerPixel ?? 1);
        final vIndex = uvRow * vPlane.bytesPerRow +
            uvColumn * (vPlane.bytesPerPixel ?? 1);

        final yValue = yPlane.bytes[yIndex];
        final uValue = uPlane.bytes[uIndex];
        final vValue = vPlane.bytes[vIndex];

        final r = _clampToUint8(yValue + 1.402 * (vValue - 128));
        final g = _clampToUint8(
          yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128),
        );
        final b = _clampToUint8(yValue + 1.772 * (uValue - 128));

        imageBuffer.setPixelRgb(x, y, r, g, b);
      }
    }

    img.Image oriented = imageBuffer;
    switch (frame.sensorOrientation) {
      case 90:
        oriented = img.copyRotate(imageBuffer, angle: 90);
        break;
      case 180:
        oriented = img.copyRotate(imageBuffer, angle: 180);
        break;
      case 270:
        oriented = img.copyRotate(imageBuffer, angle: 270);
        break;
      default:
        oriented = imageBuffer;
    }

    if (frame.lensDirection == CameraLensDirection.front) {
      oriented = img.flipHorizontal(oriented);
    }

    return oriented;
  }

  Object _createInputTensor(img.Image image) {
    final paddedImage = _letterboxImage(
      image,
      targetWidth: _inputWidth,
      targetHeight: _inputHeight,
    );
    final inputSize = _inputWidth * _inputHeight * 3;
    switch (_inputType) {
      case TensorType.float32:
        final buffer = Float32List(inputSize);
        _fillFloatInput(buffer, paddedImage);
        return _reshapeToNHWC(buffer, _inputHeight, _inputWidth, 3);
      case TensorType.uint8:
        final buffer = Uint8List(inputSize);
        _fillUint8Input(buffer, paddedImage);
        return _reshapeToNHWC(buffer, _inputHeight, _inputWidth, 3);
      default:
        throw UnsupportedError('Unsupported input type: $_inputType');
    }
  }

  img.Image _letterboxImage(
    img.Image source, {
    required int targetWidth,
    required int targetHeight,
  }) {
    final double scale = math.min(
      targetWidth / source.width,
      targetHeight / source.height,
    );
    final int resizedWidth =
        (source.width * scale).round().clamp(1, targetWidth);
    final int resizedHeight =
        (source.height * scale).round().clamp(1, targetHeight);
    final int padX = ((targetWidth - resizedWidth) / 2).floor();
    final int padY = ((targetHeight - resizedHeight) / 2).floor();

    final img.Image resized = img.copyResize(
      source,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );

    final img.Image padded = img.Image(
      width: targetWidth,
      height: targetHeight,
      numChannels: resized.numChannels,
    );
    img.compositeImage(padded, resized, dstX: padX, dstY: padY);

    return padded;
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

  void _fillFloatInput(Float32List buffer, img.Image image) {
    if (_isChannelsLast) {
      var bufferIndex = 0;
      for (int y = 0; y < _inputHeight; y++) {
        for (int x = 0; x < _inputWidth; x++) {
          final pixel = image.getPixel(x, y);
          buffer[bufferIndex++] = pixel.r / 255.0;
          buffer[bufferIndex++] = pixel.g / 255.0;
          buffer[bufferIndex++] = pixel.b / 255.0;
        }
      }
      return;
    }

    final planeSize = _inputWidth * _inputHeight;
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixelIndex = y * _inputWidth + x;
        final pixel = image.getPixel(x, y);
        buffer[pixelIndex] = pixel.r / 255.0;
        buffer[planeSize + pixelIndex] = pixel.g / 255.0;
        buffer[2 * planeSize + pixelIndex] = pixel.b / 255.0;
      }
    }
  }

  void _fillUint8Input(Uint8List buffer, img.Image image) {
    if (_isChannelsLast) {
      var bufferIndex = 0;
      for (int y = 0; y < _inputHeight; y++) {
        for (int x = 0; x < _inputWidth; x++) {
          final pixel = image.getPixel(x, y);
          buffer[bufferIndex++] = pixel.r.toInt();
          buffer[bufferIndex++] = pixel.g.toInt();
          buffer[bufferIndex++] = pixel.b.toInt();
        }
      }
      return;
    }

    final planeSize = _inputWidth * _inputHeight;
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixelIndex = y * _inputWidth + x;
        final pixel = image.getPixel(x, y);
        buffer[pixelIndex] = pixel.r.toInt();
        buffer[planeSize + pixelIndex] = pixel.g.toInt();
        buffer[2 * planeSize + pixelIndex] = pixel.b.toInt();
      }
    }
  }

  List<Detection> _decodeDetections(Float32List outputBuffer) {
    if (_outputShape.length < 3) {
      throw UnsupportedError('Unexpected output shape: $_outputShape');
    }

    int boxes = _outputShape[1];
    int valuesPerBox = _outputShape[2];
    if (valuesPerBox < 6 && boxes > valuesPerBox) {
      final temp = boxes;
      boxes = valuesPerBox;
      valuesPerBox = temp;
    }

    final detections = <Detection>[];
    for (int i = 0; i < boxes; i++) {
      final offset = i * valuesPerBox;
      if (offset + valuesPerBox > outputBuffer.length) {
        break;
      }

      final xCenter = outputBuffer[offset];
      final yCenter = outputBuffer[offset + 1];
      final width = outputBuffer[offset + 2];
      final height = outputBuffer[offset + 3];

      final hasObjectness = valuesPerBox > 5;
      final objectness = hasObjectness ? outputBuffer[offset + 4] : 1.0;
      final classStartIndex = hasObjectness ? 5 : 4;

      var bestClassScore = 0.0;
      var bestClassIndex = -1;
      for (int j = classStartIndex; j < valuesPerBox; j++) {
        final classScore = outputBuffer[offset + j];
        if (classScore > bestClassScore) {
          bestClassScore = classScore;
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
      detections.add(
        Detection(
          boundingBox: rect,
          confidence: confidence,
          label: label,
        ),
      );
    }

    return _nonMaxSuppression(detections);
  }

  Rect _buildBoundingBox(
    double xCenter,
    double yCenter,
    double width,
    double height,
  ) {
    final left = (xCenter - width / 2) / _inputWidth;
    final top = (yCenter - height / 2) / _inputHeight;
    final right = (xCenter + width / 2) / _inputWidth;
    final bottom = (yCenter + height / 2) / _inputHeight;

    return Rect.fromLTRB(
      left.clamp(0.0, 1.0),
      top.clamp(0.0, 1.0),
      right.clamp(0.0, 1.0),
      bottom.clamp(0.0, 1.0),
    );
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
