# HTTP 服务边界

`NasHealthServer` 负责服务装配、启动/停止、恢复维护状态、请求日志及鉴权。
鉴权完成后交给 `NasApiRouter`，路由器保持原有匹配顺序、路径和 HTTP 方法，
各业务模块不接收整个服务实例，也不通过 `part` 共享其私有状态。

| 模块 | 职责 |
| --- | --- |
| `movies.dart` | 影片浏览、搜索、编辑与影集操作 |
| `profiles.dart`、`profile_packages.dart` | 演员/发行商/系列资料与资料包 |
| `taxonomy.dart` | 分类目录、标签层级及导入导出 |
| `artwork.dart` | 图片上传、读取和删除 |
| `mdcng_movies.dart`、`mdcng_actors.dart` | MDCNG 预览、确认、导入任务与来源审核 |
| `scan.dart` | 扫描任务生命周期与磁盘队列调度 |
| `playback.dart`、`history.dart` | 播放会话、Range/HEAD 流、进度与观影记录 |
| `pairing.dart` | 配对会话与设备令牌校验 |
| `operations.dart` | 设备、来源盘与备份管理 |
| `ai.dart`、`scraping.dart` | AI 资料任务与已有刮削服务的 HTTP 入口 |
| `presenter.dart`、`validation.dart` | 协议响应组装、纯输入校验和比较 |
| `media_resolver.dart`、`response.dart` | 影片路径解析与 HTTP 响应编码 |

服务统一持有数据库连接、磁盘工作队列和持久状态。扫描、批量导入、备份、
小说及漫画后台读取继续复用同一个队列；播放活动计数由播放模块维护，队列
通过回调读取。没有增加定时任务、扫描、重试或落盘操作。

配对、设备管理和 AI 模块通过 getter 读取当前持久状态。小说/漫画 API 和备份
协调器也通过 getter 获取，保证恢复数据库、停止后重新启动时不会保留旧连接。
服务器按原有顺序取消任务、等待队列、关闭监听和数据库。模块构造不做文件 I/O。

增加接口时，在对应业务模块实现，再在路由器登记；公开健康、配对和服务信息
仍在统一鉴权前处理，所有管理接口继续经过统一的管理员权限检查。
