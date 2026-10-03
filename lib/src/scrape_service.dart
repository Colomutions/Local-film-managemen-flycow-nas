import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'artwork_service.dart';
import 'auth.dart';
import 'diagnostic_log.dart';
import 'library_database.dart';

class NasScrapeException implements Exception {
  NasScrapeException(this.code, this.message, {this.until = 0});
  final String code, message;
  final int until;
  @override
  String toString() => message;
}

abstract interface class NasScrapeWorker {
  bool get available;
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input);
  void cancel();
  Future<void> close();
}

/// 单一子进程通过管道通信，不开放额外管理端口。
class NasProcessScrapeWorker implements NasScrapeWorker {
  NasProcessScrapeWorker(
      {required this.script, required this.dataDir, this.node = 'node'});
  final String script, dataDir, node;
  Process? _process;
  Future<void>? _starting;
  Completer<void>? _ready;
  Completer<Map<String, dynamic>>? _pending;
  String? _requestId;
  bool _closing = false;
  @override
  bool get available => File(script).existsSync();

  Future<void> _start() async {
    if (_process != null) return;
    if (_starting != null) return _starting;
    final future = _launch();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
  }

  Future<void> _launch() async {
    if (!available)
      throw NasScrapeException('unavailable', '当前 NAS 镜像未包含内置刮削组件');
    _closing = false;
    _ready = Completer<void>();
    final process = await Process.start(node, [script, dataDir],
        environment: {'APP_CHROMIUM_NO_SANDBOX': Platform.isLinux ? '1' : '0'});
    _process = process;
    process.stderr.drain<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final value = jsonDecode(line) as Map<String, dynamic>;
        if (value['ready'] == true) {
          if (!_ready!.isCompleted) _ready!.complete();
          return;
        }
        if (value['id'] != _requestId ||
            _pending == null ||
            _pending!.isCompleted) return;
        if (value['error'] case final Map error) {
          _pending!.completeError(NasScrapeException(
              error['code'] as String? ?? 'worker',
              error['message'] as String? ?? '采集器错误',
              until: (error['until'] as num?)?.toInt() ?? 0));
        } else {
          _pending!.complete(Map<String, dynamic>.from(value['result'] as Map));
        }
      } catch (error) {
        if (_pending != null && !_pending!.isCompleted)
          _pending!.completeError(NasScrapeException('worker', '采集器返回无效数据'));
      }
    }, onError: (Object error) {
      if (_pending != null && !_pending!.isCompleted)
        _pending!.completeError(error);
    });
    unawaited(process.exitCode.then((code) {
      if (identical(_process, process)) _process = null;
      final error = NasScrapeException('worker', '采集进程已退出（$code）');
      if (!_ready!.isCompleted) _ready!.completeError(error);
      if (_pending != null && !_pending!.isCompleted)
        _pending!.completeError(error);
    }));
    try {
      await _ready!.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    await _start();
    if (_closing || _pending != null) throw NasScrapeException('busy', '采集器繁忙');
    final pending = Completer<Map<String, dynamic>>();
    _pending = pending;
    _requestId = newUuidV4();
    try {
      _process!.stdin.writeln(jsonEncode({...input, 'id': _requestId}));
      return await pending.future.timeout(const Duration(hours: 24),
          onTimeout: () {
        _process?.kill();
        throw NasScrapeException('timeout', '采集任务超时');
      });
    } finally {
      _pending = null;
      _requestId = null;
    }
  }

  @override
  void cancel() {
    _process?.stdin.writeln('{"type":"cancel"}');
  }

  @override
  Future<void> close() async {
    _closing = true;
    cancel();
    try {
      await _starting;
    } catch (_) {
      return;
    }
    final process = _process;
    if (process == null) return;
    process.stdin.writeln('{"type":"close"}');
    await process.stdin.flush();
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill();
    }
  }
}

class NasScrapeService {
  NasScrapeService(this.database, this.artwork, this.worker,
      {required this.cacheDir, NasDiagnosticLogger? logger})
      : _logger = logger ?? NasDiagnosticLogger();
  final NasLibraryDatabase database;
  final NasArtworkService artwork;
  final NasScrapeWorker worker;
  final String cacheDir;
  final NasDiagnosticLogger _logger;
  bool _stopping = false;
  Future<void>? _loop;
  Map<String, dynamic>? _active;
  String? _pauseRequested;
  bool get available => worker.available;
  void start() {
    _stopping = false;
    _loop ??= _run();
  }

  Future<void> close() async {
    _stopping = true;
    worker.cancel();
    await worker.close();
    await _loop;
    _loop = null;
  }

  Map<String, dynamic> snapshot({int offset = 0}) => {
        'available': available,
        'source': 'whatsav',
        'castSupplement': true,
        'settings': database.scrapeSettings,
        'activeTaskId': _active?['id'],
        'jobs': database.scrapeJobs(offset: offset),
      };

  Map<String, dynamic> create(Map<String, dynamic> body) {
    if (!available)
      throw NasScrapeException('unavailable', '需要更新包含内置刮削组件的 NAS 镜像');
    final kind = body['kind'];
    if (!['movies', 'actors'].contains(kind)) throw ArgumentError('任务类型无效');
    for (final key in ['refresh', 'movieImages', 'filmography', 'supplementOnly']) {
      if (body[key] != null && body[key] is! bool)
        throw ArgumentError('采集选项无效');
    }
    final supplement = body['supplementOnly'] == true;
    if (supplement && kind != 'movies') throw ArgumentError('补关联仅支持影片');
    final gallery = supplement ? 20 : body['galleryLimit'] ?? 0;
    if (gallery is! int || gallery < 0 || gallery > 20)
      throw ArgumentError('预览图数量须为 0～20');
    final refresh = body['refresh'] == true;
    final options = <String, dynamic>{
      'movieImages': body['movieImages'] != false,
      'galleryLimit': gallery,
      'filmography': body['filmography'] == true,
      if (supplement) 'supplementOnly': true,
    };
    return database.transaction(() {
      late String job;
      if (kind == 'actors') {
        final limit = body['limit'] ?? 1000;
        if (limit is! int || limit < 1 || limit > 10000)
          throw ArgumentError('演员数量须为 1～10000');
        job = database.createScrapeJob('WhatsAV 作品数排名前 $limit 位演员');
        final payload = <String, dynamic>{
          ...options,
          'refreshEntities': refresh,
          'limit': limit,
          'seen': <String>[],
          'url': 'https://whatsav.net/zh/actors?sort=video_count_desc'
        };
        database.enqueueScrapeTask([job], 'ranking', 'ranking:$job', payload,
            refresh: true);
      } else {
        final category = body['categoryId'];
        final rawIds = body['movieIds'];
        if (category != null && category is! String ||
            rawIds != null &&
                (rawIds is! List || rawIds.any((v) => v is! String)))
          throw ArgumentError('影片范围无效');
        if (category != null && rawIds != null)
          throw ArgumentError('请选择一种影片范围');
        final ids = database.scrapeMovieTargets(
            categoryId: category as String?,
            movieIds: rawIds == null ? null : List<String>.from(rawIds));
        if (ids.isEmpty) throw ArgumentError('该范围没有已入库影片，请先扫描影片');
        job = database.createScrapeJob(
            '${rawIds != null ? '选中影片' : category != null ? '分类影片' : '全库影片'}${supplement ? '补全演员关联' : '刮削'}（${ids.length} 部）');
        for (final id in ids) {
          final movie = database.findMovieForAdmin(id)!;
          final prior = database.scrapeMovieProfile(id);
          final needsPoster = options['movieImages'] == true &&
              movie.posterFileName == null &&
              (prior?['artwork'] as Map?)?['poster'] != null;
          database.enqueueScrapeTask(
              [job],
              'movie',
              supplement ? 'supplement:$id' : 'movie:$id:${options['movieImages']}:$gallery',
              {'movieId': id, 'name': movie.title, ...options},
              refresh: refresh || needsPoster || supplement);
        }
      }
      database.retryScrapeJob(job);
      return database.scrapeJob(job)!;
    });
  }

  Future<void> control(String job, String action) async {
    if (database.scrapeJob(job) == null) throw ArgumentError('任务不存在');
    if (action == 'pause') {
      database.pauseScrapeJob(job, true);
      if (_active != null &&
          database.scrapeTaskJobs(_active!['id'] as String).contains(job)) {
        _pauseRequested = _active!['id'] as String;
        worker.cancel();
      }
    } else if (action == 'resume' || action == 'retry') {
      if (action == 'retry')
        database.retryScrapeJob(job);
      else
        database.pauseScrapeJob(job, false);
    } else {
      throw ArgumentError('不支持的任务操作');
    }
  }

  void configure(Map<String, dynamic> body) {
    final min = body['minIntervalSeconds'], max = body['maxIntervalSeconds'];
    if (min is! num ||
        max is! num ||
        !min.isFinite ||
        !max.isFinite ||
        min < 1 ||
        max > 3600 ||
        max < min) throw ArgumentError('请求间隔须为 1～3600 秒，最大值不能小于最小值');
    database.setScrapeSetting('minIntervalSeconds', min);
    database.setScrapeSetting('maxIntervalSeconds', max);
  }

  Future<void> resumeSource() async {
    if (_active != null) throw ArgumentError('请先暂停正在运行的任务');
    await worker.execute({'type': 'resumeSource'});
    database.setScrapeSetting('blockedReason', null);
  }

  Future<void> _run() async {
    while (!_stopping) {
      try {
        final settings = database.scrapeSettings;
        if (!available ||
            settings['blockedReason'] != null ||
            (settings['cooldownUntil'] as num? ?? 0) >
                DateTime.now().millisecondsSinceEpoch) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        final task = database.claimScrapeTask();
        if (task == null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        _active = task;
        _pauseRequested = null;
        await _process(task);
      } catch (error) {
        _logger.event('scraping.write_failed', level: 'ERROR', fields: {
          'component': 'nas.scraping',
          'errorType': error.runtimeType.toString()
        });
        if (_active != null)
          database.finishScrapeTask(_active!['id'] as String, 'failed',
              error: '资料写入失败，请检查 NAS 日志后重试');
      } finally {
        _active = null;
      }
    }
  }

  Future<void> _process(Map<String, dynamic> task) async {
    final id = task['id'] as String, kind = task['kind'] as String;
    final payload = Map<String, dynamic>.from(task['payload'] as Map);
    try {
      if (kind == 'movie') {
        payload['code'] =
            database.scrapeMovieCode(payload['movieId'] as String);
        if (payload['supplementOnly'] == true) {
          payload['movieImages'] = await _needsSupplementGallery(payload['movieId'] as String);
          payload['galleryOnly'] = true;
        }
      }
      final result = await worker.execute({
        'type': kind,
        for (final key in [
          'code',
          'url',
          'refresh',
          'generation',
          'movieImages',
          'galleryOnly',
          'galleryLimit'
        ])
          if (payload.containsKey(key)) key: payload[key],
        'minIntervalSeconds': database.scrapeSettings['minIntervalSeconds'],
        'maxIntervalSeconds': database.scrapeSettings['maxIntervalSeconds'],
      });
      database.finishScrapeTask(id, 'running', result: result);
      final conflicts = await _apply(task, payload, result);
      final warnings =
          List<String>.from(result['warnings'] as List? ?? const []);
      final status = conflicts.isNotEmpty
          ? 'review'
          : warnings.isNotEmpty
              ? 'partial'
              : 'done';
      database.finishScrapeTask(id, status,
          result: result,
          conflicts: conflicts,
          error: warnings.isEmpty ? null : warnings.join('；'));
    } catch (error) {
      if (_stopping ||
          _pauseRequested == id ||
          error is NasScrapeException && error.code == 'cancelled') {
        database.finishScrapeTask(id, 'pending', error: '已暂停，继续时从保存进度恢复');
        return;
      }
      if (error is ArgumentError) {
        database.finishScrapeTask(id, 'review',
            error: error.message.toString());
        return;
      }
      final exception = error is NasScrapeException
          ? error
          : NasScrapeException('storage', '资料保存失败，请重试或检查 NAS 可用空间');
      _logger.event('scraping.task_failed', level: 'WARN', fields: {
        'component': 'nas.scraping',
        'errorType': error.runtimeType.toString(),
        'reason': exception.code
      });
      if (['blocked', 'parse', 'redirect'].contains(exception.code))
        database.setScrapeSetting('blockedReason', exception.message);
      if (exception.until > 0)
        database.setScrapeSetting('cooldownUntil', exception.until);
      final review =
          ['review', 'not_found', 'invalid'].contains(exception.code);
      final retry = !review && (task['attempts'] as int) < 3;
      database.finishScrapeTask(
          id,
          review
              ? 'review'
              : retry
                  ? 'retry'
                  : 'failed',
          error: exception.message,
          nextAt: exception.until > 0
              ? exception.until
              : DateTime.now().millisecondsSinceEpoch +
                  600000 * (task['attempts'] as int));
    }
  }

  Map<String, dynamic> _entity(String kind, String name, String url) {
    final uri = Uri.parse(url), parts = uri.pathSegments;
    if (parts.length != 3 ||
        parts.first != 'zh' ||
        !['actor', 'maker', 'label', 'distributor'].contains(parts[1]))
      throw ArgumentError('来源身份无效');
    final namespace = parts[1], sourceId = parts[2];
    final hash = sha256
        .convert(
            utf8.encode(jsonEncode(['whatsav', kind, namespace, sourceId])))
        .toString()
        .substring(0, 32);
    return {
      'id': '${kind}_$hash',
      'kind': kind,
      'name': name,
      'url': url,
      'namespace': namespace,
      'sourceId': sourceId,
      'source': 'whatsav',
      'provisional': false
    };
  }

  Future<List<Map<String, dynamic>>> _apply(Map<String, dynamic> task,
      Map<String, dynamic> payload, Map<String, dynamic> result,
      {Set<String> overwrite = const {}}) async {
    final kind = task['kind'] as String,
        jobs = database.scrapeTaskJobs(task['id'] as String);
    final conflicts = <Map<String, dynamic>>[];
    if (kind == 'ranking') {
      database.transaction(() {
        final seen = List<String>.from(payload['seen'] as List),
            before = seen.length,
            limit = payload['limit'] as int;
        for (final raw in result['items'] as List) {
          final actor = Map<String, dynamic>.from(raw as Map),
              entity = _entity(
                  'actor', actor['name'] as String, actor['url'] as String);
          if (seen.length >= limit) break;
          if (seen.contains(entity['id'])) continue;
          seen.add(entity['id'] as String);
          if (_resolveEntity(entity, conflicts) == null) continue;
          _enqueueEntity(jobs, entity, payload, parent: task['id'] as String);
        }
        if (seen.length == before) throw ArgumentError('演员排名分页重复，已停止');
        final next = result['nextUrl'];
        if (next is String && seen.length < limit) {
          final child = database.enqueueScrapeTask(
              jobs,
              'ranking',
              'ranking:${jobs.first}:$next',
              {...payload, 'url': next, 'seen': seen},
              refresh: true);
          database.linkScrapeChild(task['id'] as String, child);
        }
      });
      return conflicts;
    }
    if (kind == 'movie') {
      final movieId = payload['movieId'] as String;
      if (database.findMovieForAdmin(movieId) == null)
        throw ArgumentError('影片已移除');
      if (database.scrapeMovieCode(movieId) != payload['code'])
        throw ArgumentError('采集期间影片番号已变更，请重新刮削');
      final metadata = Map<String, dynamic>.from(result['metadata'] as Map);
      final entities = (result['entities'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (payload['supplementOnly'] == true) {
        return _applySupplement(movieId, payload, result, entities);
      }
      final fields = <String, Object?>{
        'title': metadata['title'],
        'original_title': metadata['originalTitle'],
        'catalog_number': metadata['code'],
        'summary': metadata['summary']
      };
      final assets =
          Map<String, dynamic>.from(result['assets'] as Map? ?? const {});
      if (assets['poster'] is Map) {
        final file = await _saveImage(
            Map<String, dynamic>.from(assets['poster'] as Map),
            'movie',
            movieId);
        fields['poster_file_name'] = file;
      }
      database.transaction(() {
        database.saveScrapeMovieProfile(movieId, {
          ...metadata,
          'actorSources': entities.where((entity) => entity['kind'] == 'actor').toList(),
        });
        conflicts.addAll(database.applyScrapeFields('movie', movieId, fields,
            overwrite: overwrite));
        final actorIds = <String>[];
        for (final entity in entities) {
          if (entity['provisional'] == true) {
            final actor = entity['kind'] == 'actor'
                ? database.findActiveActorByExactName(entity['name'] as String)
                : null;
            if (actor != null) {
              actorIds.add(actor.id);
              continue;
            }
            conflicts.add({
              'field': 'identity',
              'proposed': entity['name'],
              'current': null,
              'message': '来源没有稳定身份，未自动关联'
            });
            continue;
          }
          final id = _resolveEntity(entity, conflicts);
          if (id == null) continue;
          if (entity['kind'] == 'actor') actorIds.add(id);
          _enqueueEntity(jobs, entity, payload, parent: task['id'] as String);
        }
        database.linkScrapeActors(movieId, actorIds);
        database.linkScrapeCompanies(movieId, entities);
        final distributors = database
            .movieCompanies(movieId)
            .where((e) => e['role'] == 'distributor')
            .toList();
        if (distributors.length == 1 &&
            database.findMovieForAdmin(movieId)!.seriesId == null) {
          conflicts.addAll(database.applyScrapeFields(
              'movie', movieId, {'publisher_id': distributors.single['id']},
              overwrite: overwrite));
        }
      });
      for (final entry in assets.entries
          .where((e) => e.key == 'cover' || e.key.startsWith('gallery-'))) {
        if (entry.value is! Map) continue;
        final file = await _saveImage(
            Map<String, dynamic>.from(entry.value as Map), 'gallery', movieId);
        database.addScrapeGallery(movieId, file);
        final image = database.carouselImagesForMovie(movieId).singleWhere((i) => i.fileName == file);
        database.recordGalleryOrigin(image.id, entry.key == 'cover' ? 'whatsav_cover' : 'whatsav_screenshot');
      }
      return conflicts;
    }
    final profile = Map<String, dynamic>.from(result['profile'] as Map);
    final entity = _entity(kind == 'actor' ? 'actor' : 'company',
        profile['name'] as String, payload['url'] as String);
    if (kind == 'actor') entity['aliases'] = profile['aliases'] ?? [];
    final entityId = _resolveEntity(entity, conflicts);
    if (entityId == null) return conflicts;
    final sourceKind = kind == 'actor' ? 'actor' : 'company';
    final values = kind == 'actor'
        ? <String, Object?>{
            'stage_name': profile['name'],
            'aliases_json': jsonEncode(profile['aliases'] ?? []),
            'gender': const {
              'female': 'female',
              'male': 'male',
              'intersex': 'intersex',
              '女': 'female',
              '男': 'male'
            }[profile['gender']?.toString().toLowerCase()],
            'birth_date': profile['birthDate'],
            'height_cm': profile['heightCm'],
            'birthplace': profile['birthplace'],
            'birth_month': profile['birthDate'] is String &&
                    (profile['birthDate'] as String).length >= 7
                ? (profile['birthDate'] as String).substring(0, 7)
                : null,
            'measurements': profile['measurements'],
          }
        : <String, Object?>{
            'display_name': profile['name'],
            'original_name': profile['originalName'],
            'country_region': profile['countryRegion'],
            'founded_date': profile['foundedDate']
          };
    final image =
        (result['assets'] as Map?)?[kind == 'actor' ? 'avatar' : 'logo'];
    if (image is Map && !(kind == 'actor' && database.actorHasMdcngSource(entityId) &&
        database.findActor(entityId)!.photoAssetId != null &&
        !overwrite.contains('photo_asset_id'))) {
      final asset = await _saveImage(
          Map<String, dynamic>.from(image), sourceKind, entityId);
      values[kind == 'actor' ? 'photo_asset_id' : 'logo_asset_id'] = asset;
    }
    database.transaction(() {
      conflicts.addAll(database.applyScrapeFields(sourceKind, entityId, values,
          overwrite: overwrite));
      database.saveScrapeProfile(entity['id'] as String, result);
      if (kind == 'actor') {
        database.saveScrapeWorks(entityId, result['works'] as List? ?? []);
        final next = result['nextUrl'];
        if (payload['filmography'] == true && next is String) {
          final visited = List<String>.from(payload['visited'] as List? ?? []);
          final ids = (result['works'] as List? ?? [])
              .map((v) => (v as Map)['sourceId'])
              .toList()
            ..sort((a, b) => a.toString().compareTo(b.toString()));
          final signature =
              sha256.convert(utf8.encode(jsonEncode(ids))).toString();
          if (visited.contains(signature) || visited.length >= 10000)
            throw ArgumentError('演员作品分页重复或数量异常');
          final child = database.enqueueScrapeTask(
              jobs,
              'actor',
              'actor:$next:full',
              {
                ...payload,
                'url': next,
                'visited': [...visited, signature]
              },
              refresh: payload['refresh'] == true);
          database.linkScrapeChild(task['id'] as String, child);
        }
      }
    });
    return conflicts;
  }

  /// 重名保留为可审核结果，不让单个演员阻止影片其它字段保存。
  String? _resolveEntity(Map<String, dynamic> entity, List<Map<String, dynamic>> conflicts) {
    try {
      return database.scrapeEntity(entity);
    } on ArgumentError catch (error) {
      conflicts.add({
        'field': 'identity', 'proposed': entity['name'], 'current': null,
        'message': error.message.toString(),
        if (entity['kind'] == 'actor' && entity['provisional'] != true) ...{
          'sourceKey': entity['id'], 'sourceUrl': entity['url'],
          'candidates': database.findActorsByExactNames([
            entity['name'] as String,
            ...List<String>.from(entity['aliases'] as List? ?? const []),
          ]).map((actor) => {'id': actor.id, 'name': actor.stageName ?? actor.originalName ?? actor.translatedName ?? '未命名演员',
              'originalName': actor.originalName, 'movieCount': actor.movieCount}).toList(),
        },
      });
      return null;
    }
  }

  void _enqueueEntity(List<String> jobs, Map<String, dynamic> entity,
      Map<String, dynamic> options,
      {required String parent}) {
    final kind = entity['kind'] == 'actor' ? 'actor' : 'company',
        url = entity['url'] as String;
    final full = options['filmography'] == true;
    final child = database.enqueueScrapeTask(
        jobs,
        kind,
        '$kind:${entity['id']}:${kind == 'actor' && full ? 'full' : 'profile'}',
        {'url': url, 'name': entity['name'], 'filmography': full},
        refresh: options['refreshEntities'] == true ||
            !options.containsKey('refreshEntities') &&
                options['refresh'] == true);
    database.linkScrapeChild(parent, child);
  }

  Future<String> _saveImage(
      Map<String, dynamic> asset, String kind, String id) async {
    final relative = asset['file'];
    if (relative is! String ||
        !RegExp(r'^assets/[a-f0-9]{64}\.(jpg|png|webp)$').hasMatch(relative))
      throw ArgumentError('采集图片路径无效');
    final file = File('$cacheDir/$relative');
    if (await file.length() > NasArtworkService.maxPosterBytes)
      throw ArgumentError('采集图片过大');
    final bytes = await file.readAsBytes(),
        hash = sha256.convert(bytes).toString();
    if (hash != asset['sha256']) throw ArgumentError('采集图片校验失败');
    final mime = asset['mimeType'] as String;
    final imageId = 'scrape-$id-${hash.substring(0, 16)}';
    if (kind == 'movie')
      return artwork.savePoster(movieId: imageId, mimeType: mime, bytes: bytes);
    if (kind == 'gallery') {
      // 以内容身份复用海报目录资产，轮播服务使用独立目录副本。
      final target = File(
          '${database.dataDir}/artwork/carousel/$imageId.${relative.split('.').last}');
      if (!NasArtworkService.isValidPosterBytes(mimeType: mime, bytes: bytes))
        throw ArgumentError('图片格式无效');
      await target.parent.create(recursive: true);
      if (!await target.exists()) await target.writeAsBytes(bytes, flush: true);
      return target.uri.pathSegments.last;
    }
    final purpose = kind == 'actor' ? 'actor_photo' : 'publisher_logo',
        assetId = '$imageId-$kind';
    if (database.findManagedAsset(assetId) != null) return assetId;
    final name = await artwork.saveManagedAsset(
        assetId: assetId, mimeType: mime, bytes: bytes);
    database.addManagedAsset(
        id: assetId, purpose: purpose, fileName: name, mimeType: mime);
    return assetId;
  }

  Future<Map<String, dynamic>> resolve(
      String taskId, List<String> fields, {Map<String, String> actorMappings = const {}}) async {
    database.resolveScrapeConflicts(taskId, fields, actorMappings: actorMappings);
    return database.scrapeTask(taskId)!;
  }

  /// 仅把有来源证据的封面视为占位；旧图不明时保留，不凭张数猜测。
  Future<bool> _needsSupplementGallery(String movieId) async {
    final movie = database.findMovieForAdmin(movieId);
    if (movie == null) throw ArgumentError('影片已移除');
    final images = database.carouselImagesForMovie(movieId);
    if (images.isEmpty) return true;
    final poster = await artwork.poster(movie.posterFileName);
    final posterHash = poster == null ? null : sha256.convert(await poster.file.readAsBytes()).toString();
    for (final image in images) {
      if (const {'mdcng_cover', 'whatsav_cover'}.contains(database.galleryOrigin(image.id))) continue;
      final file = await artwork.carouselImage(image.fileName);
      if (posterHash != null && file != null &&
          sha256.convert(await file.file.readAsBytes()).toString() == posterHash) continue;
      return false;
    }
    return true;
  }

  Future<List<Map<String, dynamic>>> _applySupplement(String movieId,
      Map<String, dynamic> payload, Map<String, dynamic> result,
      List<Map<String, dynamic>> entities) async {
    final metadata = result['metadata'] as Map;
    if (metadata['code'] != payload['code']) throw ArgumentError('来源番号不一致，请核对');
    if (!entities.any((entity) => entity['kind'] == 'actor')) {
      result['warnings'] = [...?result['warnings'] as List?, '来源未提供出演演员名单'];
    }
    for (final entity in entities.where((e) => e['kind'] == 'actor')) {
      if (entity['provisional'] == true || entity['url'] is! String) continue;
      try {
        // 只读取异名线索，不创建档案，不下载头像，不采集作品列表。
        final profile = await worker.execute({
          'type': 'actor', 'url': entity['url'], 'identityOnly': true,
          'minIntervalSeconds': database.scrapeSettings['minIntervalSeconds'],
          'maxIntervalSeconds': database.scrapeSettings['maxIntervalSeconds'],
        });
        final details = profile['profile'] as Map? ?? {};
        entity['aliases'] = <String>{
          ...List<String>.from(entity['aliases'] as List? ?? []),
          if (details['name'] is String) details['name'] as String,
          ...List<String>.from(details['aliases'] as List? ?? []),
        }.toList();
      } on NasScrapeException catch (error) {
        if (['cancelled', 'limited', 'blocked', 'redirect'].contains(error.code)) rethrow;
        result['warnings'] = [...?result['warnings'] as List?, '${entity['name']}：异名读取失败，可手动关联'];
      }
    }
    if (database.findMovieForAdmin(movieId) == null || database.scrapeMovieCode(movieId) != payload['code']) {
      throw ArgumentError('影片已移除或番号已变更');
    }
    database.transaction(() {
      database.saveSupplementCast(movieId, entities.where((e) => e['kind'] == 'actor').toList());
      database.reconcileSupplementCast(movieId: movieId);
      database.supplementSummary(movieId, metadata['summary'] as String?);
    });
    final pending = database.supplementPending(movieId);
    // 同一批图片一起提交；重试时可继续下载失败项，但不追加到已有实际截图。
    if (!await _needsSupplementGallery(movieId)) return pending;
    if ((result['warnings'] as List? ?? []).any((warning) => warning.toString().startsWith('gallery-'))) {
      return pending;
    }
    final before = database.carouselImagesForMovie(movieId).map((i) => i.id).toSet();
    final hashes = <String>{};
    final movie = database.findMovieForAdmin(movieId)!;
    final poster = await artwork.poster(movie.posterFileName);
    if (poster != null) hashes.add(sha256.convert(await poster.file.readAsBytes()).toString());
    for (final image in database.carouselImagesForMovie(movieId)) {
      final file = await artwork.carouselImage(image.fileName);
      if (file != null) hashes.add(sha256.convert(await file.file.readAsBytes()).toString());
    }
    final files = <String>[];
    try {
      for (final entry in (result['assets'] as Map? ?? {}).entries) {
        if (!(entry.key as String).startsWith('gallery-') || entry.value is! Map) continue;
        final asset = Map<String, dynamic>.from(entry.value as Map);
        if (hashes.contains(asset['sha256'])) continue;
        files.add(await _saveImage(asset, 'gallery', movieId));
        hashes.add(asset['sha256'] as String);
      }
      if (database.findMovieForAdmin(movieId) == null || database.scrapeMovieCode(movieId) != payload['code']) {
        throw ArgumentError('影片已移除或番号已变更');
      }
      final current = database.carouselImagesForMovie(movieId).map((i) => i.id).toSet();
      if (before.length != current.length || !before.containsAll(current)) return pending;
      database.transaction(() {
        for (final file in files) {
          database.addScrapeGallery(movieId, file);
          final image = database.carouselImagesForMovie(movieId).singleWhere((i) => i.fileName == file);
          database.recordGalleryOrigin(image.id, 'whatsav_screenshot');
        }
      });
    } finally {
      final used = database.carouselImagesForMovie(movieId).map((i) => i.fileName).toSet();
      for (final file in files.where((f) => !used.contains(f))) {
        await artwork.deleteCarouselImage(file);
      }
    }
    return pending;
  }
}
