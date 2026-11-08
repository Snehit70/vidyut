import 'package:flutter/material.dart';

/// Says what Android's capture prompt is for, before the prompt appears, so
/// the system dialog does not arrive out of nowhere. Resolves true to go on.
Future<bool> showScreenMirrorConsent(BuildContext context) async {
  final proceed = await showModalBottomSheet<bool>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Show this screen on the laptop',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Android will ask to share your screen. It goes only to your '
              'laptop on this Wi-Fi.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Everything on the screen shows, so close anything private '
              'first.',
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return proceed ?? false;
}
