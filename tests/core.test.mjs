import { test } from "node:test";
import assert from "node:assert/strict";
import { generateTicket, countMatches, SYMBOLS } from "../src/core/lottery.js";
import { recoverResource, ticketLevel, ticketBonus, nextLevelProgress, offlineEarnings, upgradeCost, formatNumber } from "../src/core/economy.js";
import { spinWheel, targetAngle, applySpinResult, WHEEL_SECTORS } from "../src/core/wheel.js";
import { createAdState, canShowAd, recordAd, adReward, AD_PLACEMENTS } from "../src/core/ads.js";

const T1 = {
  id: "T1",
  tiers: [
    { matchCount: 0, probability: 0.65, payout: 0 },
    { matchCount: 3, probability: 0.24, payout: 8 },
    { matchCount: 5, probability: 0.08, payout: 20 },
    { matchCount: 7, probability: 0.026, payout: 80 },
    { matchCount: 9, probability: 0.004, payout: 300 },
  ],
};

test("彩票：格子数恒为 9", () => {
  for (let i = 0; i < 200; i++) {
    assert.equal(generateTicket(T1).cells.length, 9);
  }
});

test("彩票：匹配数与奖级一致", () => {
  for (let i = 0; i < 2000; i++) {
    const r = generateTicket(T1);
    assert.equal(countMatches(r.cells, r.winningSymbol), r.matchCount);
    if (r.matchCount < 3) assert.equal(r.payout, 0);
    if (r.matchCount === 3) assert.equal(r.payout, 8);
    if (r.matchCount === 9) assert.equal(r.payout, 300);
  }
});

test("彩票：非中奖格不含有效符号（除彩蛋外）", () => {
  let checked = 0;
  for (let i = 0; i < 500; i++) {
    const r = generateTicket(T1);
    for (const c of r.cells) {
      assert.ok(Object.values(SYMBOLS).includes(c), `未知符号 ${c}`);
      checked++;
    }
  }
  assert.ok(checked > 0);
});

test("彩票：可复现随机源产出相同结果", () => {
  const seq = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];
  const mk = () => { let i = 0; return { next: () => seq[i++ % seq.length] }; };
  const a = generateTicket(T1, mk());
  const b = generateTicket(T1, mk());
  assert.deepEqual(a, b);
});

// ---------- 经济 ----------

test("经济：自然恢复不超上限", () => {
  const r = recoverResource(0, 10 * 60 * 1000, 0, 30, 20);
  assert.equal(r.value, 20);
  assert.equal(r.gained, 20);
});

test("经济：恢复计算正确", () => {
  const r = recoverResource(0, 90 * 1000, 0, 30, 20);
  assert.equal(r.value, 3);
  assert.equal(r.gained, 3);
  assert.equal(r.remainderMs, 90 * 1000);
});

test("经济：票卡等级边界", () => {
  assert.equal(ticketLevel(0), 1);
  assert.equal(ticketLevel(29), 1);
  assert.equal(ticketLevel(30), 2);
  assert.equal(ticketLevel(100), 3);
  assert.equal(ticketLevel(800), 5);
  assert.equal(ticketLevel(9999), 5);
});

test("经济：等级加成与进度", () => {
  assert.equal(ticketBonus(0), 0);
  assert.equal(ticketBonus(100), 0.13);
  const p = nextLevelProgress(78);
  assert.equal(p.level, 2);
  assert.equal(p.remaining, 22);
});

test("经济：离线收益上限 8 小时", () => {
  const r = offlineEarnings(20 * 3600 * 1000, 10);
  assert.equal(r.seconds, 8 * 3600);
  assert.equal(r.capped, true);
  assert.equal(r.coins, 8 * 3600 * 10);
});

test("经济：升级成本指数增长", () => {
  const c1 = upgradeCost(500, 1);
  const c2 = upgradeCost(500, 2);
  assert.equal(c1, 500);
  assert.ok(c2 > c1);
  assert.equal(c2, Math.floor(500 * 1.55));
});

test("经济：数字格式化", () => {
  assert.equal(formatNumber(999), "999");
  assert.equal(formatNumber(12345), "1.2万");
  assert.equal(formatNumber(123456789), "1.2亿");
});

// ---------- 转盘 ----------

test("转盘：扇区概率和为 1", () => {
  const sum = WHEEL_SECTORS.reduce((a, s) => a + s.probability, 0);
  assert.ok(Math.abs(sum - 1) < 1e-9);
});

test("转盘：大奖能抽到", () => {
  let hit = 0;
  for (let i = 0; i < 20000; i++) {
    if (spinWheel().type === "jackpot") hit++;
  }
  assert.ok(hit > 300 && hit < 500, `jackpot=${hit}`);
});

test("转盘：定格角度落在目标扇区内", () => {
  for (let s = 1; s <= 8; s++) {
    const ang = targetAngle(s, 8, 0, 5, 0, () => 0.5);
    const norm = ((ang % 360) + 360) % 360;
    const center = (s - 1) * 45 + 22.5;
    assert.ok(Math.abs(norm - center) < 1e-6, `sector ${s}: ${norm} vs ${center}`);
  }
});

test("转盘：定格角度单调递增（不倒退）", () => {
  const a = targetAngle(3, 8, 720, 5, 0, () => 0.5);
  assert.ok(a > 720);
});

test("转盘：奖励结算", () => {
  const r = applySpinResult({ type: "jackpot", value: 200000 });
  assert.equal(r.coins, 200000);
  assert.equal(r.isJackpot, true);
  const t = applySpinResult({ type: "ticket", value: 5 });
  assert.equal(t.tickets, 5);
  assert.equal(t.coins, 0);
});

// ---------- 广告 ----------

test("广告：首次可看", () => {
  const s = createAdState("2026-11-05");
  const r = canShowAd(s, "A1_TICKET", 1_000_000);
  assert.equal(r.allowed, true);
});

test("广告：最小间隔拦截", () => {
  let s = createAdState("2026-11-05");
  s = recordAd(s, "A1_TICKET", 1_000_000);
  const r = canShowAd(s, "A1_TICKET", 1_000_000 + 5000);
  assert.equal(r.allowed, false);
  assert.equal(r.reason, "too_soon");
});

test("广告：单位上限拦截", () => {
  let s = createAdState("2026-11-05");
  for (let i = 0; i < 8; i++) s = recordAd(s, "A1_TICKET", i * 60_000);
  const r = canShowAd(s, "A1_TICKET", 10 * 60_000);
  assert.equal(r.allowed, false);
  assert.equal(r.reason, "placement_cap_reached");
});

test("广告：全局上限拦截", () => {
  let s = createAdState("2026-11-05");
  for (let i = 0; i < 30; i++) s = recordAd(s, "A2_BONUS", i * 60_000);
  const r = canShowAd(s, "A3_OFFLINE", 40 * 60_000);
  assert.equal(r.allowed, false);
  assert.equal(r.reason, "daily_total_reached");
});

test("广告：奖励换算", () => {
  assert.deepEqual(adReward("A1_TICKET"), { type: "ticket", value: 20 });
  assert.deepEqual(adReward("A2_BONUS", 400), { type: "coin", value: 400 });
  assert.deepEqual(adReward("A5_DIAMOND"), { type: "diamond", value: 50 });
});
