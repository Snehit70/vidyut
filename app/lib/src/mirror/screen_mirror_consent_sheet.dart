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
            // The app theme makes FilledButton full width (Size.fromHeight),
            // so it cannot sit in a Row: it gets no width and is not drawn.
            // Stack the actions instead, primary first.
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return proceed ?? false;
}
