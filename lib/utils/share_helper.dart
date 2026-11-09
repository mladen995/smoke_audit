// lib/utils/share_helper.dart
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// Opens the system share sheet for a file. [context] must still be mounted
/// (iPad needs the on-screen position to anchor the share popover).
Future<void> shareFile(
  BuildContext context,
  String path, {
  String? mimeType,
  String? subject,
}) async {
  Rect? origin;
  final RenderObject? ro = context.findRenderObject();
  if (ro is RenderBox && ro.hasSize) {
    origin = ro.localToGlobal(Offset.zero) & ro.size;
  }
  await Share.shareXFiles(
    [XFile(path, mimeType: mimeType)],
    subject: subject,
    sharePositionOrigin: origin,
  );
}
