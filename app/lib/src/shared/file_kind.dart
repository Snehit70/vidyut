import 'package:flutter/material.dart';

/// What a file is, judged by its extension, for icons and for deciding which
/// files can have a picture.
enum FileKind {
  image(Icons.image_outlined),
  video(Icons.movie_outlined),
  pdf(Icons.picture_as_pdf_outlined),
  audio(Icons.audiotrack_outlined),
  archive(Icons.folder_zip_outlined),
  apk(Icons.android_outlined),
  sheet(Icons.table_chart_outlined),
  other(Icons.insert_drive_file_outlined);

  const FileKind(this.icon);

  final IconData icon;

  /// The laptop can draw a picture of these (ADR 0027).
  bool get hasPicture => this == image || this == video || this == pdf;
}

FileKind fileKindOf(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'tif' ||
    'tiff' ||
    'heic' ||
    'heif' ||
    'avif' ||
    'svg' => FileKind.image,
    'mp4' ||
    'mkv' ||
    'mov' ||
    'webm' ||
    'avi' ||
    'm4v' ||
    'wmv' ||
    'flv' ||
    '3gp' => FileKind.video,
    'pdf' => FileKind.pdf,
    'mp3' || 'flac' || 'wav' || 'ogg' || 'm4a' || 'opus' => FileKind.audio,
    'zip' ||
    'tar' ||
    'gz' ||
    'xz' ||
    'zst' ||
    '7z' ||
    'rar' => FileKind.archive,
    'apk' => FileKind.apk,
    'csv' || 'xlsx' || 'ods' => FileKind.sheet,
    _ => FileKind.other,
  };
}
