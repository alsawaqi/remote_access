import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Forwards control messages (from the admin's WebRTC DataChannel) to the
/// native AccessibilityService.
///
/// The native handler is implemented in PHASE 5. Until then `invokeMethod`
/// throws MissingPluginException, which we swallow and log — so Phase 4 can be
/// built and the screen viewed without input working yet.
///
/// Message shapes (coordinates normalized 0..1 of the device screen):
///   {t:'tap', x, y}
///   {t:'longpress', x, y, ms}
///   {t:'swipe', x1, y1, x2, y2, ms}
///   {t:'key', k:'back'|'home'|'recents'}
///   {t:'text', v}
class InputDispatcher {
  static const MethodChannel _channel = MethodChannel('remote_access/input');

  /// Whether input is permitted for the current session (admin toggle).
  bool enabled = true;

  Future<void> handle(String raw) async {
    if (!enabled) return;

    Map<String, dynamic> message;
    try {
      message = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }

    final type = message['t'];
    try {
      switch (type) {
        case 'tap':
          await _channel.invokeMethod('tap', {'x': message['x'], 'y': message['y']});
          break;
        case 'longpress':
          await _channel.invokeMethod('longpress',
              {'x': message['x'], 'y': message['y'], 'ms': message['ms']});
          break;
        case 'swipe':
          await _channel.invokeMethod('swipe', {
            'x1': message['x1'],
            'y1': message['y1'],
            'x2': message['x2'],
            'y2': message['y2'],
            'ms': message['ms'],
          });
          break;
        case 'key':
          await _channel.invokeMethod('key', {'k': message['k']});
          break;
        case 'text':
          await _channel.invokeMethod('text', {'v': message['v']});
          break;
        default:
          debugPrint('[input] unknown control message: $type');
      }
    } on MissingPluginException {
      debugPrint('[input] native input service unavailable');
    } catch (error) {
      debugPrint('[input] dispatch error: $error');
    }
  }

  /// Whether the native AccessibilityService is currently enabled.
  Future<bool> isEnabled() async {
    try {
      return (await _channel.invokeMethod<bool>('isEnabled')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system Accessibility settings so a technician can enable it.
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (_) {}
  }
}
