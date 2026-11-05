/**
 * 广告频控（纯逻辑）
 *
 * 三层频控：全局日上限 / 单广告位上限 / 最小间隔
 */

export const AD_PLACEMENTS = Object.freeze({
  A1_TICKET: { id: "A1_TICKET", name: "补票", cap: 8, rewardType: "ticket", rewardValue: 20 },
  A2_BONUS: { id: "A2_BONUS", name: "领奖加份", cap: 10, rewardType: "coin", rewardValue: "raw" },
  A3_OFFLINE: { id: "A3_OFFLINE", name: "离线加份", cap: 1, rewardType: "coin", rewardValue: "raw" },
  A4_ENERGY: { id: "A4_ENERGY", name: "转盘加电", cap: 6, rewardType: "energy", rewardValue: 10 },
  A5_DIAMOND: { id: "A5_DIAMOND", name: "钻石礼包", cap: 5, rewardType: "diamond", rewardValue: 50 },
});

export const AD_LIMITS = Object.freeze({
  dailyTotal: 30,
  minIntervalMs: 30_000,
});

/**
 * 创建广告状态
 */
export function createAdState(dateStr) {
  return {
    date: dateStr,
    total: 0,
    byPlacement: {},
    lastTs: 0,
  };
}

/**
 * 跨日重置
 */
export function rolloverIfNeeded(state, todayStr) {
  if (state.date !== todayStr) {
    return createAdState(todayStr);
  }
  return state;
}

/**
 * 判断某广告位当前是否可看
 * @returns {{allowed:boolean, reason?:string, remaining:number}}
 */
export function canShowAd(state, placementId, nowTs, placements = AD_PLACEMENTS, limits = AD_LIMITS) {
  const p = placements[placementId];
  if (!p) return { allowed: false, reason: "unknown_placement", remaining: 0 };

  if (state.total >= limits.dailyTotal) {
    return { allowed: false, reason: "daily_total_reached", remaining: 0 };
  }

  const used = state.byPlacement[placementId] || 0;
  if (used >= p.cap) {
    return { allowed: false, reason: "placement_cap_reached", remaining: 0 };
  }

  if (nowTs - state.lastTs < limits.minIntervalMs) {
    return { allowed: false, reason: "too_soon", remaining: p.cap - used };
  }

  return { allowed: true, remaining: p.cap - used };
}

/**
 * 记录一次广告完成
 */
export function recordAd(state, placementId, nowTs) {
  return {
    ...state,
    total: state.total + 1,
    byPlacement: {
      ...state.byPlacement,
      [placementId]: (state.byPlacement[placementId] || 0) + 1,
    },
    lastTs: nowTs,
  };
}

/**
 * 计算广告奖励
 * @param {string} placementId
 * @param {number} rawValue 用于 coin 类型的原值
 */
export function adReward(placementId, rawValue = 0, placements = AD_PLACEMENTS) {
  const p = placements[placementId];
  if (!p) return null;
  const value = p.rewardValue === "raw" ? rawValue : p.rewardValue;
  return { type: p.rewardType, value };
}
