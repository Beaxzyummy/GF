/**
 * 员工系统（纯逻辑）
 *
 * 对应 GDD 第 7 章（v1.1）：
 * - 四条属性：每秒产出 / 上阵位 / 等级 / 碎片
 * - 升级成本 cost(n) = base × 1.55^(n-1)，每级 +12% 产出，上限 20 级
 * - 上阵位初始 3 个，4/5/6 号位需金币解锁（金币回收口的核心）
 * - 离线收益上限 8 小时，领取后清零
 */

import { DEFAULT_ECONOMY, upgradeCost } from "./economy.js";

/** 各稀有度的基础产出与升级成本（GDD 7.2） */
export const STAFF_BASE = Object.freeze({
  R: { production: 2, upgradeBase: 500 },
  SR: { production: 15, upgradeBase: 4000 },
  SSR: { production: 120, upgradeBase: 30000 },
  UR: { production: 800, upgradeBase: 200000 },
});

/** 每级产出增幅 */
export const LEVEL_GAIN = 0.12;

/** 等级上限 */
export const MAX_LEVEL = 20;

/** 初始上阵位（免费） */
export const BASE_SLOTS = 3;

/** 上阵位上限 */
export const MAX_SLOTS = 6;

/**
 * 上阵位解锁价格（金币回收口的核心）。
 *
 * 设计逻辑（v1.1）：
 * - 4 号位 5 万：轻度玩家攒 1-2 天，是第一个「值得为之攒钱」的目标
 * - 5 号位 200 万：中度玩家 4-6 天，配合票卡升级形成中期目标
 * - 6 号位 5000 万：重度玩家 2-3 周的长线目标
 *
 * 价格锚点来自 simulate-day 的金币产出曲线：
 * 中度玩家 T2 日产出 ≈ 3400 币 → 5 万 = 15 天太贵 → 配合 T3 票种升级后 4-6 天可达成
 */
export const SLOT_UNLOCK_COST = Object.freeze({
  4: 50_000,
  5: 2_000_000,
  6: 50_000_000,
});

/** UR 全局加成（大橘） */
export const UR_GLOBAL_BONUS = 0.5;

/**
 * 生成一个员工的初始实例。
 * @param {{id:string, name:string, rarity:string}} entry 图鉴条目
 * @param {number} nowTs
 */
export function createStaff(entry, nowTs = 0) {
  const base = STAFF_BASE[entry.rarity];
  if (!base) throw new Error(`未知稀有度：${entry.rarity}`);
  return {
    id: entry.id,
    name: entry.name,
    rarity: entry.rarity,
    level: 1,
    deployed: false,
    acquiredAt: nowTs,
  };
}

/**
 * 单个员工在某等级的每秒产出。
 * @param {{rarity:string, level:number}} staff
 */
export function staffProduction(staff) {
  const base = STAFF_BASE[staff.rarity];
  if (!base) return 0;
  const lv = Math.min(Math.max(1, staff.level), MAX_LEVEL);
  return Math.round(base.production * Math.pow(1 + LEVEL_GAIN, lv - 1));
}

/**
 * 升级到下一级的花费。
 * @param {{rarity:string, level:number}} staff
 * @param {number} ratio
 * @returns {{cost:number, atMax:boolean}}
 */
export function staffUpgradeCost(staff, ratio = DEFAULT_ECONOMY.upgradeCostRatio) {
  if (staff.level >= MAX_LEVEL) return { cost: 0, atMax: true };
  const base = STAFF_BASE[staff.rarity].upgradeBase;
  return { cost: upgradeCost(base, staff.level, ratio), atMax: false };
}

/**
 * 尝试升级。
 * @returns {{ok:boolean, staff:object, cost:number, reason?:string}}
 */
export function upgradeStaff(staff, coins, ratio = DEFAULT_ECONOMY.upgradeCostRatio) {
  if (staff.level >= MAX_LEVEL) {
    return { ok: false, staff, cost: 0, reason: "max_level" };
  }
  const { cost } = staffUpgradeCost(staff, ratio);
  if (coins < cost) {
    return { ok: false, staff, cost, reason: "no_coin" };
  }
  return { ok: true, staff: { ...staff, level: staff.level + 1 }, cost };
}

/**
 * 当前上阵位状态。
 * @param {object} saveState 需含 unlockedSlots 与 titleIndex
 * @returns {{slots:number, nextUnlock:{slot:number, cost:number}|null}}
 */
export function slotStatus(saveState) {
  const unlocked = saveState.unlockedSlots ?? BASE_SLOTS;
  const nextSlot = unlocked + 1;
  const cost = SLOT_UNLOCK_COST[nextSlot];
  return {
    slots: Math.min(unlocked, MAX_SLOTS),
    nextUnlock: cost != null ? { slot: nextSlot, cost } : null,
  };
}

/**
 * 解锁下一个上阵位。
 * @returns {{ok:boolean, unlockedSlots:number, cost:number, reason?:string}}
 */
export function unlockSlot(saveState, coins) {
  const { nextUnlock } = slotStatus(saveState);
  if (!nextUnlock) return { ok: false, unlockedSlots: saveState.unlockedSlots ?? BASE_SLOTS, cost: 0, reason: "max_slots" };
  if (coins < nextUnlock.cost) return { ok: false, unlockedSlots: saveState.unlockedSlots ?? BASE_SLOTS, cost: nextUnlock.cost, reason: "no_coin" };
  return { ok: true, unlockedSlots: nextUnlock.slot, cost: nextUnlock.cost };
}

/**
 * 上阵 / 下阵。
 * @param {object[]} staffs
 * @param {string} staffId
 * @param {boolean} deploy
 * @param {number} slots 当前已解锁上阵位数
 * @returns {{ok:boolean, staffs:object[], reason?:string}}
 */
export function setDeployed(staffs, staffId, deploy, slots) {
  const target = staffs.find((s) => s.id === staffId);
  if (!target) return { ok: false, staffs, reason: "not_found" };

  if (deploy) {
    if (target.deployed) return { ok: true, staffs };
    const n = staffs.filter((s) => s.deployed).length;
    if (n >= slots) return { ok: false, staffs, reason: "slots_full" };
  }

  return {
    ok: true,
    staffs: staffs.map((s) => (s.id === staffId ? { ...s, deployed: deploy } : s)),
  };
}

/**
 * 所有上阵员工的总产出/秒。
 * 注意：UR「大橘」的 +50% 是全局加成，在 totalProduction 中统一施加，
 * 不叠加到单员工 staffProduction 上，避免重复计算。
 * @param {object[]} staffs
 * @param {{globalBonus?:number}} opts
 */
export function totalProduction(staffs, opts = {}) {
  const deployed = staffs.filter((s) => s.deployed);
  const sum = deployed.reduce((acc, s) => acc + staffProduction(s), 0);
  const bonus = opts.globalBonus ?? 0;
  return Math.floor(sum * (1 + bonus));
}

/**
 * 是否持有全局加成员工（大橘 UR）。
 * @param {object[]} staffs
 * @param {string} urStaffId
 */
export function globalBonusOf(staffs, urStaffId = "ur_daju") {
  const has = staffs.some((s) => s.id === urStaffId);
  return has ? UR_GLOBAL_BONUS : 0;
}

/**
 * 按产出线汇总（用于后台的三个产出面板）。
 * @param {object[]} staffs
 * @param {(id:string)=>string} lineOf id → 产出线映射
 */
export function productionByLine(staffs, lineOf) {
  const out = { scratch: 0, wheel: 0, office: 0 };
  for (const s of staffs) {
    if (!s.deployed) continue;
    const line = lineOf(s.id) || "office";
    out[line] = (out[line] || 0) + staffProduction(s);
  }
  return out;
}
