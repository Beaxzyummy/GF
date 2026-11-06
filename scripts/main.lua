-- ============================================================================
-- 好运游戏厅 · v0.4（完整闭环版）
-- 功能：6 种福彩票 + HOT 全收票 + 幸运转盘 + 手机系统（抽卡/员工）+ 离线收益 + 存档
-- 架构：引擎层(Lua) 只做渲染与输入；结果生成遵循「先抽奖级，再倒填符号」
-- 数值来源：data/tickets.csv / ticket_prizes.csv / wheel.csv / gacha.csv / GDD v1.1
-- ============================================================================

local UI = require("urhox-libs/UI")
local cjson = (pcall(require, "cjson")) and require("cjson") or nil

-- ============================================================================
-- 1. 数值配置
-- ============================================================================

-- 福彩票（data/tickets.csv + ticket_prizes.csv；unlock=累计刮卡数解锁，T5/T6 待接广告/签到）
local TICKETS = {
    { id="T1", name="晨光", price=5,   unlock=0,   color={245,240,230}, tiers={
        {m=0,p=0.6500,v=0},{m=3,p=0.2400,v=8},{m=5,p=0.0800,v=20},{m=7,p=0.0260,v=80},{m=9,p=0.0040,v=300} } },
    { id="T2", name="雨后", price=20,  unlock=15,  color={122,154,140}, tiers={
        {m=0,p=0.6800,v=0},{m=3,p=0.2100,v=32},{m=5,p=0.0800,v=90},{m=7,p=0.0270,v=380},{m=9,p=0.0030,v=2000} } },
    { id="T3", name="烫金", price=80,  unlock=40,  color={201,162,39},  tiers={
        {m=0,p=0.7000,v=0},{m=3,p=0.1950,v=130},{m=5,p=0.0780,v=400},{m=7,p=0.0240,v=1800},{m=9,p=0.0030,v=12000} } },
    { id="T4", name="丝绒", price=300, unlock=100, color={142,43,53},   tiers={
        {m=0,p=0.7300,v=0},{m=3,p=0.1700,v=480},{m=5,p=0.0720,v=1500},{m=7,p=0.0255,v=8000},{m=9,p=0.0025,v=60000} } },
    { id="T5", name="夜光", price=1200,unlock=150, color={74,111,165},  tiers={
        {m=0,p=0.7600,v=0},{m=3,p=0.1500,v=2000},{m=5,p=0.0650,v=7000},{m=7,p=0.0230,v=40000},{m=9,p=0.0020,v=300000} } },
    { id="T6", name="霜花", price=5000,unlock=200, color={155,196,221}, tiers={
        {m=0,p=0.8000,v=0},{m=3,p=0.1200,v=9000},{m=5,p=0.0540,v=30000},{m=7,p=0.0240,v=180000},{m=9,p=0.0020,v=2000000} } },
}

-- HOT 全收票（GDD 第 4 章）：面额 200，8% 全收 16 格
local HOT = {
    name = "HOT 全收", price = 200,
    amounts = { 20,20,20,20,20,20, 60,60,60,60, 200,200,200, 600,600, 2000 },
    hotChance = 0.08, dollarCells = 3, dollarChance = 0.06, normalChance = 0.03,
}

-- 转盘（data/wheel.csv）
local WHEEL = {
    { name="金币小", short="+1,000", type="coin", value=1000, prob=0.3000, color={184,115,51,255} },
    { name="免费票", short="+5票", type="ticket", value=5, prob=0.1500, color={76,175,80,255} },
    { name="金币中", short="+5,000", type="coin", value=5000, prob=0.1500, color={192,192,192,255} },
    { name="再来一次", short="再转", type="respin", value=0, prob=0.1500, color={156,39,176,255} },
    { name="钻石", short="+10钻", type="diamond", value=10, prob=0.1000, color={33,150,243,255} },
    { name="金币大", short="+2万", type="coin", value=20000, prob=0.0500, color={255,215,0,255} },
    { name="员工碎片", short="+1碎片", type="fragment", value=1, prob=0.0800, color={255,152,0,255} },
    { name="大奖", short="+20万", type="jackpot", value=200000, prob=0.0200, color={244,67,54,255} },
}
local WHEEL_SPIN_SEC = 3.2
local WHEEL_EXTRA_TURNS = 5
local WHEEL_JITTER_DEG = 0.8

-- 抽卡（GDD 6.3：概率必须公示）
local GACHA = {
    { rarity="UR",  prob=0.0050 },
    { rarity="SSR", prob=0.0370 },
    { rarity="SR",  prob=0.2780 },
    { rarity="R",   prob=0.6800 },
}
local GACHA_PRICE = { single = 160, ten = 1600 }
local DUP_SHARDS = { UR=20, SSR=8, SR=3, R=1 }
local SHARDS_PER_UNIT = 10
local RARITY_COLOR = { UR={255,215,0,255}, SSR={192,160,255,255}, SR={120,190,255,255}, R={180,180,180,255} }

-- 员工图鉴（GDD 6.5：UR 1 / SSR 3 / SR 6 / R 12 = 22）
local STAFF_BASE = {
    R   = { prod=2,   upBase=500 },
    SR  = { prod=15,  upBase=4000 },
    SSR = { prod=120, upBase=30000 },
    UR  = { prod=800, upBase=200000 },
}
local STAFF_CATALOG = {
    { id="ur_daju",  name="大橘",   rarity="UR",  desc="招财猫 · 全局产出+50%" },
    { id="ssr_shop",   name="老陈",   rarity="SSR", desc="彩票柜台老师傅" },
    { id="ssr_wheel",  name="阿澜",   rarity="SSR", desc="转盘台报幕员" },
    { id="ssr_office", name="林小满", rarity="SSR", desc="后台账房先生" },
    { id="sr_1", name="小赵", rarity="SR", desc="麻利的柜台伙计" },
    { id="sr_2", name="阿武", rarity="SR", desc="总能刮出好签" },
    { id="sr_3", name="杏子", rarity="SR", desc="转盘台气氛担当" },
    { id="sr_4", name="老周", rarity="SR", desc="守老虎机二十年" },
    { id="sr_5", name="小白", rarity="SR", desc="登记实习生" },
    { id="sr_6", name="阿花", rarity="SR", desc="门口迎宾" },
    { id="r_01", name="学徒一",   rarity="R", desc="刚来的学徒" },
    { id="r_02", name="学徒二",   rarity="R", desc="刚来的学徒" },
    { id="r_03", name="学徒三",   rarity="R", desc="刚来的学徒" },
    { id="r_04", name="学徒四",   rarity="R", desc="刚来的学徒" },
    { id="r_05", name="学徒五",   rarity="R", desc="刚来的学徒" },
    { id="r_06", name="学徒六",   rarity="R", desc="刚来的学徒" },
    { id="r_07", name="学徒七",   rarity="R", desc="刚来的学徒" },
    { id="r_08", name="学徒八",   rarity="R", desc="刚来的学徒" },
    { id="r_09", name="学徒九",   rarity="R", desc="刚来的学徒" },
    { id="r_10", name="学徒十",   rarity="R", desc="刚来的学徒" },
    { id="r_11", name="学徒十一", rarity="R", desc="刚来的学徒" },
    { id="r_12", name="学徒十二", rarity="R", desc="刚来的学徒" },
}
local STAFF_BY_ID = {}
for _, s in ipairs(STAFF_CATALOG) do STAFF_BY_ID[s.id] = s end

-- 经济参数（data/economy.csv）
local ECO = {
    ticketRecoverSec = 30,  ticketCap = 20,
    energyRecoverSec = 300, energyCap = 30,
    offlineCapHours = 8,
    upgradeRatio = 1.55,
    brushRadius = 30, revealThreshold = 0.78,
    gridCols = 18, gridRows = 18,
    bankruptcyTickets = 20, bankruptcyCoins = 500, bankruptcyDailyCap = 3,
}

local SYMBOLS = { "✦", "✿", "◆", "●" }
local FILL_WEIGHTS = { {30},{28},{24},{16} }  -- 下标对应 SYMBOLS

-- ============================================================================
-- 2. 核心逻辑（先抽奖级，再倒填符号 —— 合规关键）
-- ============================================================================

local rngState_ = 20261106
local function rng()
    rngState_ = (rngState_ * 1103515245 + 12345) % 2147483648
    return rngState_ / 2147483648
end

function fmt(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return out
end

local function weightedSym(exclude)
    local idxs, total = {}, 0
    for i, w in ipairs(FILL_WEIGHTS) do
        if SYMBOLS[i] ~= exclude then table.insert(idxs, i); total = total + w[1] end
    end
    local r = rng() * total
    for _, i in ipairs(idxs) do
        r = r - FILL_WEIGHTS[i][1]
        if r <= 0 then return SYMBOLS[i] end
    end
    return SYMBOLS[idxs[#idxs]]
end

--- 福彩票生成（ticket = TICKETS 元素）
local function generateTicket(ticket)
    local r, tier, acc = rng(), nil, 0
    for _, t in ipairs(ticket.tiers) do
        acc = acc + t.p
        if r < acc then tier = t; break end
    end
    if not tier then tier = ticket.tiers[#ticket.tiers] end

    local winning = SYMBOLS[math.floor(rng() * 4) + 1]
    local matchCount = tier.m
    if matchCount == 0 then matchCount = math.floor(rng() * 3) end

    local cells, placed = {}, 0
    for i = 1, 9 do
        if placed < matchCount and rng() < (matchCount - placed) / (10 - i) then
            cells[i] = winning; placed = placed + 1
        else
            cells[i] = weightedSym(winning)
        end
    end
    while placed < matchCount do
        local i = math.floor(rng() * 9) + 1
        if cells[i] ~= winning then cells[i] = winning; placed = placed + 1 end
    end
    while placed > matchCount do
        local i = math.floor(rng() * 9) + 1
        if cells[i] == winning then cells[i] = weightedSym(winning); placed = placed - 1 end
    end
    return { kind="lottery", ticket=ticket, cells=cells, winning=winning, payout=tier.v, matchCount=matchCount }
end

--- HOT 票生成（16 格 + HOT 位；先决定 HOT，再定 $$ 格）
local function generateHot()
    local isHot = rng() < HOT.hotChance
    local cells = {}
    for i = 1, 16 do cells[i] = HOT.amounts[i] end
    -- 打乱金额（Fisher-Yates）
    for i = 16, 2, -1 do
        local j = math.floor(rng() * i) + 1
        cells[i], cells[j] = cells[j], cells[i]
    end
    -- $$ 格：随机 3 个
    local dollar = {}
    local placed = 0
    while placed < HOT.dollarCells do
        local i = math.floor(rng() * 16) + 1
        if not dollar[i] then dollar[i] = true; placed = placed + 1 end
    end
    return { kind="hot", cells=cells, dollar=dollar, isHot=isHot }
end

--- 抽卡
local function pickRarity()
    local r, acc = rng(), 0
    for _, g in ipairs(GACHA) do
        acc = acc + g.prob
        if r < acc then return g.rarity end
    end
    return "R"
end

local function pickStaff(rarity)
    local pool = {}
    for _, s in ipairs(STAFF_CATALOG) do
        if s.rarity == rarity then table.insert(pool, s) end
    end
    return pool[math.floor(rng() * #pool) + 1]
end

--- 十连：第 10 抽不达 SR 则锁定 SR（保底不污染前 9 抽公示概率）
local function gachaTen()
    local results = {}
    for i = 1, 10 do
        if i < 10 then
            table.insert(results, pickStaff(pickRarity()))
        else
            local last = pickStaff(pickRarity())
            if last.rarity == "R" then last = pickStaff("SR") end
            table.insert(results, last)
        end
    end
    return results
end

--- 员工产出
local function staffProduction(rec)
    local base = STAFF_BASE[rec.rarity]
    return math.floor(base.prod * math.pow(1.12, rec.level - 1))
end

local function staffUpgradeCost(rec)
    if rec.level >= 20 then return nil end
    return math.floor(STAFF_BASE[rec.rarity].upBase * math.pow(ECO.upgradeRatio, rec.level - 1))
end

local function totalProduction()
    local sum, hasUR = 0, false
    for _, rec in ipairs(state_.staffs) do
        if rec.deployed then
            sum = sum + staffProduction(rec)
            if rec.id == "ur_daju" then hasUR = true end
        end
    end
    if hasUR then sum = math.floor(sum * 1.5) end
    return sum
end

-- ============================================================================
-- 3. 状态 + 存档
-- ============================================================================

function defaultState()
    return {
        coins=500, diamonds=160, tickets=20, energy=30, fragments=0,
        ticketRemainMs=0, energyRemainMs=0,
        totalScratched=0, totalWon=0, spinsToday=0,
        bankruptcyDay=0, bankruptcyCount=0,
        owned={},       -- staffId → { id, rarity, level, deployed }
        shards={ UR=0,SSR=0,SR=0,R=0 },
        lastSeen=os.time(),
    }
end

state_ = defaultState()

local SAVE_FILE = "save.json"

function saveGame()
    state_.lastSeen = os.time()
    if not cjson then return end
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(cjson.encode(state_))
        file:Close()
    end
end

function loadGame()
    if not cjson or not fileSystem:FileExists(SAVE_FILE) then return false end
    local file = File(SAVE_FILE, FILE_READ)
    if not file:IsOpen() then return false end
    local ok, data = pcall(cjson.decode, file:ReadString())
    file:Close()
    if not ok or type(data) ~= "table" then return false end
    local d = defaultState()
    for k, v in pairs(data) do d[k] = v end
    if type(d.owned) ~= "table" then d.owned = {} end
    if type(d.shards) ~= "table" then d.shards = { UR=0,SSR=0,SR=0,R=0 } end
    state_ = d
    return true
end

--- 离线结算（8h 封顶；返回账单或 nil）
function settleOffline()
    local now = os.time()
    local away = now - (state_.lastSeen or now)
    if away < 60 then return nil end
    local prod = totalProduction()
    if prod <= 0 then return nil end
    local cappedSec = math.min(away, ECO.offlineCapHours * 3600)
    local coins = math.floor(cappedSec * prod)
    state_.coins = state_.coins + coins
    return { coins=coins, away=away, capped = away > ECO.offlineCapHours * 3600, prod=prod }
end

--- 破产兜底（GDD 8.x：金币<5 且 票=0 且 电=0）
function checkBankruptcy()
    local day = math.floor(os.time() / 86400)
    if state_.bankruptcyDay ~= day then
        state_.bankruptcyDay = day
        state_.bankruptcyCount = 0
    end
    if state_.coins >= 5 or state_.tickets > 0 or state_.energy > 0 then return nil end
    if state_.bankruptcyCount >= ECO.bankruptcyDailyCap then return nil end
    state_.bankruptcyCount = state_.bankruptcyCount + 1
    state_.tickets = state_.tickets + ECO.bankruptcyTickets
    state_.coins = state_.coins + ECO.bankruptcyCoins
    return { tickets=ECO.bankruptcyTickets, coins=ECO.bankruptcyCoins }
end

-- ============================================================================
-- 4. 运行时状态
-- ============================================================================

local uiRoot_ = nil
local nvgCtx_ = nil
local offlineBill_ = nil
local bankBill_ = nil

local scratch_ = {
    mode = "lottery",          -- lottery | hot
    result = nil,
    removed = {}, removed2 = {},
    removedCount = 0, total = ECO.gridCols * ECO.gridRows,
    rect = { x=0, y=0, w=252, h=252 },
    rect2 = nil,               -- HOT 附加位
    pointerDown = false, lastX = 0, lastY = 0, settled = false,
}

local wheelAnim_ = { spinning=false, angle=0, startAngle=0, targetAngle=0, elapsed=0, result=nil }

local screenStack_ = {}      -- 简单返回栈：phone 等

-- ============================================================================
-- 5. 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = "好运游戏厅"
    UI.Init({
        fonts = { { family = "sans", weights = { normal = "Fonts/NotoSansSC.ttf" } } },
        scale = UI.Scale.DEFAULT,
    })
    nvgCtx_ = UI.GetNVGContext()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("TouchMove", "HandleTouchMove")
    SubscribeToEvent("TouchEnd", "HandleTouchEnd")

    local hadSave = loadGame()
    if hadSave then
        offlineBill_ = settleOffline()
    end
    BuildLobby()
    if offlineBill_ then ShowOfflinePanel(offlineBill_) end
    bankBill_ = checkBankruptcy()
    if bankBill_ and not offlineBill_ then
        ShowToast("破产补助：票 +" .. bankBill_.tickets .. " · 金币 +" .. bankBill_.coins)
    end
    print("=== 好运游戏厅 v0.4 启动 ===")
end

function Stop()
    saveGame()
    UI.Shutdown()
end

function ShowToast(text)
    local t = uiRoot_ and uiRoot_:FindById("toast") --[[@as Label?]]
    if t then t:SetText(text) end
end

function ShowOfflinePanel(bill)
    local overlay = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 210 },
        justifyContent = "center", alignItems = "center",
        children = {
            UI.Panel {
                width = "80%", maxWidth = 320, padding = 28, gap = 12, alignItems = "center",
                backgroundColor = { 60, 45, 15, 250 }, borderRadius = 16,
                borderWidth = 2, borderColor = { 255, 215, 0, 220 },
                children = {
                    UI.Label { text = "🌙 你不在的时候", fontSize = 20, fontColor = { 245,240,230,255 } },
                    UI.Label { text = "店里赚了 " .. fmt(bill.coins) .. " 金币", fontSize = 24, fontColor = { 255,215,0,255 } },
                    UI.Label { text = string.format("离线 %d 小时 %d 分 · 产出 %d/秒", math.floor(bill.away/3600), math.floor(bill.away%3600/60), bill.prod), fontSize = 13, fontColor = { 200,185,150,230 } },
                    UI.Button { text = "收下", variant = "primary", width = "70%",
                        onClick = function(self)
                            local panel = uiRoot_:FindById("offlinePanel")
                            if panel then panel:Hide() end
                            updateHud()
                        end,
                    },
                }
            }
        }
    }
    -- 包一层 id 便于隐藏
    local wrapper = UI.Panel {
        id = "offlinePanel",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        pointerEvents = "box-none",
        children = { overlay },
    }
    uiRoot_:AddChild(wrapper)
end

-- ============================================================================
-- 6. 每帧更新（恢复/动画/overlay）
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dtMs = eventData["TimeStep"]:GetFloat() * 1000
    local dirty = false

    if state_.tickets < ECO.ticketCap then
        state_.ticketRemainMs = state_.ticketRemainMs + dtMs
        if state_.ticketRemainMs >= ECO.ticketRecoverSec * 1000 then
            state_.ticketRemainMs = state_.ticketRemainMs - ECO.ticketRecoverSec * 1000
            state_.tickets = state_.tickets + 1
            if state_.tickets >= ECO.ticketCap then state_.ticketRemainMs = 0 end
            dirty = true
        end
    end
    if state_.energy < ECO.energyCap then
        state_.energyRemainMs = state_.energyRemainMs + dtMs
        if state_.energyRemainMs >= ECO.energyRecoverSec * 1000 then
            state_.energyRemainMs = state_.energyRemainMs - ECO.energyRecoverSec * 1000
            state_.energy = state_.energy + 1
            if state_.energy >= ECO.energyCap then state_.energyRemainMs = 0 end
            dirty = true
        end
    end
    if dirty then updateHud() end

    -- 倒计时文字（大厅）
    if state_.screen == "lobby" and uiRoot_ then
        local tk = uiRoot_:FindById("ticketTimer") --[[@as Label?]]
        if tk then
            if state_.tickets >= ECO.ticketCap then tk:SetText("免费票已满")
            else
                local sec = math.ceil((ECO.ticketRecoverSec * 1000 - state_.ticketRemainMs) / 1000)
                tk:SetText(string.format("下一张免费票 %02d:%02d", math.floor(sec/60), sec%60))
            end
        end
        local el = uiRoot_:FindById("energyTimer") --[[@as Label?]]
        if el then
            if state_.energy >= ECO.energyCap then el:SetText("电已满")
            else
                local sec = math.ceil((ECO.energyRecoverSec * 1000 - state_.energyRemainMs) / 1000)
                el:SetText(string.format("下一格电 %02d:%02d", math.floor(sec/60), sec%60))
            end
        end
    end

    -- overlays
    if state_.screen == "scratch" and not scratch_.settled then
        UI.QueueOverlay(function(nvg) DrawFoil(nvg) end)
    elseif state_.screen == "wheel" then
        if wheelAnim_.spinning then
            wheelAnim_.elapsed = wheelAnim_.elapsed + dtMs / 1000
            local t = math.min(1, wheelAnim_.elapsed / WHEEL_SPIN_SEC)
            local eased = 1 - math.pow(1 - t, 4)
            wheelAnim_.angle = wheelAnim_.startAngle + (wheelAnim_.targetAngle - wheelAnim_.startAngle) * eased
            if t >= 1 then wheelAnim_.spinning = false; SettleWheel() end
        end
        UI.QueueOverlay(function(nvg) DrawWheel(nvg) end)
    end
end

-- ============================================================================
-- 7. 触摸 → 笔刷刮除
-- ============================================================================

local function toLogical(x)
    return x * (UI.GetWidth() / graphics.width)
end

local function scratchRectAt(lx, ly, r, removed, total)
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
            if not removed[key] then
                local cx = r.x + (col + 0.5) * cellW
                local cy = r.y + (row + 0.5) * cellH
                local dx, dy = cx - lx, cy - ly
                if dx * dx + dy * dy <= br2 then
                    removed[key] = true
                    scratch_.removedCount = scratch_.removedCount + 1
                    changed = true
                end
            end
        end
    end
    return changed
end

local function scratchAt(lx, ly)
    local changed = scratchRectAt(lx, ly, scratch_.rect, scratch_.removed, scratch_.total)
    if scratch_.rect2 then
        changed = scratchRectAt(lx, ly, scratch_.rect2, scratch_.removed2, 1) or changed
    end
    if changed then
        local ratio = scratch_.removedCount / scratch_.total
        if ratio >= ECO.revealThreshold then RevealAll() end
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
-- 8. 蒙版 / 转盘渲染
-- ============================================================================

local function drawFoilRect(nvg, r, removed)
    local cellW, cellH = r.w / ECO.gridCols, r.h / ECO.gridRows
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, r.x - 4, r.y - 4, r.w + 8, r.h + 8, 12)
    nvgFillColor(nvg, nvgRGBA(172, 178, 189, 255))
    nvgFill(nvg)
    for row = 0, ECO.gridRows - 1 do
        for col = 0, ECO.gridCols - 1 do
            if not removed[row * ECO.gridCols + col] then
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
end

function DrawFoil(nvg)
    drawFoilRect(nvg, scratch_.rect, scratch_.removed)
    if scratch_.rect2 then
        drawFoilRect(nvg, scratch_.rect2, scratch_.removed2)
    end
    local ratio = scratch_.removedCount / scratch_.total
    if ratio > 0.02 then
        local r = scratch_.rect
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, r.x + r.w - 78, r.y + r.h + 10, 78, 20, 6)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 120))
        nvgFill(nvg)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 220))
        nvgFontSize(nvg, 13)
        nvgTextAlign(nvg, 129)
        nvgText(nvg, r.x + r.w - 39, r.y + r.h + 21, string.format("已刮 %d%%", math.floor(ratio * 100)))
    end
end

function DrawWheel(nvg)
    local cx = UI.GetWidth() / 2
    local cy = math.floor(UI.GetHeight() * 0.36)
    local R = math.min(150, UI.GetWidth() * 0.42)
    local angle = wheelAnim_.angle or 0
    local seg = 360 / #WHEEL

    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, R + 10)
    nvgFillColor(nvg, nvgRGBA(201, 162, 39, 255))
    nvgFill(nvg)

    for i, s in ipairs(WHEEL) do
        local a0 = math.rad(angle + (i - 1) * seg - 90)
        local a1 = math.rad(angle + i * seg - 90)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgArc(nvg, cx, cy, R, a0, a1, 1)
        nvgClosePath(nvg)
        nvgFillColor(nvg, s.color)
        nvgFill(nvg)
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

    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 26)
    nvgFillColor(nvg, nvgRGBA(26, 20, 14, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 22)
    nvgFillColor(nvg, nvgRGBA(212, 175, 55, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, cx - 12, cy - R - 2)
    nvgLineTo(nvg, cx + 12, cy - R - 2)
    nvgLineTo(nvg, cx, cy - R + 22)
    nvgClosePath(nvg)
    nvgFillColor(nvg, nvgRGBA(255, 235, 160, 255))
    nvgFill(nvg)
end

-- ============================================================================
-- 9. 大厅
-- ============================================================================

local function updateCurrencyBar()
    if not uiRoot_ then return end
    local ids = { coinsLabel = "金币 " .. fmt(state_.coins), ticketsLabel = "票 " .. state_.tickets,
                  energyLabel = "⚡" .. state_.energy, diamondsLabel = "💎" .. state_.diamonds }
    for id, text in pairs(ids) do
        local l = uiRoot_:FindById(id) --[[@as Label?]]
        if l then l:SetText(text) end
    end
end

function updateHud()
    updateCurrencyBar()
    if not uiRoot_ then return end
    local stat = uiRoot_:FindById("statLabel") --[[@as Label?]]
    if stat then stat:SetText("今日刮了 " .. state_.totalScratched .. " 张 · 累计中奖 " .. fmt(state_.totalWon) .. " 币 · 产出 " .. totalProduction() .. "/秒") end
    local buy = uiRoot_:FindById("buyBtn") --[[@as Button?]]
    if buy then buy:SetText("刮一张（剩 " .. state_.tickets .. " 张）") end
end

--- 刮卡柜台（选票）
function BuildLobby()
    state_.screen = "lobby"
    saveGame()
    local ticketBtns = {}
    for _, tk in ipairs(TICKETS) do
        local unlocked = state_.totalScratched >= tk.unlock
        table.insert(ticketBtns, UI.Button {
            text = unlocked and (tk.name .. "\n¥" .. tk.price) or ("🔒" .. tk.unlock .. "张"),
            width = 82, height = 56, fontSize = 13,
            enabled = unlocked,
            onClick = function()
                StartScratch(tk)
            end,
        })
    end
    local hotUnlocked = state_.totalScratched >= 30

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        justifyContent = "space-between",
        children = {
            -- 顶栏
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 36,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Label { text = "🏛 好运游戏厅", fontSize = 19, fontColor = { 212, 175, 55, 255 } },
                    UI.Panel { gap = 10, alignItems = "center", children = {
                        UI.Label { id = "coinsLabel", text = "金币 " .. fmt(state_.coins), fontSize = 14, fontColor = { 255, 215, 0, 255 } },
                        UI.Label { id = "ticketsLabel", text = "票 " .. state_.tickets, fontSize = 14, fontColor = { 120, 220, 160, 255 } },
                        UI.Label { id = "diamondsLabel", text = "💎" .. state_.diamonds, fontSize = 14, fontColor = { 150, 200, 255, 255 } },
                        UI.Label { id = "energyLabel", text = "⚡" .. state_.energy, fontSize = 14, fontColor = { 120, 180, 255, 255 } },
                    }},
                }
            },
            -- 中部
            UI.Panel {
                width = "100%", justifyContent = "center", alignItems = "center", gap = 10,
                children = {
                    UI.Label { id = "ticketTimer", text = "", fontSize = 12, fontColor = { 150, 200, 160, 220 } },
                    -- 刮刮乐柜台
                    UI.Panel {
                        width = "90%", maxWidth = 380, padding = 16, gap = 10,
                        backgroundColor = { 44, 34, 22, 245 },
                        borderRadius = 16, borderWidth = 2, borderColor = { 201, 162, 39, 160 },
                        alignItems = "center",
                        children = {
                            UI.Label { text = "🎫 彩票柜台", fontSize = 17, fontColor = { 245, 240, 230, 255 } },
                            UI.Panel { gap = 6, flexWrap = "wrap", justifyContent = "center", children = ticketBtns },
                            UI.Label { text = "（累计刮卡解锁更高面额）", fontSize = 10, fontColor = { 150, 135, 105, 190 } },
                        }
                    },
                    -- HOT + 转盘
                    UI.Panel { gap = 10, children = {
                        UI.Panel {
                            width = 170, padding = 14, gap = 6, alignItems = "center",
                            backgroundColor = { 60, 26, 18, 245 }, borderRadius = 14,
                            borderWidth = 2, borderColor = { 244, 67, 54, 170 },
                            children = {
                                UI.Label { text = "🔥 HOT 全收", fontSize = 16, fontColor = { 255, 160, 140, 255 } },
                                UI.Label { text = hotUnlocked and "¥200 · 8%全收16格" or "🔒 刮满30张解锁", fontSize = 11, fontColor = { 220, 190, 180, 220 } },
                                UI.Button { text = hotUnlocked and "刮 HOT" or "未解锁", fontSize = 13,
                                    enabled = hotUnlocked, variant = "primary",
                                    onClick = function() StartHot() end },
                            }
                        },
                        UI.Panel {
                            width = 170, padding = 14, gap = 6, alignItems = "center",
                            backgroundColor = { 34, 30, 46, 245 }, borderRadius = 14,
                            borderWidth = 2, borderColor = { 156, 39, 176, 170 },
                            children = {
                                UI.Label { text = "🎡 幸运转盘", fontSize = 16, fontColor = { 225, 180, 255, 255 } },
                                UI.Label { id = "energyTimer", text = "", fontSize = 11, fontColor = { 190, 170, 210, 220 } },
                                UI.Button { text = "去转盘", fontSize = 13, variant = "primary",
                                    onClick = function() BuildWheel() end },
                            }
                        },
                    }},
                    UI.Label { id = "statLabel", text = "今日刮了 " .. state_.totalScratched .. " 张 · 产出 " .. totalProduction() .. "/秒", fontSize = 12, fontColor = { 170, 150, 110, 200 } },
                }
            },
            -- 底栏 + 手机
            UI.Panel {
                width = "100%", padding = 12, paddingBottom = 26,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Label { text = "v0.4 完整闭环", fontSize = 10, fontColor = { 120, 105, 80, 180 } },
                    UI.Button {
                        text = "📱 手机", fontSize = 16,
                        onClick = function() BuildPhone() end,
                    },
                    UI.Label { id = "toast", text = "", fontSize = 11, fontColor = { 255, 220, 130, 220 } },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
    updateHud()
end

-- ============================================================================
-- 10. 刮卡（福彩 + HOT 通用）
-- ============================================================================

local function layoutFoil(areaW, areaH)
    local logicalW, logicalH = UI.GetWidth(), UI.GetHeight()
    local gx = math.floor((logicalW - areaW) / 2)
    local gy = math.floor(logicalH * 0.28)
    scratch_.rect = { x = gx, y = gy, w = areaW, h = areaH }
    if scratch_.mode == "hot" then
        scratch_.rect2 = { x = gx + areaW / 2 - 40, y = gy + areaH + 16, w = 80, h = 80 }
        scratch_.total = ECO.gridCols * ECO.gridRows + ECO.gridCols * ECO.gridRows
    else
        scratch_.rect2 = nil
        scratch_.total = ECO.gridCols * ECO.gridRows
    end
    scratch_.removed = {}
    scratch_.removed2 = {}
    scratch_.removedCount = 0
end

function StartScratch(tk)
    if state_.tickets < 1 then
        ShowToast("票不足 · 等免费票恢复")
        return
    end
    state_.tickets = state_.tickets - 1
    scratch_.mode = "lottery"
    scratch_.result = generateTicket(tk)
    scratch_.settled = false
    buildScratchScreen()
end

function StartHot()
    if state_.tickets < 1 then
        ShowToast("票不足 · 等免费票恢复")
        return
    end
    state_.tickets = state_.tickets - 1
    scratch_.mode = "hot"
    scratch_.result = generateHot()
    scratch_.settled = false
    buildScratchScreen()
end

function buildScratchScreen()
    state_.screen = "scratch"
    local cur = scratch_.result
    local title, hint
    local cellWidgets = {}
    local areaW, areaH

    if scratch_.mode == "lottery" then
        areaW, areaH = 252, 252
        layoutFoil(areaW, areaH)
        title = "有效符号 " .. cur.winning .. " · " .. cur.ticket.name .. " ¥" .. cur.ticket.price
        hint = "刮到 78% 自动揭晓"
        local r = scratch_.rect
        for i = 1, 9 do
            local row = math.floor((i - 1) / 3)
            local col = (i - 1) % 3
            local isWin = cur.cells[i] == cur.winning
            table.insert(cellWidgets, UI.Panel {
                width = 76, height = 76, position = "absolute",
                left = r.x + 6 + col * 82, top = r.y + 6 + row * 82,
                borderRadius = 8,
                backgroundColor = isWin and { 70, 55, 20, 255 } or { 52, 44, 32, 255 },
                justifyContent = "center", alignItems = "center", pointerEvents = "none",
                children = { UI.Label { text = cur.cells[i], fontSize = 34,
                    fontColor = isWin and { 255, 215, 0, 255 } or { 200, 188, 165, 255 } } },
            })
        end
    else
        areaW, areaH = 232, 232
        layoutFoil(areaW, areaH)
        title = "🔥 HOT 全收 · ¥200"
        hint = "刮出 HOT → 16 格全收 · $$ 格单独给钱"
        local r = scratch_.rect
        local cw = (areaW - 18) / 4
        for i = 1, 16 do
            local row = math.floor((i - 1) / 4)
            local col = (i - 1) % 4
            local isDollar = cur.dollar[i]
            table.insert(cellWidgets, UI.Panel {
                width = cw, height = cw, position = "absolute",
                left = r.x + 6 + col * (cw + 2), top = r.y + 6 + row * (cw + 2),
                borderRadius = 6,
                backgroundColor = isDollar and { 80, 60, 15, 255 } or { 52, 44, 32, 255 },
                justifyContent = "center", alignItems = "center", pointerEvents = "none",
                children = {
                    UI.Label { text = isDollar and ("$$ " .. cur.cells[i]) or tostring(cur.cells[i]), fontSize = isDollar and 15 or 18,
                        fontColor = isDollar and { 255, 215, 0, 255 } or { 200, 188, 165, 255 } },
                },
            })
        end
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        children = {
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 36,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "←", onClick = function() BuildLobby() end },
                    UI.Label { text = title, fontSize = 16, fontColor = { 212, 175, 55, 255 } },
                    UI.Label { text = "票 " .. state_.tickets, fontSize = 13, fontColor = { 120, 220, 160, 255 } },
                }
            },
            UI.Panel {
                width = "100%", height = "100%", pointerEvents = "none",
                children = cellWidgets,
            },
            UI.Panel {
                position = "absolute", bottom = 36, left = 0, right = 0,
                justifyContent = "center",
                children = {
                    UI.Label { text = hint, fontSize = 12, fontColor = { 160, 140, 105, 200 }, position = "absolute", bottom = 52, left = 0, right = 0, textAlign = "center" },
                    UI.Button { text = "懒人模式 · 直接揭晓", width = "50%", variant = "secondary",
                        onClick = function() RevealAll() end },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
end

function RevealAll()
    if scratch_.settled or state_.screen ~= "scratch" then return end
    scratch_.settled = true
    for k = 0, ECO.gridCols * ECO.gridRows - 1 do
        scratch_.removed[k] = true
        scratch_.removed2[k] = true
    end
    scratch_.removedCount = scratch_.total
    SettleScratch()
end

function SettleScratch()
    local cur = scratch_.result
    local payout = 0
    local detail

    if scratch_.mode == "lottery" then
        payout = cur.payout
        detail = "匹配 " .. cur.matchCount .. " 个 " .. cur.winning
        state_.totalScratched = state_.totalScratched + 1
    else
        if cur.isHot then
            for _, v in ipairs(cur.cells) do payout = payout + v end
            detail = "🔥 HOT！16 格全收"
        else
            for i, v in ipairs(cur.cells) do
                if cur.dollar[i] then payout = payout + v end
            end
            detail = "$$ 格收集"
        end
        state_.totalScratched = state_.totalScratched + 1
    end

    if payout > 0 then
        state_.coins = state_.coins + payout
        state_.totalWon = state_.totalWon + payout
    end

    local banner = UI.Panel {
        id = "resultBanner",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 200 },
        justifyContent = "center", alignItems = "center",
        children = {
            UI.Panel {
                width = "80%", maxWidth = 320, padding = 28, gap = 10, alignItems = "center",
                backgroundColor = payout > 0 and { 60, 45, 15, 250 } or { 40, 36, 30, 250 },
                borderRadius = 16, borderWidth = 2,
                borderColor = payout > 0 and { 255, 215, 0, 255 } or { 110, 100, 85, 200 },
                children = {
                    UI.Label { text = payout > 0 and ("🎉 + " .. fmt(payout) .. " 币！") or "谢谢惠顾", fontSize = 26,
                        fontColor = payout > 0 and { 255, 215, 0, 255 } or { 180, 170, 150, 255 } },
                    UI.Label { text = detail, fontSize = 14, fontColor = { 200, 185, 150, 230 } },
                    UI.Button { text = "再来一张", variant = "primary", width = "70%",
                        onClick = function()
                            if scratch_.mode == "lottery" then StartScratch(cur.ticket) else StartHot() end
                        end },
                    UI.Button { text = "回大厅", width = "70%", onClick = function() BuildLobby() end },
                }
            }
        }
    }
    uiRoot_:AddChild(banner)
    saveGame()
end

-- ============================================================================
-- 11. 转盘
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
    local seg = 360 / #WHEEL
    local jitter = (rng() * 2 - 1) * WHEEL_JITTER_DEG
    local target = -90 + (idx - 0.5) * seg + jitter
    local base = math.floor(wheelAnim_.angle / 360) * 360
    target = base + (target - math.floor(target / 360) * 360) + 360
    while target < wheelAnim_.angle + 360 do target = target + 360 end
    wheelAnim_.startAngle = wheelAnim_.angle
    wheelAnim_.targetAngle = target
    wheelAnim_.elapsed = 0
    wheelAnim_.spinning = true
    wheelAnim_.result = WHEEL[idx]
    updateHud()
end

function SettleWheel()
    local s = wheelAnim_.result
    if not s then return end
    local msg
    if s.type == "respin" then
        state_.energy = math.min(ECO.energyCap, state_.energy + 1)
        msg = "🔄 再来一次！电已返还"
    elseif s.type == "coin" then
        state_.coins = state_.coins + s.value
        msg = "金币 +" .. fmt(s.value)
    elseif s.type == "ticket" then
        state_.tickets = math.min(ECO.ticketCap, state_.tickets + s.value)
        msg = "免费票 +" .. s.value
    elseif s.type == "diamond" then
        state_.diamonds = state_.diamonds + s.value
        msg = "钻石 +" .. s.value
    elseif s.type == "fragment" then
        state_.fragments = state_.fragments + s.value
        msg = "员工碎片 +1（碎片暂存，抽卡合成用）"
    end
    local lbl = uiRoot_ and uiRoot_:FindById("wheelResult") --[[@as Label?]]
    if lbl then lbl:SetText(msg) end
    local spin = uiRoot_:FindById("spinBtn") --[[@as Button?]]
    if spin then spin:SetText(state_.energy >= 1 and "再转一次（1 电）" or "电不足 · 等恢复") end
    local el = uiRoot_ and uiRoot_:FindById("wheelEnergy") --[[@as Label?]]
    if el then el:SetText("⚡" .. state_.energy) end
    saveGame()
end

function BuildWheel()
    state_.screen = "wheel"
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 26, 20, 14, 255 },
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 36,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "← 大厅", onClick = function() BuildLobby() end },
                    UI.Label { text = "🎡 幸运转盘", fontSize = 19, fontColor = { 212, 175, 55, 255 } },
                    UI.Label { id = "wheelEnergy", text = "⚡" .. state_.energy, fontSize = 15, fontColor = { 120, 180, 255, 255 } },
                }
            },
            UI.Panel { width = "100%", height = 330, pointerEvents = "none" },
            UI.Panel {
                width = "100%", padding = 20, paddingBottom = 44,
                justifyContent = "center", alignItems = "center", gap = 10,
                children = {
                    UI.Label { id = "wheelResult", text = "消耗 1 电 · 转一次", fontSize = 17, fontColor = { 255, 215, 0, 255 } },
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
-- 12. 手机系统：抽卡 + 员工
-- ============================================================================

function BuildPhone()
    state_.screen = "phone"
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 12, 12, 16, 255 },
        children = {
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 40,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "←", onClick = function() BuildLobby() end },
                    UI.Label { text = "📱 我的手机", fontSize = 18, fontColor = { 220, 220, 230, 255 } },
                    UI.Label { text = "💎" .. state_.diamonds, fontSize = 14, fontColor = { 150, 200, 255, 255 } },
                }
            },
            UI.Panel {
                width = "100%", justifyContent = "center", alignItems = "center", gap = 18,
                children = {
                    UI.Label { text = "应用（v0.4 上线 2 个）", fontSize = 12, fontColor = { 130, 130, 145, 220 } },
                    UI.Panel { gap = 20, children = {
                        UI.Button { text = "🐱\n招财猫\n抽卡", width = 96, height = 96, fontSize = 15,
                            onClick = function() BuildGacha() end },
                        UI.Button { text = "👷\n员工\n管理", width = 96, height = 96, fontSize = 15,
                            onClick = function() BuildStaff() end },
                    }},
                    UI.Label { text = "直播 / 商城 / 传奇 · 下版本", fontSize = 11, fontColor = { 90, 90, 105, 200 } },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
end

local lastGachaResults_ = nil

function BuildGacha()
    state_.screen = "gacha"
    local resultWidgets = {}
    if lastGachaResults_ then
        for _, e in ipairs(lastGachaResults_) do
            local c = RARITY_COLOR[e.rarity]
            table.insert(resultWidgets, UI.Panel {
                width = 92, height = 120, borderRadius = 10,
                backgroundColor = { 40, 40, 52, 255 },
                borderWidth = 2, borderColor = c,
                justifyContent = "center", alignItems = "center", gap = 2,
                children = {
                    UI.Label { text = e.rarity, fontSize = 15, fontColor = c },
                    UI.Label { text = e.name, fontSize = 12, fontColor = { 230, 230, 235, 255 } },
                    UI.Label { text = e.isNew and "NEW!" or ("碎片+" .. DUP_SHARDS[e.rarity]), fontSize = 10,
                        fontColor = e.isNew and { 130, 255, 150, 255 } or { 160, 160, 170, 220 } },
                }
            })
        end
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 18, 16, 24, 255 },
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 36,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "←", onClick = function() BuildPhone() end },
                    UI.Label { text = "🐱 招财猫 · 抽卡", fontSize = 18, fontColor = { 255, 200, 90, 255 } },
                    UI.Label { text = "💎" .. state_.diamonds, fontSize = 14, fontColor = { 150, 200, 255, 255 } },
                }
            },
            UI.Panel {
                width = "100%", justifyContent = "center", alignItems = "center", gap = 12,
                children = {
                    UI.Label { text = "公示概率：UR 0.50% · SSR 3.70% · SR 27.80% · R 68.00%", fontSize = 11, fontColor = { 170, 170, 185, 220 } },
                    UI.Label { text = "十连必出 SR 及以上 · 重复转碎片", fontSize = 11, fontColor = { 150, 150, 165, 200 } },
                    UI.Panel { gap = 8, flexWrap = "wrap", justifyContent = "center", width = "96%",
                        children = resultWidgets },
                }
            },
            UI.Panel {
                width = "100%", padding = 16, paddingBottom = 34,
                justifyContent = "center", gap = 10, alignItems = "center",
                children = {
                    UI.Button {
                        text = "单抽 · 160 钻", width = "70%", variant = "primary",
                        onClick = function() DoGacha(false) end },
                    UI.Button {
                        text = "十连 · 1,600 钻（必出SR+）", width = "70%",
                        onClick = function() DoGacha(true) end },
                }
            },
        }
    }
    UI.SetRoot(uiRoot_)
end

function DoGacha(ten)
    local cost = ten and GACHA_PRICE.ten or GACHA_PRICE.single
    if state_.diamonds < cost then
        ShowToast("钻石不足 · 转盘和广告可获得")
        return
    end
    state_.diamonds = state_.diamonds - cost
    local results = ten and gachaTen() or { pickStaff(pickRarity()) }
    local gainedShards = 0
    for _, e in ipairs(results) do
        if state_.owned[e.id] then
            e.isNew = false
            local n = DUP_SHARDS[e.rarity]
            state_.shards[e.rarity] = (state_.shards[e.rarity] or 0) + n
            gainedShards = gainedShards + n
        else
            e.isNew = true
            state_.owned[e.id] = { id = e.id, rarity = e.rarity, level = 1, deployed = false }
        end
    end
    lastGachaResults_ = results
    saveGame()
    local msg = "抽到 " .. #results .. " 名员工" .. (gainedShards > 0 and (" · 碎片 +" .. gainedShards) or "")
    BuildGacha()
    local lbl = uiRoot_ and uiRoot_:FindById("gachaMsg") --[[@as Label?]]
    if lbl then lbl:SetText(msg) end
end

function BuildStaff()
    state_.screen = "staff"
    local rows = {}
    local deployedCount = 0
    for _, rec in pairs(state_.owned) do
        if rec.deployed then deployedCount = deployedCount + 1 end
    end

    -- 按稀有度排序
    local order = { UR=1, SSR=2, SR=3, R=4 }
    local list = {}
    for _, rec in pairs(state_.owned) do table.insert(list, rec) end
    table.sort(list, function(a, b)
        local oa, ob = order[a.rarity] or 9, order[b.rarity] or 9
        if oa ~= ob then return oa < ob end
        return staffProduction(a) > staffProduction(b)
    end)

    for _, rec in ipairs(list) do
        local cat = STAFF_BY_ID[rec.id]
        if cat then
            local cost = staffUpgradeCost(rec)
            local c = RARITY_COLOR[rec.rarity]
            local deployText = rec.deployed and "下阵" or "上阵"
            table.insert(rows, UI.Panel {
                width = "94%", padding = 10, gap = 8, alignItems = "center",
                backgroundColor = { 34, 32, 44, 245 }, borderRadius = 10,
                children = {
                    UI.Panel { width = 54, alignItems = "center", children = {
                        UI.Label { text = rec.rarity, fontSize = 12, fontColor = c },
                        UI.Label { text = cat.name, fontSize = 13, fontColor = { 235, 235, 240, 255 } },
                    }},
                    UI.Panel { width = 90, gap = 1, children = {
                        UI.Label { text = "Lv." .. rec.level .. " · " .. staffProduction(rec) .. "/秒", fontSize = 12, fontColor = { 200, 200, 210, 255 } },
                        UI.Label { text = cat.desc, fontSize = 9, fontColor = { 150, 150, 165, 220 } },
                    }},
                    UI.Button { text = deployText, fontSize = 12, width = 60,
                        enabled = rec.deployed or deployedCount < 3,
                        onClick = function(self)
                            rec.deployed = not rec.deployed
                            saveGame()
                            BuildStaff()
                        end },
                    UI.Button {
                        text = cost and ("升级 " .. fmt(cost)) or "满级",
                        fontSize = 12, width = 86,
                        enabled = cost ~= nil and state_.coins >= cost,
                        onClick = function()
                            local c2 = staffUpgradeCost(rec)
                            if c2 and state_.coins >= c2 then
                                state_.coins = state_.coins - c2
                                rec.level = rec.level + 1
                                saveGame()
                                BuildStaff()
                            end
                        end },
                }
            })
        end
    end

    if #rows == 0 then
        table.insert(rows, UI.Label { text = "还没有员工 · 去招财猫抽卡吧", fontSize = 14, fontColor = { 160, 160, 175, 230 } })
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 18, 16, 24, 255 },
        children = {
            UI.Panel {
                width = "100%", padding = 12, paddingTop = 36,
                justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "←", onClick = function() BuildPhone() end },
                    UI.Label { text = "👷 员工 · 上阵 " .. deployedCount .. "/3", fontSize = 17, fontColor = { 230, 230, 240, 255 } },
                    UI.Label { text = "产出 " .. totalProduction() .. "/秒", fontSize = 13, fontColor = { 255, 215, 0, 255 } },
                }
            },
            UI.Panel {
                width = "100%", height = "100%", padding = 8, paddingTop = 4,
                gap = 6, alignItems = "center",
                children = rows,
            },
        }
    }
    UI.SetRoot(uiRoot_)
end
