# 影片库内部边界

`NasLibraryDatabase` 保留现有公开入口和模型导出，统一管理一个 SQLite 连接、
资源版本计数、事务、备份和关闭。业务方法转交给以下独立 repository；
repository 不依赖 HTTP 服务，也不持有整个 `NasLibraryDatabase`。

| 实现 | 负责的内容 |
| --- | --- |
| `schema_repository.dart` | 按顺序升级既有数据库 schema |
| `scan_repository.dart` | 来源盘、目录扫描、探测结果和扫描索引清理 |
| `queries_repository.dart` | 影片搜索、影片与分集读取、行到展示模型的转换 |
| `profiles_repository.dart` | 演员、发行商、系列及其关联、MDCNG 演员审计 |
| `taxonomy_repository.dart` | 分类目录绑定、标签层级和资料导入导出 |
| `movies_repository.dart` | 影片/分集修改、索引删除、源文件改名后的索引同步 |
| `collections_repository.dart` | 影集合并拆分、旧影集预览和迁移 |
| `assets_repository.dart` | 受管理图片和画廊的数据库记录 |
| `metadata_repository.dart` | AI 任务、资料来源、确认后的 MDCNG 元数据写入 |
| `playback_repository.dart` | 播放进度、续播目标和观影历史 |
| `library_values.dart` | 字符串、路径值、排序、时间和导入颜色等共用处理 |

repository 通过连接 getter 使用当前连接，避免同一个 facade 关闭再打开时
继续持有已释放的连接。跨模块调用以具体回调注入；需要跨模块原子操作时，
仍在同一连接上保留原有事务边界，使用 facade 的事务入口或原有显式事务，
不新开连接或增加独立提交。

只有扫描和影集截图复制涉及现有文件访问，其余 repository 只读写 SQLite。
本次分层没有增加定时器、扫描、后台查询或额外文件操作。扫描顺序、探测条件、
批量大小、SQL、事务边界和资源版本规则保持不变。

现有 `scrape_database.dart`、`supplement_database.dart` 暂时保留扩展实现，
复用同一个数据库入口；没有把新 repository 做成 `part`。

扩展一个领域时，在对应 repository 添加实现，再在 facade 增加所需兼容入口。
只需要模型的使用方直接导入 `../library_models.dart`，不引入 SQLite 实现。
