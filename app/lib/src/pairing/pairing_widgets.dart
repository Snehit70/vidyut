import 'package:flutter/material.dart';

import '../design/palette.dart';
import '../design/widgets.dart';
import 'relay_discovery.dart';

/// Discovery results card, shared by the home pairing screen and the
/// onboarding wizard finale (onboarding spec D3: pairing is the existing
/// flow, restyled — no behavioral change).
class NearbyRelaysCard extends StatelessWidget {
  const NearbyRelaysCard({
    super.key,
    required this.relays,
    required this.selected,
    required this.discovering,
    required this.onRefresh,
    required this.onSelect,
    this.error,
  });

  final List<DiscoveredRelay> relays;
  final DiscoveredRelay? selected;
  final bool discovering;
  final VoidCallback onRefresh;
  final ValueChanged<DiscoveredRelay> onSelect;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (discovering) ...[
              const PulsingDot(size: 8),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text('Nearby relays', style: textTheme.titleMedium),
            ),
            if (!discovering)
              IconButton(
                tooltip: 'Search again',
                icon: const Icon(Icons.refresh, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: Palette.mist,
                  foregroundColor: Palette.raspberry,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onRefresh,
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (relays.isEmpty)
          Text(
            discovering
                ? 'Searching for relays on this network…'
                : error ??
                      'No laptop found. Start the relay, then search again, '
                          'or scan its QR code below.',
            style: textTheme.bodyMedium?.copyWith(color: Palette.muted),
          )
        else
          for (final relay in relays)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Palette.petal,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.dns,
                    size: 20,
                    color: Palette.raspberry,
                  ),
                ),
                title: Text(relay.name, style: textTheme.titleSmall),
                subtitle: Text(
                  '${relay.host}:${relay.port}',
                  style: textTheme.bodySmall?.copyWith(color: Palette.muted),
                ),
                trailing: relay == selected
                    ? const Icon(Icons.check_circle, color: Palette.raspberry)
                    : null,
                onTap: () => onSelect(relay),
              ),
            ),
        if (selected != null) ...[
          const SizedBox(height: 4),
          Text(
            'Enter the pairing secret below and tap Pair manually.',
            style: textTheme.bodyMedium?.copyWith(color: Palette.muted),
          ),
        ],
      ],
    );
  }
}

/// Manual host/port/secret entry form, shared like [NearbyRelaysCard].
class ManualPairingForm extends StatelessWidget {
  const ManualPairingForm({
    super.key,
    required this.hostController,
    required this.portController,
    required this.secretController,
    required this.error,
    required this.onScanQr,
    required this.onPair,
  });

  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController secretController;
  final String? error;
  final VoidCallback onScanQr;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Manual pairing', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          controller: hostController,
          decoration: const InputDecoration(
            labelText: 'Relay IP',
            prefixIcon: Icon(Icons.router),
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: portController,
          decoration: const InputDecoration(
            labelText: 'Port',
            prefixIcon: Icon(Icons.settings_ethernet),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: secretController,
          decoration: const InputDecoration(
            labelText: 'Pairing secret',
            prefixIcon: Icon(Icons.key),
          ),
          obscureText: true,
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Palette.mist,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 18,
                    color: Palette.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Palette.error),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        PressableScale(
          child: FilledButton.icon(
            onPressed: onPair,
            icon: const Icon(Icons.link),
            label: const Text('Pair manually'),
          ),
        ),
        const SizedBox(height: 12),
        PressableScale(
          child: OutlinedButton.icon(
            onPressed: onScanQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR'),
          ),
        ),
      ],
    );
  }
}
