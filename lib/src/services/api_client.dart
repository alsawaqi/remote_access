import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Every non-2xx response, timeout or network failure from [ApiClient]
/// surfaces as an [ApiException].
///
/// [status] is the HTTP status code, or 0 when no HTTP response was received
/// (timeout / network error). [reason] is the machine-readable `reason` field
/// of the error body, when the API sends one.
class ApiException implements Exception {
  final int status;
  final String message;
  final String? reason;
  ApiException(this.status, this.message, {this.reason});

  /// The device token is no longer valid: remote access was revoked.
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status): $message';
}

/// Thin HTTP client for the device-agent endpoints. Holds the bearer token in
/// memory; persistence is handled by SecureStore.
class ApiClient {
  /// Upper bound for every request, so a stalled network can never hang a
  /// session start/teardown or the heartbeat loop.
  static const Duration requestTimeout = Duration(seconds: 15);

  String? _token;

  void setToken(String? token) => _token = token;

  String? get token => _token;

  Map<String, String> _headers({bool auth = true}) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (auth && _token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _url(String path) => Uri.parse('${AppConfig.apiBase}$path');

  Future<Map<String, dynamic>> _post(
    String path,
    Object body, {
    bool auth = true,
  }) async {
    final http.Response response;
    try {
      response = await http
          .post(_url(path), headers: _headers(auth: auth), body: jsonEncode(body))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw ApiException(
        0,
        'The server did not respond within ${requestTimeout.inSeconds} seconds.',
      );
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Network error: ${e.message}');
    }
    return _decode(response);
  }

  /// Decodes a response. 2xx -> the JSON object body (or `{}` for an empty /
  /// non-JSON body such as 204). Anything else throws [ApiException].
  Map<String, dynamic> _decode(http.Response response) {
    dynamic body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        body = null; // e.g. an HTML error page from a proxy
      }
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (body is Map) return body.cast<String, dynamic>();
      return body == null ? <String, dynamic>{} : <String, dynamic>{'data': body};
    }

    final message = (body is Map && body['message'] is String)
        ? body['message'] as String
        : 'Request failed ($status)';
    final reason =
        (body is Map && body['reason'] is String) ? body['reason'] as String : null;
    throw ApiException(status, message, reason: reason);
  }

  Future<Map<String, dynamic>> enroll({
    required String code,
    String? appVersion,
    String? osVersion,
    int? width,
    int? height,
  }) {
    return _post(
      '/api/device/enroll',
      {
        'code': code,
        'app_version': ?appVersion,
        'os_version': ?osVersion,
        'screen_width': ?width,
        'screen_height': ?height,
      },
      auth: false,
    );
  }

  /// Presence + capabilities. `active_session_id` is ALWAYS sent (null when no
  /// session is running) so the API only refreshes the liveness of the session
  /// this device is actually serving.
  Future<void> heartbeat(
    Map<String, dynamic> capabilities, {
    required int? activeSessionId,
  }) async {
    await _post('/api/device/heartbeat', {
      ...capabilities,
      'active_session_id': activeSessionId,
    });
  }

  /// Reverb private-channel authorization (the Pusher onAuthorizer hook).
  Future<Map<String, dynamic>> broadcastingAuth(
    String channelName,
    String socketId,
  ) {
    return _post(
      '/broadcasting/auth',
      {'socket_id': socketId, 'channel_name': channelName},
    );
  }

  Future<void> postOffer(int sessionId, String sdp) async {
    await _post('/api/device/sessions/$sessionId/offer', {'sdp': sdp});
  }

  Future<void> postIce(int sessionId, Map<String, dynamic> candidate) async {
    await _post('/api/device/sessions/$sessionId/ice', candidate);
  }

  /// Ends the session server-side. [reason] is one of the device end reasons
  /// (e.g. `user_stopped`, `capture_failed`, `negotiation_timeout`); the API
  /// defaults to `ended_by_device` when it is omitted. Idempotent server-side.
  Future<void> endSession(int sessionId, {String? reason}) async {
    await _post('/api/device/sessions/$sessionId/end', {'reason': ?reason});
  }
}
