# 幕境飞牛 NAS 小白部署指南

本指南用于把幕境 NAS 无界面服务部署到家中的飞牛 NAS。视频目录默认以只读方式挂载，服务不会重命名、移动或删除源视频。

## 1. 先分清三个目录

```text
Windows 共享路径：\\NAS名称\共享文件夹\mujing-nas
NAS 工程目录：  /volX/用户ID/docker/mujing-nas
NAS 媒体目录：  /volX/用户ID/视频目录
```

- Windows 共享路径只用于从电脑复制和编辑文件，不能填进 `MEDIA_ROOT`。
- NAS 工程目录保存 Dockerfile、Compose、源码、`.env` 和 `data`。
- NAS 媒体目录保存真实视频，不要把工程放进媒体目录。

工程目录应包含：

```text
mujing-nas/
├─ bin/
├─ lib/
├─ docs/
├─ data/
├─ .env
├─ .env.example
├─ docker-compose.yml
├─ docker-compose.media.yml
├─ Dockerfile
├─ pubspec.yaml
└─ pubspec.lock
```

`.env` 和 `data` 不在 Git 仓库中出现是正常的：`.env` 保存私密部署参数，`data` 保存 NAS 身份、SQLite、海报和备份。

## 2. 部署前检查

进入 NAS 终端或 SSH：

```bash
whoami
id
uname -m
sudo docker --version
sudo docker compose version
```

Intel N100/N150 一类 NAS 应显示 `x86_64` 或 `amd64`。本项目当前按 `amd64` 实机验证。

如果不加 `sudo` 时出现 `/var/run/docker.sock: permission denied`，继续使用 `sudo docker ...`。不要执行 `chmod 666 /var/run/docker.sock`。

## 3. 放置工程

把本仓库完整复制或克隆到 NAS 的 Docker 工程位置，例如：

```text
/vol2/1000/docker/mujing-nas
```

如果只知道 Windows 共享路径，可在 NAS 中查找真实位置：

```bash
find / -type f -name docker-compose.yml 2>/dev/null | grep mujing-nas
```

飞牛可能为同一目录显示 `/fs/...`、`/vol...` 等多个入口。运行 Compose 时优先使用 `/vol...` 的真实本地路径，并且只从一个目录启动服务，避免端口冲突和多个 `serverId`。

进入工程目录并创建数据目录：

```bash
cd /vol2/1000/docker/mujing-nas
mkdir -p data
```

不要删除已有 `data`。升级前应先备份它。

## 4. 创建 `.env`

仓库不会提供真实 `.env`，需要复制模板：

```bash
cp .env.example .env
```

也可以在 Windows 共享目录复制 `.env.example` 并改名为 `.env`。

编辑 `.env`：

```dotenv
PUID=1000
PGID=1001

MUJING_HOST_PORT=48291
MUJING_SERVER_NAME=幕境 NAS
MUJING_ADVERTISE_URL=http://NAS局域网地址:48291

MUJING_PAIRING_CODE=自行设置且不要公开的配对码

MUJING_MEDIA_ROOT_NAME=媒体库
MUJING_SCAN_ON_START=false
MUJING_TIMEZONE=Asia/Shanghai

MEDIA_ROOT=/NAS内部真实媒体目录
# MUJING_FIXTURE_MEDIA_RELATIVE_PATH=动漫/样片.mp4
```

注意：

- `PUID`、`PGID` 应以 NAS 上 `id` 的结果为准。
- `MUJING_ADVERTISE_URL` 必须是纯 URL，不要填写 `[地址](地址)`。
- 配对码只能保存在 `.env`，不要写进文档、截图、聊天或 Git。
- `MEDIA_ROOT` 是 NAS 内部绝对路径，不能写 Windows 的 `\\NAS\共享目录`。
- fixture 必须相对于 `MEDIA_ROOT`，不能再次填写完整绝对路径。

例如：

```dotenv
MEDIA_ROOT=/vol2/1000/视频备份
MUJING_FIXTURE_MEDIA_RELATIVE_PATH=动漫/样片.mp4
```

## 5. 可选：私人镜像加速器

Dockerfile 使用：

```text
docker.io/library/dart:3.13.2-sdk
docker.io/library/debian:bookworm-slim
```

如果私人 Registry 地址为 `registry.example.com/mirror`，可先拉取再标记为 Dockerfile 使用的本地名称：

```bash
sudo docker pull registry.example.com/mirror/dart:3.13.2-sdk
sudo docker pull registry.example.com/mirror/debian:bookworm-slim

sudo docker tag registry.example.com/mirror/dart:3.13.2-sdk dart:3.13.2-sdk
sudo docker tag registry.example.com/mirror/debian:bookworm-slim debian:bookworm-slim
```

不同 Registry 的命名空间不同，请按服务商提供的真实路径替换示例。标记后可使用 `--pull=false`，避免构建再次访问 Docker Hub。

## 6. 第一次只做最小启动

第一次不要启用媒体覆盖，先确认容器、端口、SQLite 和 `/data` 正常：

```bash
cd /vol2/1000/docker/mujing-nas

sudo docker compose --env-file .env config
sudo docker compose --env-file .env build --pull=false
sudo docker compose --env-file .env up -d
sudo docker compose ps
```

刚启动时可能显示 `health: starting`，约 30 秒后应变为 `healthy`。

在 NAS 上检查：

```bash
curl -sS http://127.0.0.1:48291/health
```

预期：

```json
{"data":{"status":"ok","service":"mujing-nas","version":"0.1.0"}}
```

局域网电脑应使用 NAS 地址，不能使用 `127.0.0.1`：

```text
http://NAS局域网地址:48291/health
```

容器不停重启时查看：

```bash
sudo docker compose ps
sudo docker logs --tail=100 mujing-nas
```

## 7. 检查服务身份

在局域网电脑访问：

```text
http://NAS局域网地址:48291/api/v1/server-info
```

确认：

- `serverName` 是 NAS 名称；
- `serverId` 是 NAS 独立身份，不能和 Windows 节点相同；
- `connection.endpoint` 是纯 NAS 局域网 URL；
- `pairingRequired=true`。

重建后再次查询，`serverId` 必须保持：

```bash
sudo docker compose --env-file .env up -d --force-recreate
```

稳定身份保存在 `./data`，不要删除这个目录。

## 8. 启用真实媒体只读挂载

先确认媒体根和测试文件存在：

```bash
ls -ld "/NAS内部真实媒体目录"
ls -l "/NAS内部真实媒体目录/相对测试文件"
```

设置 `.env` 后，使用两个 Compose 文件：

```bash
cd /vol2/1000/docker/mujing-nas

sudo docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.media.yml \
  config

sudo docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.media.yml \
  up -d --force-recreate
```

检查挂载：

```bash
sudo docker inspect mujing-nas \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

正确结果：

```text
工程目录/data -> /data  RW=true
媒体目录       -> /media RW=false
```

`RW=false` 表示媒体只读。

重要：启用媒体后，以后每次创建或重建容器都必须同时带上 `docker-compose.media.yml`。如果只执行基础 `docker compose up`，新的容器不会挂载 `/media`，API 中的 `isAvailable` 会变回 `false`。

## 9. 首次建立影片类别并扫描

确认只读媒体挂载正常后，服务启动时的影片库应为空。不要把
`MUJING_SCAN_ON_START` 设为 `true`；生产环境不会再用它扫描整个媒体根。

在 Windows 的“管理 NAS 影片”页中依次完成：

1. 打开“影院分类”的设置，新建一个类别。
2. 在 NAS 内部目录选择器中为类别选择一个媒体子目录。
3. 点击“扫描文件夹”，选择该类别并确认。

扫描只读取这个类别绑定的只读目录，并把发现的视频归入该类别。不同类别不能绑定同一目录，也不能绑定互为父子关系的目录；变更类别目录会清除该类别旧的 NAS 影片元数据，但不会删除源视频。

## 10. Android 连接

Android 与 NAS 必须处于同一可信局域网。客户端填写：

```text
http://NAS局域网地址:48291
```

不要填写：

- `127.0.0.1`，它在 Android 上代表手机自己；
- Docker 的 `172.x.x.x`；
- Windows 的 NAS 共享路径；
- 带方括号、圆括号的 Markdown 链接。

配对成功后，连接列表应显示 NAS 服务名和 NAS 地址。viewer token 不要复制到聊天、文档或截图。

## 11. 常见故障

### Docker socket 权限不足

```text
permission denied while trying to connect to /var/run/docker.sock
```

不要修改 Docker socket 权限，也不要把普通用户加入 Docker 用户组。使用管理员身份构建：

```bash
sudo -H docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.media.yml \
  build --pull=false
```

### Docker CLI 无法创建用户 Home 目录

```text
mkdir /home/<用户>: permission denied
```

这是 Docker CLI 配置目录不可写，不是项目源码错误。仅在没有 `sudo` 的临时构建场景下，创建专用临时配置目录：

```bash
mkdir -p /tmp/mujing-docker-config

HOME=/tmp DOCKER_CONFIG=/tmp/mujing-docker-config \
docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.media.yml \
  build --pull=false
```

`/tmp/mujing-docker-config` 是本项目唯一建议创建的临时目录；正式部署前可由管理员删除该**精确目录**，不要删除整个 `/tmp`。它不包含项目数据、媒体、SQLite、海报、轮播图或 `.env`。

### NAS 宿主机没有 `dart`

```text
dart: command not found
```

这是预期行为。Dart SDK 只存在于 Dockerfile 的构建阶段；用上面的 `docker compose ... build --pull=false` 编译验证，不在 NAS 宿主机运行 `dart format`、`dart analyze` 或 `dart run test`。

### `sqlite3` Dart 包找不到

```text
Couldn't resolve the package 'sqlite3'
```

确认 Dockerfile 已复制 `pubspec.lock`、执行 `dart pub get`，并使用 Dart 3.13.2 SDK。

### `libsqlite3.so` 找不到

```text
Failed to load dynamic library 'libsqlite3.so'
```

确认 Debian 运行阶段安装了 `libsqlite3-dev`。修改后必须重新 `build`，仅重启旧容器无效。

### `isAvailable=false`

依次检查：

1. fixture 是否为相对路径；
2. 是否使用了 `docker-compose.media.yml`；
3. `/media` 是否存在且为 `RW=false`；
4. 容器用户是否能读取测试文件；
5. 修改 `.env` 后是否重新创建容器。

### 修改 `.env` 后没有生效

运行中的容器不会自动读取新 `.env`，需要 `--force-recreate`。若已启用媒体，必须同时带上媒体覆盖文件。

### NAS 接口突然不响应

先停止 Android 播放重试，再检查：

```bash
sudo docker compose ps
sudo docker stats --no-stream mujing-nas
sudo docker logs --tail=100 mujing-nas
```

必要时重启容器，`restart` 不会删除 `data`：

```bash
sudo docker compose \
  --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.media.yml \
  restart
```

## 12. 升级和备份

升级前：

1. 停止正在播放的客户端；
2. 备份工程目录中的 `data`；
3. 备份 `.env`，但不要提交它；
4. 更新源码；
5. 重新构建并使用原来的 `.env`、`data` 启动；
6. 确认 `serverId`、SQLite、海报和配对状态保持。

禁止提交：

```text
.env
data/
真实视频
真实数据库
配对码
access token
```

## 13. 最终验收清单

```text
[ ] 容器为 healthy
[ ] /health 返回 200
[ ] 局域网电脑能访问 NAS endpoint
[ ] serverId 在容器重建后保持
[ ] viewer 配对成功，viewer 不能访问 admin API
[ ] /data 为 RW=true
[ ] /media 为 RW=false
[ ] 影片列表、详情、标签和海报正常
[ ] 真实测试视频 isAvailable=true
[ ] Range 200/206/416 与 HEAD 正常
[ ] Android 保存的是 NAS 连接而不是 Windows 连接
[ ] 未公开或提交配对码、token、数据库和绝对媒体路径
```
