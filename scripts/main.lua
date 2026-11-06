-- ============================================================================
-- 好运游戏厅 · v0.2（笔刷刮除 + 免费票倒计时 + 晨光 T1）
-- 架构：引擎层(Lua) 只做渲染与输入；结果生成遵循「先抽奖级，再倒填符号」
-- 本版新增：
--   1. 笔刷刮除（18x18 网格蒙版，30px 笔刷，78% 自动揭开）
--   2. 免费票倒计时（30 秒/张，上限 20 张）
-- ============================================================================

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 1. 数值配置（与 data/tickets.csv + data/ticket_prizes.csv 的 T1 一致）
-- ============================================================================

local T1 = {
    id = "T1",
    name = "晨光",
    price = 5,
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

-- 经济参数（data/economy.csv）
local ECO = {
    ticketRecoverSec = 30,
    ticketCap = 20,
    brushRadius = 30,          -- 笔刷半径（逻辑像素）
    revealThreshold = 0.78,    -- 自动揭开阈值
    gridCols = 18,             -- 蒙版网格
    gridRows = 18,
}

-- ============================================================================
-- 2. 核心逻辑（纯函数，先抽奖级再倒填符号 —— 合规关键）
-- ============================================================================

local rngState_ = 20261106
local function rng()
    rngState_ = (rngState_ * 1103515245 + 12345) % 2147483648
    return rngState_ / 2147483648
end

local function pickTier()
    local r, acc = rng(), 0
    for _, t in ipairs(T1.tiers) do
        acc = acc + t.prob
        if r < acc then return t end
    end
    return T1.tiers[#T1.tiers]
end

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

local function generateTicket()
    local tier = pickTier()
    local winning = MATCH_SYMBOLS[math.floor(rng() * 4) + 1]
    local matchCount = tier.match
    if matchCount == 0 then matchCount = math.floor(rng() * 3) end
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
    screen = "lobby",
    coins = 500,
    tickets = 20,
    ticketRemainMs = 0,        -- 距下一张免费票
    current = nil,
    totalWon = 0,
    scratchedToday = 0,
}

-- 刮卡蒙版状态
local scratch_ = {
    removed = {},              -- row*cols+col → true
    removedCount = 0,
    total = ECO.gridCols * ECO.gridRows,
    rect = { x = 0, y = 0, w = 252, h = 252 },
    pointerDown = false,
    lastX = 0, lastY = 0,
    settled = false,
}

local uiRoot_ = nil
local nvgCtx_ = nil

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
    nvgCtx_ = UI.GetNVGContext()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("TouchMove", "HandleTouchMove")
    SubscribeToEvent("TouchEnd", "HandleTouchEnd")
    BuildLobby()
    print("=== 好运游戏厅 v0.2 启动 ===")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 5. 免费票倒计时（30 秒/张，上限 20）
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dtMs = eventData["TimeStep"]:GetFloat() * 1000

    if state_.tickets < ECO.ticketCap then
        state_.ticketRemainMs = state_.ticketRemainMs + dtMs
        if state_.ticketRemainMs >= ECO.ticketRecoverSec * 1000 then
            state_.ticketRemainMs = state_.ticketRemainMs - ECO.ticketRecoverSec * 1000
            state_.tickets = state_.tickets + 1
            if state_.tickets >= ECO.ticketCap then state_.ticketRemainMs = 0 end
            updateHud()
        end
        local lbl = uiRoot_ and uiRoot_:FindById("ticketTimer") --[[@as Label?]]
        if lbl then
            local sec = math.ceil((ECO.ticketRecoverSec * 1000 - state_.ticketRemainMs) / 1000)
            lbl:SetText(string.format("下一张免费票 %02d:%02d", math.floor(sec / 60), sec % 60))
        end
    end

    -- 每帧把刮卡蒙版排进 overlay 队列（QueueOverlay 每帧消费后清空）
    if state_.screen == "scratch" and not scratch_.settled then
        UI.QueueOverlay(function(nvg) DrawFoil(nvg) end)
    end
end

-- ============================================================================
-- 6. 触摸 → 笔刷刮除
-- ============================================================================

local function toLogical(x)
    -- 引擎触摸坐标是物理像素，UI 渲染在逻辑像素
    return x * (UI.GetWidth() / graphics.width)
end

local function scratchAt(lx, ly)
    local r = scratch_.rect
    local cellW, cellH = r.w / ECO.gridCols, r.h / ECO.gridRows
    local minC = math.max(0, math.floor((lx - ECO.brushRadius - r.x) / cellW))
    local maxC = math.min(ECO.gridCols - 1, math.floor((lx + ECO.brushRadius - r.x) / cellW))
    local minR = math.max(0, math.floor((ly - ECO.brushRadius - r.y) / cellH))
    local maxR = math.min(ECO.gridRows - 1, math.floor((ly + ECO.brushRadius - r.y) / cellH))
    local br2 = ECO.brushRadius * ECO.brushRadius
    local changed = false
    for row = minR, maxR do
        for col = minC, maxC do
            local key = row * ECO.gridCols + col
            if not scratch_.removed[key] then
                local cx = r.x + (col + 0.5) * cellW
                local cy = r.y + (row + 0.5) * cellH
                local dx, dy = cx - lx, cy - ly
                if dx * dx + dy * dy <= br2 then
                    scratch_.removed[key] = true
                    scratch_.removedCount = scratch_.removedCount + 1
                    changed = true
                end
            end
        end
    end
    if changed and scratch_.removedCount / scratch_.total >= ECO.revealThreshold then
        RevealAll()
    end
end

function HandleTouchBegin(eventType, eventData)
    if state_.screen ~= "scratch" or scratch_.settled then return end
    local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
    scratch_.pointerDown = true
    scratch_.lastX, scratch_.lastY = lx, ly
    scratchAt(lx, ly)
end

function HandleTouchMove(eventType, eventData)
    if not scratch_.pointerDown or state_.screen ~= "scratch" or scratch_.settled then return end
    local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
    -- 插值：快速滑动时沿两点间补笔
    local dx, dy = lx - scratch_.lastX, ly - scratch_.lastY
    local dist = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.floor(dist / (ECO.brushRadius * 0.5)))
    for i = 1, steps do
        local t = i / steps
        scratchAt(scratch_.lastX + dx * t, scratch_.lastY + dy * t)
    end
    scratch_.lastX, scratch_.lastY = lx, ly
end

function HandleTouchEnd(eventType, eventData)
    scratch_.pointerDown = false
end

-- ============================================================================
-- 7. 蒙版渲染（银箔质感 + 已刮区域露出下层符号）
-- ============================================================================

function DrawFoil(nvg)
    local r = scratch_.rect
    local cellW, cellH = r.w / ECO.gridCols, r.h / ECO.gridRows

    -- 底箔（整块兜底）
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, r.x - 4, r.y - 4, r.w + 8, r.h + 8, 12)
    nvgFillColor(nvg, nvgRGBA(172, 178, 189, 255))
    nvgFill(nvg)

    -- 未刮掉的网格块（双色交错模拟拉丝）
    for row = 0, ECO.gridRows - 1 do
        for col = 0, ECO.gridCols - 1 do
            if not scratch_.removed[row * ECO.gridCols + col] then
                nvgBeginPath(nvg)
                nvgRect(nvg, r.x + col * cellW, r.y + row * cellH, cellW + 0.5, cellH + 0.5)
                if (row + col) % 2 == 0 then
                    nvgFillColor(nvg, nvgRGBA(188, 194, 205, 255))
                else
                    nvgFillColor(nvg, nvgRGBA(176, 182, 194, 255))
                end
                nvgFill(nvg)
            end
        end
    end

    -- 高光斜线（质感）
    nvgBeginPath(nvg)
    nvgScissor(nvg, r.x, r.y, r.w, r.h)
    nvgMoveTo(nvg, r.x, r.y + r.h * 0.25)
    nvgLineTo(nvg, r.x + r.w * 0.55, r.y)
    nvgStrokeWidth(nvg, 22)
    nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 26))
    nvgStroke(nvg)
    nvgResetScissor(nvg)

    -- 刮除率提示
    local ratio = scratch_.removedCount / scratch_.total
    if ratio > 0.02 then
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, r.x + r.w - 78, r.y + r.h + 10, 78, 20, 6)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 120))
        nvgFill(nvg)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 220))
        nvgFontSize(nvg, 13)
        nvgTextAlign(nvg, 129)  -- CENTER(1) + MIDDLE(128)
        nvgText(nvg, r.x + r.w - 39, r.y + r.h + 21, string.format("已刮 %d%%", math.floor(ratio * 100)))
    end
end

-- ============================================================================
-- 8. 界面：大厅
-- ============================================================================

local function fmt(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return out
end

local function updateHud()
    if not uiRoot_ then return end
    local coins = uiRoot_:FindById("coinsLabel") --[[@as Label?]]
    if coins then coins:SetText("金币 " .. fmt(state_.coins)) end
    local tickets = uiRoot_:FindById("ticketsLabel") --[[@as Label?]]
    if tickets then tickets:SetText("票 " .. state_.tickets) end
    local timer = uiRoot_:FindById("ticketTimer") --[[@as Label?]]
    if timer then
        if state_.tickets >= ECO.ticketCap then
            timer:SetText("免费票已满")
        else
            local sec = math.ceil((ECO.ticketRecoverSec * 1000 - state_.ticketRemainMs) / 1000)
            timer:SetText(string.format("下一张免费票 %02d:%02d", math.floor(sec / 60), sec % 60))
        end
    end
    local buy = uiRoot_:FindById("buyBtn") --[[@as Button?]]
    if buy then buy:SetText("刮一张（剩 " .. state_.tickets .. " 张）") end
end

function BuildLobby()
    state_.screen = "lobby"
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", padding = 16, paddingTop = 40,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Label { text = "🏛 好运游戏厅", fontSize = 22, fontColor = { 212, 175, 55, 255 } },
                    UI.Panel {
                        gap = 12, alignItems = "center",
                        children = {
                            UI.Label { id = "coinsLabel", text = "金币 " .. fmt(state_.coins), fontSize = 15, fontColor = { 255, 215, 0, 255 } },
                            UI.Label { id = "ticketsLabel", text = "票 " .. state_.tickets, fontSize = 15, fontColor = { 120, 220, 160, 255 } },
                        }
                    },
                }
            },
            UI.Panel {
                width = "100%", justifyContent = "center", alignItems = "center", gap = 12,
                children = {
                    UI.Panel {
                        width = "88%", maxWidth = 360, padding = 24, gap = 10,
                        backgroundColor = { 44, 34, 22, 245 },
                        borderRadius = 16, borderWidth = 2, borderColor = { 201, 162, 39, 160 },
                        alignItems = "center",
                        children = {
                            UI.Label { text = "晨光 · ¥5", fontSize = 24, fontColor = { 245, 240, 230, 255 } },
                            UI.Label { text = "中奖率 35% · 最高 300 币", fontSize = 13, fontColor = { 180, 160, 120, 220 } },
                            UI.Label { id = "ticketTimer", text = "", fontSize = 12, fontColor = { 150, 200, 160, 220 } },
                            UI.Button {
                                id = "buyBtn", text = "刮一张（剩 " .. state_.tickets .. " 张）",
                                variant = "primary", marginTop = 8, width = "80%",
                                onClick = function()
                                    if state_.tickets < 1 then return end
                                    state_.tickets = state_.tickets - 1
                                    state_.current = generateTicket()
                                    BuildScratch()
                                end,
                            },
                        }
                    },
                    UI.Label { id = "statLabel", text = "今日刮了 " .. state_.scratchedToday .. " 张 · 累计中奖 " .. fmt(state_.totalWon) .. " 币", fontSize = 13, fontColor = { 170, 150, 110, 200 } },
                }
            },
            UI.Panel {
                width = "100%", padding = 16, paddingBottom = 30,
                justifyContent = "center",
                children = {
                    UI.Label { text = "v0.2 笔刷刮除 · 转盘/手机系统开发中", fontSize = 11, fontColor = { 120, 105, 80, 180 }, textAlign = "center" },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
    updateHud()
end

-- ============================================================================
-- 9. 界面：刮卡（笔刷刮除）
-- ============================================================================

function BuildScratch()
    state_.screen = "scratch"
    scratch_.removed = {}
    scratch_.removedCount = 0
    scratch_.settled = false
    scratch_.pointerDown = false

    local cur = state_.current
    -- 刮卡区域：3x3 符号格 252x252，水平居中，垂直 30% 处
    local logicalW = UI.GetWidth()
    local logicalH = UI.GetHeight()
    local gx = math.floor((logicalW - 252) / 2)
    local gy = math.floor(logicalH * 0.30)
    scratch_.rect = { x = gx, y = gy, w = 252, h = 252 }

    -- 下层符号（pointerEvents=none，被银箔覆盖，刮开即见）
    local cells = {}
    for i = 1, 9 do
        local row = math.floor((i - 1) / 3)
        local col = (i - 1) % 3
        local isWin = cur.cells[i] == cur.winning
        table.insert(cells, UI.Panel {
            width = 76, height = 76,
            position = "absolute",
            left = gx + 6 + col * 82,
            top = gy + 6 + row * 82,
            borderRadius = 8,
            backgroundColor = isWin and { 70, 55, 20, 255 } or { 52, 44, 32, 255 },
            justifyContent = "center", alignItems = "center",
            pointerEvents = "none",
            children = {
                UI.Label {
                    text = cur.cells[i],
                    fontSize = 34,
                    fontColor = isWin and { 255, 215, 0, 255 } or { 200, 188, 165, 255 },
                },
            }
        })
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        children = {
            UI.Panel {
                width = "100%", padding = 16, paddingTop = 40, alignItems = "center", gap = 4,
                children = {
                    UI.Label { text = "有效符号 " .. cur.winning, fontSize = 22, fontColor = { 212, 175, 55, 255 } },
                    UI.Label { text = "用手指刮开银箔 · 刮到 78% 自动揭晓", fontSize = 12, fontColor = { 160, 140, 105, 200 } },
                }
            },
            -- 符号层（被蒙版覆盖）
            UI.Panel {
                width = "100%", height = "100%", pointerEvents = "none",
                children = cells,
            },
            UI.Panel {
                position = "absolute", bottom = 40, left = 0, right = 0,
                justifyContent = "center",
                children = {
                    UI.Button {
                        text = "懒人模式 · 直接揭晓", width = "50%",
                        variant = "secondary",
                        onClick = function() RevealAll() end,
                    },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
end

--- 全部揭开 + 结算
function RevealAll()
    if scratch_.settled or state_.screen ~= "scratch" then return end
    scratch_.settled = true
    scratch_.removedCount = scratch_.total
    for k = 0, scratch_.total - 1 do scratch_.removed[k] = true end
    SettleTicket()
end

--- 结算
function SettleTicket()
    local cur = state_.current
    if not cur then return end
    state_.scratchedToday = state_.scratchedToday + 1
    if cur.payout > 0 then
        state_.coins = state_.coins + cur.payout
        state_.totalWon = state_.totalWon + cur.payout
    end

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
                            if state_.tickets < 1 then
                                BuildLobby()
                                return
                            end
                            state_.tickets = state_.tickets - 1
                            state_.current = generateTicket()
                            BuildScratch()
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
end
