# 项目协作规范（好运游戏厅）

> 本文件是团队/AI 协作规范。Maker 平台托管策略见 `AGENTS.md`（hash 受监管，勿改动）。

## 硬性规则

1. **公示概率必须真实**：所有概率（彩票/转盘/抽卡）必须与 `data/*.csv` 一致。
   彩票采用「先抽奖级、再按奖级倒填符号」，见 `docs/结果生成规范.md`。
   改概率必须跑 `npm run verify` 全过。
2. **严禁引入内购/充值**：版号豁免前提。货币只能通过游玩和广告获得。
3. **严禁服务端远程开关内容**（Maker 审核规范 1.5.2）：广告 mock/live 用编译期常量 `AD_MODE`。
4. **概率文案禁赌博措辞**：不说「下注/押注/倍率/赢钱」，说「领取/额外一份/再领」。
5. **数值改动三件套**：改 `data/*.csv` 或 `src/core/` 必须跑：
   ```bash
   npm test && npm run verify && node scripts/simulate-day.mjs
   ```
   中度玩家日广告次数须落在 5-20 区间。

## 架构约定

- `src/core/` 全部纯逻辑：无 DOM、无引擎 API、无 IO，可注入 Rng 复现。
- Maker 引擎层（Lua）只做渲染与输入，结果一律调 core 逻辑。
- 数值配置一律走 `data/*.csv`，不在代码硬编码。
- 存档字段变更必须更新 `src/core/save.js` 的 `sanitizeSave` 并加兼容测试。

## 提交规范

```
feat: 刮刮乐核心生成器（先抽奖级再倒填符号）
fix: 修复模拟器 recordAd 返回值丢失
docs: GDD v1.1 加入上阵位解锁
```

提交前 `npm test` 全绿。构建/提交到 Maker 用 `maker_build_current_directory`（MCP），
本地预览用 `taptap-maker preview`。
