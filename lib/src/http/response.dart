import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../library/taxonomy_transfer.dart';

Future<Map<String, dynamic>?> readApiJsonBody(HttpRequest request,
    {int? maximumBytes}) async {
  try {
    final String text;
    if (maximumBytes == null) {
      text = await utf8.decoder.bind(request).join();
    } else {
      var length = 0;
      final bytes = <int>[];
      await for (final chunk in request) {
        length += chunk.length;
        if (length <= maximumBytes) bytes.addAll(chunk);
      }
      if (length > maximumBytes) return null;
      text = utf8.decode(bytes);
    }
    final value = jsonDecode(text);
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
    'video_poster_busy': 'NAS 正在生成另一个动态海报，请稍后重试。',
    'video_poster_failed': '无法生成预览。请检查 NAS 的 FFmpeg，或换一段较短的画面。',
    'collection_selection_changed': '参与影片的资料或分集已变化，请重新预览。',
    'collection_category_mismatch': '只能合并同一分类的影片。',
    'collection_episode_limit': '每部影片至少需要一个分集，合计不能超过 500 个分集。',
    'collection_playback_active': '参与影片正在播放或预览，请先停止播放。',
    'collection_task_active': '参与影片有未完成的采集或资料任务，请待任务结束。',
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
    'source_delete_disabled': '此 NAS 尚未开启源文件删除。',
    'source_delete_empty': '这部影片没有关联源文件，可使用仅移除索引。',
    'source_delete_unavailable': '来源盘离线、分集缺失或路径含链接。请检查媒体盘并重新扫描。',
    'source_delete_shared_video': '另一条记录也引用了同一源视频，请先核对片库归属。',
    'source_delete_changed': '文件或分集归属已变化。请重新预览，若仍提示变化请先扫描对应分类。',
    'source_delete_io': '文件操作失败，索引已保留。请检查媒体盘和目录写权限，重新预览后可继续。',
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
