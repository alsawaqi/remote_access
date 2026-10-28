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
  static const String revokedMessage =
      'Remote access was revoked by an administrator. Enrol again with a new code.';

  final SecureStore store = SecureStore();
  final ApiClient api = ApiClient();
  final InputDispatcher input = InputDispatcher();

  SignalingService? _signaling;
  RemoteSession? _session;
  String? _sessionChannel;
  Future<void> _lastTeardown = Future<void>.value();
  Timer? _heartbeat;
  bool _heartbeatInFlight = false;

  /// Bumped whenever the enrollment changes (start / revoke / unenrol) so
  /// late callbacks from a previous enrollment cannot act on the current one.
  int _epoch = 0;

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
    final epoch = ++_epoch;

    // Never keep two signaling connections / heartbeat loops alive.
    _heartbeat?.cancel();
    _heartbeat = null;
    final previous = _signaling;
    _signaling = null;
    if (previous != null) {
      try {
        await previous.disconnect();
      } catch (_) {}
    }

    final reverbKey = await store.reverbKey() ?? '';
    final deviceChannel = await store.channel() ?? 'private-device.$deviceId';
    if (epoch != _epoch) return;

    phase = DaemonPhase.connecting;
    error = null;
    notifyListeners();

    final signaling = SignalingService(
      api: api,
      reverbKey: reverbKey,
      onConnectionChange: (connected) {
        if (epoch != _epoch) return;
        connection = connected ? 'connected' : 'connecting';
        if (connected) phase = DaemonPhase.online;
        notifyListeners();
      },
    );
    _signaling = signaling;

    await signaling.connect();
    if (epoch != _epoch) return; // revoked / unenrolled while connecting

    signaling.subscribePrivate(
      deviceChannel,
      {
        'session.requested': (data) => _onSessionRequested(data, epoch),
        'session.ended': _onSessionEndedEvent,
        'device.revoked': (data) => _onDeviceRevokedEvent(data, epoch),
      },
      // 401 from /broadcasting/auth = the device token no longer exists.
      onAuthError: (status) {
        if (status == 401) _handleRevoked(epoch);
      },
    );

    _startHeartbeat(epoch);
  }

  void _startHeartbeat(int epoch) {
    _heartbeat?.cancel();
    _sendHeartbeat(epoch);
    _heartbeat = Timer.periodic(
      AppConfig.heartbeatInterval,
      (_) => _sendHeartbeat(epoch),
    );
  }

  Future<void> _sendHeartbeat(int epoch) async {
    // One heartbeat at a time: a slow network must not stack requests.
    if (_heartbeatInFlight || epoch != _epoch) return;
    _heartbeatInFlight = true;
    try {
      final caps = await _capabilities();
      if (epoch != _epoch) return;
      await api.heartbeat(caps, activeSessionId: _session?.sessionId);
    } on ApiException catch (e) {
      if (e.isUnauthorized) await _handleRevoked(epoch);
      // Anything else is transient; the next tick retries.
    } catch (_) {
      /* transient */
    } finally {
      _heartbeatInFlight = false;
    }
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

  Future<void> _onSessionRequested(Map<String, dynamic> data, int epoch) async {
    if (epoch != _epoch || _session != null) return; // one session at a time

    final signaling = _signaling;
    final sessionId = _asInt(data['session_id']);
    if (signaling == null || sessionId == null) return;

    final rawIceServers = data['ice_servers'];
    final iceServers = rawIceServers is List ? rawIceServers : <dynamic>[];
    final controlEnabled = data['control_enabled'] == true;
    final rawChannel = data['channel'];
    final sessionChannel = rawChannel is String && rawChannel.isNotEmpty
        ? rawChannel
        : 'private-remote-session.$sessionId';

    final session = RemoteSession(
      sessionId: sessionId,
      api: api,
      iceServers: iceServers,
      controlEnabled: controlEnabled,
      input: input,
      // The session ended itself (connection failure, negotiation timeout,
      // rejected answer): tell the API why.
      onClosed: (s, reason) => _endSession(s, notifyServer: true, reason: reason),
      onUnauthorized: () => _handleRevoked(epoch),
    );

    _session = session;
    _sessionChannel = sessionChannel;
    sessionActive = true;
    controlActive = controlEnabled;
    notifyListeners();

    // Give the previous session a moment to release its peer connection and
    // projection before this one acquires new ones. This wait is NOT what
    // protects this session's capture: ScreenCaptureController only stops the
    // shared service once no session holds it, so the previous session's late
    // "stop" (its teardown can outlast this bound — each step has its own 5 s
    // limit) is a no-op once this session has started capture.
    await _lastTeardown.timeout(const Duration(seconds: 10), onTimeout: () {});
    if (!identical(_session, session)) return; // ended while waiting

    signaling.subscribePrivate(
      sessionChannel,
      {
        'webrtc.answer': (d) {
          if (!identical(_session, session)) return;
          final sdp = d['sdp'];
          unawaited(session.onAnswer(sdp is String ? sdp : ''));
        },
        'webrtc.ice': (d) {
          if (d['from'] == 'device' || !identical(_session, session)) return;
          unawaited(session.onRemoteIce(d));
        },
        'session.ended': _onSessionEndedEvent,
      },
      onAuthError: (status) {
        if (status == 401) _handleRevoked(epoch);
      },
    );

    try {
      await session.start();
    } on SessionStartException catch (e) {
      if (identical(_session, session)) error = 'Capture/offer failed: ${e.message}';
      await _endSession(session, notifyServer: true, reason: e.reason);
    } catch (e) {
      if (identical(_session, session)) error = 'Capture/offer failed: $e';
      await _endSession(session, notifyServer: true, reason: EndReason.offerFailed);
    }
  }

  /// `session.ended` (device channel and session channel): only tear down when
  /// it is about the session this device is currently serving.
  void _onSessionEndedEvent(Map<String, dynamic> data) {
    final session = _session;
    final endedId = _asInt(data['session_id']);
    if (session == null || endedId == null || endedId != session.sessionId) return;
    _endSession(session, notifyServer: false);
  }

  void _onDeviceRevokedEvent(Map<String, dynamic> data, int epoch) {
    final revokedId = _asInt(data['device_id']);
    if (revokedId != null && deviceId != null && revokedId != deviceId) return;
    _handleRevoked(epoch);
  }

  /// Ends [session] — and only that instance. If it is not the live session
  /// any more (already ended or replaced) it is just released.
  Future<void> _endSession(
    RemoteSession session, {
    required bool notifyServer,
    String reason = EndReason.endedByDevice,
  }) async {
    final closing = session.close(); // idempotent: returns the teardown in flight

    if (!identical(_session, session)) {
      try {
        await closing;
      } catch (_) {}
      return;
    }

    final epoch = _epoch;
    final channel = _sessionChannel;
    _session = null;
    _sessionChannel = null;
    sessionActive = false;
    controlActive = false;
    notifyListeners();

    final teardown = closing.catchError((Object _) {});
    _lastTeardown = teardown;

    if (channel != null) {
      try {
        await _signaling?.unsubscribe(channel);
      } catch (_) {}
    }
    if (notifyServer) {
      try {
        await api.endSession(session.sessionId, reason: reason);
      } on ApiException catch (e) {
        if (e.isUnauthorized) await _handleRevoked(epoch);
      } catch (_) {}
    }

    await teardown;
  }

  /// Remote access was revoked (HTTP 401 on a device call or channel auth, or
  /// a `device.revoked` event): tear the session down locally WITHOUT calling
  /// the API, stop heartbeating, drop signaling, forget the credential and go
  /// back to the enrollment screen.
  Future<void> _handleRevoked(int epoch) async {
    if (epoch != _epoch) return; // stale enrollment or already handled
    _epoch++;

    _heartbeat?.cancel();
    _heartbeat = null;

    final session = _session;
    if (session != null) {
      try {
        await _endSession(session, notifyServer: false);
      } catch (_) {}
    }

    final signaling = _signaling;
    _signaling = null;
    if (signaling != null) {
      try {
        await signaling.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await store.clear();
    } catch (_) {}

    api.setToken(null);
    deviceId = null;
    connection = 'disconnected';
    sessionActive = false;
    controlActive = false;
    error = revokedMessage;
    phase = DaemonPhase.notEnrolled;
    notifyListeners();
  }

  Future<void> stopSessionByUser() async {
    final session = _session;
    if (session == null) return;
    await _endSession(session, notifyServer: true, reason: EndReason.userStopped);
  }

  Future<void> refreshAccessibility() async {
    accessibilityEnabled = await input.isEnabled();
    notifyListeners();
  }

  void openAccessibilitySettings() => input.openSettings();

  Future<void> unenroll() async {
    // Bulletproof reset: never let a hung session/connection block the return
    // to the enrollment screen.
    final session = _session;
    _epoch++; // stop every callback of the current enrollment
    _heartbeat?.cancel();
    _heartbeat = null;
    if (session != null) {
      try {
        await _endSession(session, notifyServer: false);
      } catch (_) {}
      try {
        await api.endSession(session.sessionId, reason: EndReason.userStopped);
      } catch (_) {}
    }
    final signaling = _signaling;
    _signaling = null;
    try {
      await signaling?.disconnect();
    } catch (_) {}
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

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  void dispose() {
    _epoch++;
    _heartbeat?.cancel();
    _session?.close();
    _signaling?.disconnect();
    super.dispose();
  }
}
