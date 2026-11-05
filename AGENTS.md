<!-- >>> TapTap Maker managed AGENTS policy version=4 hash=sha256:292e303c2bfe80f05a0c94db323f6ec3b8700639d02c0aa7838f5f5c0cc1633b >>> -->
# TapTap Maker Project Asset Tool Policy

This is a bound TapTap Maker project.
Do not use TapTap Developer Center documentation or docs for other TapTap game platforms
when developing or debugging this Maker game; use Maker MCP and the project-local
`AGENTS.md`, `engine-docs/`, `examples/`, `templates/`, `urhox-libs/`, and installed Maker
skills as the sources of truth.

TapTap Maker routing index:
- Start/resume/status: maker://status; fallback maker_status_lite.
- Build/remote Web preview/submit/push: check status, use maker_build_current_directory.
- Local preview: taptap-maker preview --target-dir; no commit/remote build.
  Requested preview iteration only: status, refresh live game edits. Never revive stopped sessions.
- 打开make mcp控制台: active distribution CLI `console open --target-dir <project> --json`; no web search.
  run-lua-validate: preview validate via taptap-maker-local; network/server projects use --network.
- Ads: read maker://ads-integration-guide before any ad-related work.
- Tap flows: test QR -> generate_test_qrcode.
- Assets: image, video, music, sound-effect, voice, 3D tools when exposed.
- Canvas capabilities/custom workflows/video: active CLI canvas capabilities; follow the canvas.md link in taptap-maker-local.
  For first/last-frame video follow its canvas-video.md link; inspect current mode before setting references.
- Canvas templates (UI/切图/动画/角色/道具/3D): active CLI canvas templates --target-dir PATH --q "keyword".
  Search names/descriptions before declaring a workflow unsupported; read only matching descriptions and Skills.
- 游戏UI/设计稿还原/切图/拼装UI.json: read maker-ui-workflow (path in status).
- Bbox预排/uiAtlasPrelayout: read maker-ui-bbox-workflow; keep reference chain.
- Lua UI提取/转JSON/UI.json检查: read lua-ui-to-json (path in status); preserve gameplay and edits.
  Existing UI edits do not restart generation.
- Resource .meta/UUID: generate_resource_meta; call when needed, never invent UUIDs.
- MCP/proxy infrastructure failure: diagnose, ask once for user consent, then use the
  active client's exact Maker command/args with `mcp report`; never use an unversioned npm package. Do not report expected project or business errors.
Read matched references only. Follow schema and next_action.

Maker build workflow:

- For explicit remote requests such as 构建, build, 远端 Web 预览,
  提交, 提交代码, 推送, or push, call `maker_build_current_directory`.
- Do not tell the user to open the Maker web page and click a build button as the default flow.
- Do not use generic Git commit, push, branch, PR, or MR workflows for Maker submit/build
  requests. Follow the result returned by `maker_build_current_directory`.

Generic code checks such as 验证代码, 跑测试, lint, or 检查实现 should not trigger a Maker
remote build unless the user explicitly requests the remote build workflow.
- Local preview uses taptap-maker preview with an explicit --target-dir and never commits or
  remotely builds. Read the taptap-maker-local Skill Local Window Preview workflow.
- During a requested local-preview iteration, check status after changes to the running game.
  If process_alive=true, refresh and collect logs/check once. Skip documentation-only edits
  and work outside that preview task; do not poll after every general code edit.
- Refresh restarts the window and loses memory state. Stopped/missing/unverified sessions must
  not be started automatically. Stop/cancel takes priority over queued refreshes.
- Clarify bare preview/run intent when local vs remote is ambiguous; never silently commit.
- Compare current evidence to explicit expectations; read the image before visual judgment.
  Missing evidence is UNDETERMINED. Only modify with authorization, at most two automatic fixes.
- Preview, build, test, and local-development intent must never select or change the service
  environment. Do not add environment parameters to Maker tool calls or user MCP config;
  use the default Maker service configuration.

Maker MCP connection recovery:

- If tools are missing, the process exits immediately, or the client reports `-32000`,
  `Connection closed`, or `command not found`, do not depend on Maker MCP tools for initial
  diagnosis. Work from local config, shell output, and client logs.
- Current Maker MCP registers whitelisted proxy tool definitions before resolving cwd, project
  binding, auth, or the remote proxy. If only proxy tools are missing, compare the active
  package version and tools/list for stale client/session caching; do not rewrite cwd.
- Attempt `taptap-maker mcp verify --json`. It verifies the stable self runtime by default;
  use `--mode npx` only when the npm launch path itself needs diagnosis. Record command failure
  as diagnostic evidence instead of skipping the check.
- If `taptap-maker` is not on PATH, reuse that config's absolute command and ordered args,
  append `mcp verify --json`, and run the same argv directly.
- This uses the same stable launcher as MCP install and completes MCP
  initialize and tools/list, and returns launcher_kind, command, stage, tools, stderr, error,
  and failure_type. It does not read the client's active config or validate client trust,
  client config caching, or Roots.
- In explicit npx mode, EPERM/EACCES or an unwritable npm cache is
  `npm_environment_error`; prefer `mcp install --launcher self` instead of blindly changing
  `~/.npm` ownership.
- First identify the active AI client from reliable evidence, then inspect only that client's
  active config path, command, ordered args, cwd, workspace/Roots, Node/npm/npx paths,
  client PATH, exit status, and stderr.
- Only when the active client is confirmed to be WorkBuddy, inspect its enable/trust state.
- Never use one client's configuration or trust state to diagnose another client.
- Classify the root cause from evidence before repairing it. Do not automatically change trust
  storage, PATH, cwd, credentials, or game code.
- Treat `taptap-maker mcp install --ide <client>` as an optional recovery only after evidence
  confirms that the active config entry is damaged.
- Never repair cwd by wrapping the command with `cd /d "<project>" && npx.cmd ...`.
  Maker supports Chinese project paths; command-shell quoting or client startup can fail
  independently of the project path.
- User-level MCP config must not contain a project cwd. If WorkBuddy or DSH does not expose Roots,
  pass target_dir on the concrete Maker tool call and record the process actual cwd only as
  diagnostic evidence.
- If cwd fallback is not a bound Maker project, project-related proxy calls fail before remote
  access and report evaluated_target_dir plus project_context_source. Fix Roots or pass the
  correct target_dir; do not treat another directory as the project status.
- Do not assume Windows 8.3 short paths exist or differ from the original long path. Verify
  the result first; an unchanged or missing short path is not a usable cwd workaround.
- Reproduce the configured Windows launch with the same direct argv boundary when possible.
  Separate outer shell quoting or stderr decoding failures from the MCP child process result,
  and record both without treating wrapper failures as server evidence.
- AI conversations share user-level MCP config. Back up the active config before any repair,
  then reconnect and verify in both the current and a new conversation.
- If the MCP connection is established but a tool or resource call fails, including `-32003`,
  use a separate evidence-first runtime-error workflow. Do not assign a fixed meaning to the
  error code; preserve the exact client error.
- `mcp verify` is not the primary check for an already connected session because it tests only
  the local launcher and stdio MCP path.
- Collect the failed tool/resource, redacted request parameters, current `tools/list`, exact
  error code/message/data, complete sanitized `remote_result`, request/correlation IDs,
  timestamp with timezone, OS/architecture, AI client and `@taptap/maker` package versions,
  and stable reproduction steps. Preserve useful nested fields while removing credentials.
- Python and maker-lua-lsp affect local Lua diagnostics, not MCP connection or remote build.
- Dev-kit, package update, and AGENTS policy checks are maintenance checks, not proof of a
  client connection failure.
- Do not rewrite command, cwd, PATH, trust state, credentials, or game code unless the
  collected evidence identifies that cause.

Maker MCP issue reporting:

- Offer a report only for likely MCP, proxy, client integration, or service defects such as
  startup/connection failure, unexpected missing tools, timeouts, repeated reconnect failure,
  HTTP 5xx/unavailable responses, or unclassified internal server errors.
- Do not report expected user or project errors such as invalid parameters, missing files,
  documented auth recovery, user cancellation, project compile errors, or business validation.
- Ask the user once before submitting each distinct failure fingerprint. If the user declines,
  do not ask again for that fingerprint in the current conversation.
- Only after the user explicitly agrees, send a compact sanitized context JSON through stdin.
- Prefer the active client's exact Maker MCP command and ordered args, then append
  `mcp report --ide <client> --target-dir <project> --context-stdin --consent --json`.
- This preserves the configured package version and the absolute Windows node.exe/npm-cli.js.
- Only with a known exact installed version, fallback to
  `npx -y --package @taptap/maker@0.0.40 taptap-maker mcp report ...`.
- Never use an unversioned npm package, or assume `taptap-maker`/`npx` is globally available.
- Never include the complete conversation, project source, other MCP server entries, PAT/token
  values, or full environment variables. Normalize the user home path to `~`.
- A `manual_required` result means GitHub submission was unavailable. Show the sanitized report
  and manual Issue URL, then continue troubleshooting without treating reporting as a failure.

Maker ad workflow:

- For any ad-related request or code touching ads, first read
  `maker://ads-integration-guide`, then follow it to inspect Maker project status, call
  `get_ad_config`, verify remote/local configuration, and read the project engine document before
  editing or testing ads. Triggers include 广告, 激励视频,
  播放广告, ad ID, ad placement, ad status, ad config, and `ShowRewardVideoAd`.
- Treat `get_ad_config` as the source of truth for current project ad activation status and
  ad config. Do not infer ad readiness from local SDK docs, `.maker-mcp/config.json`, or
  runtime callbacks.
- Keep the same explicit `target_dir` throughout. Remote success does not update local settings;
  follow the guide before proceeding if local `@runtime.ad` is missing or differs.
- If primary local project configs are missing, keep ad config unavailable and do not call the
  remote tool. Build only for an explicit user build/submit/remote Web preview request. If a successful
  build still leaves local configs missing, explain the known limitation and do not rebuild
  automatically. Implement or test ad code only after the config is available.
- Local window preview uses CLI and does not authorize commit or push.
- If `get_ad_config` reports missing `app_id` or `developer_id`, call
  `generate_test_qrcode` once to generate test QR code metadata, then call `get_ad_config`
  again. Do not use publish-only tools for this recovery path.

Maker MCP provides the following game asset generation and editing tools when they are
exposed in the current session:

- First read `taptap-maker canvas model-settings`; follow the selected generation/vision provider.
- Local uses the current client capability, custom uses canvas run, and maker uses the tools below.
- Never silently switch providers. canvas import adds client output as a new card, not a completed template step.
- `generate_image` for one image asset when generation=maker.
- `batch_generate_images` for multiple image assets.
- `edit_image` for modifying existing project images.
- `create_video_task` for game video assets or referenced image/video generation.
- Only call `create_video_task` after the user explicitly requests video generation; do not
  generate video proactively while implementing gameplay or filling asset gaps.
- Estimate video cost as duration times 200 credits per second for `model="2.0"`, 300 for
  `model="2.5"`, and for `model="wan"` 42 at 480p, 84 at 720p, and 168 at 1080p.
  When resolution is omitted, wan is billed as 1080p, so use 168 credits per second. If duration
  is omitted or `duration=-1`,
  estimate at the model maximum. When the estimate exceeds 1000 credits, show the estimate,
  say actual billing is determined at generation, wait for explicit confirmation, then repeat
  the same request with `user_confirmed=true`. Do not pass `user_confirmed=true` before
  confirmation or at or below 1000 credits.
- `query_video_task` for refreshing video task status and fetching completed videos.
- `text_to_music` for game music.
- `text_to_sound_effect` for one sound effect.
- `batch_sound_effects` for multiple sound effects.
- `text_to_dialogue` for final character dialogue.
- `text_to_dialogue` reuses confirmed local ElevenLabs voice mappings. After confirmation, pass only `character_name` and `text`.
- For ElevenLabs auditions, pass a detailed `character_description` and an `audition_line` of at least 100 characters. `candidate_count` is optional and accepts 1 to 3.
- After `audition_voices_for_character` returns previews, show them to the user and wait
  for the user to choose. Do not select or confirm a voice automatically.
- Call `confirm_character_voice` only after the user explicitly chooses one preview.
- Generated sound effects and dialogue are saved in the project.
- Voice audition previews are not saved to the project.
- Local MCP does not transcode generated audio to OGG.
- `create_3d_asset` for the complete 3D lifecycle: start, query, explicit review continuation,
  option inspection, and post-processing.
- Never automatically continue a 3D review step. Show returned previews and wait for explicit
  user approval before calling `create_3d_asset` with `action="continue"`.
- Follow the selected tool schema when one of these tools is used.

Follow each Maker tool schema for supported local path, remote URL, and data URL inputs.
If the user references attached/local media, inspect the attachment or workspace file path
before calling the tool. Local proxy may convert resolvable local reference media to data URLs
before forwarding to the remote Maker MCP server.

Generated Maker proxy assets should stay in the Maker project asset workflow under
`assets/image`, `assets/video`, `assets/audio`, or `assets/model`, with remote mappings
preserved for later edits and builds.
`create_3d_asset` local runtime `model_files` copy/extract instructions are materialized into
`assets/model`. Use `local_delivery` for the usable local model path and preserve the remote result.
<!-- <<< TapTap Maker managed AGENTS policy <<< -->


# UrhoX Lua - AI 开发指南入口

> **面向 AI Coding Agent 的文档导航中心**（Claude Code / Codex / OpenCode / Cursor / Gemini CLI 等）
>
> 这不是完整文档，而是告诉你**如何使用文档库**的指南。

---

## 🔒 引擎知识目录（分析项目时忽略）

以下目录是**引擎知识和工具**，不是用户编写的代码。当用户请求"分析项目"、"review 代码"、"检查我的代码"时，**应该忽略这些目录**：

| 引擎目录 | 用途 | 何时需要阅读 |
|---------|------|-------------|
| `engine-docs/` | 引擎 API 文档 | 用户询问 API 用法时 |
| `editor-docs/` | UrhoXEditor：写编辑器脚本、按需操作/验收编辑器 | 任务是编辑器脚本或操作当前编辑器时 |
| `examples/` | 示例代码 | 用户需要参考实现时 |
| `templates/` | 项目脚手架 | 创建新项目时 |
| `urhox-libs/` | 引擎工具库 | 用户代码引用这些库时 |
| `schemas/` | 配置/结构定义 | 需要验证配置格式时 |
| `.emmylua/` | LSP 类型定义 | 自动加载，通常不需手动阅读 |
| `skills/` | Agent skills 源（跨 Claude/Codex/Cursor/Gemini 通用） | agent 自动 discover，通常不需手动阅读 |
| `tools/` | 开发者工具（跨 agent skill 安装器等） | 内部开发用途 |
| `.claude/`, `.codex/`, `.cursor/`, `.gemini/` | 各 agent 的 skill 发现目录（junction → `skills/`） | 由 install-skills 生成，不需手动阅读 |
| `.project/` | 引擎生成的项目配置 | 通常不需阅读 |
| `.tmp/` | 临时文件 | 不需阅读 |
| `.build/` | 构建产物 | 不需阅读 |
| `dist/` | 发布产物 | 不需阅读 |

**用户代码在 `scripts/` 目录**（以及用户自己创建的其他目录如 `docs/`、`memory/`）。工程内任意 `Editor/` 目录是编辑器脚本，不是 Runtime 玩法；分析玩法时不要当成游戏入口。

### ⚠️ 关键规则

当用户说"分析项目"、"看看我的代码"、"帮我 review" 时：
- ✅ 聚焦于 `scripts/` 和用户自己创建的目录
- ❌ 忽略上述引擎知识目录

---

## ⭐ 首先阅读

**开始任何开发前，必须先阅读**：
1. **[lua-scripting-guide.md](engine-docs/lua-scripting-guide.md)** - Lua 开发指南（必读！）
2. **至少 3 个相关示例** - 从 [examples/api-index.md](examples/api-index.md) 查找

---

## 📖 文档阅读规则

### 原则 #1: 先查文档，再写代码

**不要凭记忆或猜测**，遵循以下流程：

```
收到任务
  ↓
查看下方"任务类型 → 文档映射"
  ↓
阅读对应文档（完整阅读，不要跳过）
  ↓
编写代码
  ↓
遇到问题 → 查阅对应文档（见下方"问题诊断"）
```

### 原则 #2: 完整阅读，不要只看标题

- ✅ 阅读文档的完整章节，包括示例代码
- ✅ 特别注意 ⚠️ 标记的陷阱和规则
- ❌ 不要只看 API 签名就开始写代码
- ❌ 不要假设"和标准 Urho3D 一样"

### 原则 #3: 遇到错误，立即查文档

每次遇到编译/运行时错误：
1. 先查 `lua-scripting-guide.md` 的"常见错误信息速查"章节
2. 如果是 API 使用问题，查 `api/` 对应模块
3. 如果问题已解决但文档未记录，建议用户补充到文档

---

## 🎯 核心规则（必须遵守）

### 规则 #0: 长度单位是米 📏

**UrhoX 引擎的长度单位是米（meter）**

- 所有坐标、距离、模型尺寸：单位是米
- 典型尺度：角色高度 1.5-2.0 米，跳跃初速度 7.0 米/秒，移动速度 5.0 米/秒

### 规则 #0.5: 坐标系（与 Unity 相同）🧭

**UrhoX 使用 Y-up 左手坐标系，与 Unity 相同**：

- **Y 轴向上** (UP)，**X 轴向右** (RIGHT)，**Z 轴向前** (FORWARD)
- Yaw（偏航）绕 Y 轴旋转（左右转头），Pitch（俯仰）绕 X 轴旋转（抬头低头）

```lua
-- 方向常量
Vector3.UP      -- (0, 1, 0)  向上
Vector3.FORWARD -- (0, 0, 1)  向前
Vector3.RIGHT   -- (1, 0, 0)  向右

-- 典型用法
node.position = Vector3(0, 5, 10)  -- 上方5米，前方10米
Quaternion(yaw, Vector3.UP)        -- 水平旋转（左右转）
Quaternion(pitch, Vector3.RIGHT)   -- 垂直旋转（抬头低头）
```

### 规则 #0.8: 分辨率模式与布局适配 🔴

**`graphics:SetMode()` 已禁用**，使用以下 API 获取屏幕信息：

```lua
local physW, physH = graphics:GetWidth(), graphics:GetHeight()  -- 物理分辨率
local dpr = graphics:GetDPR()                                   -- 设备像素比（1.0/2.0/3.0）
local logicalW, logicalH = physW / dpr, physH / dpr             -- 系统逻辑分辨率
```

**分辨率模式选择**：
| 场景 | 推荐模式 | 推荐布局 |
|------|---------|---------|
| **明确**了设计分辨率（如 1080P、1920×1080） | 模式 A（设计分辨率） | 绝对布局 / 响应式 |
| 未明确设计分辨率（**默认**） | 模式 B（系统逻辑分辨率） | 响应式 |
| ⚠️ 强烈不建议 | 模式 C（物理分辨率） | 响应式 | 高 DPI 屏 UI 过小 |

**NanoVG 分辨率模式编写范式 → nvg-resolution-mode skill**
- SKIP when：项目没有任何 raw NanoVG 调用（纯 UI 组件项目、纯 3D + UI HUD）
- MUST trigger when：项目包含 raw NanoVG 调用（`nvgCreate`/`nvgBeginFrame`），无论是否同时使用 UI 组件
- 详见 `nvg-resolution-mode` skill

**高层封装**：`urhox-libs/UI`（详见 `examples/14-ui-widgets-gallery.lua`）

**记住**: `graphics:SetMode()` 无效 → 用 `graphics:GetWidth(), graphics:GetHeight(), graphics:GetDPR()`

### 规则 #1: 代码存放和依赖引用 ⚠️

**代码存放**（工作目录即项目根，不要在其与 `scripts/` 之间插入额外层级）：
```
项目根/                # = 你的工作目录（路径里无需写出它）
├── scripts/           # ✅ AI 生成的用户代码放这里
├── assets/            # ✅ 资源文件（纹理、声音等）
└── urhox-libs/        # 🔒 只读！仅供参考，禁止修改（见下方说明）
```

**维护构建资产忽略规则**：将资产目录下的运行时无关目录追加忽略规则，应避免逐文件添加。详见 [构建资产忽略](engine-docs/recipes/preload-and-build-refs.md#构建资产忽略)。

> **⚠️ 为什么 urhox-libs/ 是只读的？**
> 这个目录是引擎工具库的**参考副本**，仅供 AI 阅读和理解 API 用法。
> 实际运行时使用的是引擎内置的另一份 urhox-libs，**不是这一份**。
> 因此修改这里的文件**不会生效**，也不会影响运行结果。
> 
> - 阅读 urhox-libs 的代码来理解 API 和用法
> - 在 `scripts/` 中编写自己的代码来调用 urhox-libs 提供的功能

**依赖引用**：
```lua
-- ✅ 推荐：引用 urhox-libs/ 库（模块化、跨平台）
local PlatformUtils = require "urhox-libs.Platform.PlatformUtils"
local InputManager = require "urhox-libs.Platform.InputManager"

-- ✅ 引用自己的模块（位于 scripts/ 目录下）
require "main"              -- scripts/main.lua
require "Utils.Helper"      -- scripts/Utils/Helper.lua

-- ⚠️ 兼容：旧的引擎库（可用，但不推荐）
require "LuaScripts/Utilities/Sample"
```

### 规则 #1.5: 资源路径引用 📁

`scripts/`、`assets/` 都被配置为资源根目录。引用这里面的文件时**直接从下一级开始**，不需要加目录名：

```lua
--   assets/
--   ├── Textures/
--   │   └── player.png
--   └── Sounds/
--       └── jump.ogg
-- ✅ 正确
local texture = cache:GetResource("Texture2D", "Textures/player.png")         -- assets/Textures/player.png

-- ❌ 错误：不要加目录前缀
local texture = cache:GetResource("Texture2D", "assets/Textures/player.png")
```

### 规则 #2: 脚手架起手 (必须) 🏗️

**不要从零开始写代码，必须基于标准脚手架开始**：

1. **选择脚手架**：
   - 纯 2D 游戏 → `templates/scaffold-2d.lua`
   - 2D 物理游戏（平台跳跃等） → `templates/scaffold-2d-physics.lua`
   - 3D 场景展示 → `templates/scaffold-3d-scene.lua`（自由相机，无角色）
   - 3D 角色游戏 → `templates/scaffold-3d-character.lua`（Fall Guys、Roblox风格）
   - 云变量/排行榜 → `clientCloud`（客户端）/ `serverCloud`（服务端），无需脚手架，可与任意游戏组合
     - **客户端示例**: `examples/11-client-cloud-score-leaderboard-api.lua`
     - **服务端示例**: `examples/23-server-cloud-score-leaderboard-api`

2. **使用方式**：
   - 复制脚手架内容
   - 粘贴到新文件
   - 根据注释填充游戏逻辑

详见: `templates/README.md` 查看完整脚手架对比

### 规则 #2.5: 示例可复用，但需要优化

**核心原则**：示例可以作为起点，但不要原封不动地交付。

**当示例契合用户需求时**：

1. **复制示例到用户目录**，重命名为用户指定的名称
2. **至少做一轮优化**：
   - 🎨 UI 美化（颜色、布局、动画效果）
   - ⚙️ 配置调整（难度、速度、游戏规则）
   - 📝 代码清理（移除不需要的调试代码）
   - ✨ 个性化定制（用户特定的玩法需求）
3. **确保理解代码**，能够回答用户的后续问题

**正确做法**：

| ✅ 正确 | ❌ 错误 |
|---------|---------|
| 复制示例 → 重命名 → 美化 UI → 调整配置 | 复制示例 → 直接交付 |
| 基于示例做个性化改进 | 只改文件名就交付 |
| 理解代码后根据需求修改 | 不理解代码就复制粘贴 |

**检查清单**（交付前自问）：
- [ ] 我做了哪些优化和改进？
- [ ] UI 是否有美化？配置是否调整？
- [ ] 代码是否符合用户的具体需求？
- [ ] 我能解释代码的工作原理吗？

### 规则 #3: Lua 版本特性

- **版本**: Lua 5.4（支持现代 Lua 特性）
- **重点**: 支持位运算符 `&`, `|`, `~`, `<<`, `>>`
- **重点**: `eventData` 访问方式特殊（tolua++ 绑定）
  - ✅ 正确：`local x = eventData["X"]:GetInt()`
  - ✅ 正确：`local dt = eventData["TimeStep"]:GetFloat()`
  - ✅ 正确：`local x = eventData:GetInt("X")`（这是更高效的调用方式）

详见: `engine-docs/lua-scripting-guide.md` → "eventData 访问方式详解"，事件字段定义见 `.emmylua/Events.d.lua`

### 规则 #4: Lua 数组索引从 1 开始 ⚠️

- **核心**: Lua 数组索引从 **1** 开始，不是 0
- **循环**: `for i = 1, n do`（不是 `for i = 0, n-1 do`）
- **边界**: 计算索引时用 `math.max(1, index)` 确保 >= 1
- **典型错误**: `array[0]` 不存在，返回 `nil`，导致 `attempt to index a nil value`

详见: `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"

### 规则 #4.5: table.unpack 在表构造器中的陷阱 ⚠️

**Lua 的 `table.unpack()` 只有在表构造器最后位置才会完全展开，其他位置只取第一个值**：

```lua
local items = {1, 2, 3}

-- ❌ 错误：unpack 不在最后，只展开第一个元素！
local t = { table.unpack(items), "extra" }  -- 结果: {1, "extra"}

-- ✅ 正确：unpack 放最后
local t = { "header", table.unpack(items) }  -- 结果: {"header", 1, 2, 3}
```

**记住**: 这与 JavaScript `[...arr, x]` 或 Python `[*arr, x]` 不同

### 规则 #5: 兼容性

- 基于 Urho3D 1.8，核心 API **95% 兼容**
- 扩展功能: NanoVG（C API 完全对齐）

### 规则 #6: NanoVG 渲染事件 🔴 极其重要！

**NanoVG 渲染必须使用 NanoVGRender 事件**:

```lua
function Start()
    -- ✅ NanoVG 渲染使用 NanoVGRender 事件
    SubscribeToEvent("NanoVGRender", "HandleNanoVGRender")
end

function HandleNanoVGRender(eventType, eventData)
    nvgBeginFrame(vg, width, height, 1.0)
    -- 绘制代码...
    nvgEndFrame(vg)
end
```

> ⚠️ 此用法仅适用于自定义矢量图形绘制。UI 类需求（菜单、HUD、字幕）见 Rule #10。

### 规则 #7: NanoVG 文本绘制必须先创建字体 🔴

```lua
-- ⚠️ Start() 中创建字体（只创建一次！返回值可复用，每帧调用会显存泄漏）
fontNormal = nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")

-- 渲染时设置字体后再绘制（每帧调用没问题）
nvgFontFace(vg, "sans")
nvgFontSize(vg, 24)
nvgText(vg, 100, 100, "Hello World")
```

**记住**: `nvgCreateFont` 只在初始化时调用一次，句柄可复用

### 规则 #7.5: Emoji 自动 Fallback 😀

**引擎内置 Emoji Fallback 机制，无需指定 Emoji 字体**:

### 规则 #8: NanoVG 使用场景（Canvas 替代方案）🎨

**NanoVG 用于自定义图形绘制，不是通用 UI 方案**：

| 需求 | 方案 |
|------|------|
| 文字、按钮、HUD、菜单、字幕 | `urhox-libs/UI` 组件（Rule #10） |
| 自定义图形、粒子、图表、特殊效果 | raw NanoVG |
| 用户说"Canvas 绘图" | raw NanoVG（指自由绘制，不是 UI） |
| 纯 NanoVG 2D 游戏（整个渲染管线都是 NanoVG） | raw NanoVG（无层级冲突） |
| 不确定 | 先查 `urhox-libs/UI` 组件列表（`recipes/ui.md`），无对应组件再用 NanoVG |

**记住**: Canvas/自定义图形 → NanoVG；UI/HUD/字幕 → UI 组件

详见: `engine-docs/lua-scripting-guide.md` § NanoVG（C API 映射 + UrhoX 扩展如图片染色 `nvgImagePatternTinted`）

### 规则 #9: 鼠标模式设置 🖱️

**引擎默认显示鼠标光标**。对于需要用鼠标控制视角方向的游戏（FPS、TPS、飞行模拟等），必须设置鼠标模式：

```lua
function Start()
    -- FPS/TPS 等需要鼠标控制视角的游戏：
    input.mouseMode = MM_RELATIVE
    -- MM_RELATIVE 会自动隐藏光标并锁定鼠标
end
```

### 规则 #9.1: 正交相机 orthoSize 的 0.5 因子 📷

**`camera.orthoSize` 代表视野全高度，但引擎内部使用 `orthoSize * 0.5` 作为半高度**：

```lua
-- 手动计算屏幕坐标到视图空间时：
-- 乘以 0.5
local viewX = ndcX * aspect * orthoSize * 0.5
local viewY = ndcY * orthoSize * 0.5
```

**典型应用场景**：等距视角/俯视角游戏的"缩放到鼠标位置"功能

详见: `engine-docs/gotchas/camera.md`

**鼠标模式选择**:
| 模式 | 用途 |
|------|------|
| `MM_ABSOLUTE` | 默认，适用于菜单、RTS、编辑器 |
| `MM_RELATIVE` | **FPS/TPS/飞行模拟**，鼠标控制视角 |
| `MM_FREE` | 鼠标不锁定，即使隐藏 |

**记住**: FPS/TPS 游戏 → `input.mouseMode = MM_RELATIVE`

详见: `engine-docs/api/input.md` → "鼠标模式设置指南"

### 规则 #9.2: 3D模型尺寸 - 绝不猜测 🔴

**使用3D基础模型时，必须获取精确尺寸，不要假设**:

```lua
-- ✅ 正确方法1: 查询文档
-- 详见: engine-docs/recipes/built-in-models.md
-- Box: 1.0 × 1.0 × 1.0
node.position = Vector3(0, 0.5, 0)  -- 1.0/2 = 0.5

-- ✅ 正确方法2: 使用 boundingBox 动态获取
local model = node:CreateComponent("StaticModel")
model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
local size = model.boundingBox.size
node.position = Vector3(0, size.y / 2, 0)  -- 自动正确

-- ❌ 错误: 假设尺寸
node.position = Vector3(0, 0.5, 0)  -- 如果是 Torus 就错了！
```

**记住**: 尺寸不确定 → 用 `boundingBox` 或查 `engine-docs/recipes/built-in-models.md`

### 规则 #9.3: 缺失的基础形状用 CustomGeometry 🔧

**当需要内置模型不支持的基础形状时，使用 CustomGeometry 程序化生成**：

| 需求 | 解决方案 |
|------|---------|
| 半球（水果切开效果） | CustomGeometry |
| 圆锥台/截锥体 | CustomGeometry |
| 楔形/斜面 | CustomGeometry |

```lua
-- CustomGeometry 基本用法
local geom = node:CreateComponent("CustomGeometry")
geom:BeginGeometry(0, TRIANGLE_LIST)

-- 定义顶点（位置、法线、UV）
geom:DefineVertex(Vector3(x, y, z))
geom:DefineNormal(Vector3(nx, ny, nz))
geom:DefineTexCoord(Vector2(u, v))

geom:Commit()
geom:SetMaterial(material)
```

**记住**: 内置模型没有的形状 → CustomGeometry

详见: `engine-docs/recipes/built-in-models.md` → "缺失形状的替代方案"
示例: `examples/07-minecraft-voxel-world/`

### 规则 #9.4: 程序化材质 Technique - 不要猜测路径 🔴

**程序化（纯色/无贴图）材质只用以下 Technique**：

```lua
-- ✅ 正确：程序化材质只用这两个
"Techniques/PBR/PBRNoTexture.xml"       -- 不透明 PBR
"Techniques/PBR/PBRNoTextureAlpha.xml"  -- 透明 PBR
"Techniques/NoTextureUnlit.xml"         -- 无光照
```

**记住**: 程序化材质 = `PBRNoTexture` 系列，不要猜测其他路径！

详见 `materials` skill（完整材质指南）。内置 Technique 做不到的效果改写 SurfaceShader，不要手写底层 `.glsl`/Technique XML → `engine-docs/recipes/surface-shader.md`

### 规则 #10: UI 系统选择 🔴 重要！

**UrhoX 有两套 UI 系统，原生 UI 已废弃，必须使用新 UI 系统**：

| 系统 | 状态 | 技术栈 | 说明 |
|------|------|--------|------|
| **新 UI 系统** urhox-libs/UI | ✅ 推荐 | Yoga Flexbox + NanoVG | 40+ 内置控件，游戏级 UI |
| 原生 UI 系统 | ⛔ 废弃 | Urho3D UIElement | 仅兼容旧代码，不再维护 |

**范式提示**：urhox-libs/UI 声明式构建（一次性 build 树 → SetRoot），事后更新控件有两种合法模式：
- **模式 A** — 保留 local 引用：`local btn = UI.Button{...}; btn:SetDisabled(true)`（适合少量动态元素，LSP 类型推导友好）
- **模式 B** — id 标签 + `parent:FindById("id")` 查找（适合 HUD 多元素 / 跨函数访问，无需维护一堆引用）。⚠️ `FindById` 返回 `Widget|nil`：调子类方法（`SetText` 等）前必须行尾 `--[[@as Label?]]` 收窄，否则 LSP 报 `undefined-field` ERROR

按场景选用，详见 [recipes/ui.md §11](engine-docs/recipes/ui.md)。完整 API 见 [urhox-libs/UI/init.lua](urhox-libs/UI/init.lua)。

```lua
-- ✅ 新 UI 系统（推荐）
local UI = require("urhox-libs/UI")

UI.Init({
    theme = "default-dark",    -- 推荐内置主题
    scale = UI.Scale.DEFAULT,  -- 要求默认使用（详见 engine-docs/recipes/ui.md §10 分辨率缩放策略）
})

-- 需要事后更新的控件 → 保留 local 引用
local startBtn = UI.Button { text = "Start", variant = "primary", onClick = function(self) end }

local root = UI.Panel {
    width = "100%", height = "100%",
    justifyContent = "center", alignItems = "center",
    children = {
        UI.Label { text = "Game Menu", fontSize = 24 },
        startBtn,
        UI.Slider { value = 80, onChange = function(self, v) end },
    }
}
UI.SetRoot(root)

-- 后续直接调方法
startBtn:SetDisabled(true)
```


**UI 风格 Skills**：引擎提供多套预置 UI 风格主题，每套包含完整的配色、字体、圆角、阴影等设计规范和代码模板。可用风格 skill 如 `ui-astroon`、`ui-brawlforge`、`ui-pixelforge` 等，创建和优化 UI 时应查阅这些 skill 选择合适的风格。

**记住**: 当用户请求带有风格特征的 UI 时，禁止自己编造，必须先查询是否有对应的 skill！

### 规则 #11: 类型标注 ⚠️

**重点标注"类型源头"**：`.emmylua` 已提供足够的全局类型声明，用户只需标注空值变量声明，后续类型推导将自动传递。

**未赋值或赋 nil 的变量必须添加类型标注**，否则访问其成员时，LSP 报 `undefined-field` 错误：

```lua
-- ❌ 错误
local scene = nil
local node
node = scene:CreateChild("Node")  -- 访问nil类型的成员，LSP 报错
node:SetPosition(Vector3(1,1,1))  -- 访问unkown类型的成员不会有任何提示，但不安全

-- ✅ 正确
---@type Scene
local scene = nil
---@type Node
local node = nil

-- ✅ 正确
local scene = Scene() -- 来自全局接口的调用自动传递类型推导
local node = scene:CreateChild("Node")
node:SetPosition(Vector3(1,1,1))
```

**事件函数建议标注（尤其内置事件）**：
```lua
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    -- local dt = eventData:GetFloat("TimeStep") -- 更高效，linter更准确严格
end
```

**OOP 类字段在 `:init` 冒号方法里初始化，别只放 `.new` 静态工厂里**（否则成员方法读取会误报 `undefined-field`；次选加 `---@class`/`---@field`）。详见 `engine-docs/lua-scripting-guide.md`。

**integer 目标必须配 integer 来源**（number 声明/非整型运算会扩大为 number → 诊断报错）。数组声明用 `V[]`，数字键 map 用 `table<number, V>`，别写 `table<integer, V>`。详见 `engine-docs/lua-scripting-guide.md` → "integer 目标必须配 integer 来源"。

**别对引擎对象/integer 做 `x = x <运算> ...` 自赋值**（静态分析丢类型 → undefined-field）；运算结果落新变量，或直写目标属性（`node.position = node.position + delta`）。详见 `engine-docs/lua-scripting-guide.md` → "自赋值会丢类型"。

**对无类型变量（裸声明/`=nil`）取 `[key]` 索引值，再访问字段/方法必报 undefined-field**；已初始化的 table 若经二级字段再索引，存中间变量后访问也会报（直链不报）。变量声明即初始化，共享 ctx/容器用 `@class`+`@field` 声明 value 类型。详见 `engine-docs/lua-scripting-guide.md` → "对无类型变量取索引值"。

详见：脚手架文件中的完整示例，事件类型定义见 `.emmylua/Events.d.lua`

### 规则 #12: 使用枚举值，不要猜测数字 🔴

**处理输入事件、渲染模式等场景时，必须使用枚举常量，不要使用数字常量**：

```lua
-- ❌ 错误：使用数字常量（其他框架的习惯，如 SDL）
if button == 0 then ... end           -- 错误！MOUSEB_LEFT 不一定是 0
if button ~= 0 then return end        -- 错误！
if button > 1 then return end         -- 错误！

-- ✅ 正确：使用枚举值
if button == MOUSEB_LEFT then ... end
if button == MOUSEB_RIGHT then ... end
if input:GetKeyDown(KEY_SPACE) then ... end
if input:GetKeyPress(KEY_ESCAPE) then ... end
```

**常用枚举值**：

| 类别 | 枚举值 |
|------|--------|
| 鼠标按钮 | `MOUSEB_LEFT`, `MOUSEB_MIDDLE`, `MOUSEB_RIGHT` |
| 键盘按键 | `KEY_SPACE`, `KEY_ESCAPE`, `KEY_RETURN`, `KEY_A`~`KEY_Z` 等 |
| 鼠标模式 | `MM_ABSOLUTE`, `MM_RELATIVE`, `MM_FREE` |
| 刚体类型 | `BT_STATIC`, `BT_DYNAMIC`, `BT_KINEMATIC` |

**记住**：不确定枚举值 → 查阅 `engine-docs/api/enums.md`

**检查清单**（输入事件代码自查）：
- [ ] 鼠标按钮判断使用了 `MOUSEB_LEFT` / `MOUSEB_RIGHT` 而非数字？
- [ ] 键盘按键判断使用了 `KEY_*` 枚举而非数字？

详见: `engine-docs/api/enums.md` (完整枚举列表)
示例: `examples/05-super-mario-game.lua` (正确用法，12 处 `KEY_*`)

---

### 规则 #13: 代码组织与模块化 📁

**对于需要大型、多轮对话持续开发的项目，必须采用模块化结构和渐进式开发策略**。

**代码行数阈值**：

| 单文件行数 | 建议操作 |
|-----------|---------|
| < 1000 行 | ✅ 单文件可接受 |
| 1000-1500 行 | ⚠️ 考虑拆分，提取独立模块 |
| > 1500 行 | 🚨 **必须拆分**为多个模块 |

**何时开始模块化**：

| 场景 | 建议 |
|------|------|
| 一次性小游戏、Demo | 单文件即可 |
| 需要多轮对话迭代的项目 | **从第一轮就建立模块化结构** |
| 现有代码接近 1000 行 | 主动提议拆分 |

**记住**: 大型项目 → 模块化优先；单文件超过 1500 行 → 必须拆分

### 规则 #13.5: 第三人称相机必须使用库 🔴

**将第一人称相机改为第三人称时，必须使用 `ThirdPersonCamera` 库**：

```lua
require "urhox-libs.Camera.ThirdPersonCamera"

-- 创建第三人称相机
local tpCamera_ = ThirdPersonCamera.Create(scene_, {
    modes = {
        normal = { distance = 5.0, offset = Vector3(0, 1.7, 0), fov = 45.0 },
    },
})
renderer:SetViewport(0, Viewport:new(scene_, tpCamera_:GetCamera()))

-- 在 PostUpdate 中更新（传入 yaw/pitch，库内部处理相机位置）
tpCamera_:Update(timeStep, characterNode, yaw, pitch)
```

**关键规则**：
1. **不要手动计算相机位置**（库内部封装，避免符号问题）
2. **保持 yaw 更新逻辑不变**（不要反转符号）
3. **参考脚手架**：`templates/scaffold-3d-character.lua`

**记住**: 改第三人称相机 → 用 `ThirdPersonCamera` 库！

详见: `engine-docs/recipes/camera.md`、`templates/scaffold-3d-character.lua`

### 规则 #14: 多人游戏模式判断 🔴 极其重要！

**对于同时支持单机和多人的游戏，必须先读 `.project/settings.json` 判断当前模式**：

```json
{ "@runtime": { "multiplayer": { "enabled": true } } }   // ← 判断这个字段
```

若 `multiplayer.enabled: true`，**必须完整阅读 `engine-docs/recipes/network-game-guide.md`**。

**判断逻辑**：

| `multiplayer.enabled` | 当前模式 | 代码放置位置 |
|----------------------|---------|-------------|
| `true` | **多人模式** | `network/Client.lua`, `network/Server.lua` |
| `false` 或不存在 | **单机模式** | `network/Standalone.lua` |

**为什么重要**：这个配置同时决定发布后与调试时的运行模式，所以 `enabled: true` 时**用户后续的每个功能请求都要实现为多人版本**，不只是当前这一个。

### 规则 #15: 显式释放对象用 `Dispose()` ♻️

**所有 `Object` 子类（Node / Component / File / VideoPlayer / Sound 等）都有 `Dispose()` 方法**，用来立即释放对象、避免拖到 GC。

### 规则 #16: 日志先行，稳定后清理 📝

**首次交付的代码尽量多写日志，确认无误后再清理**：
- 开发阶段：关键函数入口/出口、重要变量值、资源加载结果、条件分支都打 `print`
- 稳定阶段：删除调试 `print`，只保留关键错误日志

**记住**：看不见就无法调试——过度日志好过无日志，但最终要清理。

### 规则 #17: 物理/碰撞先设计后实现 🎯

**实现物理或碰撞检测前，先用注释画出碰撞区域示意图**：
1. 画出各碰撞体形状/尺寸（注释里的 ASCII 图即可）
2. 写明检测目的（检测什么 → 触发什么）
3. 推演边界情况（擦边、缝隙中心、最小/最大值、地面/天花板）

**记住**：设计不清晰，代码必混乱——先设计，后实现。

## 📚 可用示例代码

<!-- BEGIN AUTO-GENERATED EXAMPLES -->
### 示例列表

**总数**: 25 个示例 (🌱 1 🌿 14 🌳 10)

1. 🌿 **[NanoVG独立绘图](examples/01-nanovg-standalone.lua)** - 使用NanoVG原生API绘制矢量图形
2. 🌳 **[NanoVG UI组件](examples/02-nanovg-ui-component.lua)** - 将NanoVG渲染到纹理作为UI组件使用
3. 🌳 **[Flappy Bird 游戏](examples/03-flappy-bird-game.lua)** - 使用NanoVG实现完整的Flappy Bird游戏
4. 🌿 **[Box2D 平台跳跃最佳实践](examples/04-box2d-platformer.lua)** - 展示如何正确使用 Box2D 物理系统实现 2D 平台跳跃游戏，避免常见碰撞检测 BUG
5. 🌳 **[超级马里奥兄弟完整实现](examples/05-super-mario-game.lua)** - 使用 NanoVG 和瓦片地图碰撞实现的完整超级马里奥游戏
6. 🌳 **[我的世界体素世界（模块化架构）](examples/07-minecraft-voxel-world)** - 使用多文件模块化架构实现的 Minecraft 风格体素世界，展示大型项目的最佳实践
7. 🌳 **[VoxelTown 可破坏小镇脚手架](examples/27-voxel-town)** - 官方体素物理脚手架：可破坏小镇沙盒，含载具、水面浮力、玩法工具与昼夜光组，可直接复制为新体素项目起点
8. 🌿 **[SurfaceShader 灯光开关](examples/25-surface-custom-light-scene)** - 演示 SurfaceShader 自定义 light()，并用 urhox-libs/UI 切换三类光源。
9. 🌳 **[鹈鹕骑单车（延迟渲染 + 昼夜 + 晴雨 + 体积光 + FFT 海面）](examples/30-pelican-bike)** - 延迟渲染效果拉满的综合场景：昼夜循环、晴雨天气、闪电、体积光与光柱、GPU FFT 海面，环境光由 SkyLightCapture 从自写天空实时捕获。
10. 🌱 **[程序化天空 + 环境光跟随](examples/29-procedural-sky)** - ProceduralSky 画带太阳的昼夜天空，SkyLightCapture 让场景环境光（漫反射 + 反射）自动跟随天空变化。
11. 🌿 **[云变量积分与排行榜 API](examples/11-client-cloud-score-leaderboard-api.lua)** - clientCloud API 完整用法示例，展示云变量存储和排行榜功能
12. 🌿 **[NanoVG Bloom发光特效](examples/10-nanovg-bloom.lua)** - 使用NanoVG渐变模拟HDR Bloom/Glow发光效果
13. 🌿 **[UI 组件库展示](examples/14-ui-widgets-gallery.lua)** - 展示 UrhoX UI 库全部 41 个组件的综合画廊
14. 🌿 **[Yoga Flexbox 布局 + NanoVG 渲染](examples/13-yoga-layout-nanovg-render.lua)** - 使用 Yoga 实现 Flexbox 布局，NanoVG 渲染 UI，支持 Hover 和点击交互
15. 🌿 **[RPG 背包装备系统](examples/15-inventory-drag-drop.lua)** - 展示 RPG 游戏中完整的背包和装备系统，支持拖拽操作
16. 🌿 **[万级数据虚拟列表](examples/16-virtual-list-10k-items.lua)** - 展示 VirtualList 组件渲染 10000 个物品，使用对象池和视图回收
17. 🌿 **[MMO 聊天窗口富文本](examples/17-chat-window-rich-text.lua)** - 展示 MMO 风格的聊天窗口，支持自定义标签和图文混排
18. 🌿 **[3D 物理碰撞最佳实践](examples/18-physics-collision-3d.lua)** - 展示如何正确使用 3D 物理碰撞事件，包括地面检测、触发器、收集物品和伤害区域
19. 🌿 **[WASM 视频播放器](examples/19-video-player-ui.lua)** - 展示 WASM 平台视频播放功能，支持 UI 叠加在视频上方
20. 🌿 **[NanoVG 视频播放器](examples/20-video-player-nanovg.lua)** - 使用 VideoPlayer + NanoVG 直接渲染视频，不依赖 UI 库
21. 🌿 **[3D 视频屏幕（IMAX）](examples/21-video-screen-3d.lua)** - 在 3D 场景中创建 IMAX 风格视频屏幕，使用 VideoScreen3D 高层组件
22. 🌳 **[第三人称射击游戏（模块化架构）](examples/22-third-person-shooter)** - 使用多文件模块化架构实现的第三人称射击游戏，展示动画状态机、角色控制器、多人网络架构
23. 🌳 **[服务端云变量 API 示例](examples/23-server-cloud-score-leaderboard-api)** - 服务端 serverCloud API 完整用法示例，包含 Score CRUD、批量操作、排行榜、事务、子对象（Money/List/Message/Quota），客户端展示测试结果和排行榜 UI
24. 🌳 **[运行时模型绘制](examples/24-model-painter.lua)** - 使用 Paint 库在带 UV1 的模型上实时绘制颜色、金属度和粗糙度，支持笔刷、屏幕取色和多目标切换
25. 🌳 **[断线重连骨架](examples/28-session-reconnect-skeleton)** - 用 urhox-libs/Network/PlayerSessions 管理玩家会话：按认证 user_id 单表、掉线暂存、重连（含顶号）重绑并重推权威快照。

📊 更多详情请查看 [examples/api-index.md](examples/api-index.md) (按API查找)

*最后更新: 2026-10-17*
<!-- END AUTO-GENERATED EXAMPLES -->

### 复制示例前先检查 manifest.json 🔴

**复制示例目录前，必须先检查是否存在 `manifest.json`**：

1. 如果存在 `manifest.json`，按其 `includes` 字段复制所有匹配文件
2. 如果 `copyAll: true`，复制整个目录（包括非 .lua 文件）
3. 如果不存在，先用 `ls -la` 检查目录结构，确认是否有非代码资源

**记住**: `.fsm`、`.blendspace`、`.json` 等配置文件同样重要！

---

## 📂 资源目录结构

```
workspace/
│
├── .emmylua/                      # 📘 EmmyLua 类型定义（LSP 自动加载）
│   ├── *.d.lua                    # API 类型定义
│   └── Events.d.lua               # 事件类型定义（177 个事件）
│
├── urhox-libs/                   # 📚 通用库（平台/输入/物理/特效/网络）
├── examples/                     # 💾 示例代码
│   └── api-index.md              # 按 API 查找示例
│
├── engine-docs/                  # 📖 技术文档
│   ├── lua-scripting-guide.md    # ⭐ Lua 开发指南（必读）
│   ├── recipes/                  # 解决方案（rendering.md, surface-shader.md, ui.md 等）
│   └── api/                      # API 参考（按需查阅）
│
└── templates/                    # 🏗️ 项目脚手架（见规则 #2）
```

---

## 🗺️ 任务类型 → 文档映射

根据任务类型，按以下顺序阅读文档：

### 任务: 创建新游戏

1. **必读**: `engine-docs/lua-scripting-guide.md` 完整阅读
2. **选择脚手架**（根据游戏类型）：
   - **2D 休闲游戏**（Flappy Bird、Snake等） → `templates/scaffold-2d.lua`
   - **2D 平台跳跃**（马里奥、Celeste等） → `templates/scaffold-2d-physics.lua`
   - **3D 场景展示/可视化** → `templates/scaffold-3d-scene.lua`（自由相机，无角色）
   - **3D 角色游戏**（Fall Guys、Roblox风格） → `templates/scaffold-3d-character.lua`
   - **云变量/排行榜** → `clientCloud`（客户端）/ `serverCloud`（服务端），无需脚手架
     - 客户端示例: `examples/11-client-cloud-score-leaderboard-api.lua`
     - 服务端示例: `examples/23-server-cloud-score-leaderboard-api`
3. **参考示例** `examples/`

### 任务: 创建/修改联网多人游戏

1. **必读**: `engine-docs/recipes/network-game-guide.md` 完整阅读（权威服务器、Scene Replication、远程事件、输入同步）
2. **参考**: `engine-docs/api/network.md`（Network API 底层参考）
3. **参考**: `examples/api-index.md` 查找 `network` 相关示例
4. **必须检查**: `.project/settings.json` 的 `@runtime.multiplayer.enabled`，判断代码应写入多人 Client/Server 模块还是单机逻辑
5. **体素多人玩法必读**: [体素物理联网开发](engine-docs/recipes/voxel-networking.md)（服务端权威修改、客户端资源预热与 Ready、两域色板、重连）

### 任务: 添加游戏功能（物理、相机控制、UI、输入、存档、材质、广告、视频播放等）

1. **必读**: `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"（快速复习）
2. **必读**: `engine-docs/api/index.md` 找到相关类名，再用 LSP hover 或读 `.emmylua/<类名>.d.lua` 查签名（`api/<模块>.md` 只是类名清单，不含签名）
3. **参考**: `examples/api-index.md` 查找相关示例
4. **参考**: `engine-docs/recipes/` 查找现成解决方案

**示例**:
- 添加物理系统 → `engine-docs/api/physics-2d.md` 或 `engine-docs/api/physics.md`
- 添加游戏 UI / HUD / 菜单 → `engine-docs/recipes/ui.md`（原生 UI 已废弃）
- 添加输入处理 → `engine-docs/api/input.md`
- 添加/修改联网多人玩法、网络同步、远程事件 → `engine-docs/recipes/network-game-guide.md`（必读）+ `engine-docs/api/network.md`
- 配置灯光/雾/天空盒/后效 → `engine-docs/recipes/rendering.md`（LightGroup 预设、Zone fog、Skybox、Bloom/Vignette/AutoExposure 等后效开关）
- 添加本地存档 → `engine-docs/recipes/file-storage.md`（文件读写沙箱）
- 添加云变量/排行榜 → 客户端 `engine-docs/recipes/client-cloud-score.md` / 服务端 `engine-docs/recipes/server-cloud-score.md`
- 保存/读取整个场景、体素破坏进度、房主继续游戏 → [场景云存档与读档](engine-docs/recipes/scene-cloud-save.md)（`SaveScene` / `LoadScene`，含两端示例与生命周期）
- 边玩边下/手动下资源 → `engine-docs/recipes/download-while-playing.md`（DWP 自动加载 + 手动下载 API）
- 配置资源预下载与构建引用 → `engine-docs/recipes/preload-and-build-refs.md`（构建引用策略、预下载、资源裁剪）

### 任务: 添加多语言/国际化支持

1. **文本翻译**（脚本/配置中的字符串）→ `engine-docs/recipes/i18n-translation.md`
   - 提取可翻译字符串 → 翻译 → 构建时替换为翻译键 → 运行时查表
2. **资源变体**（图片/音频/字体等媒体）→ `engine-docs/recipes/i18n-resource.md`
   - 文件名加 `@en` 后缀 → 构建时自动关联 → 运行时按语言路由

两者可独立使用，也可组合。共享 `.project/i18n.json` 配置（`enabled`、`source_lang`、`target_langs`）。

### 任务: 配置 3D 场景灯光和渲染效果（灯光、雾效、氛围）

1. **必读**: `engine-docs/recipes/rendering.md` — LightGroup 预设、Zone 优先级机制、雾效系统、灯光亮度单位
2. **按需**（高级效果，写之前必读对应文档，不要凭印象设反射属性）：
   - 天空（程序化天空 / 太阳 / 自写 sky shader）、环境光跟随天空 → `engine-docs/recipes/sky-and-environment-lighting.md`
   - 延迟渲染、SSR / SSGI / GTAO / TAA、GBuffer 后处理 → `engine-docs/recipes/deferred-rendering.md`
   - 灯光类型、阴影（级联 / 局部光 / 时域）、灯光数量上限 → `engine-docs/recipes/lights-and-shadows.md`
   - 体积雾、体积光、光柱、灯光光晕、局部雾团 → `engine-docs/recipes/volumetric-fog.md`
   - 泛光、色调映射、自动曝光、景深、运动模糊 → `engine-docs/recipes/post-processing.md`
   - 昼夜循环、晴雨天气、湿地面、打光规范、水面的通用做法 → `engine-docs/recipes/deferred-scene-weather-lighting.md`（完整示例 `examples/30-pelican-bike`）
3. **参考**: `engine-docs/api/graphics.md` → Light / Zone — 底层 API

### 任务: 角色动画/状态机（让角色动起来）

1. **必读**: `engine-docs/recipes/state-machine.md`（FSM 格式 + BlendSpace + Lua 驱动）
2. **使用模板**: `engine-docs/recipes/templates/fsm/`（官方动画 uuid 版可直接用）
3. **参考**: `examples/22-third-person-shooter` 的 `FSM/Unified.fsm`（多层 FSM 完整示例）
4. **或使用 skill**: `/setup-fsm` 引导式配置
5. AimOffset/动画后处理后武器或特效不贴骨骼 → 同一文档的“后处理骨骼挂点”，按其中的时序和 `Bone` 生命周期约束使用 `Bone:GetFinalWorldTransform()`

### 任务: 使用 NanoVG 绘制图形

1. **必读**: `engine-docs/lua-scripting-guide.md` → "NanoVG API 映射规则"
2. **必读**: `examples/01-nanovg-standalone.lua` 完整示例
3. **参考**: [NanoVG C API 文档](https://github.com/memononen/nanovg)（函数签名完全相同）

### 任务: 在界面中显示 3D 场景预览

**必读**：[3D 场景预览](engine-docs/recipes/scene-to-nanovg.md) — 创建、绘制与关闭。

### 任务: 调试/修复错误

1. **第一步**: `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"（按错误信息定位原因）
2. **第二步**: 若是 eventData/NanoVG/Box2D 等专题问题，查 `engine-docs/lua-scripting-guide.md` 对应章节
3. **第三步**: 重新阅读相关 API 文档

---

## 🚨 问题诊断速查

遇到以下问题时，立即查阅对应章节：

### 高频踩坑（优先看）

| 症状/错误信息 | 解决方案 |
|---------|---------|
| **配置 3D 场景灯光/雾效/氛围** | 先读 `recipes/rendering.md`（LightGroup 预设 + Zone 优先级机制 + 灯光亮度单位） |
| **多人/单机游戏代码放错文件** | 先读 `.project/settings.json` 的 `multiplayer.enabled`（见规则 #14）；多人模式必须再读 `recipes/network-game-guide.md` |
| **远程事件、场景复制、客户端/服务端同步异常** | 先读 `recipes/network-game-guide.md`，再查 `api/network.md` |
| **第三人称相机方向控制错误** | 使用 `ThirdPersonCamera` 库（见规则 #13.5、`recipes/camera.md`） |
| **材质 Technique 不存在** | 使用 materials skill |
| **鼠标点击判断失败，左键无响应** | 使用 `MOUSEB_LEFT` 枚举而非数字 0（见规则 #12） |
| **SetMode 不生效** | `graphics:SetMode()` 已禁用，用 `graphics:GetWidth()`/`graphics:GetHeight()` 获取物理分辨率（见规则 #0.8） |
| **UI 在不同物理分辨率下位置错乱** | 使用 `UIScaler` 定义设计分辨率，或基于物理分辨率自行计算（见规则 #0.8） |
| **需要创建游戏 UI / HUD / 菜单** | 使用 `engine-docs/recipes/ui.md` |
| **UI 子元素溢出容器** | Yoga 默认 flexShrink=0，需设置 `flexShrink = 1`（见 `engine-docs/recipes/ui.md`） |
| **NanoVG 图形能显示，但文本不显示** | 必须先创建字体（见规则 #7） |
| **NanoVG 代码运行了但什么也不显示** | 使用 **NanoVGRender** 事件（见规则 #6） |
| **3D 预览上下颠倒** | [3D 场景预览](engine-docs/recipes/scene-to-nanovg.md) → 画面方向 |
| **UI/字幕/HUD 渲染层级冲突** | 不要用 raw NanoVG 做 UI，改用 `urhox-libs/UI` 组件（Rule #10） |
| **按空格无法跳跃，地面检测失败** | Box2D 碰撞体必须在同一刚体节点上，使用 `center` 偏移（见 `lua-scripting-guide.md` → "Box2D 脚底传感器不触发碰撞事件"） |

### 其他症状

| 症状/错误信息 | 解决方案 |
|---------|---------|
| **给图片/纹理叠色染色（raw NanoVG）** | 用 `nvgImagePatternTinted`（上游 `nvgImagePattern` 不支持染色，见 `lua-scripting-guide.md` § NanoVG） |
| **文件读写被拒绝/返回 nil** | 使用相对路径如 `"save.json"` 或 `"saves/slot1.json"`（见 `recipes/file-storage.md`） |
| **`io` 库不存在** | 已被沙箱移除，使用 `File` 替代（见 `recipes/file-storage.md`） |
| `attempt to call method 'GetInt'` | `engine-docs/lua-scripting-guide.md` → "eventData 访问方式详解" |
| `attempt to index a nil value` (数组) | `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"（数组索引从 1 开始） |
| `Null pointer access` / `Resource not found` / 性能问题 | `engine-docs/lua-scripting-guide.md` → "常见错误信息速查" |
| `Stack index X out of range` | `engine-docs/api/` 检查函数签名和参数类型 |
| **构建产物太大/资源太多/下载慢** | 先看 `engine-docs/recipes/preload-and-build-refs.md`（构建引用策略、预下载、资源裁剪），再看 `engine-docs/recipes/download-while-playing.md`（DWP） |
| **动画状态机不切换状态** | `engine-docs/recipes/state-machine.md`（检查 condition 表达式、参数是否每帧更新） |
| **AimOffset/动画后处理后武器不贴手或延迟一帧** | `engine-docs/recipes/state-machine.md` → “后处理骨骼挂点”，按时序和 `Bone` 生命周期约束使用 `Bone:GetFinalWorldTransform()` |

---

## ✅ 标准工作流程

### 开始新任务时

1. 阅读上方"任务类型 → 文档映射"
2. **完整阅读**对应文档（不要跳过）
3. **选择并复制合适的脚手架**（不要从零开始）
4. 查看相关示例代码（如果有）
5. 开始编写代码

### 编写代码时

1. 确保代码放在 `scripts/` 目录
2. 引用工具库用 `require "urhox-libs.<模块路径>"`（见规则 #1；`LuaScripts/Utilities/` 是旧路径，不要用）
3. 遇到不确定的 API → 查 `engine-docs/api/` 文档
4. 遇到编译/运行时错误 → 查 `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"

### 构建前（必须）

修改 Lua 代码后，若 LSP 功能就绪，**必须先通过 LSP 工具诊断（本地 `maker-lua-lsp` / 云端 `lua_lsp_client`）确认无 Error 再构建**。

### 完成任务后

1. 测试代码（点击 Preview 预览）
2. 如果遇到了文档未记录的错误 → 建议用户补充到 `engine-docs/lua-scripting-guide.md`

---

## 🔍 快速查找

### 我需要... (通用功能库)

→ 查阅 `urhox-libs/README.md`（平台适配/输入/物理/特效等）

### 我需要... (引擎 API)

- **创建场景和节点** → `engine-docs/api/core.md`
- **添加 3D 模型** → `engine-docs/api/graphics.md` → StaticModel
- **程序化几何体**（内置模型没有的形状：球/柱/环/多面体/胶囊/圆角盒/星形挤出/管/凸包/贴花/茶壶…） → `engine-docs/recipes/procedural-geometry.md`（three.js 兼容 API）
- **配置灯光/雾效/场景氛围** → `engine-docs/recipes/rendering.md`（LightGroup 预设 + Zone + 额外光源）
- **动态天空 / 程序化天空 / 环境光跟随天空** → `engine-docs/recipes/sky-and-environment-lighting.md`（ProceduralSky + SkyLightCapture）
- **延迟渲染 / 屏幕空间反射 / 全局光照 / GBuffer 后处理** → `engine-docs/recipes/deferred-rendering.md`
- **阴影 / 灯光数量上限 / 面光** → `engine-docs/recipes/lights-and-shadows.md`
- **体积雾 / 体积光 / 光柱 / 灯光光晕** → `engine-docs/recipes/volumetric-fog.md`
- **泛光 / 曝光 / 景深 / 运动模糊** → `engine-docs/recipes/post-processing.md`
- **昼夜循环 / 晴雨天气 / 打光规范 / 水面** → `engine-docs/recipes/deferred-scene-weather-lighting.md`
- **自定义材质 shader / 溶解 / 流光 / UV 动画 / 顶点形变 / 水面波纹 / 卡通 Toon / 描边 / 自定义 `light()`（抢先体验版）** → `engine-docs/recipes/surface-shader.md`（上层 SurfaceShader `.shader`，非底层 Technique/`.glsl`）
- **GPU 计算 / compute shader / 生成数据纹理 / GPU 数组处理 / buffer 异步读回** → [Compute addon](engine-docs/recipes/surface-shader-addons/compute.md)（`shader_type compute` + `ComputeDispatch`；默认使用 `DispatchThreads`，先检查设备支持）
- **添加 2D 精灵** → `engine-docs/api/index.md` → StaticSprite2D
- **添加物理（3D）** → `engine-docs/api/physics.md`
- - **高效处理 3D 物理碰撞（事件订阅）** → `examples/18-physics-collision-3d.lua`
- **添加物理（2D）** → `engine-docs/api/physics-2d.md`
- **体素破坏 / 爆炸挖掘 / Teardown 风格 / 体素载具（抢先体验版）** → `engine-docs/recipes/voxel-physics.md`（与 Bullet 物理互不碰撞的独立系统；**Windows、macOS、iOS、Android 和 Web 可用，HarmonyOS 为未完成实机验证的实验性支持，Linux 暂未启用**）
- **处理键盘/鼠标输入** → `engine-docs/api/input.md`
- **联网多人游戏 / 网络同步 / 远程事件** → `engine-docs/recipes/network-game-guide.md`（必读）+ `engine-docs/api/network.md`
- **体素联网 / 多人破坏与建造 / 联网色板 / 体素 Ready** → [体素物理联网开发](engine-docs/recipes/voxel-networking.md)（Lua gameplay 接入，配合 `voxel-physics.md` 使用）
- **配置灯光/雾/天空盒/后效** → `engine-docs/recipes/rendering.md`（LightGroup、Zone fog、Skybox、后效开关 Bloom/Vignette/AutoExposure 等）
- **创建游戏 UI / HUD / 菜单** → `engine-docs/recipes/ui.md`（40+ 控件，原生 UI 已废弃）
- **播放音效** → `engine-docs/api/audio.md`
- **JSON 编解码** → `engine-docs/recipes/json.md`（推荐 cjson）
- **本地文件存档** → `engine-docs/recipes/file-storage.md`（File/FileSystem，沙箱内读写）
- **边玩边下/资源下载** → `engine-docs/recipes/download-while-playing.md`（DWP 自动加载 + 手动下载 API）
- **云变量/排行榜** → 客户端 `engine-docs/recipes/client-cloud-score.md` / 服务端 `engine-docs/recipes/server-cloud-score.md`
- **场景云存档/读档、体素进度、房主继续游戏** → [场景云存档与读档](engine-docs/recipes/scene-cloud-save.md)（`clientCloud` / `serverCloud` 的 `SaveScene` / `LoadScene`）
- **使用向量/四元数** → `engine-docs/api/math.md`
- **查找枚举值** → `engine-docs/api/enums.md`
- **角色动画状态机** → `engine-docs/recipes/state-machine.md`（FSM + BlendSpace + AimOffset + Root Motion + 后处理骨骼挂点）或 `/setup-fsm`
- **Spine 骨骼动画** → `engine-docs/recipes/ui.md` § Spine（UI.Spine 组件，3.8/4.x 版本，IK/多轨道/回调）
- **SVG（预览版）** → [ui.md § SVG](engine-docs/recipes/ui.md#svg预览版)（`UI.Svg` 布局、原生实例与元素拾取）
- **NanoVG 绘图** → `examples/01-nanovg-standalone.lua` + **NanoVGRender 事件**
- **多语言/国际化** → 文本：`engine-docs/recipes/i18n-translation.md` / 资源：`engine-docs/recipes/i18n-resource.md`
- **用引擎跑一段 Lua 做程序化生成 / 离线烘焙 / 批处理** → `engine-docs/recipes/procedural-lua-headless.md` + `run-lua-headless` skill
- **完整游戏示例** → `examples/03-flappy-bird-game.lua`

### 我遇到了...

- **编译错误** → `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"
- **运行时错误** → `engine-docs/lua-scripting-guide.md` → "常见错误信息速查"
- **UI 布局问题** → `engine-docs/recipes/ui.md`（Yoga Flexbox 布局，原生 UI 已废弃）
- **联网同步/远程事件问题** → `engine-docs/recipes/network-game-guide.md` + `engine-docs/api/network.md`
- **不知道某个 API 怎么用** → `engine-docs/api/[模块].md`
- **想看完整示例** → `examples/` 或 `engine-docs/recipes/`
- **想快速开始** → 见 `templates/README.md` 选择合适脚手架
- **资源太多/下载太慢** → `engine-docs/recipes/preload-and-build-refs.md`（构建引用策略、预下载、资源裁剪）

---

*最后更新: 2026-05-26*
*版本: v0.2.1*
