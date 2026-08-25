# 幕境 NAS 服务（任务 I）

这是飞牛 NAS 的无界面服务基础。它提供不鉴权的 `GET`/`HEAD /health`、持久 `serverId`、Android 1.x 兼容的 server-info、viewer/admin 配对、受 token 保护的播放会话和 Range 流，以及 SQLite 媒体根扫描。任务 K 已提供受 admin scope 保护的媒体根只读查询、扫描任务和已扫描影片/分集的最小元数据更新；它尚未实现分类/标签、海报、备份、设备或源文件管理 API。

## 技术选型

- **运行时：Dart 3.3 + `dart:io` HTTP。** 当前 Windows 服务已将协议核心的依赖边界抽离为 Dart 接口；本项目先使用零第三方依赖的独立 Dart 进程，避免引入 Flutter、Drift、Windows 路径或桌面生命周期。
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

该覆盖文件把媒体目录以**只读**方式挂到容器 `/media`。扫描只读取该目录；当前服务没有源文件重命名、移动或删除能力。将来若要开放这些能力，必须先获得用户对读写挂载的明确授权，并实现媒体根 ID 与相对路径校验。

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

在开发机上可不依赖 Docker 运行最小测试：

```text
dart test/health_server_test.dart
```

`MUJING_ADVERTISE_URL` 可以为空。为空时已配对客户端仍可使用其手动保存的 NAS 地址，但服务不会提供连接/二维码 endpoint。确定 NAS 宿主机地址后，显式设置如 `http://192.168.1.20:48291` 并重新执行 `docker compose up -d`；服务不会从容器网卡推导地址，并会拒绝 Docker `172.16.0.0/12` 地址。

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

任务 I 使用 `sqlite3` 在 `/data/db/mujing.sqlite` 建立版本化 migration、WAL 和 `media_roots` / `movies` / `episodes` 表。设置 `MUJING_SCAN_ON_START=true` 后，服务只扫描容器 `/media` 中的 `mp4`、`m4v`、`mkv`、`mov` 与 `webm` 文件；扫描结果只保存稳定媒体根 ID 与相对路径，绝不向 API 返回宿主机路径。首次扫描完成后可把该开关改回 `false`，以避免每次重启全量扫描。

任务 I 暂不调用 ffprobe，因此时长和分辨率可为空；它也不提供管理 API、重命名、移动或删除。扫码得到的 SQLite 影片会优先替代内存 fixture；尚未扫描时仍保留 fixture 用于协议测试。

## 任务 K：管理员媒体根、扫描任务与最小影片元数据

当前仅实现以下管理员路由，所有路由都要求显式 `admin` token；缺少 token 为 `401 authentication_required`，viewer token 为 `403 insufficient_scope`：

- `GET /api/v1/admin/media-roots`：返回当前容器 `/media` 对应的服务内 `id`、名称、只读状态、启用状态和时间戳。响应不返回 `containerPath`、宿主机路径或容器路径。
- `POST /api/v1/admin/scan-jobs`：请求体仅接受服务端返回的 `{ "mediaRootId": "..." }`，创建一个 `202` 扫描任务。服务不接受、猜测或创建任意文件系统路径。
- `GET /api/v1/admin/scan-jobs` 与 `GET /api/v1/admin/scan-jobs/{id}`：读取当前进程内扫描任务的状态、文件数和可用分集数。扫描结果写入 NAS SQLite；任务状态本身在容器重启后不保留。
- `PATCH /api/v1/admin/movies/{id}`：仅接受 `title` 和/或 `summary`，更新已扫描影片的 NAS SQLite 元数据并返回浏览兼容的影片详情。
- `PATCH /api/v1/admin/episodes/{id}`：仅接受 `title`，更新已扫描分集的 NAS SQLite 元数据；响应不包含 `relativePath`。

媒体覆盖保持只读。扫描任务只能扫描当前已配置的 `/media` 根，使用媒体根 ID 和相对路径，不会执行源文件写操作。数据库 migration v2 为媒体根增加扫描时间，用于区分“尚未扫描时的协议 fixture”和“已扫描但目录为空”的真实 SQLite 结果。

重复扫描同一媒体根时仅刷新文件大小、可用性和扫描时间，不会覆盖管理员写入的影片标题、简介或分集标题。

本切片的本地回归命令：

```text
dart run test/admin_api_test.dart
```

示例错误 envelope：

```json
{"error":{"code":"authentication_required","message":"A valid device token is required."}}
```

## 目录

```text
bin/                  进程入口
lib/src/              配置和健康服务
test/                 不依赖第三方包的本地测试
docker-compose.yml    最小服务与持久数据卷
docker-compose.media.yml  显式启用的读写媒体卷
```
