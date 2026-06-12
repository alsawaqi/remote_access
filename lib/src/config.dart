/// Build-time configuration. Override per environment with --dart-define, e.g.
///   flutter run --dart-define=API_BASE=http://10.0.2.2:8082 \
///               --dart-define=REVERB_HOST=10.0.2.2 \
///               --dart-define=REVERB_PORT=8084 \
///               --dart-define=REVERB_SCHEME=ws
/// Defaults target the production VPS.
class AppConfig {
  AppConfig._();

  static const String apiBase =
      String.fromEnvironment('API_BASE', defaultValue: 'https://api.mithqal.net');

  static const String reverbHost =
      String.fromEnvironment('REVERB_HOST', defaultValue: 'ws.mithqal.net');

  static const int reverbPort =
      int.fromEnvironment('REVERB_PORT', defaultValue: 443);

  static const String reverbScheme =
      String.fromEnvironment('REVERB_SCHEME', defaultValue: 'wss');

  static bool get reverbUseTls =>
      reverbScheme == 'wss' || reverbScheme == 'https';

  /// Pusher protocol requires a cluster string even for self-hosted Reverb;
  /// it is ignored when [reverbHost] is set.
  static const String reverbCluster = 'mt1';

  static const Duration heartbeatInterval = Duration(seconds: 30);
}
