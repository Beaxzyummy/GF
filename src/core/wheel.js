/**
 * 转盘逻辑（纯逻辑）
 *
 * 合规核心：转盘决定「下一步行动」，不含任何押注结构。
 * 消耗的是「电」（行动资源），不是金币作为赌注。
 */

export const WHEEL_SECTORS = Object.freeze([
  { index: 1, name: "金币小", type: "coin", value: 1000, probability: 0.3 },
  { index: 2, name: "金币中", type: "coin", value: 5000, probability: 0.15 },
  { index: 3, name: "金币大", type: "coin", value: 20000, probability: 0.05 },
  { index: 4, name: "免费票", type: "ticket", value: 5, probability: 0.15 },
  { index: 5, name: "钻石", type: "diamond", value: 10, probability: 0.1 },
  { index: 6, name: "再来一次", type: "respin", value: 0, probability: 0.15 },
  { index: 7, name: "员工碎片", type: "fragment", value: 1, probability: 0.08 },
  { index: 8, name: "大奖", type: "jackpot", value: 200000, probability: 0.02 },
]);

/**
 * 抽取扇区
 * @param {typeof WHEEL_SECTORS} sectors
 * @param {{next:()=>number}} rng
 */
export function spinWheel(sectors = WHEEL_SECTORS, rng = { next: Math.random }) {
  const r = rng.next();
  let acc = 0;
  for (const s of sectors) {
    acc += s.probability;
    if (r < acc) return s;
  }
  return sectors[sectors.length - 1];
}

/**
 * 计算定格角度（供动画使用）
 * 每个扇区 45°，指针在 12 点方向。
 * 返回目标角度（度，顺时针），已包含多圈。
 *
 * @param {number} sectorIndex 1-based
 * @param {number} totalSectors
 * @param {number} currentAngle 当前角度
 * @param {number} extraTurns 额外圈数（默认 5 圈）
 * @param {number} jitterDeg 微小抖动（视觉上避开绝对居中）
 * @param {()=>number} rng
 */
export function targetAngle(sectorIndex, totalSectors = 8, currentAngle = 0, extraTurns = 5, jitterDeg = 3, rng = Math.random) {
  const seg = 360 / totalSectors;
  // 扇区中心角度
  const center = (sectorIndex - 1) * seg + seg / 2;
  // 在扇区内随机偏移，避免每次都停在正中
  const jitter = (rng() * 2 - 1) * jitterDeg;
  const targetBase = center + jitter;

  // 归一化当前角度
  const normalized = ((currentAngle % 360) + 360) % 360;
  let delta = targetBase - normalized;
  if (delta < 0) delta += 360;

  return currentAngle + extraTurns * 360 + delta;
}

/**
 * easeOutQuart，用于转盘减速
 * 前快后极慢，最后 3° 耗时约 0.6s
 */
export function easeOutQuart(t) {
  return 1 - Math.pow(1 - t, 4);
}

/**
 * 转盘奖励结算
 * @returns {{coins:number, diamonds:number, tickets:number, fragments:number, respin:boolean, isJackpot:boolean}}
 */
export function applySpinResult(sector) {
  return {
    coins: sector.type === "coin" || sector.type === "jackpot" ? sector.value : 0,
    diamonds: sector.type === "diamond" ? sector.value : 0,
    tickets: sector.type === "ticket" ? sector.value : 0,
    fragments: sector.type === "fragment" ? sector.value : 0,
    respin: sector.type === "respin",
    isJackpot: sector.type === "jackpot",
  };
}
