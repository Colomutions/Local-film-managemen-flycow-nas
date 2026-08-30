class NasConfig {
  static const fixedPort = 48291;
  const NasConfig({
    required this.bindHost,
    required this.port,
    required this.serverName,
    required this.advertiseUrl,
    required this.pairingCode,
    required this.fixtureMediaRelativePath,
    required this.mediaRootName,
    required this.scanOnStart,
    this.managedCategoryLibrary = false,
    required this.dataDir,
    required this.mediaDir,
    required this.timezone,
    this.logLevel = 'INFO',
    this.diagnosticMode = false,
    this.logMaxBytes = 2 * 1024 * 1024,
    this.logRetentionFiles = 3,
  });

  factory NasConfig.fromEnvironment(Map<String, String> environment) {
    final port = int.tryParse(environment['MUJING_PORT'] ?? '') ?? fixedPort;
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'MUJING_PORT', 'must be 0-65535');
    }

    return NasConfig(
      bindHost: _value(environment, 'MUJING_BIND_HOST', '0.0.0.0'),
      port: port,
      serverName: _value(environment, 'MUJING_SERVER_NAME', '幕境 NAS'),
      advertiseUrl: _advertiseUrl(environment),
      pairingCode: _optionalValue(environment, 'MUJING_PAIRING_CODE'),
      fixtureMediaRelativePath: _relativeMediaPath(environment),
      mediaRootName: _value(environment, 'MUJING_MEDIA_ROOT_NAME', '媒体库'),
      // Category-bound scanning replaces the former process-start scan for
      // deployments.  The constructor flag remains for isolated legacy tests.
      scanOnStart: false,
      managedCategoryLibrary: true,
      dataDir: _value(environment, 'MUJING_DATA_DIR', '/data'),
      mediaDir: _value(environment, 'MUJING_MEDIA_DIR', '/media'),
      timezone: _value(environment, 'MUJING_TIMEZONE', 'Asia/Shanghai'),
      logLevel: _logLevel(environment),
      diagnosticMode: _boolValue(environment, 'MUJING_DIAGNOSTIC_MODE', false),
      logMaxBytes: _positiveInt(environment, 'MUJING_LOG_MAX_BYTES', 2 * 1024 * 1024),
      logRetentionFiles: _positiveInt(environment, 'MUJING_LOG_RETENTION_FILES', 3),
    );
  }

  final String bindHost;
  final int port;
  final String serverName;
  final String? advertiseUrl;
  final String? pairingCode;
  final String? fixtureMediaRelativePath;
  final String mediaRootName;
  final bool scanOnStart;
  final bool managedCategoryLibrary;
  final String dataDir;
  final String mediaDir;
  final String timezone;
  final String logLevel;
  final bool diagnosticMode;
  final int logMaxBytes;
  final int logRetentionFiles;

  static String _logLevel(Map<String, String> environment) {
    final value = _value(environment, 'MUJING_LOG_LEVEL', 'INFO').toUpperCase();
    if (!const {'DEBUG', 'INFO', 'WARN', 'ERROR'}.contains(value)) {
      throw ArgumentError.value(value, 'MUJING_LOG_LEVEL', 'must be DEBUG, INFO, WARN, or ERROR');
    }
    return value;
  }

  static int _positiveInt(Map<String, String> environment, String key, int defaultValue) {
    final value = _optionalValue(environment, key);
    final parsed = value == null ? defaultValue : int.tryParse(value);
    if (parsed == null || parsed < 1) {
      throw ArgumentError.value(value, key, 'must be a positive integer');
    }
    return parsed;
  }

  static String _value(
    Map<String, String> environment,
    String key,
    String defaultValue,
  ) => _optionalValue(environment, key) ?? defaultValue;

  static String? _optionalValue(Map<String, String> environment, String key) {
    final value = environment[key]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _advertiseUrl(Map<String, String> environment) {
    final value = _optionalValue(environment, 'MUJING_ADVERTISE_URL');
    if (value == null) return null;

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError.value(
        value,
        'MUJING_ADVERTISE_URL',
        'must be an absolute http(s) URL without query or fragment',
      );
    }
    if (uri.hasPort && uri.port != fixedPort) {
      throw ArgumentError.value(
        value,
        'MUJING_ADVERTISE_URL',
        'must use the fixed NAS port 48291',
      );
    }

    final hostParts = uri.host.split('.');
    if (hostParts.length == 4 &&
        hostParts.first == '172' &&
        (int.tryParse(hostParts[1]) ?? -1) >= 16 &&
        (int.tryParse(hostParts[1]) ?? -1) <= 31) {
      throw ArgumentError.value(
        value,
        'MUJING_ADVERTISE_URL',
        'must be the NAS host URL, not a Docker 172.16.0.0/12 address',
      );
    }
    return uri.replace(path: uri.path == '/' ? '' : uri.path).toString();
  }

  static String? _relativeMediaPath(Map<String, String> environment) {
    final value = _optionalValue(environment, 'MUJING_FIXTURE_MEDIA_RELATIVE_PATH');
    if (value == null) return null;
    final normalized = value.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.split('/').any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
      throw ArgumentError.value(
        value,
        'MUJING_FIXTURE_MEDIA_RELATIVE_PATH',
        'must be a non-empty path relative to MUJING_MEDIA_DIR',
      );
    }
    return normalized;
  }

  static bool _boolValue(
    Map<String, String> environment,
    String key,
    bool defaultValue,
  ) {
    final value = _optionalValue(environment, key);
    if (value == null) return defaultValue;
    if (value == 'true') return true;
    if (value == 'false') return false;
    throw ArgumentError.value(value, key, 'must be true or false');
  }
}
