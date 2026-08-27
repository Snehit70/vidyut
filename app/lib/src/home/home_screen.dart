import 'package:flutter/material.dart';

import '../activity/last_activity.dart';
import '../design/motion.dart';
import '../design/palette.dart';
import '../shared/relay_connection.dart';
import '../shared/wire.dart';

/// The paired operational surface: sync truth, one explicit file action, and
/// the latest activity. Pairing and setup recovery stay outside this surface.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.connectionStatus,
    this.relayHealth,
    this.laptopTelemetry,
    this.lastActivity,
    required this.onOpenFiles,
    required this.onOpenSettings,
    required this.onOpenRecentActivity,
    required this.onOpenConnectionDetails,
    required this.onSendFiles,
    this.setupBannerLabel,
    this.onOpenSetup,
  });

  final ConnectionStatus connectionStatus;
  final RelayHealth? relayHealth;
  final LaptopTelemetry? laptopTelemetry;
  final LastActivity? lastActivity;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenRecentActivity;
  final VoidCallback onOpenConnectionDetails;
  final VoidCallback onSendFiles;
  final String? setupBannerLabel;
  final VoidCallback? onOpenSetup;

  @override
  Widget build(BuildContext context) {
    final expanded = MediaQuery.sizeOf(context).width >= 600;
    final state = _HomeSyncState.from(
      connectionStatus: connectionStatus,
      relayHealth: relayHealth,
      scheme: Theme.of(context).colorScheme,
      statusColors: VidyutStatusColors.of(context),
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset(
              'assets/icon/icon-legacy.png',
              width: 28,
              height: 28,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            const Text('Vidyut'),
          ],
        ),
        actions: [
          if (!expanded)
            _HomeAppBarAction(
              tooltip: 'Files',
              icon: Icons.folder_outlined,
              onPressed: onOpenFiles,
            ),
          _HomeAppBarAction(
            tooltip: 'Settings',
            icon: Icons.settings_outlined,
            onPressed: onOpenSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                _SyncStatusPanel(state: state, onTap: onOpenConnectionDetails),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: onSendFiles,
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('Send files'),
                ),
                if (laptopTelemetry != null) ...[
                  _LaptopTelemetrySection(
                    telemetry: laptopTelemetry,
                    connected: connectionStatus == ConnectionStatus.connected,
                  ),
                  const SizedBox(height: 12),
                ],
                _LatestActivitySection(
                  activity: lastActivity,
                  onTap: onOpenRecentActivity,
                ),
                if (setupBannerLabel != null && onOpenSetup != null) ...[
                  const SizedBox(height: 10),
                  _HomeSetupBanner(
                    label: setupBannerLabel!,
                    onTap: onOpenSetup!,
                  ),
                ],
                if (constraints.maxWidth >= 600) const SizedBox(height: 8),
              ],
            );
            final constrainedContent = Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: content,
              ),
            );
            if (!expanded) return constrainedContent;
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: 0,
                  onDestinationSelected: (index) {
                    if (index == 1) onOpenFiles();
                  },
                  labelType: NavigationRailLabelType.all,
                  groupAlignment: -0.8,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('Home'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder),
                      label: Text('Files'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: constrainedContent),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LaptopTelemetrySection extends StatelessWidget {
  const _LaptopTelemetrySection({
    required this.telemetry,
    required this.connected,
  });

  final LaptopTelemetry? telemetry;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isStale =
        !connected ||
        telemetry == null ||
        (DateTime.now().millisecondsSinceEpoch - telemetry!.ts > 10000);

    String resolveValue(String text, Object? metric) {
      if (isStale || metric == null) return 'Unavailable';
      return text;
    }

    String resolveDetail(String detail, Object? metric) {
      if (!connected) {
        return 'Laptop disconnected';
      }
      if (isStale || metric == null) return 'Unavailable';
      return detail;
    }

    final batteryCard = _TelemetryCard(
      label: 'Battery',
      value: resolveValue(
        _percent(telemetry?.batteryPercent),
        telemetry?.batteryPercent,
      ),
      detail: resolveDetail(
        _batteryState(telemetry?.batteryState),
        telemetry?.batteryState,
      ),
      color: theme.colorScheme.primary,
    );

    final tempCard = _TelemetryCard(
      label: 'CPU temperature',
      value: resolveValue(
        _temp(telemetry?.cpuTemperatureCelsius),
        telemetry?.cpuTemperatureCelsius,
      ),
      detail: resolveDetail(
        _temperatureState(telemetry?.cpuTemperatureCelsius),
        telemetry?.cpuTemperatureCelsius,
      ),
      color: _temperatureColor(
        theme,
        isStale ? null : telemetry?.cpuTemperatureCelsius,
      ),
    );

    final memoryCard = _TelemetryCard(
      label: 'Memory',
      value: resolveValue(
        _bytes(telemetry?.memoryUsedBytes),
        telemetry?.memoryUsedBytes,
      ),
      detail: resolveDetail(
        _ratio(telemetry?.memoryUsedBytes, telemetry?.memoryTotalBytes),
        telemetry?.memoryUsedBytes,
      ),
      color: theme.colorScheme.primary,
    );

    final storageCard = _TelemetryCard(
      label: 'Storage',
      value: resolveValue(
        _bytes(telemetry?.storageUsedBytes),
        telemetry?.storageUsedBytes,
      ),
      detail: resolveDetail(
        _ratio(telemetry?.storageUsedBytes, telemetry?.storageTotalBytes),
        telemetry?.storageUsedBytes,
      ),
      color: theme.colorScheme.secondary,
    );

    final cpuCard = _TelemetryCard(
      label: 'CPU usage',
      value: resolveValue(
        telemetry?.cpuUsagePercent == null
            ? 'Unavailable'
            : '${telemetry!.cpuUsagePercent!.round()}%',
        telemetry?.cpuUsagePercent,
      ),
      detail: resolveDetail(
        _cpuState(telemetry?.cpuUsagePercent),
        telemetry?.cpuUsagePercent,
      ),
      color: _cpuColor(theme, isStale ? null : telemetry?.cpuUsagePercent),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Laptop telemetry', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: batteryCard),
            const SizedBox(width: 8),
            Expanded(child: tempCard),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: memoryCard),
            const SizedBox(width: 8),
            Expanded(child: storageCard),
          ],
        ),
        const SizedBox(height: 8),
        cpuCard,
      ],
    );
  }
}

class _TelemetryCard extends StatelessWidget {
  const _TelemetryCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
  });

  final String label;
  final String value;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value, $detail',
      child: Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _percent(double? value) =>
    value == null ? 'Unavailable' : '${value.round()}%';
String _temp(double? value) =>
    value == null ? 'Unavailable' : '${value.toStringAsFixed(1)}°C';
String _batteryState(String? value) => switch (value) {
  'charging' => 'Charging',
  'plugged_in' => 'Plugged in',
  'on_battery' => 'On battery',
  _ => 'Unavailable',
};
String _bytes(int? used) => used == null
    ? 'Unavailable'
    : '${(used / 1073741824).toStringAsFixed(1)} GB';
String _ratio(int? used, int? total) =>
    used == null || total == null || total == 0
    ? 'Unavailable'
    : '${(used / total * 100).round()}% used';
String _cpuState(double? value) => value == null
    ? 'Unavailable'
    : value < 50
    ? 'Low'
    : value <= 80
    ? 'Moderate'
    : 'High';
String _temperatureState(double? value) => value == null
    ? 'Unavailable'
    : value >= 82
    ? 'Critical'
    : value >= 70
    ? 'Warning'
    : 'Normal';
Color _cpuColor(ThemeData theme, double? value) => value == null
    ? theme.colorScheme.onSurfaceVariant
    : value > 80
    ? theme.colorScheme.error
    : value >= 50
    ? theme.colorScheme.tertiary
    : theme.colorScheme.primary;
Color _temperatureColor(ThemeData theme, double? value) => value == null
    ? theme.colorScheme.onSurfaceVariant
    : value >= 82
    ? theme.colorScheme.error
    : value >= 70
    ? theme.colorScheme.tertiary
    : theme.colorScheme.primary;

class _HomeAppBarAction extends StatelessWidget {
  const _HomeAppBarAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _HomeSyncState {
  const _HomeSyncState({
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
    required this.containerColor,
    required this.searching,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final Color containerColor;
  final bool searching;

  factory _HomeSyncState.from({
    required ConnectionStatus connectionStatus,
    required RelayHealth? relayHealth,
    required ColorScheme scheme,
    required VidyutStatusColors statusColors,
  }) {
    if (connectionStatus == ConnectionStatus.connected) {
      if (relayHealth == null) {
        return _HomeSyncState(
          label: 'Checking sync',
          description: 'Checking the laptop clipboard connection.',
          icon: Icons.sync_outlined,
          color: scheme.primary,
          containerColor: scheme.primaryContainer,
          searching: true,
        );
      }
      if (relayHealth.degraded) {
        return _HomeSyncState(
          label: 'Sync needs attention',
          description:
              'Connected, but automatic clipboard sync needs recovery.',
          icon: Icons.sync_problem_outlined,
          color: statusColors.warning,
          containerColor: statusColors.warningContainer,
          searching: false,
        );
      }
      return _HomeSyncState(
        label: 'Ready',
        description: 'Automatic clipboard sync is ready between your devices.',
        icon: Icons.sync_outlined,
        color: statusColors.success,
        containerColor: statusColors.successContainer,
        searching: false,
      );
    }

    if (connectionStatus == ConnectionStatus.searching) {
      return _HomeSyncState(
        label: 'Searching',
        description: 'Looking for your laptop on the local network.',
        icon: Icons.wifi_find_outlined,
        color: scheme.primary,
        containerColor: scheme.primaryContainer,
        searching: true,
      );
    }

    return _HomeSyncState(
      label: 'Offline',
      description:
          "Can't reach your laptop right now. Vidyut will reconnect automatically.",
      icon: Icons.cloud_off_outlined,
      color: scheme.error,
      containerColor: scheme.secondaryContainer,
      searching: false,
    );
  }
}

class _SyncStatusPanel extends StatelessWidget {
  const _SyncStatusPanel({required this.state, required this.onTap});

  final _HomeSyncState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: '${state.label}. ${state.description}',
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _StatusGlyph(
                  state: state,
                  animate:
                      state.searching &&
                      !disableAnimations &&
                      Motion.loopsEnabled,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.label, style: textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        state.description,
                        style: textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: state.color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.state, required this.animate});

  final _HomeSyncState state;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: state.containerColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(state.icon, size: 26, color: state.color),
            if (animate &&
                Motion.loopsEnabled &&
                !MediaQuery.disableAnimationsOf(context))
              Positioned(
                right: 6,
                top: 6,
                child: _SearchDot(color: state.color),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchDot extends StatefulWidget {
  const _SearchDot({required this.color});

  final Color color;

  @override
  State<_SearchDot> createState() => _SearchDotState();
}

class _SearchDotState extends State<_SearchDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: DecoratedBox(
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
        child: const SizedBox(width: 8, height: 8),
      ),
    );
  }
}

class _LatestActivitySection extends StatelessWidget {
  const _LatestActivitySection({required this.activity, required this.onTap});

  final LastActivity? activity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final activityLabel = activity == null
        ? 'Nothing shared yet'
        : activity!.outcome == ActivityOutcome.failed
        ? 'Failed: ${activity!.describe()}'
        : activity!.describe();
    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: 'Latest activity. $activityLabel',
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Latest activity', style: textTheme.titleMedium),
                const SizedBox(height: 8),
                _ActivityRow(activity: activity),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeSetupBanner extends StatelessWidget {
  const _HomeSetupBanner({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.tune, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(label)),
              Icon(Icons.chevron_right, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity});

  final LastActivity? activity;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final hasActivity = activity != null;
    final failed = hasActivity && activity!.outcome == ActivityOutcome.failed;
    final icon = !hasActivity
        ? Icons.history_outlined
        : failed
        ? Icons.error_outline
        : activity!.direction == ActivityDirection.received
        ? Icons.call_received_outlined
        : Icons.call_made_outlined;
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: failed ? scheme.errorContainer : scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  icon,
                  size: 20,
                  color: failed ? scheme.error : scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasActivity
                    ? failed
                          ? 'Failed: ${activity!.describe()}'
                          : activity!.describe()
                    : 'Nothing shared yet',
                style: textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
