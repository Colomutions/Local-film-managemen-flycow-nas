import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../library/taxonomy_transfer.dart';

Future<Map<String, dynamic>?> readApiJsonBody(HttpRequest request) async {
  try {
    final value = jsonDecode(await utf8.decoder.bind(request).join());
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  } on FormatException {
    return null;
  }
}

Future<void> writeTaxonomyResult(
  HttpRequest request,
  NasTaxonomyTransferResult result,
) =>
    writeApiJson(
      request.response,
      result.conflicts.isEmpty ? HttpStatus.ok : HttpStatus.conflict,
      {'data': result.toJson()},
    );

Future<void> writeApiError(HttpRequest request, int statusCode, String code) {
  final messages = <String, String>{
    'authentication_required': 'A valid device token is required.',
    'insufficient_scope': 'This device does not have the required scope.',
    'invalid_request': 'The request is invalid.',
    'invalid_taxonomy': 'The taxonomy definition file is invalid.',
    'invalid_profile_package': '资料包格式或内容不合法。',
    'profile_package_failed': '资料包生成失败。',
    'ai_not_configured': 'AI settings have not been configured on this NAS.',
    'ai_task_not_ready': 'The AI task does not have an applicable result yet.',
    'method_not_allowed': 'The HTTP method is not supported for this resource.',
    'pairing_failed': 'Pairing could not be confirmed.',
    'pairing_not_configured': 'Pairing is not configured on this server.',
    'playback_not_ready': 'The playback stream has not started.',
    'resource_not_found': 'Resource not found.',
    'service_unavailable': 'Service is unavailable.',
    'novel_storage_unavailable': 'Novel storage is unavailable.',
    'service_maintenance': 'The NAS database is being restored.',
    'source_rename_disabled':
        'Source rename is disabled until the writable media deployment opt-in is enabled.',
    'invalid_source_name':
        'The requested source name is invalid or changes the file extension.',
    'source_name_conflict': 'A file with the requested name already exists.',
    'source_rename_failed': 'The source file could not be renamed.',
    'source_metadata_update_failed':
        'The source file rename could not be saved to the media database.',
    'collection_merge_conflict':
        'The requested files cannot be merged into this collection.',
    'collection_split_conflict':
        'The requested episodes cannot be split from this collection.',
    'collection_migration_conflict':
        'The migration preview is stale or requires a valid metadata source.',
    'mdcng_batch_running':
        'A category MDCNG import is running; wait for it to finish.',
    'mdcng_no_failed_items':
        'The category MDCNG import has no failed items to retry.',
    'scan_running': 'A media scan is running; wait for it to finish.',
    'mdcng_sidecar_not_found':
        'No MDCNG NFO matching the video file name was found next to the video.',
    'invalid_mdcng_sidecar':
        'The MDCNG NFO sidecar or its local artwork references are invalid.',
    'invalid_mdcng_selection':
        'The requested MDCNG fields are unavailable or invalid for this preview.',
    'mdcng_preview_stale':
        'The MDCNG NFO changed after preview; request a new preview before applying.',
    'mdcng_overwrite_confirmation_required':
        'Replacing an existing metadata value requires explicit confirmation.',
    'mdcng_actor_resolution_required':
        'One or more MDCNG actors require an existing exact actor match.',
    'mdcng_tag_resolution_required':
        'One or more MDCNG tags require an existing exact taxonomy tag match.',
    'mdcng_poster_overwrite_not_supported':
        'Replacing an existing poster is not supported by the first MDCNG apply flow.',
    'mdcng_import_failed': 'The confirmed MDCNG metadata could not be applied.',
    'mdcng_actor_source_not_configured':
        'MDCNG actor source is not configured for this NAS service.',
    'source_unavailable':
        'The configured MDCNG actor data directory is unavailable.',
    'source_incomplete':
        'The MDCNG actor data directory is missing required database files.',
    'source_unreadable':
        'The MDCNG task database cannot be read safely right now.',
    'profile_database_unreadable':
        'The MDCNG actress profile database cannot be read.',
    'mdcng_actor_source_unreadable':
        'The MDCNG actor source could not be read.',
    'mdcng_actor_preview_stale':
        'MDCNG actor data changed after preview; reload it before applying.',
    'mdcng_actor_profile_resolution_required':
        'The MDCNG actor task does not have one unambiguous profile match.',
    'mdcng_actor_target_resolution_required':
        'Choose whether to create a new actor or merge into an existing actor.',
    'invalid_mdcng_actor_selection':
        'One or more selected MDCNG actor fields are unavailable or invalid.',
    'mdcng_actor_overwrite_confirmation_required':
        'Replacing an existing actor field requires explicit confirmation.',
    'invalid_mdcng_actor_image':
        'The selected MDCNG actor image is missing or is not a valid image.',
    'mdcng_actor_import_failed':
        'The confirmed MDCNG actor data could not be imported.',
    'mdcng_actor_deferred':
        'This MDCNG actor is marked not to import. Restore it before importing.',
    'mdcng_actor_already_imported':
        'This MDCNG actor is already imported and cannot be marked not to import.',
  };
  return writeApiJson(request.response, statusCode, {
    'error': {'code': code, 'message': messages[code] ?? 'Request failed.'},
  });
}

Future<void> writeApiJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> payload, {
  bool headOnly = false,
}) async {
  final bytes = utf8.encode(jsonEncode(payload));
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.headers.contentLength = bytes.length;
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  if (!headOnly) {
    response.add(bytes);
  }
  await response.close();
}

Future<void> writeApiBinary(
  HttpResponse response,
  List<int> bytes, {
  required String fileName,
}) async {
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType('application', 'zip');
  response.headers.contentLength = bytes.length;
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  response.headers.set(
    'content-disposition',
    'attachment; filename="$fileName"',
  );
  response.add(bytes);
  await response.close();
}
