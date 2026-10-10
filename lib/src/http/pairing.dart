import 'dart:async';
import 'dart:io';

import '../auth.dart';
import '../config.dart';
import '../persistent_state.dart';

import 'response.dart';

/// Pairing sessions and device-token authentication.
class NasPairingHttpApi {
  NasPairingHttpApi(this.config, this.state, this._persistState);
  final NasConfig config;
  final NasPersistentState? Function() state;
  NasPersistentState? get _state => state();
  final Future<void> Function() _persistState;
  void clear() => _pairingSessions.clear();

  final Map<String, _PairingSession> _pairingSessions = {};

  Future<void> createPairingSession(HttpRequest request) async {
    if (config.pairingCode == null) {
      return writeApiError(
          request, HttpStatus.serviceUnavailable, 'pairing_not_configured');
    }
    final body = await readApiJsonBody(request);
    if (body == null || body['serverId'] != _state!.serverId) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final requestedScope = body['requestedScope'] ?? 'viewer';
    if (requestedScope != 'viewer' && requestedScope != 'admin') {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final rawPlatform = body['platform'];
    final platform = rawPlatform is String &&
            const {'windows', 'android'}.contains(rawPlatform)
        ? rawPlatform
        : 'unknown';
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final sessionId = newUuidV4();
    _pairingSessions[sessionId] = _PairingSession(
      scope: requestedScope as String,
      platform: platform,
      expiresAt: expiresAt,
    );
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'pairingSessionId': sessionId,
        'expiresAt': expiresAt.toIso8601String(),
      },
    });
  }

  Future<void> confirmPairing(HttpRequest request) async {
    final sessionId = request.uri.pathSegments[4];
    final session = _pairingSessions.remove(sessionId);
    final body = await readApiJsonBody(request);
    if (session == null ||
        session.expiresAt.isBefore(DateTime.now().toUtc()) ||
        body == null ||
        !constantTimeEquals(body['pairingPassword'] as String? ?? '',
            config.pairingCode ?? '')) {
      return writeApiError(request, HttpStatus.unauthorized, 'pairing_failed');
    }
    final token = newOpaqueSecret();
    final deviceId = newUuidV4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 365));
    _state!.tokens[sha256Hex(token)] = NasDeviceToken(
      deviceId: deviceId,
      scope: session.scope,
      expiresAt: expiresAt,
      platform: session.platform,
    );
    await _persistState();
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'deviceId': deviceId,
        'accessToken': token,
        'expiresAt': expiresAt.toIso8601String(),
        'scope': session.scope,
        'platform': session.platform,
      },
    });
  }

  String? authenticatedTokenHash(HttpRequest request) {
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader);
    if (authorization == null || !authorization.startsWith('Bearer '))
      return null;
    final token = authorization.substring('Bearer '.length).trim();
    if (token.isEmpty) return null;
    final tokenHash = sha256Hex(token);
    final device = _state!.tokens[tokenHash];
    return device != null && device.expiresAt.isAfter(DateTime.now().toUtc())
        ? tokenHash
        : null;
  }
}

class _PairingSession {
  const _PairingSession({
    required this.scope,
    required this.platform,
    required this.expiresAt,
  });

  final String scope;
  final String platform;
  final DateTime expiresAt;
}
