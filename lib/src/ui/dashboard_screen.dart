import 'package:flutter/material.dart';

import '../services/device_daemon.dart';

class DashboardScreen extends StatefulWidget {
  final DeviceDaemon daemon;
  const DashboardScreen({super.key, required this.daemon});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  DeviceDaemon get daemon => widget.daemon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    daemon.refreshAccessibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the technician returns from Accessibility settings.
    if (state == AppLifecycleState.resumed) daemon.refreshAccessibility();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = daemon.phase == DaemonPhase.online;

    return Scaffold(
      appBar: AppBar(title: const Text('Remote Access Agent')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Consent / "being controlled" indicator (always visible while live).
            if (daemon.sessionActive)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.visibility, color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          daemon.controlActive
                              ? 'This device is being viewed and controlled remotely.'
                              : 'This device screen is being viewed remotely.',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            _statusTile('Connection', daemon.connection, online ? Colors.green : Colors.orange),
            _statusTile('Device ID', daemon.deviceId?.toString() ?? '—', theme.colorScheme.primary),
            _statusTile('OS', daemon.osVersion ?? '—', theme.colorScheme.primary),
            _statusTile('Session', daemon.sessionActive ? 'Active' : 'Idle',
                daemon.sessionActive ? Colors.red : Colors.grey),
            _statusTile('Input control', daemon.accessibilityEnabled ? 'Enabled' : 'Disabled',
                daemon.accessibilityEnabled ? Colors.green : Colors.orange),
            if (!daemon.accessibilityEnabled) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: daemon.openAccessibilitySettings,
                icon: const Icon(Icons.accessibility_new),
                label: const Text('Enable input control (Accessibility)'),
              ),
            ],
            if (daemon.error != null) ...[
              const SizedBox(height: 8),
              Text(daemon.error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 24),
            if (daemon.sessionActive)
              OutlinedButton.icon(
                onPressed: () => daemon.stopSessionByUser(),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('End remote session'),
              ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _confirmUnenroll(context),
              child: const Text('Unenrol this device'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusTile(String label, String value, Color color) => Card(
        child: ListTile(
          leading: Icon(Icons.circle, size: 12, color: color),
          title: Text(label),
          trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );

  Future<void> _confirmUnenroll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unenrol device?'),
        content: const Text(
            'This revokes remote access until the device is enrolled again with a new code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unenrol')),
        ],
      ),
    );
    if (confirmed == true) await daemon.unenroll();
  }
}
