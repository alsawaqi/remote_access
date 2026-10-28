import 'dart:async';
import 'dart:convert';

import 'package:dart_pusher_channels/dart_pusher_channels.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_client.dart';

typedef EventHandler = void Function(Map<String, dynamic> data);

/// Called when authorizing a private channel against /broadcasting/auth fails.
/// [status] is the HTTP status of the auth endpoint's response, or null when
/// no HTTP response was received (timeout, network error, ...).
typedef ChannelAuthErrorHandler = void Function(int? status);

class _ChannelAuthException implements Exception {
  final int? status;
  final String message;
  _ChannelAuthException(this.status, this.message);

  @override
  String toString() => 'ChannelAuthException(${status ?? '-'}): $message';
}

/// Private-channel authorizer. Same wire format as the package's
/// EndpointAuthorizableChannelTokenAuthorizationDelegate.forPrivateChannel
/// (form-encoded POST of socket_id + channel_name to /broadcasting/auth with
/// the device bearer token), plus the agent-wide request timeout and the HTTP
/// status surfaced on failure.
class _DeviceChannelAuthDelegate
    implements
        EndpointAuthorizableChannelAuthorizationDelegate<
            PrivateChannelAuthorizationData> {
  _DeviceChannelAuthDelegate({required this.token, required this.onAuthFailed});

  final String token;

  @override
  final EndpointAuthFailedCallback? onAuthFailed;

  @override
  Future<PrivateChannelAuthorizationData> authorizationData(
    String socketId,
    String channelName,
  ) async {
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('${AppConfig.apiBase}/broadcasting/auth'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: {'socket_id': socketId, 'channel_name': channelName},
      ).timeout(ApiClient.requestTimeout);
    } on TimeoutException {
      throw _ChannelAuthException(null, 'channel authorization timed out');
    }

    if (response.statusCode != 200) {
      throw _ChannelAuthException(response.statusCode, 'channel authorization refused');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw _ChannelAuthException(response.statusCode, 'invalid authorization response');
    }
    final auth = decoded is Map ? decoded['auth'] : null;
    if (auth is! String || auth.isEmpty) {
      throw _ChannelAuthException(response.statusCode, 'authorization response has no auth key');
    }
    return PrivateChannelAuthorizationData(authKey: auth);
  }
}

/// Connects to self-hosted Laravel Reverb over the Pusher protocol and binds
/// private-channel events. Private channels are authorized against the API's
/// /broadcasting/auth with the device bearer token.
class SignalingService {
  final ApiClient api;
  final String reverbKey;
  final void Function(bool connected)? onConnectionChange;

  SignalingService({
    required this.api,
    required this.reverbKey,
    this.onConnectionChange,
  });

  PusherChannelsClient? _client;
  StreamSubscription<void>? _connectionSub;
  final Map<String, Channel> _channels = {};
  final Map<String, List<StreamSubscription<ChannelReadEvent>>> _eventSubs = {};

  Future<void> connect() async {
    final options = PusherChannelsOptions.fromHost(
      scheme: AppConfig.reverbScheme,
      host: AppConfig.reverbHost,
      key: reverbKey,
      port: AppConfig.reverbPort,
    );

    final client = PusherChannelsClient.websocket(
      options: options,
      connectionErrorHandler: (exception, trace, refresh) {
        onConnectionChange?.call(false);
        refresh();
      },
    );
    _client = client;

    _connectionSub = client.onConnectionEstablished.listen((_) {
      onConnectionChange?.call(true);
      // Re-subscribe surviving channels after a (re)connect.
      for (final channel in _channels.values) {
        channel.subscribeIfNotUnsubscribed();
      }
    });

    await client.connect();
  }

  /// Subscribe to a private channel and bind one handler per event name.
  ///
  /// [onAuthError] fires when the channel's authorization request fails, e.g.
  /// with HTTP 401 once the device token has been revoked (on the first
  /// subscribe or on any re-subscribe after a reconnect).
  void subscribePrivate(
    String name,
    Map<String, EventHandler> handlers, {
    ChannelAuthErrorHandler? onAuthError,
  }) {
    final client = _client;
    if (client == null) return;

    final channel = client.privateChannel(
      name,
      authorizationDelegate: _DeviceChannelAuthDelegate(
        token: api.token ?? '',
        onAuthFailed: (exception, trace) {
          final status = exception is _ChannelAuthException ? exception.status : null;
          if (kDebugMode) {
            debugPrint('[signaling] auth failed for "$name" (status=$status)');
          }
          onAuthError?.call(status);
        },
      ),
    );

    final subs = <StreamSubscription<ChannelReadEvent>>[];
    handlers.forEach((eventName, handler) {
      subs.add(channel.bind(eventName).listen((event) {
        if (kDebugMode) {
          debugPrint('[signaling] recv "$eventName" type=${event.data.runtimeType} data=${event.data}');
        }
        // A malformed payload must never surface as an unhandled stream error.
        try {
          handler(_decode(event.data));
        } catch (error) {
          debugPrint('[signaling] handler for "$eventName" failed: $error');
        }
      }));
    });

    _channels[name] = channel;
    _eventSubs[name] = subs;
    channel.subscribe();
  }

  Future<void> unsubscribe(String name) async {
    final subs = _eventSubs.remove(name) ??
        const <StreamSubscription<ChannelReadEvent>>[];
    for (final sub in subs) {
      await sub.cancel();
    }
    _channels.remove(name)?.unsubscribe();
  }

  Map<String, dynamic> _decode(dynamic data) {
    dynamic decoded = data;

    // The payload may arrive as a JSON string (standard Pusher) — parse it.
    if (decoded is String) {
      if (decoded.isEmpty) return <String, dynamic>{};
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    if (decoded is! Map) return <String, dynamic>{};
    var map = decoded.cast<String, dynamic>();

    // Some deliveries hand over the full Pusher frame {event, channel, data}
    // instead of just the inner payload — unwrap the nested `data` in that case.
    final looksLikePayload = map.containsKey('sdp') ||
        map.containsKey('candidate') ||
        map.containsKey('session_id') ||
        map.containsKey('device_id');
    if (!looksLikePayload && map['data'] != null) {
      var inner = map['data'];
      if (inner is String) {
        try {
          inner = jsonDecode(inner);
        } catch (_) {/* leave as-is */}
      }
      if (inner is Map) {
        map = inner.cast<String, dynamic>();
      }
    }

    return map;
  }

  Future<void> disconnect() async {
    for (final subs in _eventSubs.values) {
      for (final sub in subs) {
        await sub.cancel();
      }
    }
    _eventSubs.clear();
    _channels.clear();
    await _connectionSub?.cancel();
    _connectionSub = null;
    _client?.dispose();
    _client = null;
  }
}
