/**
 * 抽卡 / 员工 / 存档 三个模块的单元测试
 * 运行：node --test tests/gacha-staff-save.test.mjs
 */

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import {
  RARITY_ORDER, RARITY_RANK, DUPLICATE_SHARDS, SHARDS_PER_UNIT,
  GACHA_PRICE, STAFF_CATALOG, RARITY_COUNT,
  pickRarity, pickEntry, pullOnce, pullTen, draw,
  shardsForDuplicate, settleDraw, canDraw, canCraft,
} from "../src/core/gacha.js";

import {
  STAFF_BASE, LEVEL_GAIN, MAX_LEVEL, BASE_SLOTS, MAX_SLOTS,
  SLOT_UNLOCK_COST,
  createStaff, staffProduction, staffUpgradeCost, upgradeStaff,
  slotStatus, unlockSlot, setDeployed, totalProduction, globalBonusOf,
} from "../src/core/staff.js";

import {
  createSave, detectClockTamper, settleOffline, sanitizeSave,
  serializeSave, deserializeSave, saveBytes, SAVE_VERSION,
  CLOCK_BACKWARD_TOLERANCE_MS,
} from "../src/core/save.js";

import { DEFAULT_ECONOMY } from "../src/core/economy.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/** 读取 gacha.csv */
function loadGachaTable() {
  const text = readFileSync(resolve(__dirname, "../data/gacha.csv"), "utf8").trim().split("\n");
  return text.slice(1).map((line) => {
    const [rarity, probability, count] = line.split(",");
    return { rarity, probability: Number(probability), count: Number(count) };
  });
}

/** 可复现的伪随机源 */
function makeRng(seed = 12345) {
  let s = seed >>> 0;
  return {
    next() {
      s = (s * 1664525 + 1013904223) >>> 0;
      return s / 4294967296;
    },
  };
}

const TABLE = loadGachaTable();

// ============ 抽卡 ============

test("抽卡：CSV 概率和 = 1", () => {
  const sum = TABLE.reduce((a, r) => a + r.probability, 0);
  assert.ok(Math.abs(sum - 1) < 1e-9, `概率和 ${sum}`);
});

test("抽卡：图鉴条目数与 CSV 的 count 一致", () => {
  for (const row of TABLE) {
    const actual = STAFF_CATALOG.filter((c) => c.rarity === row.rarity).length;
    assert.equal(actual, row.count, `${row.rarity} 条目数 ${actual} != ${row.count}`);
    assert.equal(actual, RARITY_COUNT[row.rarity]);
  }
  assert.equal(STAFF_CATALOG.length, 22);
});

test("抽卡：单抽稀有度分布匹配公示概率", () => {
  const N = 200000;
  const rng = makeRng(7);
  const counts = { UR: 0, SSR: 0, SR: 0, R: 0 };
  for (let i = 0; i < N; i++) counts[pickRarity(TABLE, rng)]++;

  for (const row of TABLE) {
    const actual = counts[row.rarity] / N;
    const diff = Math.abs(actual - row.probability);
    assert.ok(diff < 0.004, `${row.rarity} 实际 ${actual.toFixed(4)} vs 公示 ${row.probability}`);
  }
});

test("抽卡：单抽返回合法条目", () => {
  const rng = makeRng(99);
  for (let i = 0; i < 500; i++) {
    const e = pullOnce(TABLE, STAFF_CATALOG, rng);
    assert.ok(e && e.id && e.rarity, "条目结构非法");
    assert.ok(STAFF_CATALOG.some((c) => c.id === e.id));
  }
});

test("抽卡：十连必出 SR 及以上", () => {
  const rng = makeRng(2024);
  let guaranteedCount = 0;
  for (let i = 0; i < 5000; i++) {
    const { results, guaranteed } = pullTen(TABLE, STAFF_CATALOG, rng);
    assert.equal(results.length, 10);
    const hasHigh = results.some((e) => RARITY_RANK[e.rarity] >= RARITY_RANK.SR);
    assert.ok(hasHigh, "十连没有 SR 及以上，保底失效");
    if (guaranteed) guaranteedCount++;
  }
  // 纯随机下 10 连全 R 概率 ≈ 0.68^10 ≈ 2.1%，保底命中率应在 1.5%-3%
  const rate = guaranteedCount / 5000;
  assert.ok(rate > 0.01 && rate < 0.04, `保底触发率 ${rate.toFixed(4)} 偏离预期`);
});

test("抽卡：十连保底不污染前 9 抽概率", () => {
  // 只统计前 9 抽的 SR+ 比例，应接近公示值 (0.5+3.7+27.8)%=32%
  const N = 60000;
  const rng = makeRng(555);
  let high = 0;
  for (let i = 0; i < N; i++) {
    const { results } = pullTen(TABLE, STAFF_CATALOG, rng);
    for (let k = 0; k < 9; k++) {
      if (RARITY_RANK[results[k].rarity] >= RARITY_RANK.SR) high++;
    }
  }
  const rate = high / (N * 9);
  assert.ok(Math.abs(rate - 0.32) < 0.01, `前 9 抽 SR+ 率 ${rate.toFixed(4)} 偏离 0.32`);
});

test("抽卡：draw 模式分派正确", () => {
  const rng = makeRng(1);
  assert.equal(draw("single", TABLE, STAFF_CATALOG, rng).results.length, 1);
  assert.equal(draw("ten", TABLE, STAFF_CATALOG, rng).results.length, 10);
});

test("抽卡：重复转碎片数量正确", () => {
  assert.equal(shardsForDuplicate("R"), 1);
  assert.equal(shardsForDuplicate("SR"), 3);
  assert.equal(shardsForDuplicate("SSR"), 8);
  assert.equal(shardsForDuplicate("UR"), 20);
});

test("抽卡：settleDraw 区分新获得与重复", () => {
  const a = STAFF_CATALOG.find((c) => c.id === "r_01");
  const b = STAFF_CATALOG.find((c) => c.id === "sr_1");
  const { newStaff, shards, owned } = settleDraw([a, a, b], {});
  assert.equal(newStaff.length, 2);
  assert.equal(owned.r_01, 1);
  assert.equal(shards.R, 1, "第二次获得 r_01 应转 1 碎片");
});

test("抽卡：钻石不足时不可抽", () => {
  assert.equal(canDraw("single", 100).ok, false);
  assert.equal(canDraw("single", 160).ok, true);
  assert.equal(canDraw("ten", 1600).ok, true);
  assert.equal(canDraw("ten", 1599).short, 1);
  assert.equal(GACHA_PRICE.ten, GACHA_PRICE.single * 10, "十连不应打折");
});

test("抽卡：碎片合成门槛", () => {
  assert.equal(canCraft(SHARDS_PER_UNIT - 1).ok, false);
  assert.equal(canCraft(SHARDS_PER_UNIT).ok, true);
});

// ============ 员工 ============

test("员工：初始等级与产出", () => {
  const e = STAFF_CATALOG.find((c) => c.id === "r_01");
  const s = createStaff(e, 0);
  assert.equal(s.level, 1);
  assert.equal(staffProduction(s), STAFF_BASE.R.production);
});

test("员工：每级 +12% 产出", () => {
  const s = { rarity: "SR", level: 2 };
  const expected = Math.round(STAFF_BASE.SR.production * (1 + LEVEL_GAIN));
  assert.equal(staffProduction(s), expected);
});

test("员工：等级 20 封顶", () => {
  const s = { rarity: "R", level: 20 };
  assert.equal(staffUpgradeCost(s).atMax, true);
  assert.equal(upgradeStaff(s, 1e12).ok, false);
  assert.equal(upgradeStaff(s, 1e12).reason, "max_level");
});

test("员工：升级成本按 1.55 指数增长", () => {
  const s = { rarity: "R", level: 1 };
  const c1 = staffUpgradeCost(s, 1.55).cost;
  assert.equal(c1, 500);
  const c2 = staffUpgradeCost({ rarity: "R", level: 2 }, 1.55).cost;
  assert.equal(c2, Math.floor(500 * 1.55));
});

test("员工：金币不足升级失败", () => {
  const s = { rarity: "R", level: 1 };
  const r = upgradeStaff(s, 100);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "no_coin");
  assert.equal(r.staff.level, 1, "失败不应改变等级");
});

test("员工：升级成功扣费并提升等级", () => {
  const s = { rarity: "R", level: 1 };
  const r = upgradeStaff(s, 1000);
  assert.equal(r.ok, true);
  assert.equal(r.staff.level, 2);
  assert.equal(r.cost, 500);
});

// （上阵位解锁机制见下方独立测试组）

test("上阵位：初始 3 个，4/5/6 号位需金币解锁", () => {
  const st = { unlockedSlots: 3 };
  const s = slotStatus(st);
  assert.equal(s.slots, 3);
  assert.deepEqual(s.nextUnlock, { slot: 4, cost: 50_000 });
});

test("上阵位：解锁成功扣费", () => {
  const st = { unlockedSlots: 3 };
  const r = unlockSlot(st, 50_000);
  assert.equal(r.ok, true);
  assert.equal(r.unlockedSlots, 4);
  assert.equal(r.cost, 50_000);
});

test("上阵位：金币不足拒绝", () => {
  const r = unlockSlot({ unlockedSlots: 3 }, 49_999);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "no_coin");
  assert.equal(r.cost, 50_000);
});

test("上阵位：满 6 后不能再解锁", () => {
  const r = unlockSlot({ unlockedSlots: 6 }, 1e12);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "max_slots");
});

test("上阵位：三档解锁价格形成阶梯", () => {
  assert.equal(SLOT_UNLOCK_COST[4], 50_000);
  assert.ok(SLOT_UNLOCK_COST[5] > SLOT_UNLOCK_COST[4] * 20, "5 号位应显著更贵");
  assert.ok(SLOT_UNLOCK_COST[6] > SLOT_UNLOCK_COST[5] * 10, "6 号位应显著更贵");
});

test("上阵位：低存档兼容（无 unlockedSlots 字段视为 3）", () => {
  const s = slotStatus({});
  assert.equal(s.slots, 3);
});

test("员工：上阵超过位数被拒", () => {
  const staffs = [
    { id: "a", deployed: true },
    { id: "b", deployed: true },
    { id: "c", deployed: true },
    { id: "d", deployed: false },
  ];
  const r = setDeployed(staffs, "d", true, 3);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "slots_full");
});

test("员工：下阵总是允许", () => {
  const staffs = [{ id: "a", deployed: true }];
  const r = setDeployed(staffs, "a", false, 0);
  assert.equal(r.ok, true);
  assert.equal(r.staffs[0].deployed, false);
});

test("员工：上阵重复调用幂等", () => {
  const staffs = [{ id: "a", deployed: true }];
  const r = setDeployed(staffs, "a", true, 3);
  assert.equal(r.ok, true);
  assert.equal(r.staffs.filter((s) => s.deployed).length, 1);
});

test("员工：总产出只算上阵的", () => {
  const staffs = [
    { id: "a", rarity: "R", level: 1, deployed: true },
    { id: "b", rarity: "R", level: 1, deployed: true },
    { id: "c", rarity: "R", level: 1, deployed: false },
  ];
  assert.equal(totalProduction(staffs), 4);
});

test("员工：大橘提供全局 +50%", () => {
  const staffs = [
    { id: "ur_daju", rarity: "UR", level: 1, deployed: true },
    { id: "a", rarity: "R", level: 1, deployed: true },
  ];
  assert.equal(globalBonusOf(staffs), 0.5);
  // (800 + 2) * 1.5 = 1203
  assert.equal(totalProduction(staffs, { globalBonus: 0.5 }), Math.floor(802 * 1.5));
  assert.equal(globalBonusOf([{ id: "a" }]), 0);
});

// ============ 存档 ============

test("存档：新建存档字段完整", () => {
  const s = createSave(1000);
  assert.equal(s.version, SAVE_VERSION);
  assert.equal(s.tickets, 20);
  assert.equal(s.diamonds, 160);
  assert.ok(Array.isArray(s.staffs));
});

test("存档：离线金币按上阵产出结算", () => {
  const now = 1_700_000_000_000;
  const save = { ...createSave(now), staffs: [{ id: "a", rarity: "R", level: 1, deployed: true }] };
  const later = now + 3600 * 1000; // 1 小时
  const { bill } = settleOffline(save, later);
  assert.equal(bill.coins, 2 * 3600, "R 员工 2/秒 × 3600 秒");
  assert.equal(bill.capped, false);
});

test("存档：离线收益封顶 8 小时", () => {
  const now = 1_700_000_000_000;
  const save = { ...createSave(now), staffs: [{ id: "a", rarity: "R", level: 1, deployed: true }] };
  const later = now + 48 * 3600 * 1000;
  const { bill } = settleOffline(save, later);
  assert.equal(bill.capped, true);
  assert.equal(bill.offlineSeconds, DEFAULT_ECONOMY.offlineCapHours * 3600);
  assert.equal(bill.coins, 2 * 8 * 3600);
});

test("存档：时钟回拨被识别且不结算", () => {
  const now = 1_700_000_000_000;
  const save = { ...createSave(now), staffs: [{ id: "a", rarity: "R", level: 1, deployed: true }] };
  const past = now - 2 * 3600 * 1000;
  const { save: next, bill } = settleOffline(save, past);
  assert.equal(bill.tampered, true);
  assert.equal(bill.coins, 0);
  assert.equal(next.flags.clockTampered, true);
  assert.equal(next.flags.tamperCount, 1);
});

test("存档：小幅时钟回拨（5 分钟内）不算篡改", () => {
  const now = 1_700_000_000_000;
  const past = now - (CLOCK_BACKWARD_TOLERANCE_MS - 1000);
  const r = detectClockTamper(now, past);
  assert.equal(r.tampered, false);
});

test("存档：票自然恢复不超过上限", () => {
  const now = 1_700_000_000_000;
  const save = { ...createSave(now), tickets: 20 };
  const later = now + 10 * 3600 * 1000;
  const { save: next } = settleOffline(save, later);
  assert.equal(next.tickets, DEFAULT_ECONOMY.ticketCap);
});

test("存档：票按 30 秒/张恢复", () => {
  const now = 1_700_000_000_000;
  const save = { ...createSave(now), tickets: 0, ticketLastTs: now };
  const later = now + 150 * 1000; // 150 秒 = 5 张
  const { save: next, bill } = settleOffline(save, later);
  assert.equal(bill.ticketsGained, 5);
  assert.equal(next.tickets, 5);
});

test("存档：脏存档被修正而不是抛错", () => {
  const now = 1_700_000_000_000;
  const dirty = {
    version: 1,
    coins: -100,
    tickets: 9999,
    energy: -5,
    staffs: "not-an-array",
    lastSeenAt: now + 999999,
  };
  const { save, fixed } = sanitizeSave(dirty, now);
  assert.ok(fixed.length > 0);
  assert.equal(save.coins, 0);
  assert.equal(save.tickets, DEFAULT_ECONOMY.ticketCap);
  assert.equal(save.energy, 0);
  assert.ok(Array.isArray(save.staffs));
  assert.equal(save.lastSeenAt, now);
});

test("存档：序列化往返一致", () => {
  const now = 1_700_000_000_000;
  const save = createSave(now);
  save.coins = 123456;
  save.staffs = [createStaff(STAFF_CATALOG[0], now)];
  const { save: back, fixed } = deserializeSave(serializeSave(save), now);
  assert.equal(fixed.length, 0);
  assert.equal(back.coins, 123456);
  assert.equal(back.staffs.length, 1);
});

test("存档：非法 JSON 回落到新存档", () => {
  const now = 1_700_000_000_000;
  const { save, fixed } = deserializeSave("{broken", now);
  assert.equal(save.version, SAVE_VERSION);
  assert.ok(fixed.includes("empty"), `应标记为空档，实际 ${JSON.stringify(fixed)}`);
});

test("存档：null / 数组 / 字符串都回落新存档", () => {
  const now = 1_700_000_000_000;
  for (const bad of [null, [], "abc", 42]) {
    const { save, fixed } = sanitizeSave(bad, now);
    assert.equal(save.version, SAVE_VERSION);
    assert.deepEqual(fixed, ["empty"]);
  }
});

test("存档：高版本存档降级保留货币", () => {
  const now = 1_700_000_000_000;
  const { save, fixed } = sanitizeSave({ version: 99, coins: 88888 }, now);
  assert.ok(fixed.includes("version"));
  assert.equal(save.coins, 88888);
  assert.equal(save.version, SAVE_VERSION);
});

test("存档：体积远小于本地存储限制", () => {
  const now = 1_700_000_000_000;
  const save = createSave(now);
  save.staffs = STAFF_CATALOG.map((e) => createStaff(e, now));
  const bytes = saveBytes(save);
  assert.ok(bytes < 8 * 1024, `存档 ${bytes} 字节，超出预期`);
});
