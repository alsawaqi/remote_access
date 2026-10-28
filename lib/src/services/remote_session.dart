import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../input/input_dispatcher.dart';
import 'api_client.dart';
import 'screen_capture.dart';

/// End reasons the device reports to POST /api/device/sessions/{id}/end.
class EndReason {
  EndReason._();

  static const String endedByDevice = 'ended_by_device';
  static const String captureFailed = 'capture_failed';
  static const String offerFailed = 'offer_failed';
  static const String negotiationTimeout = 'negotiation_timeout';
  static const String answerRejected = 'answer_rejected';
  static const String connectionFailed = 'connection_failed';
  static const String userStopped = 'user_stopped';
}

/// Thrown by [RemoteSession.start] when the session could not be started.
/// [reason] is the end reason to report to the API.
class SessionStartException implements Exception {
  final String reason;
  final String message;
  SessionStartException(this.reason, this.message);

  @override
  String toString() => message;
}

typedef SessionClosedCallback = void Function(
  RemoteSession session,
  String reason,
);

/// One live WebRTC session. The DEVICE is the offerer: it captures the screen
/// (MediaProjection via getDisplayMedia), creates the control DataChannel, and
/// sends the offer. The admin answers.
class RemoteSession {
  /// Upper bound for getDisplayMedia (MediaProjection acquisition).
  static const Duration captureTimeout = Duration(seconds: 30);

  /// The peer connection must reach `connected` within this long after the
  /// offer was posted, or the session ends with `negotiation_timeout`.
  static const Duration negotiationTimeout = Duration(seconds: 45);

  /// Bound for each individual release step so teardown can never hang.
  static const Duration _releaseStepTimeout = Duration(seconds: 5);

  /// How long this session keeps holding the capture service after it ended
  /// while its getDisplayMedia call is still outstanding (typically the
  /// MediaProjection consent dialog is still on screen). See [_release].
  static const Duration _pendingCaptureGrace = Duration(minutes: 2);

  final int sessionId;
  final ApiClient api;
  final List<dynamic> iceServers;
  final bool controlEnabled;
  final InputDispatcher input;

  /// Invoked once when the session ends ITSELF (connection failure,
  /// negotiation timeout, rejected answer), after its resources are released,
  /// with the end reason. Not invoked for `close(notify: false)`.
  final SessionClosedCallback? onClosed;

  /// Invoked when an API call made by this session is answered with HTTP 401,
  /// i.e. the device token was revoked.
  final void Function()? onUnauthorized;

  RemoteSession({
    required this.sessionId,
    required this.api,
    required this.iceServers,
    required this.controlEnabled,
    required this.input,
    this.onClosed,
    this.onUnauthorized,
  });

  final ScreenCaptureController _capture = ScreenCaptureController();
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  RTCDataChannel? _control;
  Future<void>? _captureStarting;

  /// The getDisplayMedia call, from the moment it is made until start() takes
  /// ownership of its stream. While set, [_release] owns it: it releases
  /// whatever the call produces and only then gives up the capture service.
  Future<MediaStream>? _displayMediaPending;
  Timer? _negotiationTimer;
  bool _connected = false;
  bool _answerReceived = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _closed = false;
  Future<void>? _closing;

  bool get isClosed => _closed;

  /// Acquires capture, builds the peer connection and posts the offer.
  ///
  /// Throws [SessionStartException] on failure (the caller ends the session
  /// with its reason). If the session is closed while starting, everything
  /// acquired so far is released and this returns normally. On HTTP 401 it
  /// calls [onUnauthorized] and returns.
  Future<void> start() async {
    // 1) Peer connection.
    final RTCPeerConnection pc;
    try {
      pc = await createPeerConnection({
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
      });
    } catch (e) {
      if (_closed) return;
      throw SessionStartException(
        EndReason.offerFailed,
        'Could not create the WebRTC peer connection: $e',
      );
    }
    if (_closed) {
      await _disposePeerConnection(pc);
      return;
    }
    _pc = pc;

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      if (_closed || candidate.candidate == null) return;
      api.postIce(sessionId, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }).catchError((Object error) {
        if (error is ApiException && error.isUnauthorized) {
          onUnauthorized?.call();
        }
        // Anything else (e.g. 409 once the session has ended) is not
        // actionable per-candidate; session.ended / timeouts handle it.
      });
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _connected = true;
          _negotiationTimer?.cancel();
          _negotiationTimer = null;
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          close(notify: true, reason: EndReason.connectionFailed);
          break;
        default:
          break;
      }
    };

    // 2) Android 10+/14 require a running mediaProjection foreground service
    // BEFORE the projection is acquired (flutter_webrtc does not start one).
    // If it can't enter the foreground (e.g. Android 14+ kiosk without the
    // project_media app-op), abort now with an actionable message rather than
    // letting getDisplayMedia fail or the native service crash the app.
    final captureStart = _capture.start();
    _captureStarting = captureStart;
    try {
      await captureStart;
    } catch (e) {
      if (_closed) return;
      throw SessionStartException(
        EndReason.captureFailed,
        'Screen capture could not start: $e. On Android 14+ the device needs '
        'the screen-capture permission — accept the on-screen prompt, or '
        'pre-grant it via MDM/Device-Owner '
        '(appops set net.mithqal.remoteaccess PROJECT_MEDIA allow).',
      );
    }
    // If closed meanwhile, close() waits for the service start and stops it.
    if (_closed) return;

    // 3) Screen capture — triggers the Android MediaProjection consent dialog
    // unless the project_media app-op was pre-granted.
    final displayMedia = navigator.mediaDevices.getDisplayMedia({
      'video': true,
      'audio': false,
    });
    // Set in the same synchronous step as the call (and after the _closed
    // check above), so a later close() always sees it.
    _displayMediaPending = displayMedia;
    final MediaStream stream;
    try {
      stream = await displayMedia.timeout(captureTimeout);
    } on TimeoutException {
      // The call is still outstanding. _displayMediaPending stays set, so the
      // close() that follows (or already ran) releases a projection granted
      // later and keeps the capture service up until then — stopping it first
      // would crash the process if the consent dialog is accepted afterwards.
      if (_closed) return;
      throw SessionStartException(
        EndReason.captureFailed,
        'Screen capture did not start within ${captureTimeout.inSeconds} seconds.',
      );
    } catch (e) {
      if (_closed) return;
      throw SessionStartException(EndReason.captureFailed, 'Screen capture failed: $e');
    }
    // Closed meanwhile: _release() owns the call and disposes this stream
    // before it gives up the capture service.
    if (_closed) return;
    _displayMediaPending = null;
    _stream = stream;

    // 4) Tracks, control channel and offer. From here on every acquired
    // resource is stored in a field right away, so close() releases it.
    final String sdp;
    try {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
        if (_closed) return;
      }

      // Control channel (admin -> device). The offerer creates it.
      input.enabled = controlEnabled;
      final control = await pc.createDataChannel('control', RTCDataChannelInit());
      if (_closed) {
        await _quietly(control.close);
        return;
      }
      _control = control;
      control.onMessage = (RTCDataChannelMessage message) {
        if (_closed) return;
        input.handle(message.text);
      };

      final offer = await pc.createOffer({});
      if (_closed) return;
      await pc.setLocalDescription(offer);
      if (_closed) return;
      sdp = offer.sdp ?? '';
    } catch (e) {
      if (_closed) return;
      throw SessionStartException(EndReason.offerFailed, 'Could not create the offer: $e');
    }

    // 5) Post the offer.
    try {
      await api.postOffer(sessionId, sdp);
    } on ApiException catch (e) {
      if (_closed) return;
      if (e.isUnauthorized) {
        onUnauthorized?.call();
        return;
      }
      throw SessionStartException(
        EndReason.offerFailed,
        'Could not send the offer: ${e.message}',
      );
    } catch (e) {
      if (_closed) return;
      throw SessionStartException(EndReason.offerFailed, 'Could not send the offer: $e');
    }
    if (_closed || _connected) return;

    // 6) The admin must answer and ICE must connect within the window.
    _negotiationTimer = Timer(negotiationTimeout, () {
      _negotiationTimer = null;
      if (_closed || _connected) return;
      close(notify: true, reason: EndReason.negotiationTimeout);
    });
  }

  /// Applies the admin's answer. Never throws: a rejected answer ends the
  /// session with `answer_rejected`. Duplicate answers are ignored.
  Future<void> onAnswer(String sdp) async {
    final pc = _pc;
    if (_closed || pc == null) return;
    if (_answerReceived) {
      debugPrint('[session $sessionId] duplicate answer ignored');
      return;
    }
    _answerReceived = true;

    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(_sanitizeSdp(sdp), 'answer'),
      );
    } catch (e) {
      debugPrint('[session $sessionId] answer rejected: $e');
      if (!_closed) await close(notify: true, reason: EndReason.answerRejected);
      return;
    }
    if (_closed) return;
    _remoteDescriptionSet = true;

    // Candidates that arrived before the answer.
    final pending = List<RTCIceCandidate>.of(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final candidate in pending) {
      if (_closed) return;
      await _addRemoteCandidate(pc, candidate);
    }
  }

  /// Defensive SDP normalization for the answer we receive. Two independent
  /// issues can otherwise make libwebrtc reject it with the misleading
  /// "SessionDescription is NULL": (1) some flutter_webrtc/libwebrtc builds emit
  /// SDP with non-CRLF or doubled line endings, and (2) a trailing CRLF can be
  /// stripped in transit. Cause (2) is now fixed centrally on the API (its
  /// TrimStrings middleware excludes the `sdp` field), so this stays as a cheap
  /// safety net: split on any newline, trim, drop blank lines, rejoin with CRLF.
  String _sanitizeSdp(String sdp) {
    final lines = sdp
        .split(RegExp(r'\r\n|\r|\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return '${lines.join('\r\n')}\r\n';
  }

  /// Adds a remote ICE candidate. Never throws. Candidates that arrive before
  /// the answer has been applied are queued and added right after it.
  Future<void> onRemoteIce(Map<String, dynamic> data) async {
    if (_closed) return;
    final raw = data['candidate'];
    if (raw is! String || raw.isEmpty) return;
    final mid = data['sdpMid'];
    final index = data['sdpMLineIndex'];
    final candidate = RTCIceCandidate(
      raw,
      mid is String ? mid : null,
      index is num ? index.toInt() : null,
    );

    final pc = _pc;
    if (pc == null || !_remoteDescriptionSet) {
      _pendingRemoteIce.add(candidate);
      return;
    }
    await _addRemoteCandidate(pc, candidate);
  }

  Future<void> _addRemoteCandidate(RTCPeerConnection pc, RTCIceCandidate candidate) async {
    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('[session $sessionId] remote ICE candidate rejected: $e');
    }
  }

  /// Releases every resource. Idempotent: later calls return the teardown
  /// already in progress. With [notify], [onClosed] is invoked with [reason]
  /// (default `ended_by_device`) once everything is released.
  Future<void> close({bool notify = false, String? reason}) {
    final existing = _closing;
    if (existing != null) return existing;
    _closed = true;
    return _closing = _release(
      notify: notify,
      reason: reason ?? EndReason.endedByDevice,
    );
  }

  Future<void> _release({required bool notify, required String reason}) async {
    _negotiationTimer?.cancel();
    _negotiationTimer = null;
    _pendingRemoteIce.clear();

    final control = _control;
    final stream = _stream;
    final pc = _pc;
    _control = null;
    _stream = null;
    _pc = null;

    if (pc != null) {
      pc.onIceCandidate = null;
      pc.onConnectionState = null;
    }
    if (control != null) {
      control.onMessage = null;
      await _quietly(control.close);
    }
    if (stream != null) await _disposeStream(stream);
    if (pc != null) await _disposePeerConnection(pc);

    // Never stop the capture service while its start is still in flight (the
    // start is bounded by ScreenCaptureController's own timeout).
    final starting = _captureStarting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }

    final pendingCapture = _displayMediaPending;
    _displayMediaPending = null;
    if (pendingCapture == null) {
      await _capture.stop();
    } else {
      // start() never took over getDisplayMedia's result; the call may still
      // be outstanding (the consent dialog may still be up). If it is granted
      // later, flutter_webrtc calls getMediaProjection on the
      // main thread without a try/catch; with no mediaProjection foreground
      // service running that throws SecurityException and kills the process.
      // So keep this session's hold on the service until the call settles and
      // its stream is released — in the background, so teardown (and revoke)
      // never waits for a dialog nobody may answer.
      _releaseCaptureWhenSettled(pendingCapture);
    }

    if (notify) onClosed?.call(this, reason);
  }

  /// Disposes whatever [pending] produces, then releases this session's hold
  /// on the capture service. The hold is released after
  /// [_pendingCaptureGrace] at the latest, so an unanswered consent dialog
  /// cannot keep the "Remote support active" notification up indefinitely.
  /// A stream that arrives after that is still disposed.
  void _releaseCaptureWhenSettled(Future<MediaStream> pending) {
    final settled = pending.then<void>(_disposeStream, onError: (Object _) {});
    unawaited(
      settled
          .timeout(_pendingCaptureGrace, onTimeout: () {})
          .whenComplete(_capture.stop),
    );
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await _quietly(track.stop);
    }
    await _quietly(stream.dispose);
  }

  Future<void> _disposePeerConnection(RTCPeerConnection pc) async {
    await _quietly(pc.close);
    await _quietly(pc.dispose);
  }

  static Future<void> _quietly(Future<void> Function() step) async {
    try {
      await step().timeout(_releaseStepTimeout);
    } catch (_) {}
  }
}
