import 'dart:typed_data';

import 'file_download_result.dart';

Future<FileDownloadResult> saveDownloadedFile(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) {
  throw UnsupportedError('This platform cannot save downloaded files.');
}
