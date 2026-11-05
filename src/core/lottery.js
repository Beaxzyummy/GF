/**
 * 彩票结果生成器（纯逻辑，无引擎依赖）
 *
 * 关键设计：先抽奖级，再按奖级倒填符号。
 * 原因见 docs/结果生成规范.md —— 若随机填 9 格再数匹配数，
 * 特等奖概率会从 0.40% 掉到约 1e-12，与公示概率不符（合规事故）。
 */

export const SYMBOLS = Object.freeze({
  STAR: "✦",
  FLOWER: "✿",
  DIAMOND: "◆",
  CIRCLE: "●",
  SPARKLE: "★",
});

/** 可用作「有效匹配符号」的集合 */
export const MATCH_SYMBOLS = Object.freeze([
  SYMBOLS.STAR,
  SYMBOLS.FLOWER,
  SYMBOLS.DIAMOND,
  SYMBOLS.CIRCLE,
]);

/** 非中奖格填充权重（仅影响视觉多样性，不影响概率） */
const FILL_WEIGHTS = Object.freeze([
  [SYMBOLS.STAR, 30],
  [SYMBOLS.FLOWER, 28],
  [SYMBOLS.DIAMOND, 24],
  [SYMBOLS.CIRCLE, 16],
]);

export const GRID_SIZE = 9;
export const SPARKLE_BONUS_RATE = 0.032;

/**
 * 可注入的随机源，便于测试复现。
 * @typedef {{ next: () => number }} Rng
 */

/** 默认随机源 */
export const defaultRng = { next: () => Math.random() };

/**
 * 按权重抽取下标。
 * @param {number[]} weights
 * @param {Rng} rng
 * @returns {number}
 */
function weightedIndex(weights, rng) {
  let total = 0;
  for (const w of weights) total += w;
  let r = rng.next() * total;
  for (let i = 0; i < weights.length; i++) {
    r -= weights[i];
    if (r <= 0) return i;
  }
  return weights.length - 1;
}

/**
 * 从 pool 中无放回抽取 k 个互不相同的下标。
 * @param {number} n 池大小
 * @param {number} k 抽取数量
 * @param {Rng} rng
 * @returns {number[]}
 */
function sampleIndices(n, k, rng) {
  const idx = Array.from({ length: n }, (_, i) => i);
  for (let i = n - 1; i > 0; i--) {
    const j = Math.floor(rng.next() * (i + 1));
    [idx[i], idx[j]] = [idx[j], idx[i]];
  }
  return idx.slice(0, k);
}

/**
 * 按奖级表抽取奖级。
 * @param {{matchCount:number, probability:number, payout:number}[]} tiers
 * @param {Rng} rng
 */
export function pickTier(tiers, rng = defaultRng) {
  const r = rng.next();
  let acc = 0;
  for (const t of tiers) {
    acc += t.probability;
    if (r < acc) return t;
  }
  return tiers[tiers.length - 1];
}

/**
 * 生成一张刮刮乐的完整结果。
 *
 * @param {{id:string, tiers:{matchCount:number,probability:number,payout:number}[]}} ticket
 * @param {Rng} rng
 * @returns {{
 *   ticketId: string,
 *   winningSymbol: string,
 *   decoySymbols: string[],
 *   cells: string[],
 *   matchCount: number,
 *   payout: number,
 *   bonusTicket: boolean
 * }}
 */
export function generateTicket(ticket, rng = defaultRng) {
  const tiers = ticket.tiers;

  // 1. 先抽奖级
  const tier = pickTier(tiers, rng);
  const target = tier.matchCount;

  // 2. 选有效符号 + 2 个干扰符号
  const winningSymbol = MATCH_SYMBOLS[Math.floor(rng.next() * MATCH_SYMBOLS.length)];
  const decoys = MATCH_SYMBOLS.filter((s) => s !== winningSymbol);
  // 干扰符号保持固定顺序，避免额外随机影响可复现性
  const decoySymbols = [decoys[0], decoys[1]];

  // 3. 决定实际匹配数
  //    奖级为 0 时，匹配数必须是 0-2 之间的随机值（保持真实感）
  let matchCount = target;
  if (target === 0) {
    matchCount = Math.floor(rng.next() * 3); // 0 | 1 | 2
  }

  const cells = new Array(GRID_SIZE).fill(null);

  // 4. 填有效符号
  const matchPositions = sampleIndices(GRID_SIZE, matchCount, rng);
  for (const p of matchPositions) cells[p] = winningSymbol;

  // 5. 填非中奖格（从排除有效符号的池中抽）
  const fillPool = FILL_WEIGHTS.filter(([s]) => s !== winningSymbol);
  const fillWeights = fillPool.map(([, w]) => w);
  for (let i = 0; i < GRID_SIZE; i++) {
    if (cells[i] === null) {
      cells[i] = fillPool[weightedIndex(fillWeights, rng)][0];
    }
  }

  // 6. 双星彩蛋（独立判定，覆盖非中奖格）
  let bonusTicket = false;
  if (rng.next() < SPARKLE_BONUS_RATE) {
    const emptySlots = [];
    for (let i = 0; i < GRID_SIZE; i++) {
      if (cells[i] !== winningSymbol) emptySlots.push(i);
    }
    if (emptySlots.length >= 2) {
      const picked = sampleIndices(emptySlots.length, 2, rng);
      for (const k of picked) cells[emptySlots[k]] = SYMBOLS.SPARKLE;
      bonusTicket = true;
    }
  }

  return {
    ticketId: ticket.id,
    winningSymbol,
    decoySymbols,
    cells,
    matchCount,
    payout: tier.payout,
    bonusTicket,
  };
}

/**
 * 统计匹配数（用于校验，不参与生成）。
 * @param {string[]} cells
 * @param {string} winningSymbol
 * @returns {number}
 */
export function countMatches(cells, winningSymbol) {
  let n = 0;
  for (const c of cells) if (c === winningSymbol) n++;
  return n;
}
