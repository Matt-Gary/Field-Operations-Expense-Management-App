import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Utility to compress image bytes before uploading.
///
/// Decodes the image, optionally resizes if larger than [maxDimension],
/// and re-encodes as JPEG at [jpegQuality].
/// Text should remain legible at quality ≥ 80 and maxDimension ≥ 1920.
class ImageCompressor {
  /// Compress [bytes] to JPEG.
  ///
  /// - [maxDimension]: longest side cap (default 1920px)
  /// - [jpegQuality]: 0–100 (default 85)
  ///
  /// Returns compressed bytes, or the original bytes if decoding fails
  /// (e.g. non-image file).
  static Uint8List compress(
    Uint8List bytes, {
    int maxDimension = 1920,
    int jpegQuality = 85,
  }) {
    // Try to decode the image
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes; // not an image — return as-is

    var image = decoded;

    // Resize only if needed
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > maxDimension) {
      if (image.width >= image.height) {
        image = img.copyResize(image, width: maxDimension);
      } else {
        image = img.copyResize(image, height: maxDimension);
      }
    }

    // Encode as JPEG
    final compressed = img.encodeJpg(image, quality: jpegQuality);
    return Uint8List.fromList(compressed);
  }
}
