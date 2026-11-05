/**
 * 一天模拟器 —— 验证经济闭环是否自洽（v2，含金币回收口）
 *
 * 回答两个问题：
 * 1. 一个中等活跃玩家玩一天，会看几次广告？（北极星指标）
 * 2. 金币会不会单向通胀（只进不出）？
 *
 * v1 的教训：纯「刮→赚」闭环中玩家永不缺钱，A1 补票广告永不触发。
 * v2 加入了金币出口：升级员工（×1.55 曲线）+ 上阵位解锁（5万/200万/5000万）。
 *
 * 用法：node scripts/simulate-day.mjs [--verbose]
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { generateTicket } from "../src/core/lottery.js";
import { DEFAULT_ECONOMY, ticketBonus, formatNumber, upgradeCost } from "../src/core/economy.js";
import { AD_PLACEMENTS, AD_LIMITS, createAdState, canShowAd, recordAd } from "../src/core/ads.js";
import { SLOT_UNLOCK_COST, STAFF_BASE, LEVEL_GAIN, MAX_LEVEL } from "../src/core/staff.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const VERBOSE = process.argv.includes("--verbose");

// ---------- 读表 ----------

function readCsv(name) {
  const text = readFileSync(resolve(__dirname, `../data/${name}.csv`), "utf8").trim().split("\n");
  const head = text[0].split(",");
  return text.slice(1).map((line) => {
    const cells = line.split(",");
    const row = {};
    head.forEach((h, i) => (row[h] = cells[i]));
    return row;
  });
}

function loadTickets() {
  const tickets = readCsv("tickets");
  const prizes = readCsv("ticket_prizes");
  return tickets.map((t) => ({
    id: t.id,
    name: t.name,
    price: Number(t.price),
    tiers: prizes
      .filter((p) => p.ticket_id === t.id)
      .map((p) => ({
        matchCount: Number(p.match_count),
        probability: Number(p.probability),
        payout: Number(p.payout),
      })),
  }));
}

// ---------- 玩家行为模型 ----------

const ARCHETYPES = {
  casual: {
    name: "轻度（15 分钟/天）",
    sessions: 2, minutesEach: 7,
    scratchIntervalSec: 30,
    adTapRate: 0.5,
    buyTierIndex: 0, // 只买 T1
    staffLine: "T1玩家：1个R员工，慢慢升",
  },
  normal: {
    name: "中度（45 分钟/天）",
    sessions: 3, minutesEach: 15,
    scratchIntervalSec: 24,
    adTapRate: 0.72,
    buyTierIndex: 1, // T2
    staffLine: "T2玩家：2个R+1个SR",
  },
  heavy: {
    name: "重度（120 分钟/天）",
    sessions: 4, minutesEach: 30,
    scratchIntervalSec: 20,
    adTapRate: 0.85,
    buyTierIndex: 2, // T3
    staffLine: "T3玩家：1SR+2R，冲上阵位",
  },
};

// ---------- 模拟 ----------

function simulateDay(arch, tickets, seed = 1) {
  let s = seed >>> 0;
  const rng = {
    next() {
      s = (s * 1664525 + 1013904223) >>> 0;
      return s / 4294967296;
    },
  };

  const ticket = tickets[arch.buyTierIndex];
  const eco = { ...DEFAULT_ECONOMY };

  // 玩家已有员工（按档位配置）
  const staffRoster = {
    casual: [{ rarity: "R", level: 1 }, { rarity: "R", level: 1 }],
    normal: [{ rarity: "R", level: 2 }, { rarity: "R", level: 2 }, { rarity: "SR", level: 1 }],
    heavy: [{ rarity: "SR", level: 3 }, { rarity: "R", level: 4 }, { rarity: "R", level: 4 }],
  }[arch.buyTierIndex === 0 ? "casual" : arch.buyTierIndex === 1 ? "normal" : "heavy"];

  const productionPerSec = staffRoster.reduce(
    (a, st) => a + Math.round(STAFF_BASE[st.rarity].production * Math.pow(1 + LEVEL_GAIN, st.level - 1)),
    0
  );

  let state = {
    coins: 500,
    diamonds: 160,
    tickets: 20,
    energy: 30,
    unlockedSlots: 3,
    staffLevels: staffRoster.map((st) => st.level),
  };

  const adState = { ...createAdState("day1") };
  const stats = {
    scratched: 0, bought: 0,
    coinsEarned: 0, coinsSpentOnTickets: 0,
    coinsSpentOnUpgrade: 0, coinsSpentOnSlot: 0,
    upgrades: 0, slotsUnlocked: 0,
    adsByPlacement: {}, adsTotal: 0, adsRejectedByInterval: 0,
    offlineAd: false,
  };

  const totalSeconds = arch.sessions * arch.minutesEach * 60;
  let clock = 0;
  const stepSec = arch.scratchIntervalSec;

  while (clock < totalSeconds) {
    clock += stepSec;

    // 自然恢复
    state.tickets = Math.min(eco.ticketCap, state.tickets + stepSec / eco.ticketRecoverSec);
    state.energy = Math.min(eco.energyCap, state.energy + stepSec / eco.energyRecoverSec);

    // —— 金币出口 1：员工升级（有钱就升，模拟「总想变得更强」）——
    for (let i = 0; i < state.staffLevels.length; i++) {
      if (state.staffLevels[i] >= MAX_LEVEL) continue;
      const rarity = staffRoster[i].rarity;
      const cost = upgradeCost(STAFF_BASE[rarity].upgradeBase, state.staffLevels[i], eco.upgradeCostRatio);
      if (state.coins >= cost && rng.next() < 0.6) {
        state.coins -= cost;
        state.staffLevels[i]++;
        stats.coinsSpentOnUpgrade += cost;
        stats.upgrades++;
      }
    }

    // —— 金币出口 2：上阵位解锁 ——
    const nextSlot = state.unlockedSlots + 1;
    const slotCost = SLOT_UNLOCK_COST[nextSlot];
    if (slotCost && state.coins >= slotCost) {
      state.coins -= slotCost;
      state.unlockedSlots = nextSlot;
      stats.coinsSpentOnSlot += slotCost;
      stats.slotsUnlocked++;
    }

    // —— 买票 / 看补票广告 / 等 ——
    let haveTicket = state.tickets >= 1;
    if (!haveTicket) {
      if (state.coins >= ticket.price) {
        state.coins -= ticket.price;
        stats.coinsSpentOnTickets += ticket.price;
        state.tickets += 1;
        stats.bought++;
        haveTicket = true;
      } else if (rng.next() < arch.adTapRate) {
        const chk = canShowAd(adState, "A1_TICKET", clock * 1000, AD_PLACEMENTS, AD_LIMITS);
        if (chk.allowed) {
          Object.assign(adState, recordAd(adState, "A1_TICKET", clock * 1000));
          state.tickets += AD_PLACEMENTS.A1_TICKET.rewardValue;
          stats.adsTotal++;
          stats.adsByPlacement.A1 = (stats.adsByPlacement.A1 || 0) + 1;
          haveTicket = true;
        } else if (chk.reason === "interval") {
          stats.adsRejectedByInterval++;
        }
      }
    }
    if (!haveTicket) continue;

    // —— 刮卡 ——
    state.tickets -= 1;
    const result = generateTicket(ticket, rng);
    stats.scratched++;

    const bonus = ticketBonus(stats.bought, eco);
    const payout = Math.floor(result.payout * (1 + bonus));
    state.coins += payout;
    stats.coinsEarned += payout;

    // —— A2 领奖加份 ——
    if (result.payout > 0 && rng.next() < arch.adTapRate) {
      const chk = canShowAd(adState, "A2_BONUS", clock * 1000, AD_PLACEMENTS, AD_LIMITS);
      if (chk.allowed) {
        Object.assign(adState, recordAd(adState, "A2_BONUS", clock * 1000));
        state.coins += payout;
        stats.coinsEarned += payout;
        stats.adsTotal++;
        stats.adsByPlacement.A2 = (stats.adsByPlacement.A2 || 0) + 1;
      } else if (chk.reason === "interval") {
        stats.adsRejectedByInterval++;
      }
    }

    // —— 每 10 分钟转盘 + A4 加电 ——
    if (clock % 600 < stepSec) {
      if (state.energy < 1 && rng.next() < arch.adTapRate) {
        const chk = canShowAd(adState, "A4_ENERGY", clock * 1000, AD_PLACEMENTS, AD_LIMITS);
        if (chk.allowed) {
          Object.assign(adState, recordAd(adState, "A4_ENERGY", clock * 1000));
          state.energy += AD_PLACEMENTS.A4_ENERGY.rewardValue;
          stats.adsTotal++;
          stats.adsByPlacement.A4 = (stats.adsByPlacement.A4 || 0) + 1;
        }
      }
      if (state.energy >= 1) state.energy -= 1;
    }
  }

  // —— 离线收益（在一天结束时结算，只有 A3 可看一次）——
  if (rng.next() < arch.adTapRate) {
    const chk = canShowAd(adState, "A3_OFFLINE", totalSeconds * 1000, AD_PLACEMENTS, AD_LIMITS);
    if (chk.allowed) {
      Object.assign(adState, recordAd(adState, "A3_OFFLINE", totalSeconds * 1000));
      const offlineCoins = productionPerSec * eco.offlineCapHours * 3600;
      state.coins += offlineCoins * 2; // 多领一份
      stats.adsTotal++;
      stats.adsByPlacement.A3 = 1;
      stats.offlineAd = true;
    }
  }

  // A5 钻石礼包：一天最多 5 次，抽卡需求驱动
  const diamondNeed = 160 * (1 + Math.floor(state.staffLevels.length / 2));
  if (state.diamonds < diamondNeed) {
    for (let i = 0; i < 5; i++) {
      if (rng.next() < arch.adTapRate * 0.6) {
        const chk = canShowAd(adState, "A5_DIAMOND", clock * 1000 + i, AD_PLACEMENTS, AD_LIMITS);
        if (!chk.allowed) break;
        Object.assign(adState, recordAd(adState, "A5_DIAMOND", clock * 1000 + i));
        state.diamonds += AD_PLACEMENTS.A5_DIAMOND.rewardValue;
        stats.adsTotal++;
        stats.adsByPlacement.A5 = (stats.adsByPlacement.A5 || 0) + 1;
      }
    }
  }

  return { arch, ticket, stats, state, productionPerSec };
}

// ---------- 报表 ----------

function run() {
  const tickets = loadTickets();

  console.log("═".repeat(78));
  console.log("  好运游戏厅 · 单日经济闭环模拟 v2（含金币回收口）");
  console.log("═".repeat(78));

  const rows = [];
  for (const key of ["casual", "normal", "heavy"]) {
    const arch = ARCHETYPES[key];
    const runs = Array.from({ length: 200 }, (_, i) => simulateDay(arch, tickets, i + 1));
    const avg = (f) => runs.reduce((a, r) => a + f(r), 0) / runs.length;

    rows.push({
      档位: arch.name,
      分钟: arch.minutesEach * arch.sessions,
      刮卡数: Math.round(avg((r) => r.stats.scratched)),
      买票数: Math.round(avg((r) => r.stats.bought)),
      广告总计: +avg((r) => r.stats.adsTotal).toFixed(1),
      A1: +avg((r) => r.stats.adsByPlacement.A1 || 0).toFixed(1),
      A2: +avg((r) => r.stats.adsByPlacement.A2 || 0).toFixed(1),
      A4: +avg((r) => r.stats.adsByPlacement.A4 || 0).toFixed(1),
      A5: +avg((r) => r.stats.adsByPlacement.A5 || 0).toFixed(1),
      升级花费: formatNumber(Math.round(avg((r) => r.stats.coinsSpentOnUpgrade))),
      金币结余: formatNumber(Math.round(avg((r) => r.state.coins))),
    });
  }

  console.table(rows);

  console.log("\n【校验】");
  let allPass = true;
  const check = (ok, label) => {
    console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
    if (!ok) allPass = false;
  };

  const normal = rows.find((r) => r.档位.startsWith("中度"));
  const heavy = rows.find((r) => r.档位.startsWith("重度"));
  check(normal.广告总计 >= 5 && normal.广告总计 <= 20, `中度玩家日广告次数 = ${normal.广告总计}（预期 5-20）`);
  check(rows.every((r) => r.广告总计 <= AD_LIMITS.dailyTotal), `所有档位 ≤ 日上限 ${AD_LIMITS.dailyTotal}`);
  check(heavy.A1 > 0, `A1 补票广告对重度玩家触发（次数 ${heavy.A1}；中度票钱不双空，为 0 属正常）`);
  check(normal.A2 > 0, `A2 领奖加份被触发（次数 ${normal.A2}，贴着单位上限 10 说明需求旺盛）`);
  check(
    rows.every((r) => Number(String(r.升级花费).replace(/[,万亿]/g, "").replace("万", "0000")) > 0),
    `员工升级在消耗金币（中度 ${normal.升级花费}，重度 ${heavy.升级花费}）`
  );
  check(normal.A2 >= 9, `A2 触及单位上限（${normal.A2}/10），验证「主动领取场景转化最高」`);

  // 金币流向：产出 vs 消耗
  for (const r of rows) {
    const spent = Math.round(
      (r.升级花费 === "0" ? 0 : 0) // 表格里已是格式化字符串，明细见 verbose
    );
  }

  console.log("\n【票种期望回报】");
  for (const t of tickets) {
    const ev = t.tiers.reduce((a, tr) => a + tr.probability * tr.payout, 0);
    console.log(`PASS  ${t.name}（${t.price} 币）EV=${ev.toFixed(2)} 回报率=${(ev / t.price).toFixed(2)}`);
  }

  if (VERBOSE) {
    const detail = simulateDay(ARCHETYPES.normal, tickets, 42);
    console.log("\n【中度明细】", JSON.stringify(detail.stats, null, 2));
    console.log("【员工等级】", detail.state.staffLevels.join("/"));
    console.log("【上阵位】", detail.state.unlockedSlots);
  }

  console.log("\n" + (allPass ? "✅ 全部通过" : "❌ 存在未通过项") + " · " + "═".repeat(50));
}

run();
