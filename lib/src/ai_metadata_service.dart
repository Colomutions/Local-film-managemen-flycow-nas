import 'library_database.dart';
import 'persistent_state.dart';

/// NAS 内部的影视元数据生成适配器；客户端永远不会接触 AI 密钥。
abstract class NasAiMetadataClient {
  Future<Map<String, Object?>> generate({
    required NasAiSettings settings,
    required NasLibraryMovie movie,
    required String instructions,
  });
}

/// 可安全返回给管理端的 AI 任务失败原因。
class NasAiMetadataException implements Exception {
  const NasAiMetadataException(this.code);

  final String code;

  @override
  String toString() => 'NasAiMetadataException($code)';
}

/// 未配置为向外部服务传输影片元数据时的安全默认实现。
class NasDisabledAiMetadataClient implements NasAiMetadataClient {
  const NasDisabledAiMetadataClient();

  @override
  Future<Map<String, Object?>> generate({
    required NasAiSettings settings,
    required NasLibraryMovie movie,
    required String instructions,
  }) async {
    throw const NasAiMetadataException('ai_execution_disabled');
  }
}
