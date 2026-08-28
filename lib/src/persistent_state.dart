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
  NasPersistentState({required this.serverId, Map<String, NasDeviceToken>? tokens})
      : tokens = tokens ?? <String, NasDeviceToken>{};

  final String serverId;
  final Map<String, NasDeviceToken> tokens;
}

class NasPersistentStateStore {
  NasPersistentStateStore(this.dataDir);

  final String dataDir;
  Future<void> _saveTail = Future<void>.value();

  File get _file => File('$dataDir${Platform.pathSeparator}state${Platform.pathSeparator}server.json');

  Future<NasPersistentState?> load() async {
    final file = _file;
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['serverId'] is! String || (decoded['serverId'] as String).isEmpty) {
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
    return NasPersistentState(serverId: decoded['serverId'] as String, tokens: tokens);
  }

  Future<void> save(NasPersistentState state) {
    // Capture the state synchronously, then serialize file replacement. Multiple
    // devices can finish pairing at once; sharing one fixed `.tmp` path without
    // this queue lets concurrent renames fail and incorrectly return 500.
    final payload = jsonEncode({
      'serverId': state.serverId,
      'tokens': state.tokens.map((key, value) => MapEntry(key, value.toJson())),
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
