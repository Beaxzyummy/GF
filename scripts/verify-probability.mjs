#!/usr/bin/env node
/**
 * 概率自检：读取 data/*.csv，跑 N 次模拟，验证
 *  1. 各表概率之和 = 1.0000
 *  2. 实际奖级频率与公示偏差 < 阈值
 *  3. 特等奖确实会出现
 *  4. 奖级为 0 的票，匹配数永不为 3
 *  5. 双星彩蛋触发率符合预期
 *
 * 用法：node scripts/verify-probability.mjs [--n 1000000]
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { generateTicket, countMatches, SYMBOLS } from "../src/core/lottery.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

const argN = process.argv.indexOf("--n");
const N = argN > -1 ? Number(process.argv[argN + 1]) : 1_000_000;

/** 极简 CSV 解析（无引号字段，够用） */
function parseCsv(text) {
  const lines = text.trim().split(/\r?\n/);
  const header = lines[0].split(",");
  return lines.slice(1).map((line) => {
    const cols = line.split(",");
    const row = {};
    header.forEach((h, i) => (row[h.trim()] = cols[i]?.trim() ?? ""));
    return row;
  });
}

function loadTickets() {
  const tickets = parseCsv(readFileSync(join(ROOT, "data/tickets.csv"), "utf8"));
  const prizes = parseCsv(readFileSync(join(ROOT, "data/ticket_prizes.csv"), "utf8"));

  return tickets.map((t) => ({
    id: t.id,
    name: t.name,
    price: Number(t.price),
    winRate: Number(t.win_rate),
    tiers: prizes
      .filter((p) => p.ticket_id === t.id)
      .map((p) => ({
        matchCount: Number(p.match_count),
        probability: Number(p.probability),
        payout: Number(p.payout),
      })),
  }));
}

let failures = 0;
function check(label, ok, detail = "") {
  const tag = ok ? "  PASS" : "  FAIL";
  if (!ok) failures++;
  console.log(`${tag}  ${label}${detail ? "  " + detail : ""}`);
}

console.log(`\n=== 概率自检  (N=${N.toLocaleString()}) ===\n`);

const tickets = loadTickets();

// --- 1. 概率之和 ---
console.log("[1] 概率总和校验");
for (const t of tickets) {
  const sum = t.tiers.reduce((a, b) => a + b.probability, 0);
  check(`${t.name} 奖级概率和 = ${sum.toFixed(4)}`, Math.abs(sum - 1) < 1e-4);
}

// --- 2~5. 模拟 ---
console.log("\n[2] 奖级频率模拟");

for (const t of tickets) {
  const counts = new Map();
  let bonus = 0;
  let invalidTierZero = 0;

  for (let i = 0; i < N; i++) {
    const r = generateTicket(t, { next: Math.random });
    counts.set(r.matchCount, (counts.get(r.matchCount) || 0) + 1);
    if (r.bonusTicket) bonus++;
    if (r.matchCount < 3 && r.payout > 0) invalidTierZero++;
    // 校验格子数
    if (r.cells.length !== 9) throw new Error("格子数错误");
  }

  let maxDev = 0;
  const parts = [];
  for (const tier of t.tiers) {
    // 未中奖档（matchCount=0）实际覆盖 0/1/2 三种匹配数，需合并统计
    const actual =
      tier.matchCount === 0
        ? ((counts.get(0) || 0) + (counts.get(1) || 0) + (counts.get(2) || 0)) / N
        : (counts.get(tier.matchCount) || 0) / N;
    const dev = Math.abs(actual - tier.probability);
    maxDev = Math.max(maxDev, dev);
    if (tier.matchCount > 0) {
      parts.push(`${tier.matchCount}格:${(actual * 100).toFixed(2)}%(期望${(tier.probability * 100).toFixed(2)}%)`);
    }
  }

  check(
    `${t.name} 最大偏差 ${(maxDev * 100).toFixed(3)}%`,
    maxDev < 0.002,
    parts.join(" ")
  );

  // 特等奖必现
  const topTier = t.tiers[t.tiers.length - 1];
  const topCount = counts.get(topTier.matchCount) || 0;
  check(
    `  └ 特等奖出现 ${topCount} 次`,
    topCount > 0,
    `期望约 ${Math.round(topTier.probability * N)} 次`
  );

  // 一致性
  check(`  └ 匹配数<3 时产出恒为 0`, invalidTierZero === 0);

  // 双星彩蛋率
  const bonusRate = bonus / N;
  check(
    `  └ 双星彩蛋率 ${(bonusRate * 100).toFixed(2)}%`,
    Math.abs(bonusRate - 0.032) < 0.004
  );
}

// --- 6. 转盘 ---
console.log("\n[3] 转盘概率校验");
const wheel = parseCsv(readFileSync(join(ROOT, "data/wheel.csv"), "utf8"));
const wheelSum = wheel.reduce((a, r) => a + Number(r.probability), 0);
check(`转盘扇区概率和 = ${wheelSum.toFixed(4)}`, Math.abs(wheelSum - 1) < 1e-4);

// --- 7. 抽卡 ---
console.log("\n[4] 抽卡概率校验");
const gacha = parseCsv(readFileSync(join(ROOT, "data/gacha.csv"), "utf8"));
const gachaSum = gacha.reduce((a, r) => a + Number(r.probability), 0);
check(`抽卡概率和 = ${gachaSum.toFixed(4)}`, Math.abs(gachaSum - 1) < 1e-4);
for (const r of gacha) {
  const p = Number(r.probability);
  check(`  ${r.rarity} ${(p * 100).toFixed(2)}% 可被四舍五入到两位`, /^\d+\.\d{4}$/.test(r.probability));
}

// --- 8. 单张期望 ---
console.log("\n[5] 单张期望与回报率");
for (const t of tickets) {
  const ev = t.tiers.reduce((a, b) => a + b.probability * b.payout, 0);
  const ratio = ev / t.price;
  check(
    `${t.name.padEnd(3)} EV=${ev.toFixed(2).padStart(9)}  回报率=${ratio.toFixed(2)}`,
    ratio > 1 && ratio < 2.5
  );
}

console.log(`\n=== 结果：${failures === 0 ? "全部通过" : failures + " 项失败"} ===\n`);
process.exit(failures === 0 ? 0 : 1);
