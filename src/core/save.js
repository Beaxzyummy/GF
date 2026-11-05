/**
 * 存档系统（纯逻辑）
 *
 * 目标：单机离线也能有可信的离线收益。
 *
 * 三条防线：
 * 1. 单调时钟校验 —— 系统时间只能前进，大幅回拨视为篡改
 * 2. 上限截断 —— 无论怎么改时间，最多只结算 offlineCapHours
 * 3. 累计校验 —— 单次离线收益超过理论最大值直接判脏
 *
 * 明确不做：加密 / 混淆 / 服务端校验。本项目纯单机无内购，
 * 防作弊只需防「随手改时间刷币」，不需要防专业破解。
 */

import { DEFAULT_ECONOMY, offlineEarnings, recoverResource } from "./economy.js";
import { totalProduction } from "./staff.js";

export const SAVE_VERSION = 1;

/** 时间回拨容忍阈值：5 分钟内视为正常（时区/校准误差） */
export const CLOCK_BACKWARD_TOLERANCE_MS = 5 * 60 * 1000;

/**
 * 创建一份全新存档。
 * @param {number} nowTs
 */
export function createSave(nowTs) {
  return {
    version: SAVE_VERSION,
    createdAt: nowTs,
    lastSeenAt: nowTs,
    lastTickAt: nowTs,

    // 三货币
    coins: 500,
    diamonds: 160,
    tickets: 20,
    energy: 30,

    // 票/电恢复的时间基准
    ticketLastTs: nowTs,
    energyLastTs: nowTs,

    // 进度
    titleIndex: 0,
    unlockedSlots: 3, // 上阵位解锁进度（4/5/6 号位需金币解锁）
    totalBoughtByTicket: {},
    staffs: [],
    ownedStaffIds: [],
    shards: {},
    clearCount: {}, // 每种票刮开张数

    // 广告
    adState: { date: "", total: 0, byPlacement: {}, lastTs: 0 },

    // 统计
    stats: {
      totalScratched: 0,
      totalWon: 0,
      maxPayout: 0,
      totalAdsWatched: 0,
      daysPlayed: 0,
    },

    // 防作弊
    flags: { clockTampered: false, tamperCount: 0 },
  };
}

/**
 * 检测时钟回拨。
 * @returns {{tampered:boolean, backwardsMs:number}}
 */
export function detectClockTamper(lastSeenAt, nowTs) {
  const backwardsMs = lastSeenAt - nowTs;
  const tampered = backwardsMs > CLOCK_BACKWARD_TOLERANCE_MS;
  return { tampered, backwardsMs: Math.max(0, backwardsMs) };
}

/**
 * 结算离线收益 + 资源恢复。
 *
 * 返回新存档与一份「给玩家看的账单」，界面层直接渲染 bill 即可。
 *
 * @param {object} save
 * @param {number} nowTs
 * @param {object} opts
 * @returns {{
 *   save:object,
 *   bill:{
 *     offlineMs:number, offlineSeconds:number, coins:number,
 *     capped:boolean, ticketsGained:number, energyGained:number,
 *     tampered:boolean
 *   }
 * }}
 */
export function settleOffline(save, nowTs, opts = {}) {
  const eco = { ...DEFAULT_ECONOMY, ...(opts.economy || {}) };
  const next = { ...save, stats: { ...save.stats }, flags: { ...save.flags } };

  // —— 1. 时钟校验 ——
  const { tampered } = detectClockTamper(save.lastSeenAt, nowTs);
  if (tampered) {
    next.flags.clockTampered = true;
    next.flags.tamperCount = (next.flags.tamperCount || 0) + 1;
    // 篡改后不结算离线金币，只把时间基准拉到当前，资源恢复也归零
    next.lastSeenAt = nowTs;
    next.lastTickAt = nowTs;
    next.ticketLastTs = nowTs;
    next.energyLastTs = nowTs;
    return {
      save: next,
      bill: {
        offlineMs: 0,
        offlineSeconds: 0,
        coins: 0,
        capped: false,
        ticketsGained: 0,
        energyGained: 0,
        tampered: true,
      },
    };
  }

  // —— 2. 离线金币 ——
  const offlineMs = Math.max(0, nowTs - save.lastSeenAt);
  const perSec = totalProduction(save.staffs, { globalBonus: opts.globalBonus ?? 0 });
  const earn = offlineEarnings(offlineMs, perSec, eco.offlineCapHours);

  next.coins = save.coins + earn.coins;

  // —— 3. 票与电的自然恢复 ——
  const tk = recoverResource(save.ticketLastTs, nowTs, save.tickets, eco.ticketRecoverSec, eco.ticketCap);
  const en = recoverResource(save.energyLastTs, nowTs, save.energy, eco.energyRecoverSec, eco.energyCap);
  next.tickets = tk.value;
  next.energy = en.value;
  next.ticketLastTs = tk.remainderMs;
  next.energyLastTs = en.remainderMs;

  // —— 4. 收尾 ——
  next.lastSeenAt = nowTs;
  next.lastTickAt = nowTs;

  return {
    save: next,
    bill: {
      offlineMs,
      offlineSeconds: earn.seconds,
      coins: earn.coins,
      capped: earn.capped,
      ticketsGained: tk.gained,
      energyGained: en.gained,
      tampered: false,
    },
  };
}

/**
 * 存档合法性校验（读档时调用）。
 * 任一字段越界就修正到安全值，而不是抛错 —— 玩家不该因为存档脏了就进不去。
 *
 * @returns {{save:object, fixed:string[]}}
 */
export function sanitizeSave(raw, nowTs) {
  const fixed = [];

  // 空档 / 非对象：直接回落全新存档（此时不该继续做字段合并，
  // 否则默认值会让 version 校验失效，脏档被静默接受）
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { save: createSave(nowTs), fixed: ["empty"] };
  }

  const s = { ...createSave(nowTs), ...raw };

  if (typeof s.version !== "number" || s.version > SAVE_VERSION) {
    fixed.push("version");
    // 高版本存档降级：保留货币，重置结构
    return { save: { ...createSave(nowTs), coins: numOr(s.coins, 500) }, fixed };
  }

  const numericFields = [
    "coins", "diamonds", "tickets", "energy",
    "titleIndex", "unlockedSlots",
    "createdAt", "lastSeenAt", "lastTickAt", "ticketLastTs", "energyLastTs",
  ];
  for (const f of numericFields) {
    const v = numOr(s[f], 0);
    if (!Number.isFinite(s[f]) || s[f] < 0) {
      fixed.push(f);
      s[f] = Math.max(0, v);
    }
  }

  // 票/电不能超过上限
  if (s.tickets > DEFAULT_ECONOMY.ticketCap) {
    fixed.push("tickets>cap");
    s.tickets = DEFAULT_ECONOMY.ticketCap;
  }
  if (s.energy > DEFAULT_ECONOMY.energyCap) {
    fixed.push("energy>cap");
    s.energy = DEFAULT_ECONOMY.energyCap;
  }

  // 上阵位不能小于初始值、不能超过上限
  if (s.unlockedSlots < 3) {
    fixed.push("unlockedSlots<3");
    s.unlockedSlots = 3;
  }

  // 时间戳不能在未来
  for (const f of ["lastSeenAt", "lastTickAt", "ticketLastTs", "energyLastTs"]) {
    if (s[f] > nowTs) {
      fixed.push(`${f}>now`);
      s[f] = nowTs;
    }
  }

  if (!Array.isArray(s.staffs)) {
    fixed.push("staffs");
    s.staffs = [];
  }
  if (!s.stats || typeof s.stats !== "object") {
    fixed.push("stats");
    s.stats = createSave(nowTs).stats;
  }
  if (!s.adState || typeof s.adState !== "object") {
    fixed.push("adState");
    s.adState = createSave(nowTs).adState;
  }
  if (!s.flags || typeof s.flags !== "object") {
    fixed.push("flags");
    s.flags = { clockTampered: false, tamperCount: 0 };
  }

  return { save: s, fixed };
}

function numOr(v, fallback) {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

/**
 * 序列化 / 反序列化（给引擎侧存储用，纯字符串进出）。
 */
export function serializeSave(save) {
  return JSON.stringify(save);
}

export function deserializeSave(text, nowTs) {
  let raw = null;
  try {
    raw = JSON.parse(text);
  } catch {
    raw = null;
  }
  return sanitizeSave(raw, nowTs);
}

/**
 * 存档体积估算（用于确认没写爆本地存储）。
 */
export function saveBytes(save) {
  return new TextEncoder().encode(serializeSave(save)).length;
}
