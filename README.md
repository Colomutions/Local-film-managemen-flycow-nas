# 幕境 NAS 服务（任务 I）

这是飞牛 NAS 的无界面服务基础。它提供不鉴权的 `GET`/`HEAD /health`、持久 `serverId`、Android 1.x 兼容的 server-info、viewer/admin 配对、受 token 保护的播放会话和 Range 流，以及 SQLite 媒体根扫描。任务 K 已提供受 admin scope 保护的媒体根、扫描、影片/分集元数据、分类、标签、标签层级、海报、设备管理与备份 API；它尚未实现源文件管理 API。

第一次部署请先阅读 [`docs/飞牛NAS小白部署指南.md`](docs/飞牛NAS小白部署指南.md)，其中包含目录说明、`.env`、镜像加速、最小启动、只读媒体挂载、扫描和常见故障处理。

## 技术选型

- **运行时：Dart 3.13.2 + `dart:io` HTTP。** 当前 Windows 服务已将协议核心的依赖边界抽离为 Dart 接口；本项目使用独立 Dart 进程与 `sqlite3` 持久层，避免引入 Flutter、Drift、Windows 路径或桌面生命周期。
- **镜像：`dart:3.3-sdk` 构建，Debian Bookworm 运行。** Intel N150 使用 `linux/amd64`；镜像不需要 NAS 的 GUI 或 Docker Socket。
- **安全：** 容器没有特权模式，使用可配置的 `PUID:PGID`，并启用 `no-new-privileges`。

后续任务会在这个进程中逐步加入持久状态、鉴权和 `/api/v1` 兼容路由；不会复制 Windows/Android 工程或共享 SQLite。

## 配置与卷

1. 在 NAS 上将本目录放在应用数据位置（例如飞牛 Docker 的项目目录）。
2. 复制 `.env.example` 为 `.env`，并设置 `PUID`、`PGID` 和端口。`PUID:PGID` 必须对 `./data` 有写权限；它表示容器内进程访问 NAS 文件时采用的 Linux 用户/组编号。
3. 主编排文件只挂载 `./data:/data`。服务身份与设备令牌哈希保存在 `/data/state/server.json`；原始令牌和配对码不会写入该文件。

真实媒体目录尚未确定，因此默认不挂载。以后要启用媒体卷，先在 `.env` 设置一个已经存在的 NAS 目录：

```dotenv
MEDIA_ROOT=/你的/NAS/媒体目录
```

然后使用媒体覆盖文件启动：

```text
docker compose --env-file .env -f docker-compose.yml -f docker-compose.media.yml up -d --build
```

该覆盖文件把媒体目录以**只读**方式挂到容器 `/media`。扫描只读取该目录；默认不会修改源媒体。

### 受控源文件改名（默认关闭）

只有需要从 Windows 管理员页面执行“同目录改名”时，用户才可在 `.env` 显式设置 `MUJING_ALLOW_SOURCE_RENAME=true`，并改用 `docker-compose.media-writable.yml`，而不是只读覆盖文件：

```text
sudo -H docker compose --env-file .env -f docker-compose.yml -f docker-compose.media-writable.yml build
sudo -H docker compose --env-file .env -f docker-compose.yml -f docker-compose.media-writable.yml up -d
```

这是对 NAS 源媒体写入的明确风险开关：服务仍只接受当前已扫描分集的相对路径，只能同目录改名、必须保留扩展名、拒绝路径逃逸和文件名冲突；不会移动或删除文件。成功后服务在一个 SQLite 事务内更新分集路径、标题和文件元数据；数据库更新失败时会尽力回滚文件名。未启用可写覆盖或开关时，专用 API 会明确拒绝请求。不要同时使用只读和可写媒体覆盖文件。

## 启动与验证

无媒体挂载的最小启动：

```text
docker compose --env-file .env up -d --build
```

健康检查：

```text
curl http://<NAS 局域网地址>:48291/health
```

预期响应：

```json
{"data":{"status":"ok","service":"mujing-nas","version":"0.1.0"}}
```

以下 `dart` 命令只适用于安装了 Dart SDK 的开发机；飞牛 NAS 宿主机默认不安装 Dart，出现 `dart: command not found` 属于预期。NAS 上应使用 Docker 构建验证，Dockerfile 会在构建阶段执行 `dart pub get` 与 `dart compile exe`：

```text
docker compose --env-file .env -f docker-compose.yml -f docker-compose.media.yml build --pull=false
```

在开发机上可不依赖 Docker 运行最小测试：

```text
dart test/health_server_test.dart
```

`MUJING_ADVERTISE_URL` 可以为空。为空时已配对客户端仍可使用其手动保存的 NAS 地址，但服务不会提供连接/二维码 endpoint。确定 NAS 宿主机地址后，显式设置如 `http://192.168.1.20:48291` 并重新执行 `docker compose up -d`；服务不会从容器网卡推导地址，并会拒绝 Docker `172.16.0.0/12` 地址。

## 升级、回退与异常启动

升级前，在飞牛 Docker 图形界面保留当前可用镜像版本，并确认 `./data` 持久目录和媒体只读挂载配置不变；不得删除数据卷、重建空数据目录或提交 `.env`。随后按当前是否启用媒体覆盖文件执行既有 `up -d --build` 命令，并通过 Docker 容器健康状态确认服务恢复。

若升级后未 healthy 或立即退出：停止继续重建，保留 `./data` 和当前日志；在 Docker 图形界面选择先前保留的镜像版本，以相同的 `./data` 和只读媒体挂载重新启动。不要执行带卷删除的 down 操作，不要覆盖 SQLite、恢复备份或操作源媒体。若日志显示数据库 schema 版本高于服务支持范围，应保持数据卷不变，改用支持该 schema 的服务版本。

本地预检可执行：

```text
dart run test/upgrade_guard_test.dart
dart run test/startup_integrity_test.dart
```

这些测试使用临时目录，分别验证重复迁移、未来 schema 拒绝、损坏状态/SQLite 的安全失败和残留备份临时目录保持；不替代真实 NAS 的镜像升级验收。

首次部署还要在未跟踪的 `.env` 设置 `MUJING_PAIRING_CODE`。它仅用于确认五分钟内有效的配对会话，不能提交或写入日志。

## 任务 E/F API 与权限

- `GET` / `HEAD /health`：无需鉴权；只返回状态、服务名和版本，不返回卷路径、令牌或连接地址。
- `GET /api/v1/server-info`：返回 Android 当前 DTO 所需的 `serverId`、`serverName`、`apiVersion`、`minimumClientVersion`、`pairingRequired` 和 capabilities。显式配置 `MUJING_ADVERTISE_URL` 时才额外返回 `connection.endpoint`。
- `POST /api/v1/pairing/sessions`：请求必须包含 `serverId`；可选 `requestedScope` 只能是 `viewer` 或 `admin`。省略 scope（Android 当前行为）固定创建 `viewer` 会话。
- `POST /api/v1/pairing/sessions/{id}/confirm`：请求 `pairingPassword`，成功响应包含 `deviceId`、`accessToken`、`expiresAt` 和 `scope`。令牌有效期当前为一年，持久化时仅保存 SHA-256 哈希。

`viewer` 可用于后续浏览、播放和观看状态 API；`admin` 只由显式请求的未来 Windows 管理客户端取得。尚未实现的 `/api/v1/admin/*` 路由会拒绝 viewer 为 `403 insufficient_scope`，不会把 Android 默认升级为 admin。

任务 F 提供一条仅用于协议验证的内存 fixture：

- `GET /api/v1/movies`：一条 Android DTO 兼容的摘要；支持可选 `query`。
- `GET /api/v1/movies/{movieId}`：同一影片的详情和不可播放的示例分集。
- `GET /api/v1/tag-paths`：示例标签树路径。
- `GET` / `HEAD /api/v1/assets/posters/{movieId}`：受 Bearer token 保护的内存 PNG，使用相对 `posterUrl`。
- `GET /api/v1/favorites`、`GET /api/v1/history`：返回空列表，等待真实观看状态任务实现。

所有上述路由都不会读取媒体卷、返回宿主机路径，或宣称示例分集可播放。任务 I 会用 NAS SQLite 和扫描结果替换此 fixture。

任务 G 允许把这条 fixture 显式绑定到一个真实媒体文件，用于部署验证。必须同时启用媒体覆盖文件，并在未跟踪 `.env` 中设置：

```dotenv
MEDIA_ROOT=/NAS/上的实际媒体目录
MUJING_FIXTURE_MEDIA_RELATIVE_PATH=相对于媒体目录的/test.mp4
```

服务端只接受相对路径，拒绝绝对路径、`..` 路径逃逸，并在每次流请求时解析符号链接，确保最终文件仍位于容器 `/media` 根内。该配置可在部署时手动提供；本任务没有配置页面，也不会把宿主机路径返回给客户端。

- `POST /api/v1/playback/sessions`：viewer 创建直接播放会话，返回相对流 URL。
- `PATCH /api/v1/playback/sessions/{id}/progress`：viewer 写入当前进度；任务 G 中进度只保存在内存，容器重启后清空。
- `DELETE /api/v1/playback/sessions/{id}`：关闭会话。
- `GET` / `HEAD /api/v1/playback/sessions/{id}/stream`：支持无 Range 的 `200`、单 Range 的 `206` 和非法 Range 的 `416`，不把整文件读入内存。

服务使用 `sqlite3` 在 `/data/db/mujing.sqlite` 建立版本化 migration、WAL 和 `media_roots` / `movies` / `episodes` 表。生产环境把容器 `/media` 作为只读边界，启动时不自动扫描；在 Windows NAS 管理页创建类别并绑定其子目录后，才会显式扫描该类别中的 `mp4`、`m4v`、`mkv`、`mov` 与 `webm` 文件。类别目录不得相同、互为父子或经符号链接越出媒体根；扫描结果只保存稳定媒体根 ID 与相对路径，绝不向 API 返回宿主机路径。`MUJING_SCAN_ON_START` 仅保留给隔离的旧测试构造，环境配置中不再启用它。

任务 I 暂不调用 ffprobe，因此时长和分辨率可为空；它也不提供管理 API、重命名、移动或删除。扫码得到的 SQLite 影片会优先替代内存 fixture；尚未扫描时仍保留 fixture 用于协议测试。

## 任务 K：管理员媒体根、扫描、元数据、分类标签与海报

当前仅实现以下管理员路由，所有路由都要求显式 `admin` token；缺少 token 为 `401 authentication_required`，viewer token 为 `403 insufficient_scope`：

- `GET /api/v1/admin/media-roots`：返回当前容器 `/media` 对应的服务内 `id`、名称、只读状态、启用状态和时间戳。响应不返回 `containerPath`、宿主机路径或容器路径。
- `POST /api/v1/admin/scan-jobs`：请求体仅接受服务端返回的 `{ "mediaRootId": "..." }`，创建一个 `202` 扫描任务。服务不接受、猜测或创建任意文件系统路径。
- `GET /api/v1/admin/scan-jobs` 与 `GET /api/v1/admin/scan-jobs/{id}`：读取当前进程内扫描任务的状态、文件数和可用分集数。扫描结果写入 NAS SQLite；任务状态本身在容器重启后不保留。
- `PATCH /api/v1/admin/movies/{id}`：仅接受 `title` 和/或 `summary`，更新已扫描影片的 NAS SQLite 元数据并返回浏览兼容的影片详情。
- `PATCH /api/v1/admin/episodes/{id}`：仅接受 `title`，更新已扫描分集的 NAS SQLite 元数据；响应不包含 `relativePath`。
- `GET`/`POST`/`PATCH`/`DELETE /api/v1/admin/categories`：管理 NAS 节点内的分类名称。删除分类会清空影片上的该分类关联，不影响媒体文件。
- `GET`/`POST`/`PATCH`/`DELETE /api/v1/admin/tags`：管理 NAS 节点内的标签名称。删除标签会级联删除其 placement 与影片关联，不影响媒体文件。
- `GET`/`POST`/`PATCH`/`DELETE /api/v1/admin/tag-placements`：用 `tagId` 与可空 `parentPlacementId` 管理标签层级；服务拒绝循环层级。
- `POST /api/v1/admin/movies/{id}/poster`：admin 将 PNG、JPEG 或 WebP 原始 bytes 上传为已扫描影片的海报。请求必须使用对应的 `Content-Type`，最大 10 MiB；响应仅返回相对 `posterUrl`。

媒体覆盖保持只读。扫描任务只能扫描当前已配置的 `/media` 根，使用媒体根 ID 和相对路径，不会执行源文件写操作。数据库 migration v2 为媒体根增加扫描时间，用于区分“尚未扫描时的协议 fixture”和“已扫描但目录为空”的真实 SQLite 结果。

重复扫描同一媒体根时仅刷新文件大小、可用性和扫描时间，不会覆盖管理员写入的影片标题、简介或分集标题。

影片 PATCH 还可设置可空 `categoryId` 和完整替换的 `tagPlacementIds`。这些字段只能是服务端已有 ID；浏览 API 仍只返回分类 DTO、标签 DTO 和名称路径，Android 按名称做跨节点聚合时不使用这些节点内 ID。

海报写入持久 `/data/artwork/posters`，SQLite migration v4 只记录服务生成的海报文件名。替换海报会清理旧的同影片海报资产；`GET`/`HEAD /api/v1/assets/posters/{movieId}` 继续要求 Bearer token，绝不返回文件名或绝对路径。上传校验 MIME 白名单、大小和格式签名，不读取、写入或重命名 `/media` 中的源视频。

本切片的本地回归命令：

```text
dart run test/admin_api_test.dart
dart run test/taxonomy_api_test.dart
dart run test/artwork_api_test.dart
dart run test/devices_api_test.dart
dart run test/backups_api_test.dart
```

示例错误 envelope：

```json
{"error":{"code":"authentication_required","message":"A valid device token is required."}}
```

## 任务 K：设备与备份

- `GET /api/v1/admin/devices` 与 `DELETE /api/v1/admin/devices/{deviceId}`：仅 admin 可查看脱敏的设备 ID、scope 和过期时间，或撤销指定设备。撤销后该设备的原令牌立即失效；响应不返回令牌、令牌哈希或配对码。
- `POST /api/v1/admin/backups`：仅 admin 可创建备份，成功返回服务生成的备份 ID、创建时间与数据大小。备份使用 SQLite `VACUUM INTO` 生成一致性快照，并复制 `/data` 内的服务身份状态、可选配置和海报资产。
- `GET /api/v1/admin/backups` 与 `GET /api/v1/admin/backups/{id}`：仅返回备份元数据，不提供文件系统路径、备份内容下载或恢复操作。

备份绝不包含 `/media` 源视频，也不修改 SQLite 正常数据、海报或媒体文件。真实 NAS 上仍需验证 Docker 重建后的备份清单、SQLite 快照和海报资产可用性。

## 目录

```text
bin/                  进程入口
lib/src/              配置和健康服务
test/                 不依赖第三方包的本地测试
docker-compose.yml    最小服务与持久数据卷
docker-compose.media.yml  显式启用的读写媒体卷
```
