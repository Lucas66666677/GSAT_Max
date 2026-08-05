import 'dart:io';
import 'dart:typed_data';

import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import 'file_download_result.dart';

Future<FileDownloadResult> saveDownloadedFile(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File(
    '${directory.path}${Platform.pathSeparator}$fileName',
  );
  await file.writeAsBytes(bytes, flush: true);
  final result = await OpenFile.open(file.path);
  return FileDownloadResult(
    opened: result.type == ResultType.done,
    message: result.type == ResultType.done
        ? 'PDF 已開啟，可以直接列印。'
        : 'PDF 已儲存至 ${file.path}',
  );
}
