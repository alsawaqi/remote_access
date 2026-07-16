import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../input/input_dispatcher.dart';
import 'api_client.dart';
import 'screen_capture.dart';

/// One live WebRTC session. The DEVICE is the offerer: it captures the screen
/// (MediaProjection via getDisplayMedia), creates the control DataChannel, and
/// sends the offer. The admin answers.
class RemoteSession {
  final int sessionId;
  final ApiClient api;
  final List<dynamic> iceServers;
  final bool controlEnabled;
  final InputDispatcher input;
  final void Function()? onClosed;

  RemoteSession({
    required this.sessionId,
    required this.api,
    required this.iceServers,
    required this.controlEnabled,
    required this.input,
    this.onClosed,
  });

  final ScreenCaptureController _capture = ScreenCaptureController();
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  RTCDataChannel? _control;
  bool _closed = false;

  Future<void> start() async {
    _pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) return;
      api
          .postIce(sessionId, {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          })
          .catchError((_) {});
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        close(notify: true);
      }
    };

    // Android 10+/14 require a running mediaProjection foreground service
    // BEFORE the projection is acquired (flutter_webrtc does not start one).
    // If it can't enter the foreground (e.g. Android 14+ kiosk without the
    // project_media app-op), abort now with an actionable message rather than
    // letting getDisplayMedia fail or the native service crash the app.
    try {
      await _capture.start();
    } catch (e) {
      throw Exception(
        'Screen capture could not start: $e. On Android 14+ the device needs '
        'the screen-capture permission — accept the on-screen prompt, or '
        'pre-grant it via MDM/Device-Owner '
        '(appops set com.example.remote_access PROJECT_MEDIA allow).',
      );
    }

    // Screen capture — triggers the Android MediaProjection consent dialog.
    _stream = await navigator.mediaDevices.getDisplayMedia({
      'video': true,
      'audio': false,
    });
    for (final track in _stream!.getTracks()) {
      await _pc!.addTrack(track, _stream!);
    }

    // Control channel (admin -> device). The offerer creates it.
    input.enabled = controlEnabled;
    _control = await _pc!.createDataChannel('control', RTCDataChannelInit());
    _control!.onMessage = (RTCDataChannelMessage message) {
      input.handle(message.text);
    };

    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    await api.postOffer(sessionId, offer.sdp ?? '');
  }

  Future<void> onAnswer(String sdp) async {
    await _pc?.setRemoteDescription(
      RTCSessionDescription(_sanitizeSdp(sdp), 'answer'),
    );
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

  Future<void> onRemoteIce(Map<String, dynamic> candidate) async {
    if (candidate['candidate'] == null) return;
    await _pc?.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        (candidate['sdpMLineIndex'] as num?)?.toInt(),
      ),
    );
  }

  Future<void> close({bool notify = false}) async {
    if (_closed) return;
    _closed = true;

    try {
      await _control?.close();
    } catch (_) {}
    try {
      for (final track in _stream?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
    } catch (_) {}
    try {
      await _stream?.dispose();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}

    _control = null;
    _stream = null;
    _pc = null;
    await _capture.stop();

    if (notify) onClosed?.call();
  }
}
