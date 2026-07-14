import 'dart:io';

import 'package:image/image.dart' as image;

const _sourcePath = 'assets/icons/icon_512x512.png';
const _outputPath = 'windows/runner/resources/app_icon.ico';
const _sizes = <int>[16, 20, 24, 32, 40, 48, 64, 96, 128, 256];

void main() {
  final source = image.decodePng(File(_sourcePath).readAsBytesSync());
  if (source == null) {
    throw StateError('Unable to decode $_sourcePath');
  }

  final frames = _sizes
      .map(
        (size) => image.copyResize(
          source,
          width: size,
          height: size,
          interpolation: image.Interpolation.average,
        ),
      )
      .toList(growable: false);
  final icon = image.Image.from(frames.first);
  for (final frame in frames.skip(1)) {
    icon.addFrame(frame);
  }

  File(_outputPath).writeAsBytesSync(image.encodeIco(icon));
}
