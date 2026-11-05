/**
 * 经济系统（纯逻辑）
 *
 * 三货币：金币(coin) / 钻石(diamond) / 票(ticket) + 电(energy)
 * 核心设计：金币可无限膨胀，票与电才是时间闸门。
 */

/** 默认经济参数，可被 data/economy.csv 覆盖 */
export const DEFAULT_ECONOMY = Object.freeze({
  ticketRecoverSec: 30,
  ticketCap: 20,
  energyRecoverSec: 300,
  energyCap: 30,
  offlineCapHours: 8,
  adsDailyTotal: 30,
  upgradeCostRatio: 1.55,
  ticketLevelThresholds: [0, 30, 100, 300, 800],
  ticketLevelBonus: [0, 0.06, 0.13, 0.21, 0.3],
  bankruptcyTickets: 20,
  bankruptcyCoins: 500,
  bankruptcyDailyCap: 3,
});

/**
 * 计算自然恢复的资源量（基于时间差）
 * @param {number} lastTs 上次结算时间戳(ms)
 * @param {number} nowTs 当前时间戳(ms)
 * @param {number} current 当前持有量
 * @param {number} recoverSec 每单位恢复所需秒数
 * @param {number} cap 上限
 * @returns {{value:number, gained:number, remainderMs:number}}
 */
export function recoverResource(lastTs, nowTs, current, recoverSec, cap) {
  if (current >= cap) {
    return { value: cap, gained: 0, remainderMs: nowTs };
  }
  const elapsed = Math.max(0, nowTs - lastTs);
  const unitMs = recoverSec * 1000;
  const gained = Math.floor(elapsed / unitMs);
  const next = Math.min(cap, current + gained);
  // 溢出后的余数时间：若已到上限，余数清零
  const remainderMs = next >= cap ? nowTs : lastTs + gained * unitMs;
  return { value: next, gained: next - current, remainderMs };
}

/**
 * 票卡等级：根据累计购买数换算等级(1-5)
 * @param {number} totalBought
 * @param {number[]} thresholds
 * @returns {number}
 */
export function ticketLevel(totalBought, thresholds = DEFAULT_ECONOMY.ticketLevelThresholds) {
  let lv = 1;
  for (let i = 0; i < thresholds.length; i++) {
    if (totalBought >= thresholds[i]) lv = i + 1;
  }
  return lv;
}

/**
 * 票卡奖金加成
 * @param {number} totalBought
 * @param {object} eco
 * @returns {number} 如 0.13
 */
export function ticketBonus(totalBought, eco = DEFAULT_ECONOMY) {
  const lv = ticketLevel(totalBought, eco.ticketLevelThresholds);
  return eco.ticketLevelBonus[lv - 1];
}

/**
 * 距离下一等级还差多少张
 * @returns {{level:number, nextAt:number|null, remaining:number}}
 */
export function nextLevelProgress(totalBought, eco = DEFAULT_ECONOMY) {
  const lv = ticketLevel(totalBought, eco.ticketLevelThresholds);
  const nextIdx = lv; // thresholds[lv] 是下一级门槛
  if (nextIdx >= eco.ticketLevelThresholds.length) {
    return { level: lv, nextAt: null, remaining: 0 };
  }
  const nextAt = eco.ticketLevelThresholds[nextIdx];
  return { level: lv, nextAt, remaining: nextAt - totalBought };
}

/**
 * 员工升级成本
 * @param {number} baseCost
 * @param {number} currentLevel 1-based
 * @param {number} ratio
 */
export function upgradeCost(baseCost, currentLevel, ratio = DEFAULT_ECONOMY.upgradeCostRatio) {
  return Math.floor(baseCost * Math.pow(ratio, currentLevel - 1));
}

/**
 * 离线收益
 * @param {number} offlineMs
 * @param {number} productionPerSec 所有上阵员工总产出
 * @param {number} capHours
 */
export function offlineEarnings(offlineMs, productionPerSec, capHours = DEFAULT_ECONOMY.offlineCapHours) {
  const cappedMs = Math.min(Math.max(0, offlineMs), capHours * 3600 * 1000);
  const seconds = Math.floor(cappedMs / 1000);
  return {
    coins: Math.floor(seconds * productionPerSec),
    seconds,
    capped: offlineMs > capHours * 3600 * 1000,
  };
}

/**
 * 批量购买可行性判断
 * @returns {{ok:boolean, need:number, have:number, short:number}}
 */
export function canBuy(price, count, tickets, coins) {
  const needTickets = price * count;
  const short = Math.max(0, needTickets - tickets);
  return { ok: short === 0, need: needTickets, have: tickets, short };
}

/**
 * 破产判定与补助
 */
export function checkBankruptcy(state, eco = DEFAULT_ECONOMY) {
  const noCoins = state.coins < 5;
  const noTickets = state.tickets === 0;
  const noEnergy = state.energy === 0;
  if (!(noCoins && noTickets && noEnergy)) return null;
  if ((state.bankruptcyToday || 0) >= eco.bankruptcyDailyCap) return null;
  return { tickets: eco.bankruptcyTickets, coins: eco.bankruptcyCoins };
}

/**
 * 数字格式化：1,234 / 1.2万 / 3.4亿 / 5.6万亿
 */
export function formatNumber(n) {
  const abs = Math.abs(n);
  if (abs < 10000) return Math.round(n).toLocaleString("en-US");
  if (abs < 1e8) return (n / 1e4).toFixed(abs < 1e6 ? 1 : 0) + "万";
  if (abs < 1e12) return (n / 1e8).toFixed(abs < 1e10 ? 1 : 0) + "亿";
  return (n / 1e12).toFixed(1) + "万亿";
}
