import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'github_update_checker.dart';

sealed class ApkDownloadResult {
  const ApkDownloadResult();
}

class ApkReady extends ApkDownloadResult {
  const ApkReady(this.path);
  final String path;
}

class ApkDownloadFailed extends ApkDownloadResult {
  const ApkDownloadFailed(this.message);
  final String message;
}

class ApkInstaller {
  ApkInstaller({this.timeout = const Duration(minutes: 2)});

  static const _channel = MethodChannel('vidyut/updater');
  final Duration timeout;

  Future<ApkDownloadResult> download(
    UpdateAvailable release, {
    required void Function(double progress) onProgress,
  }) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/vidyut_updates',
    );
    await directory.create(recursive: true);
    await for (final entry in directory.list()) {
      if (entry is File) await entry.delete();
    }
    final apk = File('${directory.path}/${release.assetName}');
    final client = HttpClient();
    try {
      final expected = await _downloadText(client, release.sha256Url);
      final expectedHash = expected.trim().split(RegExp(r'\s+')).first;
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
        return const ApkDownloadFailed('The published checksum is invalid.');
      }
      final request = await client
          .getUrl(Uri.parse(release.downloadUrl))
          .timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'vidyut-updater');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        return const ApkDownloadFailed('The APK download failed.');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = apk.openWrite();
      await for (final chunk in response.timeout(timeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress((received / total).clamp(0, 1));
      }
      await sink.close();
      final digest = await Sha256().hash(await apk.readAsBytes());
      final actual = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual.toLowerCase() != expectedHash.toLowerCase()) {
        await apk.delete();
        return const ApkDownloadFailed(
          'The downloaded APK did not match its checksum.',
        );
      }
      onProgress(1);
      return ApkReady(apk.path);
    } on Object {
      if (await apk.exists()) await apk.delete();
      return const ApkDownloadFailed(
        'Download interrupted. Check your connection and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _downloadText(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'vidyut-updater');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw const HttpException('checksum download failed');
    }
    return response.transform(utf8.decoder).join().timeout(timeout);
  }

  Future<bool> canInstall() async {
    return await _channel.invokeMethod<bool>('canInstall') ?? false;
  }

  Future<void> openInstallSettings() {
    return _channel.invokeMethod<void>('openInstallSettings');
  }

  Future<void> install(String path) {
    return _channel.invokeMethod<void>('install', {'path': path});
  }
}
