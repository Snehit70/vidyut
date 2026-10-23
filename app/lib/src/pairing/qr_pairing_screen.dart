import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../debug/debug_log.dart';

class QrPairingScreen extends StatefulWidget {
  const QrPairingScreen({super.key});

  @override
  State<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends State<QrPairingScreen> {
  bool _handled = false;
  bool _cameraReady = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareCamera());
  }

  Future<void> _prepareCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() {
        if (status.isGranted) {
          _cameraReady = true;
        } else {
          _cameraError =
              'Camera permission is required to scan a pairing QR code.';
        }
      });
    } on Exception catch (error) {
      if (!mounted) return;
      sharedDebugLog.add(
        'pairing',
        'Could not start the camera: $error',
        isError: true,
      );
      setState(
        () => _cameraError = 'Could not start the camera. Use manual pairing.',
      );
    }
  }

  void _handleCameraError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    sharedDebugLog.add(
      'pairing',
      'Could not start the camera: $error',
      isError: true,
    );
    setState(
      () => _cameraError = 'Could not start the camera. Use manual pairing.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: Stack(
        children: [
          if (_cameraReady && _cameraError == null)
            MobileScanner(
              onDetectError: _handleCameraError,
              errorBuilder: (context, error) => _CameraErrorView(
                message: error.errorDetails?.message ?? error.errorCode.message,
              ),
              onDetect: (capture) {
                if (_handled) return;
                final rawValue = capture.barcodes.firstOrNull?.rawValue;
                if (rawValue == null || rawValue.isEmpty) return;
                _handled = true;
                Navigator.of(context).pop(rawValue);
              },
            )
          else if (_cameraError != null)
            _CameraErrorView(message: _cameraError!)
          else
            const Center(child: CircularProgressIndicator()),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Text(
                    'Point at the QR code on the laptop',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraErrorView extends StatelessWidget {
  const _CameraErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '$message\n\nGo back and use Pair manually.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
