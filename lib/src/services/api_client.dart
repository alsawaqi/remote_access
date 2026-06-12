import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);

  @override
  String toString() => 'ApiException($status): $message';
}

/// Thin HTTP client for the device-agent endpoints. Holds the bearer token in
/// memory; persistence is handled by SecureStore.
class ApiClient {
  String? _token;

  void setToken(String? token) => _token = token;

  String? get token => _token;

  Map<String, String> _headers({bool auth = true}) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (auth && _token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _url(String path) => Uri.parse('${AppConfig.apiBase}$path');

  Map<String, dynamic> _decode(http.Response response) {
    final dynamic body =
        response.body.isNotEmpty ? jsonDecode(response.body) : <String, dynamic>{};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body is Map ? body.cast<String, dynamic>() : {'data': body};
    }

    final message = (body is Map && body['message'] is String)
        ? body['message'] as String
        : 'Request failed (${response.statusCode})';
    throw ApiException(response.statusCode, message);
  }

  Future<Map<String, dynamic>> enroll({
    required String code,
    String? appVersion,
    String? osVersion,
    int? width,
    int? height,
  }) async {
    final response = await http.post(
      _url('/api/device/enroll'),
      headers: _headers(auth: false),
      body: jsonEncode({
        'code': code,
        'app_version': ?appVersion,
        'os_version': ?osVersion,
        'screen_width': ?width,
        'screen_height': ?height,
      }),
    );
    return _decode(response);
  }

  Future<void> heartbeat(Map<String, dynamic> capabilities) async {
    await http.post(
      _url('/api/device/heartbeat'),
      headers: _headers(),
      body: jsonEncode(capabilities),
    );
  }

  /// Reverb private-channel authorization (the Pusher onAuthorizer hook).
  Future<Map<String, dynamic>> broadcastingAuth(
    String channelName,
    String socketId,
  ) async {
    final response = await http.post(
      _url('/broadcasting/auth'),
      headers: _headers(),
      body: jsonEncode({'socket_id': socketId, 'channel_name': channelName}),
    );
    return _decode(response);
  }

  Future<void> postOffer(int sessionId, String sdp) async {
    await http.post(
      _url('/api/device/sessions/$sessionId/offer'),
      headers: _headers(),
      body: jsonEncode({'sdp': sdp}),
    );
  }

  Future<void> postIce(int sessionId, Map<String, dynamic> candidate) async {
    await http.post(
      _url('/api/device/sessions/$sessionId/ice'),
      headers: _headers(),
      body: jsonEncode(candidate),
    );
  }

  Future<void> endSession(int sessionId) async {
    await http.post(
      _url('/api/device/sessions/$sessionId/end'),
      headers: _headers(),
      body: jsonEncode(<String, dynamic>{}),
    );
  }
}
