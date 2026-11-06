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
    { id="T5", name="夜光", price=1200,unlock=0, unlockAds=3, color={74,111,165},  tiers={
        {m=0,p=0.7600,v=0},{m=3,p=0.1500,v=2000},{m=5,p=0.0650,v=7000},{m=7,p=0.0230,v=40000},{m=9,p=0.0020,v=300000} } },
    { id="T6", name="霜花", price=5000,unlock=0, unlockStreak=3, color={155,196,221}, tiers={
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

-- ============================================================================
-- 1.5 广告系统（AD_MODE 编译期常量，规范 1.5.2：严禁远程开关）
-- A1 补票 8次 / A2 领奖加份 10次 / A3 离线加份 1次 / A4 转盘加电 6次 / A5 钻石礼包 5次
-- 全局日上限 30 · 最小间隔 30 秒（广告策划案 + src/core/ads.js）
-- ============================================================================

local AD_MODE = "mock"   -- "mock" = 演示广告；广告变现开通后改为 "live" 接 SDK

local AD_PLACEMENTS = {
    A1 = { name="补票",     cap=8,  reward="ticket",  value=20 },
    A2 = { name="领奖加份", cap=10, reward="coin",    value="raw" },
    A3 = { name="离线加份", cap=1,  reward="coin",    value="raw" },
    A4 = { name="转盘加电", cap=6,  reward="energy",  value=10 },
    A5 = { name="钻石礼包", cap=5,  reward="diamond", value=50 },
}
local AD_DAILY_TOTAL = 30
local AD_MIN_INTERVAL = 30

local SYMBOLS = { "福", "禄", "寿", "喜" }
-- 每个符号的专属色，让「找相同」一眼可辨
local SYMBOL_COLOR = {
    ["福"] = { 232, 92, 78, 255 },
    ["禄"] = { 226, 186, 72, 255 },
    ["寿"] = { 168, 144, 232, 255 },
    ["喜"] = { 118, 206, 146, 255 },
}
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

--- 好运十倍（体彩经典玩法）：1 个中奖号码 + 10 个我的号码，号码相同即中其下方奖金；×10 翻十倍
local M10_PRIZES = { 2, 5, 10, 20, 50, 100 }
local function generateM10()
    local winning = math.floor(rng() * 40) + 1
    local r = rng()
    local hitCount = 0
    if r < 0.55 then hitCount = 0
    elseif r < 0.85 then hitCount = 1
    elseif r < 0.97 then hitCount = 2
    else hitCount = 3 end

    local hits = {}
    for i = 1, hitCount do hits[i] = true end
    for i = 10, 2, -1 do
        local j = math.floor(rng() * i) + 1
        hits[i], hits[j] = hits[j], hits[i]
    end

    local entries = {}
    local payout, matchCount, hasTen = 0, 0, false
    for i = 1, 10 do
        local num = math.floor(rng() * 40) + 1
        if hits[i] then
            num = winning
        else
            while num == winning do num = math.floor(rng() * 40) + 1 end
        end
        local prize = M10_PRIZES[math.floor(rng() * #M10_PRIZES) + 1]
        local mult = 1
        if hits[i] and rng() < 0.06 then mult = 10; hasTen = true end
        entries[i] = { num = num, prize = prize, mult = mult, hit = hits[i] == true }
        if num == winning then
            payout = payout + prize * mult
            matchCount = matchCount + 1
        end
    end
    return { kind = "m10", winning = winning, entries = entries, payout = payout,
        matchCount = matchCount, hasTen = hasTen }
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
    return math.floor(base.prod * ((1.12)^(rec.level - 1)))
end

local function staffUpgradeCost(rec)
    if rec.level >= 20 then return nil end
    return math.floor(STAFF_BASE[rec.rarity].upBase * ((ECO.upgradeRatio)^(rec.level - 1)))
end

local function totalProduction()
    local sum, hasUR = 0, false
    for _, rec in pairs(state_.owned) do
        if type(rec) == "table" and rec.deployed then
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
        ads={ day=0, total=0, byPlacement={}, lastTs=0 },
        seenTutorial=false,
    }
end

state_ = defaultState()

local SAVE_FILE = "save.json"

local function todayIndex() return math.floor(os.time() / 86400) end

--- 连续登录天数（T6 解锁条件用）
function updateLoginStreak()
    local today = todayIndex()
    if state_.loginDay == today then return end
    if state_.loginDay == today - 1 then
        state_.loginStreak = (state_.loginStreak or 0) + 1
    else
        state_.loginStreak = 1
    end
    state_.loginDay = today
end

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
    -- 存档迁移：旧版本没有 ads 频控表，补默认值避免 nil 索引崩溃
    if type(d.ads) ~= "table" or type(d.ads.byPlacement) ~= "table" then
        d.ads = { day=todayIndex(), total=0, byPlacement={}, lastTs=0 }
    end
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
-- 3.5 广告频控（三层：全局日上限 / 单位上限 / 最小间隔）
-- ============================================================================

local adCtx_ = nil   -- { placement, rewardFn, remaining, overlay }

function adRollover()
    local today = todayIndex()
    if state_.ads.day ~= today then
        state_.ads = { day=today, total=0, byPlacement={}, lastTs=0 }
    end
end

--- 是否可看某广告位
---@return boolean ok, string reason
function adCanShow(pid)
    adRollover()
    local p = AD_PLACEMENTS[pid]
    if not p then return false, "unknown" end
    if state_.ads.total >= AD_DAILY_TOTAL then return false, "daily" end
    local used = state_.ads.byPlacement[pid] or 0
    if used >= p.cap then return false, "cap" end
    if os.time() - (state_.ads.lastTs or 0) < AD_MIN_INTERVAL then return false, "interval" end
    return true, nil
end

--- 记录一次广告完成
function adRecord(pid)
    adRollover()
    state_.ads.total = state_.ads.total + 1
    state_.ads.byPlacement[pid] = (state_.ads.byPlacement[pid] or 0) + 1
    state_.ads.lastTs = os.time()
    state_.adsWatchedTotal = (state_.adsWatchedTotal or 0) + 1
end

--- 发奖
function adGrant(pid, rawValue)
    local p = AD_PLACEMENTS[pid]
    if not p then return "" end
    if p.reward == "ticket" then
        state_.tickets = math.min(ECO.ticketCap, state_.tickets + p.value)
        return "票 +" .. p.value
    elseif p.reward == "energy" then
        state_.energy = math.min(ECO.energyCap, state_.energy + p.value)
        return "电 +" .. p.value
    elseif p.reward == "diamond" then
        state_.diamonds = state_.diamonds + p.value
        return "钻石 +" .. p.value
    elseif p.reward == "coin" and p.value == "raw" then
        state_.coins = state_.coins + (rawValue or 0)
        return "金币 +" .. fmt(rawValue or 0)
    end
    return ""
end

--- 播放广告（mock：5 秒演示广告；live：待变现开通后接 sdk:ShowRewardVideoAd）
--- rewardFn 在奖励发放后回调（用于刷新界面）
function ShowAd(pid, rewardFn, rawValue)
    local ok, reason = adCanShow(pid)
    if not ok then
        local msg = reason == "daily" and "今日广告次数已用完" or (reason == "cap" and "该广告位今日已达上限" or "操作太频繁 · 稍后再看")
        ShowToast(msg)
        return false
    end
    adCtx_ = { placement = pid, rewardFn = rewardFn, rawValue = rawValue, remaining = 5 }
    adRecord(pid)
    -- 演示广告全屏覆盖
    local overlay = UI.Panel {
        id = "adOverlay",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 8, 8, 12, 252 },
        justifyContent = "center", alignItems = "center", gap = 14,
        children = {
            UI.Label { text = "📺 演示广告", fontSize = 26, fontColor = { 240, 240, 245, 255 } },
            UI.Label { id = "adCountdown", text = "5", fontSize = 52, fontColor = { 255, 215, 0, 255 } },
            UI.Label { text = AD_PLACEMENTS[pid].name .. " · " .. AD_MODE:upper() .. " 模式", fontSize = 13, fontColor = { 160, 160, 175, 220 } },
            UI.Label { text = "正式版此处为真实激励视频", fontSize = 11, fontColor = { 110, 110, 125, 190 } },
        }
    }
    uiRoot_:AddChild(overlay)
    return true
end

--- 每帧推进广告倒计时（在 HandleUpdate 开头调用）
function tickAd(dtMs)
    if not adCtx_ then return end
    adCtx_.remaining = adCtx_.remaining - dtMs / 1000
    local lbl = uiRoot_ and uiRoot_:FindById("adCountdown") --[[@as Label?]]
    if lbl then lbl:SetText(tostring(math.max(1, math.ceil(adCtx_.remaining)))) end
    if adCtx_.remaining <= 0 then
        local msg = adGrant(adCtx_.placement, adCtx_.rawValue)
        local fn = adCtx_.rewardFn
        local pid = adCtx_.placement
        adCtx_ = nil
        local ov = uiRoot_ and uiRoot_:FindById("adOverlay")
        if ov then ov:Hide() end
        if fn then fn() end
        updateHud()
        saveGame()
        ShowToast("🎁 " .. msg)
    end
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
    cols = 3,
    removed = {}, removed2 = {},
    removedCount = 0, total = ECO.gridCols * ECO.gridRows,
    rect = { x=0, y=0, w=252, h=252 },
    rect2 = nil,               -- HOT 附加位
    foil = {},                 -- 每个格子的银色涂层 Widget
    pointerDown = false, lastX = 0, lastY = 0, settled = false,
}

local wheelAnim_ = { spinning=false, angle=0, startAngle=0, targetAngle=0, elapsed=0, result=nil }

-- 三层中奖反馈（GDD 第 11 章）
-- T1 普通奖：金色粒子 60 颗 / T2 大奖(HOT/高倍)：全屏白闪 + 粒子雨 200 颗
local particles_ = {}     -- { x,y,vx,vy,life,maxLife,color,size }
local flashAlpha_ = 0     -- 白闪

local function spawnParticles(cx, cy, n, burst)
    for i = 1, n do
        local a = rng() * math.pi * 2
        local sp = (burst and 180 or 120) * (0.4 + rng() * 0.9)
        local palette = burst and { {255,215,0},{255,120,60},{255,255,200} } or { {255,215,0},{255,180,40} }
        local c = palette[math.floor(rng() * #palette) + 1]
        particles_[#particles_ + 1] = {
            x = cx, y = cy,
            vx = math.cos(a) * sp, vy = math.sin(a) * sp - (burst and 90 or 40),
            life = 1.1 + rng() * 0.7, maxLife = 1.8,
            color = c, size = burst and (3 + rng() * 4) or (2 + rng() * 3),
        }
    end
end

local function updateParticles(dt)
    for i = #particles_, 1, -1 do
        local p = particles_[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(particles_, i)
        else
            p.vy = p.vy + 320 * dt          -- 重力
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
        end
    end
    if flashAlpha_ > 0 then flashAlpha_ = math.max(0, flashAlpha_ - dt * 2.2) end
end

local function drawParticles(nvg)
    for _, p in ipairs(particles_) do
        local alpha = math.min(1, p.life / 0.5) * 255
        nvgBeginPath(nvg)
        nvgRect(nvg, p.x - p.size / 2, p.y - p.size / 2, p.size, p.size)
        nvgFillColor(nvg, nvgRGBA(p.color[1], p.color[2], p.color[3], alpha))
        nvgFill(nvg)
    end
    if flashAlpha_ > 0 then
        nvgBeginPath(nvg)
        nvgRect(nvg, 0, 0, UI.GetWidth(), UI.GetHeight())
        nvgFillColor(nvg, nvgRGBA(255, 255, 245, math.floor(flashAlpha_ * 200)))
        nvgFill(nvg)
    end
end

local screenStack_ = {}      -- 简单返回栈：phone 等

-- ============================================================================
-- 4.5 视觉主题（统一色板 / 组件工厂）
-- ============================================================================

local C = {
    bg      = { 20, 15, 10, 255 },
    card    = { 38, 28, 18, 255 },
    card2   = { 52, 39, 25, 255 },
    gold    = { 212, 175, 55, 255 },
    goldL   = { 246, 226, 158, 255 },
    goldD   = { 128, 99, 28, 255 },
    text    = { 242, 236, 222, 255 },
    dim     = { 166, 146, 112, 235 },
    line    = { 96, 76, 42, 255 },
    green   = { 112, 212, 148, 255 },
    red     = { 228, 84, 70, 255 },
    blue    = { 120, 180, 255, 255 },
    silver  = { 198, 204, 214, 255 },
    silver2 = { 176, 182, 194, 255 },
}

--- 主按钮（金） / 次按钮（深棕） / 幽灵按钮
local function goldBtn(text, onClick, o)
    o = o or {}
    return UI.Button {
        id = o.id, text = text, onClick = onClick,
        width = o.width or "100%", height = o.height or 46,
        fontSize = o.fontSize or 15,
        backgroundColor = o.bg or C.gold,
        textColor = o.fg or { 38, 28, 10, 255 },
        borderRadius = 10, borderWidth = 0,
    }
end

local function darkBtn(text, onClick, o)
    o = o or {}
    return UI.Button {
        text = text, onClick = onClick,
        width = o.width or "100%", height = o.height or 44,
        fontSize = o.fontSize or 14,
        backgroundColor = o.bg or C.card2,
        textColor = o.fg or C.text,
        borderRadius = 10, borderWidth = 1, borderColor = { 110, 88, 48, 255 },
    }
end

--- 统一顶栏：避开引擎顶部的开发水印（paddingTop 62）
local function makeHeader(title, rightText, onBack, rightColor)
    local right
    if rightText then
        right = UI.Label { text = rightText, fontSize = 13, fontColor = rightColor or C.dim }
    else
        right = UI.Panel { width = 44, height = 1 }
    end
    return UI.Panel {
        width = "100%", paddingTop = 62, paddingBottom = 8,
        paddingLeft = 14, paddingRight = 14,
        justifyContent = "space-between", alignItems = "center",
        children = {
            UI.Button {
                text = "‹", width = 44, height = 38, fontSize = 22,
                backgroundColor = { 44, 34, 22, 255 }, textColor = C.goldL,
                borderRadius = 10, onClick = onBack or function() BuildLobby() end,
            },
            UI.Label { text = title, fontSize = 16, fontColor = C.goldL },
            right,
        },
    }
end

-- ============================================================================
-- 5. 生命周期
-- ============================================================================

function Start()
    -- 启动保护：出错时把错误显示出来，避免黑屏闪退无法定位
    local ok, err = xpcall(StartInner, function(e)
        return debug.traceback(tostring(e), 2)
    end)
    if not ok then
        print("=== 启动错误: " .. tostring(err) .. " ===")
        pcall(function()
            UI.Init({})
            local root = UI.Panel {
                width = "100%", height = "100%", backgroundColor = { 60, 10, 10, 255 },
                justifyContent = "center", alignItems = "center", gap = 12, padding = 20,
                children = {
                    UI.Label { text = "启动出错了", fontSize = 20, fontColor = { 255, 120, 120, 255 } },
                    UI.Label { text = tostring(err):sub(1, 300), fontSize = 12, fontColor = { 255, 200, 200, 230 } },
                }
            }
            UI.SetRoot(root)
        end)
    end
end

function StartInner()
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

    -- 全局渲染钩子：每帧 UI 绘制完成后回调（UI.QueueOverlay 会在每帧开头被清空，用不了）
    UI.SetInspectorRenderHook(function(nvg)
        if not nvg then return end
        pcall(function()
            drawParticles(nvg)
            if state_.screen == "wheel" then DrawWheel(nvg) end
        end)
    end)

    local hadSave = loadGame()
    updateLoginStreak()
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
                    UI.Button { text = "📺 看广告 多领一份", width = "70%",
                        onClick = function(self)
                            ShowAd("A3", function()
                                self:SetText("✅ 已多领一份")
                                self:SetDisabled(true)
                                updateHud()
                            end, bill.coins)
                        end },
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
    tickAd(dtMs)

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

    -- 粒子推进
    updateParticles(dtMs / 1000)

    -- 转盘动画推进（实际绘制交给全局渲染钩子，见 StartInner）
    if state_.screen == "wheel" and wheelAnim_.spinning then
        wheelAnim_.elapsed = wheelAnim_.elapsed + dtMs / 1000
        local t = math.min(1, wheelAnim_.elapsed / WHEEL_SPIN_SEC)
        local eased = 1 - ((1 - t)^(4))
        wheelAnim_.angle = wheelAnim_.startAngle + (wheelAnim_.targetAngle - wheelAnim_.startAngle) * eased
        if t >= 1 then wheelAnim_.spinning = false; SettleWheel() end
    end
end

-- ============================================================================
-- 7. 触摸 → 笔刷刮除
-- ============================================================================

local function toLogical(x)
    return x * (UI.GetWidth() / graphics.width)
end

local function updateScratchProgress()
    local ratio = scratch_.removedCount / math.max(1, scratch_.total)
    local pct = math.floor(ratio * 100)
    if uiRoot_ then
        local lbl = uiRoot_:FindById("scratchPct") --[[@as Label?]]
        if lbl then
            lbl:SetText(string.format("已刮 %d%% · 刮到 %d%% 自动揭晓", pct, math.floor(ECO.revealThreshold * 100)))
        end
        local bar = uiRoot_:FindById("scratchBar")
        if bar then
            bar:SetWidth(math.floor((scratch_.barW or 240) * math.min(100, pct) / 100))
        end
    end
end

local function scratchRectAt(lx, ly, r, removed, total)
    local cols = scratch_.cols or 3
    local rows = scratch_.rows or cols
    local cellW, cellH = r.w / cols, r.h / rows
    local minC = math.max(0, math.floor((lx - ECO.brushRadius - r.x) / cellW))
    local maxC = math.min(cols - 1, math.floor((lx + ECO.brushRadius - r.x) / cellW))
    local minR = math.max(0, math.floor((ly - ECO.brushRadius - r.y) / cellH))
    local maxR = math.min(rows - 1, math.floor((ly + ECO.brushRadius - r.y) / cellH))
    local br2 = ECO.brushRadius * ECO.brushRadius
    local changed = false
    for row = minR, maxR do
        for col = minC, maxC do
            local key = row * cols + col
            if not removed[key] then
                local cx = r.x + (col + 0.5) * cellW
                local cy = r.y + (row + 0.5) * cellH
                local dx, dy = cx - lx, cy - ly
                if dx * dx + dy * dy <= br2 then
                    removed[key] = true
                    scratch_.removedCount = scratch_.removedCount + 1
                    local f = scratch_.foil and scratch_.foil[key + 1]
                    if f then f:Hide() end
                    changed = true
                end
            end
        end
    end
    return changed
end

local function scratchAt(lx, ly)
    local changed = scratchRectAt(lx, ly, scratch_.rect, scratch_.removed, scratch_.total)
    if changed then
        updateScratchProgress()
        local ratio = scratch_.removedCount / math.max(1, scratch_.total)
        if ratio >= ECO.revealThreshold then RevealAll() end
    end
end

function HandleTouchBegin(eventType, eventData)
    if adCtx_ then return end
    if state_.screen ~= "scratch" or scratch_.settled then return end
    local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
    scratch_.pointerDown = true
    scratch_.lastX, scratch_.lastY = lx, ly
    scratchAt(lx, ly)
end

function HandleTouchMove(eventType, eventData)
    if adCtx_ then return end
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
    local cy = math.floor(UI.GetHeight() * 0.325)
    local R = math.min(148, UI.GetWidth() * 0.40)
    local angle = wheelAnim_.angle or 0
    local n = #WHEEL
    local seg = 360 / n

    -- 外圈光晕
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, R + 16)
    nvgFillColor(nvg, nvgRGBA(120, 88, 28, 90))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, R + 11)
    nvgFillColor(nvg, nvgRGBA(212, 175, 55, 255))
    nvgFill(nvg)

    for i, s in ipairs(WHEEL) do
        local a0 = math.rad(angle + (i - 1) * seg - 90)
        local a1 = math.rad(angle + i * seg - 90)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgArc(nvg, cx, cy, R, a0, a1, 1)
        nvgClosePath(nvg)
        nvgFillColor(nvg, nvgRGBA(s.color[1], s.color[2], s.color[3], 255))
        nvgFill(nvg)
        -- 扇区描边
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgLineTo(nvg, cx + math.cos(a0) * R, cy + math.sin(a0) * R)
        nvgStrokeColor(nvg, nvgRGBA(255, 245, 210, 60))
        nvgStrokeWidth(nvg, 1)
        nvgStroke(nvg)

        local mid = math.rad(angle + (i - 0.5) * seg - 90)
        local tx = cx + math.cos(mid) * R * 0.66
        local ty = cy + math.sin(mid) * R * 0.66
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 13)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 245))
        nvgTextAlign(nvg, 18)
        nvgText(nvg, tx, ty, s.short)
    end

    -- 中奖扇区高亮
    if not wheelAnim_.spinning and wheelAnim_.highlight then
        local i = wheelAnim_.highlight
        local a0 = math.rad(angle + (i - 1) * seg - 90)
        local a1 = math.rad(angle + i * seg - 90)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgArc(nvg, cx, cy, R - 1, a0, a1, 1)
        nvgClosePath(nvg)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 45))
        nvgFill(nvg)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cx, cy)
        nvgArc(nvg, cx, cy, R - 1, a0, a1, 1)
        nvgClosePath(nvg)
        nvgStrokeColor(nvg, nvgRGBA(255, 240, 190, 220))
        nvgStrokeWidth(nvg, 2)
        nvgStroke(nvg)
    end

    -- 内圈
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, R * 0.32)
    nvgStrokeColor(nvg, nvgRGBA(255, 240, 200, 70))
    nvgStrokeWidth(nvg, 1)
    nvgStroke(nvg)

    -- 轴心
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 34)
    nvgFillColor(nvg, nvgRGBA(26, 20, 14, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, 30)
    nvgFillColor(nvg, nvgRGBA(212, 175, 55, 255))
    nvgFill(nvg)
    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, 15)
    nvgFillColor(nvg, nvgRGBA(50, 36, 12, 255))
    nvgTextAlign(nvg, 2 + 16)
    nvgText(nvg, cx, cy + 5, "转")

    -- 顶部指针
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, cx - 14, cy - R - 4)
    nvgLineTo(nvg, cx + 14, cy - R - 4)
    nvgLineTo(nvg, cx, cy - R + 26)
    nvgClosePath(nvg)
    nvgFillColor(nvg, nvgRGBA(255, 235, 160, 255))
    nvgFill(nvg)
end


-- ============================================================================
-- 9. 大厅
-- ============================================================================

local function updateCurrencyBar()
    if not uiRoot_ then return end
    local ids = {
        coinsLabel = "金币 " .. fmt(state_.coins),
        ticketsLabel = "票 " .. state_.tickets .. " · 电 " .. state_.energy,
        energyLabel = "电 " .. state_.energy,
        diamondsLabel = "钻 " .. state_.diamonds,
    }
    for id, text in pairs(ids) do
        local l = uiRoot_:FindById(id) --[[@as Label?]]
        if l then l:SetText(text) end
    end
end

function updateHud()
    updateCurrencyBar()
    if not uiRoot_ then return end
    local stat = uiRoot_:FindById("statLabel") --[[@as Label?]]
    if stat then stat:SetText("今日已刮 " .. state_.totalScratched .. " 张 · 累计中奖 " .. fmt(state_.totalWon)
        .. " 金币 · 员工产出 " .. totalProduction() .. "/秒") end
    local a1 = uiRoot_:FindById("a1Btn") --[[@as Button?]]
    if a1 and state_.ads then
        a1:SetText("没票了？看广告 +20 票（今日 " .. (state_.ads.byPlacement.A1 or 0) .. "/8）")
    end
end

--- 刮卡柜台（选票）
function BuildLobby()
    state_.screen = "lobby"
    saveGame()
    local topPad = math.floor(UI.GetHeight() * 0.105)

    local ticketBtns = {}
    for _, tk in ipairs(TICKETS) do
        local unlocked, lockHint = true, nil
        if state_.totalScratched < (tk.unlock or 0) then
            unlocked = false; lockHint = "刮满 " .. tk.unlock .. " 张"
        elseif tk.unlockAds and (state_.adsWatchedTotal or 0) < tk.unlockAds then
            unlocked = false; lockHint = "看广告 " .. tk.unlockAds .. " 次"
        elseif tk.unlockStreak and (state_.loginStreak or 0) < tk.unlockStreak then
            unlocked = false; lockHint = "登录 " .. tk.unlockStreak .. " 天"
        end
        table.insert(ticketBtns, UI.Button {
            text = unlocked and (tk.name .. "   " .. tk.price .. "币") or ("未解锁 · " .. lockHint),
            width = "48%", height = 52, fontSize = 13,
            backgroundColor = unlocked and { 54, 41, 26, 255 } or { 30, 25, 20, 255 },
            textColor = unlocked and { 240, 220, 160, 255 } or { 122, 110, 90, 255 },
            borderRadius = 10, borderWidth = 1,
            borderColor = unlocked and { 138, 110, 54, 255 } or { 58, 48, 36, 255 },
            disabled = not unlocked,
            onClick = function() StartScratch(tk) end,
        })
    end

    -- 好运十倍（体彩经典玩法）
    local m10Unlocked = true  -- 好运十倍直接开放，作为第二种核心玩法
    table.insert(ticketBtns, UI.Button {
        text = "好运十倍   10币",
        width = "48%", height = 52, fontSize = 13,
        backgroundColor = m10Unlocked and { 62, 30, 26, 255 } or { 30, 25, 20, 255 },
        textColor = m10Unlocked and { 255, 176, 140, 255 } or { 122, 110, 90, 255 },
        borderRadius = 10, borderWidth = 1,
        borderColor = m10Unlocked and { 168, 70, 54, 255 } or { 58, 48, 36, 255 },
        disabled = not m10Unlocked,
        onClick = function() StartM10() end,
    })

    local hotUnlocked = state_.totalScratched >= 30

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        justifyContent = "space-between",
        children = {
            -- 顶栏
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 10,
                paddingLeft = 16, paddingRight = 16,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Panel { gap = 3, children = {
                        UI.Label { text = "好运游戏厅", fontSize = 21, fontColor = C.goldL },
                        UI.Label { text = "刮一张 · 试试今天的手气", fontSize = 11, fontColor = C.dim },
                    }},
                    UI.Panel { alignItems = "flex-end", gap = 4, children = {
                        UI.Label { id = "coinsLabel", text = "金币 " .. fmt(state_.coins), fontSize = 16, fontColor = C.gold },
                        UI.Label { id = "ticketsLabel", text = "票 " .. state_.tickets .. " · 电 " .. state_.energy, fontSize = 11, fontColor = C.green },
                    }},
                },
            },
            -- 主体
            UI.Panel {
                width = "100%", paddingLeft = 16, paddingRight = 16, gap = 10,
                children = {
                    UI.Label { id = "ticketTimer", text = "", fontSize = 11, fontColor = C.dim },
                    UI.Panel {
                        width = "100%", padding = 12, gap = 9,
                        backgroundColor = C.card, borderRadius = 14,
                        borderWidth = 1, borderColor = { 96, 74, 38, 255 },
                        children = {
                            UI.Panel { width = "100%", flexDirection = "row",
                                justifyContent = "space-between", alignItems = "center",
                                children = {
                                    UI.Label { text = "彩票柜台", fontSize = 14, fontColor = C.text },
                                    UI.Label { text = "3 个相同符号即中奖", fontSize = 10, fontColor = C.dim },
                                } },
                            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap",
                                justifyContent = "space-between", gap = 8, children = ticketBtns },
                            UI.Label { text = "有免费票先用免费票 · 没票时按面额用金币购买",
                                fontSize = 10, fontColor = C.dim },
                            UI.Button { id = "a1Btn", text = "没票了？看广告 +20 票（今日 0/8）",
                                width = "100%", height = 38, fontSize = 12,
                                backgroundColor = { 44, 60, 44, 255 }, textColor = { 172, 228, 180, 255 },
                                borderRadius = 9, onClick = function() ShowAd("A1", updateHud) end },
                        },
                    },
                    -- HOT 全收
                    UI.Panel { width = "100%", padding = 14,
                        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                        backgroundColor = { 52, 26, 20, 255 }, borderRadius = 14,
                        borderWidth = 1, borderColor = { 150, 56, 44, 255 },
                        children = {
                            UI.Panel { gap = 4, children = {
                                UI.Label { text = "HOT 全收 · 200 币", fontSize = 15, fontColor = { 255, 152, 134, 255 } },
                                UI.Label { text = hotUnlocked and "刮出 HOT，16 格奖金全收" or "累计刮满 30 张解锁", fontSize = 11, fontColor = { 214, 178, 168, 225 } },
                            }},
                            UI.Button { text = hotUnlocked and "开刮" or "未解锁",
                                width = 84, height = 40, fontSize = 13,
                                backgroundColor = hotUnlocked and { 190, 62, 50, 255 } or { 58, 44, 38, 255 },
                                textColor = { 255, 240, 230, 255 }, borderRadius = 9,
                                disabled = not hotUnlocked, onClick = function() StartHot() end },
                        },
                    },
                    -- 幸运转盘
                    UI.Panel { width = "100%", padding = 14,
                        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                        backgroundColor = { 40, 34, 54, 255 }, borderRadius = 14,
                        borderWidth = 1, borderColor = { 108, 78, 148, 255 },
                        children = {
                            UI.Panel { gap = 4, children = {
                                UI.Label { text = "幸运转盘", fontSize = 15, fontColor = { 226, 192, 255, 255 } },
                                UI.Label { id = "energyTimer", text = "", fontSize = 11, fontColor = { 190, 175, 215, 225 } },
                            }},
                            UI.Button { text = "去转", width = 84, height = 40, fontSize = 13,
                                backgroundColor = { 108, 72, 160, 255 }, textColor = { 250, 242, 255, 255 },
                                borderRadius = 9, onClick = function() BuildWheel() end },
                        },
                    },
                    UI.Label { id = "statLabel", text = "", fontSize = 11, fontColor = { 140, 122, 94, 225 } },
                },
            },
            -- 底栏
            UI.Panel {
                width = "100%", paddingLeft = 16, paddingRight = 16, paddingTop = 8, paddingBottom = 28,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center", gap = 10,
                children = {
                    UI.Button { text = "手机 · 抽卡 / 员工", width = "58%", height = 46, fontSize = 14,
                        backgroundColor = { 44, 52, 68, 255 }, textColor = { 200, 220, 255, 255 },
                        borderRadius = 10, onClick = function() BuildPhone() end },
                    UI.Button { text = "玩法", width = "34%", height = 46, fontSize = 14,
                        backgroundColor = C.card2, textColor = C.text, borderRadius = 10,
                        borderWidth = 1, borderColor = { 110, 88, 48, 255 },
                        onClick = function() ShowTutorial() end },
                },
            },
            UI.Panel { position = "absolute", bottom = 6, left = 0, right = 0,
                alignItems = "center", pointerEvents = "none",
                children = { UI.Label { id = "toast", text = "", fontSize = 11, fontColor = { 255, 220, 130, 235 } } } },
        },
    }
    UI.SetRoot(uiRoot_)
    updateHud()
    if not state_.seenTutorial then ShowTutorial() end
end

--- 新手引导 / 玩法说明
function ShowTutorial()
    if not uiRoot_ or uiRoot_:FindById("tutOverlay") then return end
    local ov = UI.Panel {
        id = "tutOverlay",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 215 },
        justifyContent = "center", alignItems = "center", padding = 22,
        children = {
            UI.Panel { width = "100%", maxWidth = 360, padding = 22, gap = 12, alignItems = "stretch",
                backgroundColor = { 40, 30, 19, 255 }, borderRadius = 18,
                borderWidth = 2, borderColor = C.gold,
                children = {
                    UI.Label { text = "怎么玩", fontSize = 22, fontColor = C.goldL, textAlign = "center" },
                    UI.Label { text = "1. 大厅选彩票：有免费票直接刮，没票用金币买", fontSize = 13, fontColor = C.text },
                    UI.Label { text = "2. 刮开涂层，刮到 78% 自动开奖", fontSize = 13, fontColor = C.text },
                    UI.Label { text = "3. 福彩：3 个相同符号中奖；好运十倍：号码相同", fontSize = 13, fontColor = C.text },
                    UI.Label { text = "4. 好运十倍刮出 ×10，该注奖金翻十倍", fontSize = 13, fontColor = C.text },
                    UI.Label { text = "5. 转盘赚票/电/钻石，手机里抽员工挂机产出", fontSize = 13, fontColor = C.text },
                    goldBtn("知道了，开始刮卡", function()
                        state_.seenTutorial = true
                        saveGame()
                        local o = uiRoot_ and uiRoot_:FindById("tutOverlay")
                        if o then o:Hide() end
                    end),
                },
            },
        },
    }
    uiRoot_:AddChild(ov)
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

--- 进场：有免费票优先免费用，没有则用金币购买
local function enterTicket(price, name)
    if state_.tickets >= 1 then
        state_.tickets = state_.tickets - 1
        return true
    end
    if state_.coins >= price then
        state_.coins = state_.coins - price
        saveGame()
        ShowToast("已用 " .. price .. " 金币购买「" .. name .. "」")
        return true
    end
    ShowToast("免费票不足，金币也不够（" .. name .. " 需 " .. price .. " 金币）")
    return false
end

function StartScratch(tk)
    if not enterTicket(tk.price, tk.name) then return end
    scratch_.mode = "lottery"
    scratch_.result = generateTicket(tk)
    scratch_.settled = false
    buildScratchScreen()
end

function StartHot()
    if not enterTicket(HOT.price, "HOT 全收") then return end
    scratch_.mode = "hot"
    scratch_.result = generateHot()
    scratch_.settled = false
    buildScratchScreen()
end

function StartM10()
    if not enterTicket(10, "好运十倍") then return end
    scratch_.mode = "m10"
    scratch_.result = generateM10()
    scratch_.settled = false
    buildScratchScreen()
end

function buildScratchScreen()
    if scratch_.mode == "m10" then buildM10Screen(); return end
    state_.screen = "scratch"
    local cur = scratch_.result
    local W, H = UI.GetWidth(), UI.GetHeight()
    local isLottery = (scratch_.mode == "lottery")
    local cols = isLottery and 3 or 4
    local topPad = math.floor(H * 0.105)

    local maxGridW = isLottery and math.min(W * 0.64, 288) or math.min(W * 0.76, 330)
    local gap = 6
    local cell = math.floor((maxGridW - gap * (cols - 1)) / cols)
    local gridW = cell * cols + gap * (cols - 1)
    local gridH = gridW
    local cardW = gridW + 32
    local cardH = gridH + 128
    local cardX = math.floor((W - cardW) / 2)
    local cardY = math.floor(H * 0.185)
    local gx = cardX + 16
    local gy = cardY + 104

    scratch_.cols = cols
    scratch_.barW = gridW
    scratch_.rect = { x = gx, y = gy, w = gridW, h = gridH }
    scratch_.rect2 = nil
    scratch_.total = cols * cols
    scratch_.removed = {}
    scratch_.removed2 = {}
    scratch_.removedCount = 0
    scratch_.foil = {}

    local winColor = isLottery and (SYMBOL_COLOR[cur.winning] or C.goldL) or C.gold

    local cellWidgets, foilWidgets = {}, {}
    for i = 1, cols * cols do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local x = gx + col * (cell + gap)
        local y = gy + row * (cell + gap)
        local text, color, isWin
        if isLottery then
            text = cur.cells[i]
            isWin = (text == cur.winning)
            color = SYMBOL_COLOR[text] or C.text
        else
            text = tostring(cur.cells[i])
            isWin = cur.dollar[i] == true
            color = isWin and C.gold or { 214, 202, 180, 255 }
        end

        table.insert(cellWidgets, UI.Panel {
            position = "absolute", left = x, top = y, width = cell, height = cell,
            backgroundColor = isWin and { 62, 46, 18, 255 } or { 30, 24, 16, 255 },
            borderRadius = 8, borderWidth = 1,
            borderColor = isWin and { 140, 110, 44, 255 } or { 74, 60, 36, 255 },
            justifyContent = "center", alignItems = "center", pointerEvents = "none",
            children = {
                UI.Label {
                    text = text,
                    fontSize = isLottery and math.floor(cell * 0.46) or math.floor(cell * 0.28),
                    fontColor = color,
                },
            },
        })
        table.insert(foilWidgets, UI.Panel {
            position = "absolute", left = x, top = y, width = cell, height = cell,
            backgroundColor = (row + col) % 2 == 0 and C.silver or C.silver2,
            borderRadius = 8, justifyContent = "center", alignItems = "center",
            pointerEvents = "none",
            children = { UI.Label { text = "刮", fontSize = math.floor(cell * 0.2), fontColor = { 118, 124, 136, 255 } } },
        })
        scratch_.foil[i] = foilWidgets[#foilWidgets]
    end

    local rewardRow
    if isLottery then
        local parts = {}
        for _, t in ipairs(cur.ticket.tiers) do
            if t.m > 0 then table.insert(parts, t.m .. "个 = " .. fmt(t.v) .. "币") end
        end
        rewardRow = table.concat(parts, "   ")
    else
        rewardRow = "HOT = 16 格全收   ·   $$ 格 = 单独奖金"
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        children = {
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 6,
                paddingLeft = 14, paddingRight = 14,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "‹", width = 42, height = 38, fontSize = 22,
                        backgroundColor = { 44, 34, 22, 255 }, textColor = C.goldL, borderRadius = 10,
                        onClick = function() BuildLobby() end },
                    UI.Label { text = isLottery and (cur.ticket.name .. " · " .. cur.ticket.price .. " 币") or "HOT 全收 · 200 币",
                        fontSize = 16, fontColor = C.goldL },
                    UI.Label { text = "票 " .. state_.tickets, fontSize = 12, fontColor = C.green },
                },
            },
            -- 卡片底
            UI.Panel {
                position = "absolute", left = cardX, top = cardY, width = cardW, height = cardH,
                backgroundColor = { 44, 33, 20, 255 }, borderRadius = 16,
                borderWidth = 2, borderColor = C.goldD, pointerEvents = "none",
            },
            -- 卡头：有效符号
            UI.Panel {
                position = "absolute", left = cardX + 16, top = cardY + 14,
                width = cardW - 32, height = 74,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                pointerEvents = "none",
                children = {
                    UI.Panel { gap = 3, children = {
                        UI.Label { text = "本张有效符号", fontSize = 11, fontColor = C.dim },
                        UI.Label { text = isLottery and ("找出 3 个「" .. cur.winning .. "」") or "刮出 HOT，16 格全收",
                            fontSize = 15, fontColor = C.text },
                    }},
                    UI.Panel { width = 58, height = 58, borderRadius = 29,
                        backgroundColor = { 28, 21, 13, 255 }, borderWidth = 2,
                        borderColor = { winColor[1], winColor[2], winColor[3], 220 },
                        justifyContent = "center", alignItems = "center",
                        children = { UI.Label { text = isLottery and cur.winning or "奖",
                            fontSize = 30, fontColor = winColor } } },
                },
            },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = cellWidgets },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = foilWidgets },
            -- 进度与奖级
            UI.Panel {
                position = "absolute", left = cardX + 16, top = cardY + cardH + 12, width = cardW - 32, gap = 8,
                alignItems = "center", pointerEvents = "none",
                children = {
                    UI.Label { id = "scratchPct", text = "刮开 0% · 刮到 78% 自动揭晓", fontSize = 11, fontColor = C.dim },
                    UI.Panel { width = "100%", height = 6, backgroundColor = { 38, 30, 20, 255 }, borderRadius = 3,
                        children = { UI.Panel { id = "scratchBar", width = "0%", height = 6,
                            backgroundColor = C.gold, borderRadius = 3 } } },
                    UI.Label { text = rewardRow, fontSize = 10, fontColor = { 150, 132, 100, 235 }, textAlign = "center" },
                },
            },
            UI.Panel { position = "absolute", bottom = 34, left = 16, right = 16,
                children = {
                    UI.Button { text = "懒得刮 · 直接揭晓", width = "100%", height = 46, fontSize = 14,
                        backgroundColor = { 46, 37, 24, 255 }, textColor = C.goldL, borderRadius = 10,
                        borderWidth = 1, borderColor = { 120, 96, 50, 255 },
                        onClick = function() RevealAll() end },
                },
            },
        },
    }
    UI.SetRoot(uiRoot_)
end

--- 好运十倍界面：中奖号码常显 + 10 个我的号码（2×5）
function buildM10Screen()
    state_.screen = "scratch"
    local cur = scratch_.result
    local W, H = UI.GetWidth(), UI.GetHeight()
    local topPad = math.floor(H * 0.105)

    local rows, cols = 5, 2
    local gap = 8
    local gridW = math.min(W * 0.86, 410)
    local cellW = math.floor((gridW - gap) / cols)
    local cellH = math.floor(cellW * 0.56)
    local gridH = rows * cellH + (rows - 1) * gap
    local cardW = gridW + 24
    local cardH = gridH + 116
    local cardX = math.floor((W - cardW) / 2)
    local cardY = math.max(topPad + 54, math.floor(H * 0.16))
    local gx = cardX + 12
    local gy = cardY + 104

    scratch_.cols, scratch_.rows = cols, rows
    scratch_.barW = gridW
    scratch_.rect = { x = gx, y = gy, w = gridW, h = gridH }
    scratch_.rect2 = nil
    scratch_.total = rows * cols
    scratch_.removed, scratch_.removed2 = {}, {}
    scratch_.removedCount = 0
    scratch_.foil = {}

    local cellWidgets, foilWidgets = {}, {}
    for i = 1, rows * cols do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local x = gx + col * (cellW + gap)
        local y = gy + row * (cellH + gap)
        local e = cur.entries[i]
        local hit = (e.num == cur.winning)
        local prizeText = e.prize .. "币" .. (e.mult > 1 and " ×10" or "")

        table.insert(cellWidgets, UI.Panel {
            position = "absolute", left = x, top = y, width = cellW, height = cellH,
            flexDirection = "row", justifyContent = "space-between", alignItems = "center",
            padding = 10, borderRadius = 8, borderWidth = 1,
            backgroundColor = hit and { 62, 46, 18, 255 } or { 30, 24, 16, 255 },
            borderColor = hit and { 150, 116, 46, 255 } or { 74, 60, 36, 255 },
            pointerEvents = "none",
            children = {
                UI.Label { text = tostring(e.num), fontSize = math.floor(cellH * 0.42),
                    fontColor = hit and C.goldL or { 214, 202, 180, 255 } },
                UI.Label { text = prizeText, fontSize = 12,
                    fontColor = e.mult > 1 and { 255, 140, 90, 255 } or C.dim },
            },
        })
        table.insert(foilWidgets, UI.Panel {
            position = "absolute", left = x, top = y, width = cellW, height = cellH,
            backgroundColor = (row + col) % 2 == 0 and C.silver or C.silver2,
            borderRadius = 8, justifyContent = "center", alignItems = "center",
            pointerEvents = "none",
            children = { UI.Label { text = "刮", fontSize = 18, fontColor = { 118, 124, 136, 255 } } },
        })
        scratch_.foil[i] = foilWidgets[#foilWidgets]
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        children = {
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 6,
                paddingLeft = 14, paddingRight = 14,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "‹", width = 42, height = 38, fontSize = 22,
                        backgroundColor = { 44, 34, 22, 255 }, textColor = C.goldL, borderRadius = 10,
                        onClick = function() BuildLobby() end },
                    UI.Label { text = "好运十倍 · 10 币", fontSize = 16, fontColor = C.goldL },
                    UI.Label { text = "票 " .. state_.tickets, fontSize = 12, fontColor = C.green },
                },
            },
            UI.Panel {
                position = "absolute", left = cardX, top = cardY, width = cardW, height = cardH,
                backgroundColor = { 44, 33, 20, 255 }, borderRadius = 16,
                borderWidth = 2, borderColor = C.goldD, pointerEvents = "none",
            },
            -- 中奖号码 + 规则
            UI.Panel {
                position = "absolute", left = cardX + 12, top = cardY + 12,
                width = cardW - 24, height = 80,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                pointerEvents = "none",
                children = {
                    UI.Panel { flexDirection = "row", alignItems = "center", gap = 10, children = {
                        UI.Label { text = "中奖号码", fontSize = 11, fontColor = C.dim },
                        UI.Panel { width = 56, height = 56, borderRadius = 10,
                            backgroundColor = { 28, 21, 13, 255 }, borderWidth = 2, borderColor = C.gold,
                            justifyContent = "center", alignItems = "center",
                            children = { UI.Label { text = tostring(cur.winning), fontSize = 28, fontColor = C.goldL } } },
                    }},
                    UI.Panel { alignItems = "flex-end", gap = 3, children = {
                        UI.Label { text = "号码相同 = 中下方奖金", fontSize = 11, fontColor = C.text },
                        UI.Label { text = "刮出 ×10 = 该注翻十倍", fontSize = 10, fontColor = { 230, 140, 90, 235 } },
                    }},
                },
            },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = cellWidgets },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = foilWidgets },
            UI.Panel {
                position = "absolute", left = cardX + 12, top = cardY + cardH + 12, width = cardW - 24, gap = 8,
                alignItems = "center", pointerEvents = "none",
                children = {
                    UI.Label { id = "scratchPct", text = "刮开 0% · 刮到 78% 自动揭晓", fontSize = 11, fontColor = C.dim },
                    UI.Panel { width = "100%", height = 6, backgroundColor = { 38, 30, 20, 255 }, borderRadius = 3,
                        children = { UI.Panel { id = "scratchBar", width = 0, height = 6,
                            backgroundColor = C.gold, borderRadius = 3 } } },
                },
            },
            UI.Panel { position = "absolute", bottom = 34, left = 16, right = 16,
                children = {
                    UI.Button { text = "懒得刮 · 直接揭晓", width = "100%", height = 46, fontSize = 14,
                        backgroundColor = { 46, 37, 24, 255 }, textColor = C.goldL, borderRadius = 10,
                        borderWidth = 1, borderColor = { 120, 96, 50, 255 },
                        onClick = function() RevealAll() end },
                },
            },
        },
    }
    UI.SetRoot(uiRoot_)
end

function RevealAll()
    if scratch_.settled or state_.screen ~= "scratch" then return end
    scratch_.settled = true
    local n = scratch_.total or 9
    for i = 1, n do
        scratch_.removed[i - 1] = true
        local f = scratch_.foil and scratch_.foil[i]
        if f then f:Hide() end
    end
    scratch_.removedCount = scratch_.total
    updateScratchProgress()
    SettleScratch()
end

function SettleScratch()
    local cur = scratch_.result
    local payout = 0
    local detail

    if scratch_.mode == "lottery" then
        payout = cur.payout
        if payout > 0 then
            detail = "刮出 " .. cur.matchCount .. " 个「" .. cur.winning .. "」"
        else
            detail = "只刮到 " .. cur.matchCount .. " 个「" .. cur.winning .. "」，差一点"
        end
        state_.totalScratched = state_.totalScratched + 1
    elseif scratch_.mode == "m10" then
        payout = cur.payout
        if payout > 0 then
            detail = "命中 " .. cur.matchCount .. " 个号码" .. (cur.hasTen and " · ×10 爆奖！" or "")
        else
            detail = "没有刮出中奖号码「" .. cur.winning .. "」"
        end
        state_.totalScratched = state_.totalScratched + 1
    else
        if cur.isHot then
            for _, v in ipairs(cur.cells) do payout = payout + v end
            detail = "HOT 出现 · 16 格奖金全收"
        else
            for i, v in ipairs(cur.cells) do
                if cur.dollar[i] then payout = payout + v end
            end
            detail = "$$ 格奖金已收集"
        end
        state_.totalScratched = state_.totalScratched + 1
    end

    if payout > 0 then
        state_.coins = state_.coins + payout
        state_.totalWon = state_.totalWon + payout
        local bigHit = (scratch_.mode == "hot" and cur.isHot)
            or (scratch_.mode == "m10" and cur.hasTen)
            or payout >= 2000
        local r = scratch_.rect
        spawnParticles(r.x + r.w / 2, r.y + r.h / 2, bigHit and 220 or 60, bigHit)
        if bigHit then flashAlpha_ = 1.0 end
    end

    local kids = {
        UI.Label { text = payout > 0 and "开奖结果" or "开奖结果", fontSize = 11, fontColor = C.dim },
        UI.Label { text = payout > 0 and ("＋" .. fmt(payout) .. " 金币") or "这张没中",
            fontSize = payout > 0 and 30 or 24,
            fontColor = payout > 0 and C.goldL or { 170, 158, 136, 255 } },
        UI.Label { text = detail, fontSize = 13, fontColor = { 208, 192, 158, 235 } },
    }

    if payout > 0 then
        table.insert(kids, UI.Label { text = "奖金已到账 · 可看广告再领一份", fontSize = 11, fontColor = C.green })
        table.insert(kids, UI.Button {
            id = "doubleBtn",
            text = "看广告 · 再领 " .. fmt(payout) .. " 币",
            width = "100%", height = 46, fontSize = 14,
            backgroundColor = { 62, 92, 58, 255 }, textColor = { 200, 246, 200, 255 },
            borderRadius = 10, borderWidth = 1, borderColor = { 110, 160, 100, 255 },
            onClick = function(self)
                ShowAd("A2", function()
                    self:SetText("已翻倍到账")
                    self:SetDisabled(true)
                    updateHud()
                end, payout)
            end,
        })
        table.insert(kids, darkBtn("收下 · 再来一张", function()
            if scratch_.mode == "lottery" then StartScratch(cur.ticket)
            elseif scratch_.mode == "m10" then StartM10()
            else StartHot() end
        end))
    else
        table.insert(kids, goldBtn("再来一张", function()
            if scratch_.mode == "lottery" then StartScratch(cur.ticket)
            elseif scratch_.mode == "m10" then StartM10()
            else StartHot() end
        end))
    end
    table.insert(kids, UI.Button {
        text = "回大厅", width = "100%", height = 40, fontSize = 13,
        backgroundColor = { 0, 0, 0, 0 }, textColor = C.dim, borderRadius = 8,
        onClick = function() BuildLobby() end,
    })
    table.insert(kids, UI.Label { text = "剩余票 " .. state_.tickets .. " 张",
        fontSize = 10, fontColor = { 130, 116, 92, 220 } })

    local banner = UI.Panel {
        id = "resultBanner",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 205 },
        justifyContent = "center", alignItems = "center", padding = 22,
        children = {
            UI.Panel {
                width = "100%", maxWidth = 340, padding = 22, gap = 10, alignItems = "stretch",
                backgroundColor = payout > 0 and { 52, 40, 18, 255 } or { 38, 33, 27, 255 },
                borderRadius = 18, borderWidth = 2,
                borderColor = payout > 0 and C.gold or { 104, 94, 80, 220 },
                children = kids,
            },
        },
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
    -- 扇区 i 的中心角在 angle + (i-0.5)*seg - 90；指针固定在正上方(-90)
    -- 因此让扇区中心对准指针：angle = -(i-0.5)*seg
    local jitter = (rng() * 2 - 1) * (seg * 0.28)
    local target = -(idx - 0.5) * seg + jitter
    while target < wheelAnim_.angle + WHEEL_EXTRA_TURNS * 360 do target = target + 360 end
    wheelAnim_.startAngle = wheelAnim_.angle
    wheelAnim_.targetAngle = target
    wheelAnim_.elapsed = 0
    wheelAnim_.spinning = true
    wheelAnim_.result = WHEEL[idx]
    wheelAnim_.resultIdx = idx
    wheelAnim_.highlight = nil
    updateHud()
end

function SettleWheel()
    local s = wheelAnim_.result
    if not s then return end
    local msg
    if s.type == "respin" then
        state_.energy = math.min(ECO.energyCap, state_.energy + 1)
        msg = "再来一次 · 电已返还"
    elseif s.type == "coin" then
        state_.coins = state_.coins + s.value
        msg = "+" .. fmt(s.value) .. " 金币"
        if s.value >= 20000 then
            spawnParticles(UI.GetWidth()/2, UI.GetHeight()*0.325, 220, true)
            flashAlpha_ = 1.0
        end
    elseif s.type == "jackpot" then
        state_.coins = state_.coins + s.value
        msg = "头奖 +" .. fmt(s.value) .. " 金币"
        spawnParticles(UI.GetWidth()/2, UI.GetHeight()*0.325, 260, true)
        flashAlpha_ = 1.0
    elseif s.type == "ticket" then
        state_.tickets = math.min(ECO.ticketCap, state_.tickets + s.value)
        msg = "+" .. s.value .. " 张票"
    elseif s.type == "diamond" then
        state_.diamonds = state_.diamonds + s.value
        msg = "+" .. s.value .. " 钻石"
    elseif s.type == "fragment" then
        state_.fragments = state_.fragments + s.value
        msg = "+1 员工碎片"
    end
    wheelAnim_.highlight = wheelAnim_.resultIdx
    local lbl = uiRoot_ and uiRoot_:FindById("wheelResult") --[[@as Label?]]
    if lbl then lbl:SetText(s.name .. " · " .. msg) end
    local spin = uiRoot_:FindById("spinBtn") --[[@as Button?]]
    if spin then spin:SetText(state_.energy >= 1 and "再转一次（1 电）" or "电不足 · 等恢复") end
    local el = uiRoot_ and uiRoot_:FindById("wheelEnergy") --[[@as Label?]]
    if el then el:SetText("电 " .. state_.energy) end
    local a4 = uiRoot_ and uiRoot_:FindById("a4Btn") --[[@as Button?]]
    if a4 and state_.ads then
        a4:SetText("电不够？看广告 +10 电（今日 " .. (state_.ads.byPlacement.A4 or 0) .. "/6）")
    end
    saveGame()
end

function BuildWheel()
    state_.screen = "wheel"
    local topPad = math.floor(UI.GetHeight() * 0.105)
    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        justifyContent = "space-between",
        children = {
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 6,
                paddingLeft = 14, paddingRight = 14,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "‹", width = 42, height = 38, fontSize = 22,
                        backgroundColor = { 44, 34, 22, 255 }, textColor = C.goldL, borderRadius = 10,
                        onClick = function() BuildLobby() end },
                    UI.Label { text = "幸运转盘", fontSize = 17, fontColor = C.goldL },
                    UI.Label { id = "wheelEnergy", text = "电 " .. state_.energy, fontSize = 12, fontColor = C.blue },
                },
            },
            UI.Panel { width = "100%", height = 360, pointerEvents = "none" },
            UI.Panel {
                width = "100%", paddingLeft = 18, paddingRight = 18, paddingBottom = 40,
                alignItems = "center", gap = 10,
                children = {
                    UI.Label { id = "wheelResult", text = "消耗 1 电 · 转一次", fontSize = 16, fontColor = C.goldL },
                    goldBtn(state_.energy >= 1 and "转！（1 电）" or "电不足 · 等恢复", function()
                        if not wheelAnim_.spinning and state_.energy >= 1 then StartWheelSpin() end
                    end, { height = 50, fontSize = 16, id = "spinBtn" }),
                    UI.Button {
                        id = "a4Btn",
                        text = "电不够？看广告 +10 电（今日 0/6）",
                        width = "100%", height = 42, fontSize = 12,
                        backgroundColor = { 46, 42, 60, 255 }, textColor = { 210, 200, 240, 255 },
                        borderRadius = 9, borderWidth = 1, borderColor = { 100, 88, 130, 255 },
                        onClick = function()
                            ShowAd("A4", function()
                                local lbl = uiRoot_ and uiRoot_:FindById("wheelEnergy") --[[@as Label?]]
                                if lbl then lbl:SetText("电 " .. state_.energy) end
                            end)
                        end },
                    UI.Label { text = "1 电 = 1 次 · 每 5 分钟回 1 电 · 转盘结果即时到账",
                        fontSize = 10, fontColor = { 140, 124, 100, 225 }, textAlign = "center" },
                },
            },
        },
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
                width = "100%", padding = 12, paddingTop = math.floor(UI.GetHeight() * 0.105),
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
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
                    UI.Panel { flexDirection = "row", gap = 16, children = {
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
                width = "100%", padding = 12, paddingTop = math.floor(UI.GetHeight() * 0.105),
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
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
                    UI.Panel { flexDirection = "row", gap = 8, flexWrap = "wrap", justifyContent = "center", width = "96%",
                        children = resultWidgets },
                }
            },
            UI.Panel {
                width = "100%", padding = 16, paddingBottom = 34,
                justifyContent = "center", gap = 10, alignItems = "center",
                children = {
                    UI.Button {
                        text = "单抽 · 160 钻", width = "70%", height = 46, fontSize = 15,
                        backgroundColor = { 212, 175, 55, 255 }, textColor = { 38, 28, 10, 255 },
                        borderRadius = 10, onClick = function() DoGacha(false) end },
                    UI.Button {
                        text = "十连 · 1,600 钻（必出 SR 以上）", width = "70%", height = 46, fontSize = 15,
                        backgroundColor = { 54, 41, 26, 255 }, textColor = { 240, 220, 160, 255 },
                        borderRadius = 10, borderWidth = 1, borderColor = { 138, 110, 54, 255 },
                        onClick = function() DoGacha(true) end },
                    UI.Button {
                        id = "a5Btn", text = "钻石不够？看广告 +50 钻（今日 " .. (state_.ads.byPlacement.A5 or 0) .. "/5）",
                        fontSize = 12, width = "70%", height = 40,
                        backgroundColor = { 44, 60, 44, 255 }, textColor = { 172, 228, 180, 255 },
                        borderRadius = 9,
                        onClick = function()
                            ShowAd("A5", function()
                                local d = uiRoot_ and uiRoot_:FindById("diamondsLabel") --[[@as Label?]]
                                if d then d:SetText("💎" .. state_.diamonds) end
                            end)
                        end },
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
                        disabled = not (rec.deployed or deployedCount < 3),
                        onClick = function(self)
                            rec.deployed = not rec.deployed
                            saveGame()
                            BuildStaff()
                        end },
                    UI.Button {
                        text = cost and ("升级 " .. fmt(cost)) or "满级",
                        fontSize = 12, width = 86,
                        disabled = not (cost ~= nil and state_.coins >= cost),
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
                width = "100%", padding = 12, paddingTop = math.floor(UI.GetHeight() * 0.105),
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
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
