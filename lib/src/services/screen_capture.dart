import 'package:flutter/services.dart';

/// Controls the native foreground service that must be running for Android
/// MediaProjection screen capture (Android 10+/14 requirement). Implemented
/// natively in MainActivity + ScreenCaptureService.
///
/// The native service is process-wide, but every session owns its own
/// controller. Each controller holds the service from [start] until its
/// [stop], and the service is only stopped once NO controller holds it any
/// more. A late [stop] from a previous session (slow teardown, or a projection
/// request that was still pending) therefore can never stop the service under
/// a newer session's capture.
class ScreenCaptureController {
  static const MethodChannel _channel = MethodChannel('remote_access/capture');

  /// Controllers currently holding the service (identity semantics).
  static final Set<ScreenCaptureController> _holders = <ScreenCaptureController>{};

  /// Starts the mediaProjection foreground service and completes only once the
  /// service has actually entered the foreground. Throws (PlatformException /
  /// TimeoutException) if it could not — e.g. on Android 14+ when the
  /// `project_media` app-op has not been granted — so the caller can abort the
  /// session cleanly instead of proceeding into a capture that will fail.
  ///
  /// The hold is taken even if this throws; the caller must still call [stop].
  Future<void> start() async {
    _holders.add(this);
    await _channel.invokeMethod('start').timeout(const Duration(seconds: 8));
  }

  /// Releases this controller's hold and stops the service if no other
  /// controller still holds it. A no-op for a controller that holds nothing.
  Future<void> stop() async {
    if (!_holders.remove(this) || _holders.isNotEmpty) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
