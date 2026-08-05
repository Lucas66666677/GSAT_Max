// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'file_download_result.dart';

Future<FileDownloadResult> saveDownloadedFile(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  final blob = html.Blob(<Object>[bytes], mimeType);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: objectUrl)
    ..download = fileName
    ..rel = 'noopener'
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  await Future<void>.delayed(Duration.zero);
  html.Url.revokeObjectUrl(objectUrl);
  return FileDownloadResult(
    opened: true,
    message: 'PDF 已下載，可從瀏覽器的下載清單開啟或列印。',
  );
}
