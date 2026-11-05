/**
 * 抽卡系统（纯逻辑）
 *
 * 对应 GDD 6.3 - 6.5：
 * - 单抽 160 钻，十连 1,600 钻（不打折）
 * - 稀有度概率 UR 0.50% / SSR 3.70% / SR 27.80% / R 68.00%
 * - 十连必出 SR 及以上（保底），保底不改变公示的单抽概率
 * - 重复转碎片：R=1, SR=3, SSR=8, UR=20
 *
 * 合规要点：公示概率必须是「单抽真实概率」。保底是额外承诺，
 * 只能提升结果，不能用来掩盖真实概率。
 */

/** 稀有度阶梯（从高到低），用于保底判定 */
export const RARITY_ORDER = Object.freeze(["UR", "SSR", "SR", "R"]);

/** 稀有度等级（数字越大越稀有），便于比较 */
export const RARITY_RANK = Object.freeze({ R: 1, SR: 2, SSR: 3, UR: 4 });

/** 重复转碎片数量 */
export const DUPLICATE_SHARDS = Object.freeze({ UR: 20, SSR: 8, SR: 3, R: 1 });

/** 合成一个员工所需碎片 */
export const SHARDS_PER_UNIT = 10;

/** 抽卡单价 */
export const GACHA_PRICE = Object.freeze({ single: 160, ten: 1600 });

/** 十连次数与保底门槛 */
export const TEN_PULL_COUNT = 10;
export const TEN_PULL_GUARANTEE_RANK = RARITY_RANK.SR;

/**
 * 员工图鉴（GDD 6.5：UR 1 / SSR 3 / SR 6 / R 12 = 22 条）
 * 每条的稀有度必须与 RARITY_COUNT 一致，否则 pickEntry 会抽不到某档。
 */
export const RARITY_COUNT = Object.freeze({ UR: 1, SSR: 3, SR: 6, R: 12 });

export const STAFF_CATALOG = Object.freeze([
  // UR —— 全局产出 +50%
  { id: "ur_daju", name: "大橘", rarity: "UR", line: "global", desc: "招财猫，全局产出 +50%" },
  // SSR —— 三名店长，各主导一条产出线
  { id: "ssr_shop", name: "老陈", rarity: "SSR", line: "scratch", desc: "彩票柜台的老师傅" },
  { id: "ssr_wheel", name: "阿澜", rarity: "SSR", line: "wheel", desc: "转盘台前的报幕员" },
  { id: "ssr_office", name: "林小满", rarity: "SSR", line: "office", desc: "后台的账房先生" },
  // SR —— 六名伙计
  { id: "sr_1", name: "小赵", rarity: "SR", line: "scratch", desc: "手脚麻利的柜台伙计" },
  { id: "sr_2", name: "阿武", rarity: "SR", line: "scratch", desc: "总能刮出好签" },
  { id: "sr_3", name: "杏子", rarity: "SR", line: "wheel", desc: "转盘台的气氛担当" },
  { id: "sr_4", name: "老周", rarity: "SR", line: "wheel", desc: "守着老虎机二十年" },
  { id: "sr_5", name: "小白", rarity: "SR", line: "office", desc: "负责登记的实习生" },
  { id: "sr_6", name: "阿花", rarity: "SR", line: "office", desc: "门口招手的迎宾" },
  // R —— 十二名学徒
  { id: "r_01", name: "学徒一", rarity: "R", line: "scratch", desc: "刚来的学徒" },
  { id: "r_02", name: "学徒二", rarity: "R", line: "scratch", desc: "刚来的学徒" },
  { id: "r_03", name: "学徒三", rarity: "R", line: "scratch", desc: "刚来的学徒" },
  { id: "r_04", name: "学徒四", rarity: "R", line: "wheel", desc: "刚来的学徒" },
  { id: "r_05", name: "学徒五", rarity: "R", line: "wheel", desc: "刚来的学徒" },
  { id: "r_06", name: "学徒六", rarity: "R", line: "wheel", desc: "刚来的学徒" },
  { id: "r_07", name: "学徒七", rarity: "R", line: "office", desc: "刚来的学徒" },
  { id: "r_08", name: "学徒八", rarity: "R", line: "office", desc: "刚来的学徒" },
  { id: "r_09", name: "学徒九", rarity: "R", line: "office", desc: "刚来的学徒" },
  { id: "r_10", name: "学徒十", rarity: "R", line: "scratch", desc: "刚来的学徒" },
  { id: "r_11", name: "学徒十一", rarity: "R", line: "wheel", desc: "刚来的学徒" },
  { id: "r_12", name: "学徒十二", rarity: "R", line: "office", desc: "刚来的学徒" },
]);

/**
 * 按概率抽稀有度。
 * @param {{rarity:string, probability:number}[]} table 稀有度概率表
 * @param {{next:()=>number}} rng
 */
export function pickRarity(table, rng) {
  const r = rng.next();
  let acc = 0;
  for (const row of table) {
    acc += row.probability;
    if (r < acc) return row.rarity;
  }
  return table[table.length - 1].rarity;
}

/**
 * 在指定稀有度内均匀抽一条员工。
 * @param {string} rarity
 * @param {object[]} catalog
 * @param {{next:()=>number}} rng
 */
export function pickEntry(rarity, catalog, rng) {
  const pool = catalog.filter((c) => c.rarity === rarity);
  if (pool.length === 0) throw new Error(`catalog 中不存在稀有度 ${rarity}`);
  return pool[Math.floor(rng.next() * pool.length)];
}

/**
 * 单抽一次（不含保底逻辑，可独立用于公示验证）。
 * @param {{rarity:string, probability:number}[]} table
 * @param {object[]} catalog
 * @param {{next:()=>number}} rng
 */
export function pullOnce(table, catalog, rng) {
  const rarity = pickRarity(table, rng);
  return pickEntry(rarity, catalog, rng);
}

/**
 * 十连抽。第 10 抽若不达 SR，则强制提升到 SR（保底）。
 *
 * 实现要点：保底用的是「重抽一次并锁定 SR」而非「把最后一抽概率改掉」。
 * 这样前 9 抽的边际概率仍严格等于公示值，公示不受污染。
 *
 * @param {{rarity:string, probability:number}[]} table
 * @param {object[]} catalog
 * @param {{next:()=>number}} rng
 * @returns {{results:object[], guaranteed:boolean}}
 */
export function pullTen(table, catalog, rng) {
  const results = [];
  for (let i = 0; i < TEN_PULL_COUNT; i++) {
    results.push(pullOnce(table, catalog, rng));
  }
  let guaranteed = false;
  const hasHigh = results.some((e) => RARITY_RANK[e.rarity] >= TEN_PULL_GUARANTEE_RANK);
  if (!hasHigh) {
    // 保底：锁定 SR 池，均匀抽一条替换第 10 抽
    results[TEN_PULL_COUNT - 1] = pickEntry("SR", catalog, rng);
    guaranteed = true;
  }
  return { results, guaranteed };
}

/**
 * 抽卡主入口。
 * @param {"single"|"ten"} mode
 */
export function draw(mode, table, catalog, rng) {
  if (mode === "ten") return pullTen(table, catalog, rng);
  const e = pullOnce(table, catalog, rng);
  return { results: [e], guaranteed: false };
}

/**
 * 计算重复转碎片数量。
 * @param {string} rarity
 */
export function shardsForDuplicate(rarity) {
  return DUPLICATE_SHARDS[rarity] ?? 0;
}

/**
 * 结算一次抽卡结果，处理「新获得 / 转碎片」。
 *
 * @param {object[]} results 抽卡结果条目
 * @param {Record<string, number>} owned 已拥有记录 { staffId: count }
 * @returns {{newStaff:object[], shards:Record<string,number>, owned:Record<string,number>}}
 */
export function settleDraw(results, owned = {}) {
  const nextOwned = { ...owned };
  const newStaff = [];
  const shards = {};

  for (const entry of results) {
    if (nextOwned[entry.id]) {
      const n = shardsForDuplicate(entry.rarity);
      shards[entry.rarity] = (shards[entry.rarity] || 0) + n;
    } else {
      nextOwned[entry.id] = 1;
      newStaff.push(entry);
    }
  }

  // 重复获得同一员工第二次起仍按碎片计，不叠加数量
  return { newStaff, shards, owned: nextOwned };
}

/**
 * 钻石是否够抽。
 */
export function canDraw(mode, diamonds) {
  const cost = mode === "ten" ? GACHA_PRICE.ten : GACHA_PRICE.single;
  return { ok: diamonds >= cost, cost, short: Math.max(0, cost - diamonds) };
}

/**
 * 碎片是否够合成。
 */
export function canCraft(shardCount) {
  return { ok: shardCount >= SHARDS_PER_UNIT, need: SHARDS_PER_UNIT, have: shardCount };
}
