# Lumia 开发文档（DEVELOPMENT）

Lumia 的软件端「本地大脑 + 桌面外壳」实现。硬件端约定见
[HARDWARE_PROTOCOL.md](../HARDWARE_PROTOCOL.md)，产品 idea 见 [IDEA.md](../IDEA.md)。

本实现覆盖 4 个目标：

1. **限制开发时长**：每日额度 `n + k*m` 小时，用尽后支持一次延时（当日未用即可用）；
   延时后当日硬停；每周内每用一次延时，`k` 衰减为 `0.8*k`（周一重置）。
2. **接收「突发奇想」**：T5AI-Core 语音 / 文本经 Orange Pi 3B 转发到服务端落库。
3. **时长耗尽后展示今日成绩**：扫描本地 git 仓库并可绑定 GitHub 账号拉取当日全部 commits（成就墙）。
4. **定时提醒**：吃饭 / 睡觉 / 喝水 / 活动；联动久坐传感 + 清闲椅拉伸。弹窗不抢焦点，
   平时缩在系统托盘，托盘右键进入设置。

---

## 1. 架构总览

```
                        localhost HTTP (:8787)
  ┌───────────────┐   ┌──────────────────────────┐   ┌────────────────────┐
  │  硬件端        │──▶│  Python 本地大脑 (FastAPI) │◀──│  Electron 桌面外壳  │
  │  T5AI / 久坐   │   │  • 时长引擎 (n+k*m/延时)   │   │  • 系统托盘         │
  │  / 椅子继电器  │◀──│  • 提醒调度 + 久坐检测     │──▶│  • 非抢焦点弹窗     │
  └───────────────┘   │  • 灵感落库 / 成就墙       │   │  • 设置(空白)/成就墙 │
                      │  • JSON 存储 + 事件总线   │   └────────────────────┘
                      └──────────────────────────┘
```

- **后端（`backend/`，Python）**：唯一真相源。两个后台循环——1s 的开发计时器、30s 的
  提醒调度器——加一组 REST 接口。状态落 JSON 文件。
- **前端（`electron/`，Electron）**：只做展示与交互。轮询 `/api/events/poll` 拿事件后弹窗，
  托盘菜单发起动作。不含业务判定。
- 两端通过 `127.0.0.1:8787` 通信，前端与硬件端用的是**同一套** HTTP 接口。

---

## 2. 目录结构

```
Lumia_works/
├── backend/
│   ├── lumia/
│   │   ├── app.py          # FastAPI 应用 + 后台循环 + 路由
│   │   ├── config.py       # config.json 读写（线程安全，深合并）
│   │   ├── db.py           # JSON 存储封装
│   │   ├── events.py       # 内存事件总线（供前端轮询）
│   │   ├── activity.py     # 前台进程 + 空闲检测（Windows ctypes，跨平台降级）
│   │   ├── coding.py       # 开发时长引擎（额度/延时/周衰减）★核心
│   │   ├── reminders.py    # 提醒调度 + 久坐检测 + 触发椅子
│   │   ├── chair.py        # 椅子继电器（simulate/relay）
│   │   ├── ideas.py        # 灵感文本/音频落库
│   │   └── gitstats.py     # 今日 commits 成就墙
│   ├── scripts/mock_hardware.py  # 无硬件时模拟上报
│   ├── config.example.json # 默认配置模板（首次运行复制成 config.json）
│   ├── requirements.txt
│   └── run.py              # 入口：python run.py
├── pet/                    # Lumia 桌宠（PyQt6，仅在 Ubuntu 上运行，独立进程，详见 pet/README.md）
├── electron/
│   ├── main.js             # 主进程：托盘 / 弹窗 / 轮询 / 可选拉起后端
│   ├── preload.js          # contextBridge：window.lumia
│   ├── popup.html          # 非抢焦点提醒卡片
│   ├── achievements.html   # 成就墙窗口
│   ├── settings.html       # 设置窗口（当前留空占位）
│   ├── config.json         # 前端配置（后端地址/弹窗位置/轮询间隔）
│   └── package.json
└── docs/DEVELOPMENT.md
```

---

## 3. 快速开始

### 3.1 启动后端

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe run.py        # 监听 http://127.0.0.1:8787
```

首次运行会把 `config.example.json` 复制为 `config.json`（后续只改后者）。

### 3.2 启动桌面外壳

```powershell
cd electron
npm install
npm start
```

启动后程序缩在系统托盘（右键：查看状态 / 成就墙 / 请求延时 / 设置 / 退出）。

> 想让 Electron 自动拉起后端：把 `electron/config.json` 里 `backend.spawn` 设为 `true`。

### 3.3 无硬件自测

```powershell
cd backend
.\.venv\Scripts\python.exe scripts/mock_hardware.py idea "重构 event bus"
.\.venv\Scripts\python.exe scripts/mock_hardware.py sit --seated --pressure 0.8
.\.venv\Scripts\python.exe scripts/mock_hardware.py stretch
.\.venv\Scripts\python.exe scripts/mock_hardware.py delay
.\.venv\Scripts\python.exe scripts/mock_hardware.py state
```

---

## 4. 开发时长引擎（core，`coding.py`）

### 4.1 每日额度

```
allowed_hours = n + k_eff * m
    n      = coding.daily_fixed_hours   每日固定额度（h）
    m      = coding.sleep_hours          睡眠时长（h）
    k_eff  = coding.conversion_k * 0.8 ** (本周今天之前已用延时的天数)
```

- 默认 `n=4, k=0.5, m=7` → 额度 `4 + 0.5*7 = 7.5h = 27000s`。
- **周衰减**：ISO 周（周一为起点）内，今天**之前**每有一天用过延时，`k` 就多乘一次 0.8；
  跨周自动清零（只统计本周的延时记录）。

### 4.2 「正在开发」如何判定

`activity.is_coding()` 每秒判定一次，同时满足才计入：
- 前台窗口所属**进程名**在 `coding.dev_processes` 列表内；
- 距上次键鼠输入 < `coding.idle_threshold_seconds`（默认 60s，避免挂机计时）。

Windows 下用纯 `ctypes`（`GetForegroundWindow` / `QueryFullProcessImageNameW` /
`GetLastInputInfo`），无额外依赖；Linux(X11) 下用 `xprop` 取前台窗口 PID 后读
`/proc/<pid>/comm`，空闲时间用 `xprintidle`（需安装 `xprop` / `xprintidle`，
缺失时降级为「不计时」）；Wayland 及其他平台降级为「不计时」。

### 4.3 状态机

| 状态 | 含义 | 触发事件 |
|------|------|----------|
| `idle` / `coding` | 额度内，是否正在敲 | — |
| `limit_reached` | 额度用尽且可延时 | `coding_limit`（弹窗带「延时」按钮）|
| `delay_active` | 延时进行中 | `coding_delay_started` |
| `day_locked` | 延时用尽 / 无法延时 → 当日硬停 | `coding_locked`（弹窗带「成就墙」）|

- 延时把 `allowed_effective = allowed + delay_minutes`，并记 `delay_ends_at = now + delay_minutes`；
  到点或额度耗尽即 `day_locked`，并持久化 `locked=1`（重启当天仍锁定）。
- **每日一次**：`delay_available` 仅要求「今天未用」。
- 前端锁定页双重触发：事件边沿（`coding_limit`/`coding_locked`）+ 每秒对照 `/api/state` 电平补开（防强制关闭锁定窗），
  后端重启导致事件 id 回退时自动重同步水位。

> 说明：延时既是「最后 60~90 分钟收尾」，也是「今天到此为止」的信号——用完即当日硬停，
> 对应产品规则第 3 条。`delay_minutes` 可在配置里设为 60~90。

---

## 5. 提醒与久坐（`reminders.py`）

- **时钟提醒**：`sleep_time`（单个）与 `meals`（多个）在目标时刻后 2 分钟窗口内**每日触发一次**。
- **间隔提醒**：`water_interval_min` / `move_interval_min`，每 N 分钟触发。
- **久坐检测**：`/api/sit` 上报驱动。连续就座 ≥ `sit.sedentary_minutes` 触发久坐提醒，
  同时按 `chair.mode` 请求椅子拉伸；`sit.renudge_minutes` 内不重复打扰；`seated=false` 清零计时。

所有提醒写入 `reminders_log`，并通过事件总线推给前端弹窗。

---

## 6. HTTP 接口

| 方法 | 路径 | 调用方 | 说明 |
|------|------|--------|------|
| GET  | `/api/health` | 任意 | 健康检查 |
| GET  | `/api/state` | 前端 | 开发时长 + 久坐快照 + `latest_event_id` |
| POST | `/api/coding/delay` | 前端 | 请求延时，返回 `{ok, ends_at, minutes}` 或 `{ok:false, reason}` |
| GET  | `/api/events/poll?after=<id>` | 前端 | 拉取 `id > after` 的事件（弹窗数据源）|
| POST | `/api/capture/text` | 灵感盒/T5AI | `{"text": "...", "source": "..."}` |
| POST | `/api/capture/audio` | 灵感盒/T5AI | multipart 字段 `file` |
| GET  | `/api/ideas?limit=N` | 前端 | 最近灵感列表 |
| POST | `/api/sit` | 久坐传感 | `{"seated": bool, "pressure": 0..1}` |
| POST | `/api/chair/stretch` | 前端/本地 | `{"source": "..."}` → 转发继电器或模拟 |
| GET  | `/api/achievements/today` | 前端 | 今日开发者参与的全部 commits（作者/提交者/Co-authored-by 任一匹配；本地仓库 + GitHub 双查询合并去重，时间倒序）；支持 `offset`/`limit` 分页，身份反查仅对当前页执行 |
| POST | `/api/github/auth/start` | 前端 | 发起 Device Flow 授权，返回一次性代码与验证页地址 |
| POST | `/api/github/auth/poll` | 前端 | 轮询授权结果，成功后自动写入用户名与令牌 |
| GET / PUT | `/api/config` | 前端 | 读取 / 深合并更新配置 |

`/api/capture/*`、`/api/sit`、`/api/chair/stretch` 与
[HARDWARE_PROTOCOL.md](../HARDWARE_PROTOCOL.md) 中固件所需端点一致，硬件可直接对接。

### 事件对象

```jsonc
{
  "id": 12, "ts": "2026-07-24T01:35:10", "type": "coding_limit",
  "title": "今日开发时长已用尽", "message": "……",
  "actions": [ {"id": "delay", "label": "延时 60 分钟"} ],
  "data": {}
}
```

前端启动时先读 `/api/state.latest_event_id` 作为起点，避免回放历史事件。

---

## 7. 配置项（`backend/config.json`）

| 键 | 默认 | 说明 |
|----|------|------|
| `coding.daily_fixed_hours` `n` | 4.0 | 每日固定额度（h）|
| `coding.conversion_k` `k` | 0.5 | 睡眠转化系数（基准）|
| `coding.sleep_hours` `m` | 7.0 | 睡眠时长（h）|
| `coding.delay_minutes` | 60 | 延时时长（60~90）|
| `coding.idle_threshold_seconds` | 60 | 空闲超过则不计时 |
| `coding.dev_processes` | 见模板 | 计入开发时长的进程名（不区分大小写）|
| `reminders.sleep_time` | "01:30" | 睡觉提醒时刻 |
| `reminders.meals` | ["12:00","19:00"] | 吃饭提醒时刻（多个）|
| `reminders.water_interval_min` / `move_interval_min` | 60 / 45 | 喝水 / 活动间隔 |
| `sit.sedentary_minutes` / `renudge_minutes` | 45 / 20 | 久坐阈值 / 重复提醒间隔 |
| `chair.mode` | "simulate" | `simulate` 仅日志；`relay` 转发到继电器 |
| `chair.relay_url` | — | 继电器 `:8790/stretch` 地址 |
| `git.repos` | [] | 成就墙扫描的本地仓库路径列表 |
| `git.github_client_id` | "" | GitHub OAuth App 的 Client ID，网页授权（Device Flow）用 |
| `git.github_username` | "" | 绑定 GitHub 账号，拉取当天全部 commits 并去重合并（授权后自动写入） |
| `git.github_token` | "" | 授权后自动写入，也可手填 PAT；访问私有仓库 commits 需要 |
| `server.host` / `port` | 127.0.0.1 / 8787 | 监听地址 |

`m`（睡眠时长）当前由配置提供；未来可由 T5AI/可穿戴接入后自动写入。

---

## 8. 前端要点（`electron/`）

- **不抢焦点弹窗**：`BrowserWindow({ focusable:false, skipTaskbar:true, alwaysOnTop:true, show:false })`
  → `win.showInactive()`，定位在主屏工作区右下角。多事件排队逐一显示，12s 自动消失。
- **托盘图标**：用 `nativeImage.createFromBitmap` 现场生成 16×16 BGRA，无需二进制素材。
- **设置窗口**：`settings.html` 目前是空白占位，仅验证「托盘 → 设置」打开流程。
- **可选拉起后端**：`config.json.backend.spawn=true` 时由主进程 `spawn` Python，退出时回收。
- **Linux 适配**：启动时强制 `ozone-platform-hint=x11`（Wayland 下走 XWayland，否则浮窗
  `setBounds` 定位不可用），并开启 `enable-transparent-visuals` + 禁用硬件加速以兼容
  透明窗口；托盘需要 libappindicator。

---

## 9. 数据存储（JSON，`backend/lumia.json`）

单文件 JSON，写入时先写临时文件再原子替换防损坏。顶层键：
`coding_daily`（按日期索引的每日用量/延时/锁定/保存缓冲）、`delay_log`（延时历史，驱动周衰减）、
`ideas`（灵感）、`sit_events`（就座事件）、`reminders_log`（提醒记录）、`seq`（各表自增 id 计数）。

---

## 10. 已知边界 / 后续可扩展

- Linux 仅支持 X11/XWayland：计时依赖 `xprop` + `xprintidle`，纯 Wayland 下拿不到
  前台窗口，降级为不计时；`/proc/<pid>/comm` 进程名截断为 15 字符，配置
  `dev_processes` 时需注意。
- `m` 睡眠时长目前手填；可接 T5AI/手环自动采集。
- 成就墙的 "builds" 暂未统计（当前只列 commits）；可接 CI/构建日志。
- 音频灵感仅落盘保存，未做转写；可挂本地 whisper。
- 手动「请求延时」严格校验：未达今日上限或当日已用过延时均拒绝（一天仅一次）。
- 设置界面留空，后续对接 `/api/config` 即可做成可视化配置。
