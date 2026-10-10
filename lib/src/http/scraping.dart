import 'dart:async';
import 'dart:io';

import '../library_database.dart';
import '../scrape_service.dart';

import 'response.dart';

/// HTTP adapter for the existing scrape service.
class NasScrapingHttpApi {
  NasScrapingHttpApi(this._libraryDatabase, this.scraper);
  final NasLibraryDatabase _libraryDatabase;
  final NasScrapeService? Function() scraper;
  NasScrapeService? get _scraper => scraper();

  Future<void> scrapingRequest(HttpRequest request) async {
    final service = _scraper;
    if (service == null)
      return writeApiError(
          request, HttpStatus.serviceUnavailable, 'scraping_unavailable');
    final path = request.uri.pathSegments.skip(4).toList();
    final offset =
        int.tryParse(request.uri.queryParameters['offset'] ?? '0') ?? -1;
    if (offset < 0 || offset > 1000000)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    try {
      Object? result;
      var status = HttpStatus.ok;
      if (request.method == 'GET' && path.isEmpty) {
        result = service.snapshot(offset: offset);
      } else if (request.method == 'POST' &&
          path.length == 1 &&
          path.first == 'jobs') {
        final body = await readApiJsonBody(request);
        if (body == null) throw ArgumentError('请求无效');
        result = service.create(body);
        status = HttpStatus.accepted;
      } else if (request.method == 'GET' &&
          path.length == 2 &&
          path.first == 'jobs') {
        result = _libraryDatabase.scrapeJob(path[1], offset: offset);
        if (result == null)
          return await writeApiError(
              request, HttpStatus.notFound, 'resource_not_found');
      } else if (request.method == 'POST' &&
          path.length == 3 &&
          path.first == 'jobs') {
        await service.control(path[1], path[2]);
        result = {'ok': true};
      } else if (request.method == 'POST' &&
          path.length == 1 &&
          path.first == 'settings') {
        service.configure(await readApiJsonBody(request) ?? {});
        result = _libraryDatabase.scrapeSettings;
      } else if (request.method == 'POST' &&
          path.length == 1 &&
          path.first == 'resume-source') {
        await service.resumeSource();
        result = {'ok': true};
      } else if (request.method == 'POST' &&
          path.length == 3 &&
          path.first == 'tasks' &&
          path.last == 'resolve') {
        final body = await readApiJsonBody(request), fields = body?['fields'];
        if (fields is! List || fields.any((v) => v is! String))
          throw ArgumentError('审核字段无效');
        final mappings = body?['actorMappings'] ?? const <String, String>{};
        if (mappings is! Map ||
            mappings.length > 1000 ||
            mappings.entries.any(
                (entry) => entry.key is! String || entry.value is! String)) {
          throw ArgumentError('演员身份选择无效');
        }
        result = await service.resolve(path[1], List<String>.from(fields),
            actorMappings: Map<String, String>.from(mappings));
      } else {
        return await writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }
      await writeApiJson(request.response, status, {'data': result});
    } on ArgumentError catch (error) {
      await writeApiJson(request.response, HttpStatus.badRequest, {
        'error': {
          'code': 'invalid_request',
          'message': error.message.toString()
        }
      });
    } on NasScrapeException catch (error) {
      await writeApiJson(request.response, HttpStatus.serviceUnavailable, {
        'error': {'code': 'scraping_${error.code}', 'message': error.message}
      });
    }
  }
}
