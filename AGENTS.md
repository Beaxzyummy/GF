# AGENTS.md — AI 协作规范

本仓库供 AI Agent（Claude Code / Maker MCP 等）参与开发，请遵守以下约定。

## 项目定位

《好运游戏厅》：刮刮乐 + 美式彩票 + 转盘的游戏厅框架小游戏。
纯单机离线、无内购、IAA 变现、TapTap Maker 平台。

## 硬性规则

1. **公示概率必须真实**：所有概率类功能（彩票/转盘/抽卡）的概率表必须与 `data/*.csv` 一致。
   彩票采用「先抽奖级、再按奖级倒填符号」模型，见 `docs/结果生成规范.md`。
   任何改概率的 PR 必须跑 `npm run verify` 且全过。
2. **严禁引入内购/充值**：这是版号豁免的前提。金币/钻石/票只能通过游玩和广告获得。
3. **严禁服务端远程开关内容**（Maker 审核规范 1.5.2）：广告 mock/live 切换用编译期常量
   `AD_MODE`，不用远程配置。
4. **概率文案禁用赌博措辞**：不说「下注/押注/倍率/赢钱」，说「领取/额外一份/再领」。
5. **数值改动三件套**：改 `data/*.csv` 或 `src/core/` 数值时，必须同步跑：
   ```bash
   npm test && npm run verify && node scripts/simulate-day.mjs
   ```
   且中度玩家日广告次数须落在 5-20 区间。

## 架构约定

- `src/core/` 全部是**纯逻辑**：无 DOM、无引擎 API、无 IO，全部可注入 Rng 复现。
- 引擎层（Lua/Cocos 等 Maker 侧）只做渲染与输入，结果一律调 core。
- 数值配置一律走 `data/*.csv`，不在代码里硬编码数值。
- 存档字段变更必须更新 `src/core/save.js` 的 `sanitizeSave` 并加兼容测试。

## 提交规范

```
feat: 刮刮乐核心生成器（先抽奖级再倒填符号）
fix: 修复模拟器 recordAd 返回值丢失
docs: GDD v1.1 加入上阵位解锁
```

提交前跑 `npm test`，全绿才允许 commit。

## Maker 工作流

1. 改代码 → `npx @taptap/maker doctor` 确认环境
2. 本地验证用 `npx @taptap/maker preview`，不要远程构建
3. 提交构建用 MCP 工具 `maker_build_current_directory`，保持同一 `target_dir`
4. 广告相关改动先读 `maker://ads-integration-guide`
