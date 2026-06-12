import 'dart:async';
import 'dart:convert';

import 'package:dart_pusher_channels/dart_pusher_channels.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import 'api_client.dart';

typedef EventHandler = void Function(Map<String, dynamic> data);

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
  void subscribePrivate(String name, Map<String, EventHandler> handlers) {
    final client = _client;
    if (client == null) return;

    final channel = client.privateChannel(
      name,
      authorizationDelegate:
          EndpointAuthorizableChannelTokenAuthorizationDelegate.forPrivateChannel(
        authorizationEndpoint: Uri.parse('${AppConfig.apiBase}/broadcasting/auth'),
        headers: {
          'Authorization': 'Bearer ${api.token ?? ''}',
          'Accept': 'application/json',
        },
      ),
    );

    final subs = <StreamSubscription<ChannelReadEvent>>[];
    handlers.forEach((eventName, handler) {
      subs.add(channel.bind(eventName).listen((event) {
        if (kDebugMode) {
          debugPrint('[signaling] recv "$eventName" type=${event.data.runtimeType} data=${event.data}');
        }
        handler(_decode(event.data));
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
        map.containsKey('session_id');
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
