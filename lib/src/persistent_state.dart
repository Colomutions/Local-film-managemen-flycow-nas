import 'dart:convert';
import 'dart:io';

class NasDeviceToken {
  const NasDeviceToken({
    required this.deviceId,
    required this.scope,
    required this.expiresAt,
  });

  final String deviceId;
  final String scope;
  final DateTime expiresAt;

  Map<String, Object> toJson() => {
        'deviceId': deviceId,
        'scope': scope,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static NasDeviceToken? fromJson(Object? value) {
    if (value is! Map) return null;
    final deviceId = value['deviceId'];
    final scope = value['scope'];
    final expiresAt = DateTime.tryParse(value['expiresAt'] as String? ?? '');
    if (deviceId is! String ||
        deviceId.isEmpty ||
        (scope != 'viewer' && scope != 'admin') ||
        expiresAt == null) {
      return null;
    }
    return NasDeviceToken(
      deviceId: deviceId,
      scope: scope,
      expiresAt: expiresAt.toUtc(),
    );
  }
}

class NasPersistentState {
  NasPersistentState({
    required this.serverId,
    Map<String, NasDeviceToken>? tokens,
    NasAiSettings? aiSettings,
  })  : tokens = tokens ?? <String, NasDeviceToken>{},
        aiSettings = aiSettings ?? const NasAiSettings();

  final String serverId;
  final Map<String, NasDeviceToken> tokens;
  final NasAiSettings aiSettings;
}

/// 仅在 NAS 持久化的 AI 配置；API 读取时永远不会回传密钥明文。
class NasAiSettings {
  const NasAiSettings({
    this.provider,
    this.endpoint,
    this.model,
    this.apiKey,
  });

  final String? provider;
  final String? endpoint;
  final String? model;
  final String? apiKey;

  bool get isConfigured =>
      provider != null && endpoint != null && model != null && apiKey != null;

  Map<String, Object?> toJson() => {
        'provider': provider,
        'endpoint': endpoint,
        'model': model,
        'apiKey': apiKey,
      };

  static NasAiSettings fromJson(Object? value) {
    if (value is! Map) return const NasAiSettings();
    String? read(String key) {
      final raw = value[key];
      return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    }

    return NasAiSettings(
      provider: read('provider'),
      endpoint: read('endpoint'),
      model: read('model'),
      apiKey: read('apiKey'),
    );
  }
}

class NasPersistentStateStore {
  NasPersistentStateStore(this.dataDir);

  final String dataDir;
  Future<void> _saveTail = Future<void>.value();

  File get _file => File(
      '$dataDir${Platform.pathSeparator}state${Platform.pathSeparator}server.json');

  Future<NasPersistentState?> load() async {
    final file = _file;
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['serverId'] is! String ||
        (decoded['serverId'] as String).isEmpty) {
      throw StateError('Invalid NAS persistent state.');
    }
    final tokens = <String, NasDeviceToken>{};
    final rawTokens = decoded['tokens'];
    if (rawTokens is Map) {
      rawTokens.forEach((key, value) {
        final token = NasDeviceToken.fromJson(value);
        if (key is String && token != null) tokens[key] = token;
      });
    }
    return NasPersistentState(
      serverId: decoded['serverId'] as String,
      tokens: tokens,
      aiSettings: NasAiSettings.fromJson(decoded['aiSettings']),
    );
  }

  Future<void> save(NasPersistentState state) {
    // Capture the state synchronously, then serialize file replacement. Multiple
    // devices can finish pairing at once; sharing one fixed `.tmp` path without
    // this queue lets concurrent renames fail and incorrectly return 500.
    final payload = jsonEncode({
      'serverId': state.serverId,
      'tokens': state.tokens.map((key, value) => MapEntry(key, value.toJson())),
      'aiSettings': state.aiSettings.toJson(),
    });
    final write = _saveTail.then<void>(
      (_) => _writePayload(payload),
      onError: (_, __) => _writePayload(payload),
    );
    _saveTail = write;
    return write;
  }

  Future<void> _writePayload(String payload) async {
    final file = _file;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }
}
