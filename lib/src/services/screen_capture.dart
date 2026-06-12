import 'package:flutter/services.dart';

/// Controls the native foreground service that must be running for Android
/// MediaProjection screen capture (Android 10+/14 requirement). Implemented
/// natively in MainActivity + ScreenCaptureService.
class ScreenCaptureController {
  static const MethodChannel _channel = MethodChannel('remote_access/capture');

  /// Starts the mediaProjection foreground service and completes only once the
  /// service has actually entered the foreground. Throws (PlatformException /
  /// TimeoutException) if it could not — e.g. on Android 14+ when the
  /// `project_media` app-op has not been granted — so the caller can abort the
  /// session cleanly instead of proceeding into a capture that will fail.
  Future<void> start() async {
    await _channel.invokeMethod('start').timeout(const Duration(seconds: 8));
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
