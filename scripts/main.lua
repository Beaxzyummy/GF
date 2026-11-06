-- ============================================================================
-- 好运游戏厅 · v0.3（+ 幸运转盘）
-- 架构：引擎层(Lua) 只做渲染与输入；结果生成遵循「先抽奖级，再倒填符号」
-- 功能：笔刷刮除 / 免费票倒计时 / 幸运转盘（8 扇区 + 电消耗 + 停针动画）
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
    energyRecoverSec = 300,    -- 1 点电/5 分钟
    energyCap = 30,
}

-- 转盘 8 扇区（与 data/wheel.csv 一致；概率和 = 1.0000）
-- 合规：扇区写具体数值，不写倍率；消耗行动资源（电），无押注动作
local WHEEL = {
    { name = "金币小",   short = "+1,000",  type = "coin",     value = 1000,   prob = 0.3000, color = { 184, 115, 51, 255 } },
    { name = "免费票",   short = "+5票",    type = "ticket",   value = 5,      prob = 0.1500, color = { 76, 175, 80, 255 } },
    { name = "金币中",   short = "+5,000",  type = "coin",     value = 5000,   prob = 0.1500, color = { 192, 192, 192, 255 } },
    { name = "再来一次", short = "再转",    type = "respin",   value = 0,      prob = 0.1500, color = { 156, 39, 176, 255 } },
    { name = "钻石",     short = "+10钻",   type = "diamond",  value = 10,     prob = 0.1000, color = { 33, 150, 243, 255 } },
    { name = "金币大",   short = "+2万",    type = "coin",     value = 20000,  prob = 0.0500, color = { 255, 215, 0, 255 } },
    { name = "员工碎片", short = "+1碎片",  type = "fragment", value = 1,      prob = 0.0800, color = { 255, 152, 0, 255 } },
    { name = "大奖",     short = "+20万",   type = "jackpot",  value = 200000, prob = 0.0200, color = { 244, 67, 54, 255 } },
}
local WHEEL_SPIN_SEC = 3.2      -- GDD 5.x：总时长 3.2s
local WHEEL_EXTRA_TURNS = 5     -- 额外圈数
local WHEEL_JITTER_DEG = 0.8    -- 停针微颤 ±0.8°

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
    diamonds = 160,
    tickets = 20,
    energy = 30,
    ticketRemainMs = 0,
    energyRemainMs = 0,
    fragments = 0,
    current = nil,
    totalWon = 0,
    scratchedToday = 0,
    spinsToday = 0,
}

-- 转盘动画状态
local wheelAnim_ = {
    spinning = false,
    angle = 0,
    startAngle = 0,
    targetAngle = 0,
    elapsed = 0,
    result = nil,
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

    -- 电恢复
    if state_.energy < ECO.energyCap then
        state_.energyRemainMs = state_.energyRemainMs + dtMs
        if state_.energyRemainMs >= ECO.energyRecoverSec * 1000 then
            state_.energyRemainMs = state_.energyRemainMs - ECO.energyRecoverSec * 1000
            state_.energy = state_.energy + 1
            if state_.energy >= ECO.energyCap then state_.energyRemainMs = 0 end
            updateHud()
        end
        local el = uiRoot_ and uiRoot_:FindById("energyTimer") --[[@as Label?]]
        if el then
            local sec = math.ceil((ECO.energyRecoverSec * 1000 - state_.energyRemainMs) / 1000)
            el:SetText(string.format("下一格电 %02d:%02d", math.floor(sec / 60), sec % 60))
        end
    end

    -- 刮卡蒙版 overlay
    if state_.screen == "scratch" and not scratch_.settled then
        UI.QueueOverlay(function(nvg) DrawFoil(nvg) end)
    end

    -- 转盘动画
    if wheelAnim_.spinning and state_.screen == "wheel" then
        wheelAnim_.elapsed = wheelAnim_.elapsed + dtMs / 1000
        local t = math.min(1, wheelAnim_.elapsed / WHEEL_SPIN_SEC)
        local eased = 1 - math.pow(1 - t, 4)  -- easeOutQuart
        wheelAnim_.angle = wheelAnim_.startAngle + (wheelAnim_.targetAngle - wheelAnim_.startAngle) * eased
        if t >= 1 then
            wheelAnim_.spinning = false
            SettleWheel()
        end
        UI.QueueOverlay(function(nvg) DrawWheel(nvg) end)
    elseif state_.screen == "wheel" then
        UI.QueueOverlay(function(nvg) DrawWheel(nvg) end)
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
-- 6.5 幸运转盘
-- ============================================================================

local function pickWheelSector()
    local r, acc = rng(), 0
    for i, s in ipairs(WHEEL) do
        acc = acc + s.prob
        if r < acc then return i end
    end
    return #WHEEL
end

function StartWheelSpin()
    if wheelAnim_.spinning or state_.energy < 1 then return end
    state_.energy = state_.energy - 1
    state_.spinsToday = state_.spinsToday + 1
    local idx = pickWheelSector()
    -- 停在扇区 idx 的中线：扇区 0 从 -90°（正上）开始顺时针，每格 45°
    local seg = 360 / #WHEEL
    local jitter = (rng() * 2 - 1) * WHEEL_JITTER_DEG
    local target = -90 + (idx - 0.5) * seg + jitter + WHEEL_EXTRA_TURNS * 360
    wheelAnim_.startAngle = wheelAnim_.angle or 0
    -- 从当前角度就近多转，避免倒转
    local base = math.floor((wheelAnim_.startAngle) / 360) * 360
    target = base + (target - math.floor(target / 360) * 360) + 360
    while target < wheelAnim_.startAngle + 360 do target = target + 360 end
    wheelAnim_.targetAngle = target
    wheelAnim_.elapsed = 0
    wheelAnim_.spinning = true
    wheelAnim_.result = WHEEL[idx]
    updateHud()
end

function SettleWheel()
    local s = wheelAnim_.result
    if not s then return end
    if s.type == "coin" then
        state_.coins = state_.coins + s.value
    elseif s.type == "ticket" then
        state_.tickets = math.min(ECO.ticketCap, state_.tickets + s.value)
    elseif s.type == "diamond" then
        state_.diamonds = state_.diamonds + s.value
    elseif s.type == "fragment" then
        state_.fragments = state_.fragments + s.value
    end
    local msg
    if s.type == "respin" then
        -- 再来一次：返还电
        state_.energy = math.min(ECO.energyCap, state_.energy + 1)
        msg = "🔄 再来一次！电已返还"
    elseif s.type == "jackpot" then
        state_.coins = state_.coins + s.value
        msg = "🎉 大奖 +200,000 金币！"
    elseif s.type == "coin" then
        msg = "金币 +" .. fmt(s.value)
    elseif s.type == "ticket" then
        msg = "免费票 +" .. s.value
    elseif s.type == "diamond" then
        msg = "钻石 +" .. s.value
    elseif s.type == "fragment" then
        msg = "员工碎片 +1"
    end
    local lbl = uiRoot_ and uiRoot_:FindById("wheelResult") --[[@as Label?]]
    if lbl then lbl:SetText(msg) end
    local spin = uiRoot_:FindById("spinBtn") --[[@as Button?]]
    if spin then spin:SetText(state_.energy >= 1 and "再转一次（1 电）" or "电不足 · 等恢复") end
    updateHud()
end

-- 绘制转盘（NanoVG overlay，逻辑像素坐标系）
function DrawWheel(nvg)
    local cx = UI.GetWidth() / 2
    local cy = math.floor(UI.GetHeight() * 0.38)
    local R = math.min(150, UI.GetWidth() * 0.42)
    local angle = wheelAnim_.angle or 0
    local seg = 360 / #WHEEL

    -- 外圈
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, R + 10)
    nvgFillColor(nvg, nvgRGBA(201, 162, 39, 255))
    nvgFill(nvg)

    for i, s in ipairs(WHEEL) do
        local a0 = math.rad(angle + (i - 1) * seg - 90)
        local a1 = math.rad(angle + i * seg - 90)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgArc(nvg, cx, cy, R, a0, a1, 1)  -- 1 = NVG_CW
        nvgClosePath(nvg)
        nvgFillColor(nvg, s.color)
        nvgFill(nvg)
        -- 扇区文字
        local mid = math.rad(angle + (i - 0.5) * seg - 90)
        local tx = cx + math.cos(mid) * R * 0.62
        local ty = cy + math.sin(mid) * R * 0.62
        nvgSave(nvg)
        nvgTranslate(nvg, tx, ty)
        nvgRotate(nvg, mid + math.pi / 2)
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 15)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 240))
        nvgTextAlign(nvg, 129)
        nvgText(nvg, 0, 0, s.short)
        nvgRestore(nvg)
    end

    -- 中心圆 + 指针（固定在正上）
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 26)
    nvgFillColor(nvg, nvgRGBA(26, 20, 14, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 22)
    nvgFillColor(nvg, nvgRGBA(212, 175, 55, 255))
    nvgFill(nvg)
    -- 指针三角
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, cx - 12, cy - R - 2)
    nvgLineTo(nvg, cx + 12, cy - R - 2)
    nvgLineTo(nvg, cx, cy - R + 22)
    nvgClosePath(nvg)
    nvgFillColor(nvg, nvgRGBA(255, 235, 160, 255))
    nvgFill(nvg)
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

function fmt(n)
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
    local energy = uiRoot_:FindById("energyLabel") --[[@as Label?]]
    if energy then energy:SetText("⚡" .. state_.energy) end
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
                            UI.Label { id = "energyLabel", text = "⚡" .. state_.energy, fontSize = 15, fontColor = { 120, 180, 255, 255 } },
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
                    -- 第二台机台：幸运转盘
                    UI.Panel {
                        width = "88%", maxWidth = 360, padding = 20, gap = 8,
                        backgroundColor = { 34, 30, 46, 245 },
                        borderRadius = 16, borderWidth = 2, borderColor = { 156, 39, 176, 160 },
                        alignItems = "center",
                        children = {
                            UI.Label { text = "🎡 幸运转盘", fontSize = 20, fontColor = { 225, 180, 255, 255 } },
                            UI.Label { text = "金币 / 票 / 钻石 / 碎片 / 大奖 20 万", fontSize = 12, fontColor = { 190, 170, 210, 220 } },
                            UI.Label { id = "energyTimer", text = "", fontSize = 12, fontColor = { 160, 200, 240, 220 } },
                            UI.Button {
                                text = "去转盘（剩 " .. state_.energy .. " 电）",
                                variant = "primary", width = "80%",
                                onClick = function() BuildWheel() end,
                            },
                        }
                    },
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
-- 8.5 界面：转盘
-- ============================================================================

function BuildWheel()
    state_.screen = "wheel"
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", padding = 16, paddingTop = 40,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button {
                        text = "← 大厅", onClick = function() BuildLobby() end,
                    },
                    UI.Label { text = "🎡 幸运转盘", fontSize = 20, fontColor = { 212, 175, 55, 255 } },
                    UI.Label { text = "⚡" .. state_.energy, fontSize = 16, fontColor = { 120, 180, 255, 255 } },
                }
            },
            UI.Panel {
                width = "100%", height = 320, pointerEvents = "none",
            },
            UI.Panel {
                width = "100%", padding = 20, paddingBottom = 44,
                justifyContent = "center", alignItems = "center", gap = 10,
                children = {
                    UI.Label { id = "wheelResult", text = "消耗 1 电 · 转一次", fontSize = 18, fontColor = { 255, 215, 0, 255 } },
                    UI.Button {
                        id = "spinBtn",
                        text = state_.energy >= 1 and "转！（1 电）" or "电不足 · 等恢复",
                        variant = "primary", width = "70%",
                        onClick = function()
                            if not wheelAnim_.spinning then StartWheelSpin() end
                        end,
                    },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
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
