import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import '../input/input_dispatcher.dart';
import 'api_client.dart';
import 'remote_session.dart';
import 'secure_store.dart';
import 'signaling_service.dart';

enum DaemonPhase { notEnrolled, connecting, online, error }

/// Long-lived coordinator: keeps the Reverb connection alive, heartbeats, and
/// drives a [RemoteSession] when the admin requests one. Exposes state via
/// ChangeNotifier for the UI.
class DeviceDaemon extends ChangeNotifier {
  final SecureStore store = SecureStore();
  final ApiClient api = ApiClient();
  final InputDispatcher input = InputDispatcher();

  SignalingService? _signaling;
  RemoteSession? _session;
  Timer? _heartbeat;
  String? _deviceChannel;

  DaemonPhase phase = DaemonPhase.notEnrolled;
  String connection = 'disconnected';
  bool sessionActive = false;
  bool controlActive = false;
  String? error;
  int? deviceId;
  String? osVersion;
  bool accessibilityEnabled = false;

  Future<void> bootstrap() async {
    if (await store.isEnrolled()) {
      api.setToken(await store.token());
      deviceId = await store.deviceId();
      await _start();
    } else {
      phase = DaemonPhase.notEnrolled;
      notifyListeners();
    }
  }

  Future<void> enroll(String code) async {
    error = null;
    phase = DaemonPhase.connecting;
    notifyListeners();

    try {
      final caps = await _capabilities();
      final result = await api.enroll(
        code: code.trim().toUpperCase(),
        appVersion: caps['app_version'] as String?,
        osVersion: caps['os_version'] as String?,
      );

      final token = result['device_token'] as String;
      final device = (result['device'] as Map).cast<String, dynamic>();
      final id = (device['id'] as num).toInt();
      final reverbKey = result['reverb_key'] as String? ?? '';
      final channel = result['channel'] as String? ?? 'private-device.$id';

      await store.saveEnrollment(
        token: token,
        deviceId: id,
        reverbKey: reverbKey,
        channel: channel,
      );
      api.setToken(token);
      deviceId = id;

      await _start();
    } catch (e) {
      error = e.toString();
      phase = DaemonPhase.error;
      notifyListeners();
    }
  }

  Future<void> _start() async {
    final reverbKey = await store.reverbKey() ?? '';
    _deviceChannel = await store.channel() ?? 'private-device.$deviceId';

    phase = DaemonPhase.connecting;
    error = null;
    notifyListeners();

    _signaling = SignalingService(
      api: api,
      reverbKey: reverbKey,
      onConnectionChange: (connected) {
        connection = connected ? 'connected' : 'connecting';
        if (connected) phase = DaemonPhase.online;
        notifyListeners();
      },
    );

    await _signaling!.connect();
    _signaling!.subscribePrivate(_deviceChannel!, {
      'session.requested': (data) => _onSessionRequested(data),
      'session.ended': (_) => _endSession(notifyServer: false),
    });

    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _sendHeartbeat();
    _heartbeat = Timer.periodic(AppConfig.heartbeatInterval, (_) => _sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    try {
      await api.heartbeat(await _capabilities());
    } catch (_) {/* transient */}
  }

  Future<Map<String, dynamic>> _capabilities() async {
    String? appVersion;
    String? os;
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    try {
      os = 'Android ${(await DeviceInfoPlugin().androidInfo).version.release}';
    } catch (_) {}
    osVersion = os;
    accessibilityEnabled = await input.isEnabled();

    return {
      'app_version': ?appVersion,
      'os_version': ?os,
      'accessibility_enabled': accessibilityEnabled,
      'projection_ready': true,
    };
  }

  Future<void> _onSessionRequested(Map<String, dynamic> data) async {
    if (_session != null) return; // one session at a time

    final sessionId = (data['session_id'] as num).toInt();
    final iceServers = (data['ice_servers'] as List?) ?? <dynamic>[];
    final controlEnabled = data['control_enabled'] == true;
    final sessionChannel =
        data['channel'] as String? ?? 'private-remote-session.$sessionId';

    _signaling!.subscribePrivate(sessionChannel, {
      'webrtc.answer': (d) => _session?.onAnswer(d['sdp'] as String? ?? ''),
      'webrtc.ice': (d) {
        if (d['from'] != 'device') _session?.onRemoteIce(d);
      },
      'session.ended': (_) => _endSession(notifyServer: false),
    });

    _session = RemoteSession(
      sessionId: sessionId,
      api: api,
      iceServers: iceServers,
      controlEnabled: controlEnabled,
      input: input,
      onClosed: () => _endSession(notifyServer: true),
    );

    sessionActive = true;
    controlActive = controlEnabled;
    notifyListeners();

    try {
      await _session!.start();
    } catch (e) {
      error = 'Capture/offer failed: $e';
      await _endSession(notifyServer: true);
    }
  }

  Future<void> _endSession({required bool notifyServer}) async {
    final session = _session;
    final sessionId = session?.sessionId;

    _session = null;
    sessionActive = false;
    controlActive = false;
    notifyListeners();

    await session?.close();

    if (sessionId != null) {
      try {
        await _signaling?.unsubscribe('private-remote-session.$sessionId');
      } catch (_) {}
      if (notifyServer) {
        try {
          await api.endSession(sessionId);
        } catch (_) {}
      }
    }
  }

  Future<void> stopSessionByUser() => _endSession(notifyServer: true);

  Future<void> refreshAccessibility() async {
    accessibilityEnabled = await input.isEnabled();
    notifyListeners();
  }

  void openAccessibilitySettings() => input.openSettings();

  Future<void> unenroll() async {
    // Bulletproof reset: never let a hung session/connection block the return
    // to the enrollment screen.
    try {
      await _endSession(notifyServer: true);
    } catch (_) {}
    _heartbeat?.cancel();
    try {
      await _signaling?.disconnect();
    } catch (_) {}
    _signaling = null;
    try {
      await store.clear();
    } catch (_) {}
    api.setToken(null);
    deviceId = null;
    connection = 'disconnected';
    error = null;
    sessionActive = false;
    controlActive = false;
    phase = DaemonPhase.notEnrolled;
    notifyListeners();
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _signaling?.disconnect();
    super.dispose();
  }
}
