-- ============================================================================
-- 好运游戏厅 · 垂直切片 v0.1（晨光刮刮乐 T1 可玩版）
-- 架构：引擎层(Lua) 只做渲染与输入；结果生成遵循「先抽奖级，再倒填符号」
-- 参考：docs/结果生成规范.md · src/core/lottery.js（JS 参考实现）
-- ============================================================================

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 1. 数值配置（与 data/tickets.csv + data/ticket_prizes.csv 的 T1 一致）
-- ============================================================================

local T1 = {
    id = "T1",
    name = "晨光",
    price = 5,
    -- 奖级表：{匹配数, 概率, 产出}，概率和必须 = 1
    tiers = {
        { match = 0, prob = 0.6500, payout = 0 },
        { match = 3, prob = 0.2400, payout = 8 },
        { match = 5, prob = 0.0800, payout = 20 },
        { match = 7, prob = 0.0260, payout = 80 },
        { match = 9, prob = 0.0040, payout = 300 },
    },
}

local SYMBOLS = { STAR = "✦", FLOWER = "✿", DIAMOND = "◆", CIRCLE = "●" }
local MATCH_SYMBOLS = { SYMBOLS.STAR, SYMBOLS.FLOWER, SYMBOLS.DIAMOND, SYMBOLS.CIRCLE }
local FILL_WEIGHTS = { {SYMBOLS.STAR,30}, {SYMBOLS.FLOWER,28}, {SYMBOLS.DIAMOND,24}, {SYMBOLS.CIRCLE,16} }

-- ============================================================================
-- 2. 核心逻辑（纯函数，先抽奖级再倒填符号 —— 合规关键）
-- ============================================================================

local rngState_ = 20261106
local function rng()
    rngState_ = (rngState_ * 1103515245 + 12345) % 2147483648
    return rngState_ / 2147483648
end

--- 按奖级表抽一格（先抽奖级）
local function pickTier()
    local r, acc = rng(), 0
    for _, t in ipairs(T1.tiers) do
        acc = acc + t.prob
        if r < acc then return t end
    end
    return T1.tiers[#T1.tiers]
end

--- 加权抽一个干扰填充符号
local function pickFill(exclude)
    local pool, total = {}, 0
    for _, w in ipairs(FILL_WEIGHTS) do
        if w[1] ~= exclude then
            table.insert(pool, w)
            total = total + w[2]
        end
    end
    local r = rng() * total
    for _, w in ipairs(pool) do
        r = r - w[2]
        if r <= 0 then return w[1] end
    end
    return pool[#pool][1]
end

--- 生成一张 T1 的完整结果
local function generateTicket()
    -- 1. 先抽奖级（保证公示概率真实）
    local tier = pickTier()
    -- 2. 选有效符号
    local winning = MATCH_SYMBOLS[math.floor(rng() * 4) + 1]
    -- 3. 决定实际匹配数（未中奖 0-2 个，保持真实感）
    local matchCount = tier.match
    if matchCount == 0 then matchCount = math.floor(rng() * 3) end
    -- 4/5. 填格：中奖位填有效符号，其余从排除池抽
    local cells = {}
    local placed = 0
    for i = 1, 9 do
        if placed < matchCount and rng() < (matchCount - placed) / (10 - i) then
            cells[i] = winning
            placed = placed + 1
        else
            cells[i] = pickFill(winning)
        end
    end
    -- 修补：确保恰好 matchCount 个
    while placed < matchCount do
        local i = math.floor(rng() * 9) + 1
        if cells[i] ~= winning then cells[i] = winning; placed = placed + 1 end
    end
    while placed > matchCount do
        local i = math.floor(rng() * 9) + 1
        if cells[i] == winning then cells[i] = pickFill(winning); placed = placed - 1 end
    end
    return { cells = cells, winning = winning, payout = tier.payout, matchCount = matchCount }
end

-- ============================================================================
-- 3. 游戏状态
-- ============================================================================

local state_ = {
    screen = "lobby",          -- lobby | scratch | result
    coins = 500,
    tickets = 20,
    current = nil,             -- 当前票结果
    scratchedCount = 0,        -- 已点开格子数
    totalWon = 0,
}

local uiRoot_ = nil

-- ============================================================================
-- 4. 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = "好运游戏厅"
    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/NotoSansSC.ttf" } }
        },
        scale = UI.Scale.DEFAULT,
    })
    BuildLobby()
    print("=== 好运游戏厅 v0.1 启动 ===")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 5. 界面：大厅
-- ============================================================================

local function fmt(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return out
end

local function updateHud()
    local coins = uiRoot_:FindById("coinsLabel") --[[@as Label?]]
    if coins then coins:SetText("金币 " .. fmt(state_.coins)) end
    local tickets = uiRoot_:FindById("ticketsLabel") --[[@as Label?]]
    if tickets then tickets:SetText("票 " .. state_.tickets) end
end

local function clearRoot()
    if uiRoot_ then uiRoot_ = nil end
end

function BuildLobby()
    clearRoot()
    state_.screen = "lobby"
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },   -- 暗金复古底色
        justifyContent = "space-between",
        children = {
            -- 顶栏：标题 + 货币
            UI.Panel {
                width = "100%", padding = 16, paddingTop = 40,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Label { text = "🏛 好运游戏厅", fontSize = 22, fontColor = { 212, 175, 55, 255 } },
                    UI.Panel {
                        gap = 12, alignItems = "center",
                        children = {
                            UI.Label { id = "coinsLabel", text = "金币 500", fontSize = 15, fontColor = { 255, 215, 0, 255 } },
                            UI.Label { id = "ticketsLabel", text = "票 20", fontSize = 15, fontColor = { 120, 220, 160, 255 } },
                        }
                    },
                }
            },
            -- 中部：彩票柜台
            UI.Panel {
                width = "100%", justifyContent = "center", alignItems = "center", gap = 16,
                children = {
                    UI.Panel {
                        width = "88%", maxWidth = 360, padding = 24, gap = 10,
                        backgroundColor = { 44, 34, 22, 245 },
                        borderRadius = 16, borderWidth = 2, borderColor = { 201, 162, 39, 160 },
                        alignItems = "center",
                        children = {
                            UI.Label { text = "晨光 · ¥5", fontSize = 24, fontColor = { 245, 240, 230, 255 } },
                            UI.Label { text = "中奖率 35% · 最高 300 币", fontSize = 13, fontColor = { 180, 160, 120, 220 } },
                            UI.Label { text = "累积符号 ✦✿◆● 3/5/7/9 个中奖", fontSize = 12, fontColor = { 150, 135, 105, 200 } },
                            UI.Button {
                                id = "buyBtn", text = "刮一张（剩 " .. state_.tickets .. " 张）",
                                variant = "primary", marginTop = 8, width = "80%",
                                onClick = function()
                                    if state_.tickets < 1 then return end
                                    state_.tickets = state_.tickets - 1
                                    state_.current = generateTicket()
                                    state_.scratchedCount = 0
                                    BuildScratch()
                                end,
                            },
                        }
                    },
                    UI.Label { id = "statLabel", text = "今日累计中奖 0 币", fontSize = 13, fontColor = { 170, 150, 110, 200 } },
                }
            },
            -- 底栏
            UI.Panel {
                width = "100%", padding = 16, paddingBottom = 30,
                justifyContent = "center",
                children = {
                    UI.Label { text = "v0.1 垂直切片 · 转盘/手机系统开发中", fontSize = 11, fontColor = { 120, 105, 80, 180 }, textAlign = "center" },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
    updateHud()
end

-- ============================================================================
-- 6. 界面：刮卡（点按式揭开，笔刷刮除在下一迭代）
-- ============================================================================

local scratchCellIds_ = {}
local opened_ = {}          -- 已揭开的格子索引集合

function BuildScratch()
    clearRoot()
    state_.screen = "scratch"
    local cur = state_.current
    local cells = {}
    scratchCellIds_ = {}
    opened_ = {}
    for i = 1, 9 do
        local idx = i
        local cellId = "cell" .. idx
        table.insert(scratchCellIds_, cellId)
        table.insert(cells, UI.Button {
            id = cellId,
            text = "？",
            width = 72, height = 72,
            fontSize = 30,
            backgroundColor = { 90, 72, 45, 255 },
            borderRadius = 10,
            textColor = { 230, 210, 170, 255 },
            onClick = function(self)
                if opened_[idx] then return end
                opened_[idx] = true
                self:SetText(cur.cells[idx])
                self:SetBackgroundColor(cur.cells[idx] == cur.winning and { 201, 162, 39, 255 } or { 60, 50, 36, 255 })
                state_.scratchedCount = state_.scratchedCount + 1
                if state_.scratchedCount >= 9 then
                    SettleTicket()
                end
            end,
        })
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", padding = 16, paddingTop = 40, alignItems = "center",
                children = {
                    UI.Label { text = "有效符号 " .. cur.winning, fontSize = 20, fontColor = { 212, 175, 55, 255 } },
                    UI.Label { text = "点开全部 9 格（78% 自动揭开开发中）", fontSize = 12, fontColor = { 160, 140, 105, 200 } },
                }
            },
            UI.Panel {
                width = 252, height = 252, alignItems = "center",
                flexWrap = "wrap", gap = 6,
                children = cells,
            },
            UI.Panel {
                width = "100%", padding = 20, paddingBottom = 36,
                children = {
                    UI.Button {
                        text = "揭开全部", width = "60%",
                        onClick = function()
                            for idx = 1, 9 do
                                if not opened_[idx] then
                                    opened_[idx] = true
                                    local c = uiRoot_:FindById("cell" .. idx) --[[@as Button?]]
                                    if c then
                                        c:SetText(cur.cells[idx])
                                        c:SetBackgroundColor(cur.cells[idx] == cur.winning and { 201, 162, 39, 255 } or { 60, 50, 36, 255 })
                                    end
                                    state_.scratchedCount = state_.scratchedCount + 1
                                end
                            end
                            SettleTicket()
                        end,
                    },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
end

--- 结算（9 格全开后调用）
function SettleTicket()
    local cur = state_.current
    if not cur or state_.screen ~= "scratch" then return end
    state_.screen = "result"
    if cur.payout > 0 then
        state_.coins = state_.coins + cur.payout
        state_.totalWon = state_.totalWon + cur.payout
    end
    -- 结果横幅
    local banner = UI.Panel {
        id = "resultBanner",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 200 },
        justifyContent = "center", alignItems = "center", gap = 16,
        children = {
            UI.Panel {
                width = "80%", maxWidth = 320, padding = 28, gap = 10, alignItems = "center",
                backgroundColor = cur.payout > 0 and { 60, 45, 15, 250 } or { 40, 36, 30, 250 },
                borderRadius = 16, borderWidth = 2,
                borderColor = cur.payout > 0 and { 255, 215, 0, 255 } or { 110, 100, 85, 200 },
                children = {
                    UI.Label {
                        text = cur.payout > 0 and ("🎉 中了 " .. cur.payout .. " 币！") or "谢谢惠顾",
                        fontSize = 26,
                        fontColor = cur.payout > 0 and { 255, 215, 0, 255 } or { 180, 170, 150, 255 },
                    },
                    UI.Label { text = "匹配 " .. cur.matchCount .. " 个 " .. cur.winning, fontSize = 14, fontColor = { 200, 185, 150, 230 } },
                    UI.Button {
                        text = "再来一张", variant = "primary", width = "70%",
                        onClick = function()
                            BuildLobby()
                        end,
                    },
                    UI.Button {
                        text = "回大厅", width = "70%",
                        onClick = function() BuildLobby() end,
                    },
                }
            }
        }
    }
    uiRoot_:AddChild(banner)
    local stat = uiRoot_:FindById("statLabel")
    -- 回大厅时刷新（BuildLobby 会重算）
end
