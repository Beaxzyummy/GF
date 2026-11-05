# 好运游戏厅（Fortune Arcade）

> 刮刮乐 × 美式彩票 × 幸运转盘，装在「游戏厅」框架里的解压刷宝小游戏。
> 纯单机离线 · 无内购 · IAA（广告变现）· TapTap 制造（Maker）平台。

## 文档导航

| 文档 | 内容 |
|---|---|
| [好运游戏厅-访谈提纲v2.0.md](./好运游戏厅-访谈提纲v2.0.md) | 9 模块深度访谈提纲与 11 项决策记录 |
| [50款同类游戏研究报告.md](./50款同类游戏研究报告.md) | 7 大赛道 50 款拆解，30/70 法则等硬结论 |
| [好运游戏厅-PRD.md](./好运游戏厅-PRD.md) | 需求、范围、排期、指标体系 |
| [好运游戏厅-GDD.md](./好运游戏厅-GDD.md) | 完整数值与系统设计（含 v1.1 修订） |
| [好运游戏厅-广告策划案.md](./好运游戏厅-广告策划案.md) | 5 广告位、频控、mock 方案、收益模型 |
| [docs/结果生成规范.md](./docs/结果生成规范.md) | 「先抽奖级再倒填符号」的合规实现说明 |

## 快速开始

```bash
npm test          # 62 个单元测试（概率 / 经济 / 转盘 / 广告 / 抽卡 / 员工 / 存档）
npm run verify    # 30 万次概率模拟校验
npm run verify:quick
node scripts/simulate-day.mjs            # 单日经济闭环模拟
node scripts/simulate-day.mjs --verbose  # 含中度玩家明细
```

## 目录结构

```
├── data/            # 数值配置（CSV，策划可直改）
│   ├── tickets.csv         # 6 种福彩票
│   ├── ticket_prizes.csv   # 30 行奖级分布
│   ├── wheel.csv           # 转盘 8 扇区
│   ├── gacha.csv           # 抽卡稀有度概率
│   ├── ads.csv             # 5 广告位
│   └── economy.csv         # 14 个可调参数
├── src/core/        # 纯逻辑（无引擎依赖，全部可测）
│   ├── lottery.js   # 刮刮乐结果生成（先抽奖级再倒填符号）
│   ├── wheel.js     # 转盘与停针动画参数
│   ├── gacha.js     # 抽卡（十连保底不污染公示概率）
│   ├── staff.js     # 员工产出/升级/上阵位解锁
│   ├── economy.js   # 三货币与恢复曲线
│   ├── ads.js       # 三层广告频控
│   └── save.js      # 存档与离线结算（时钟回拨防护）
├── scripts/         # 验证脚本
└── tests/           # node:test 单元测试
```

## 核心设计原则

1. **30/70 法则**：核心刮刮乐只占 30% 内容量，70% 是养成/收集（员工、上阵位、票卡等级）
2. **票缺口**：自然产出 < 消耗，缺口由「看广告」补 → 商业模型的心脏
3. **奖级先行、符号后填**：保证公示概率真实（合规红线）
4. **虚拟货币严禁充值**：纯 IAA，无内购 → 免版号（开放试玩）
5. **转盘 Coin Master 化**：转盘决定「下一步行动」而非输赢，规避赌博判定

## 分支策略

| 分支 | 内容 |
|---|---|
| `main` | 稳定版，随时可提交 Maker 构建 |
| `develop` | 集成分支 |
| `feat/core-scratch` | 刮刮乐核心玩法 |
| `feat/american-ticket` | HOT 全收票 |
| `feat/fortune-wheel` | 转盘 |
| `feat/phone-system` | 手机（抽卡+员工） |
| `feat/economy` | 经济与存档 |
| `feat/ads` | 广告接入 |
| `art` / `audio` / `docs` | 资源与文档 |

## Maker 工作流

```bash
npx @taptap/maker doctor        # 环境自检
npx @taptap/maker init          # 初始化（需 PAT）
npx @taptap/maker preview       # 本地预览
npx @taptap/maker build         # 构建
```

MCP 配置见 `.maker-mcp/config.json`（首次 init 后生成，绑定本仓库）。
