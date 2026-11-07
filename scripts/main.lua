-- ============================================================================
-- 好运游戏厅 · v0.9（v2.1 多局票结构）
-- 功能：10 款多局刮刮票（五档面额）+ 幸运转盘 + 手机系统（抽卡/员工）+ 离线收益 + 存档
-- 架构：引擎层(Lua) 只做渲染与输入；结果生成遵循「先抽奖级，再倒填符号」
-- 数值来源：data/tickets.csv / ticket_prizes.csv / wheel.csv / gacha.csv / GDD v1.1
-- ============================================================================

local UI = require("urhox-libs/UI")
local cjson = (pcall(require, "cjson")) and require("cjson") or nil

-- ============================================================================
-- 1. 数值配置
-- ============================================================================

-- ============================================================================
-- 票种表（v2.1 多局结构 · 10 款 · 五档面额）
-- 面额＝真实档位（只印在票面）；票价＝金币（1 元 = 200 币）
-- judge: "symbol" 找目标符号 / "number" 对上幸运号
-- zones: 每个玩法区（区与区兼中兼得）
-- ============================================================================
local TICKET_DEFS = {
    { id="dawn",   name="晨光",  yuan=5,  price=1000,  rtp=1.55, judge="symbol", target="福",
      zones={ {cols=4, rows=2, label="找福 · 4 次"} }, skin="zodiac", unlock=0 },
    { id="rain",   name="雨后",  yuan=10, price=2000,  rtp=1.70, judge="number", lucky=1,
      zones={ {cols=3, rows=4, label="对号 · 12 次"} }, skin="green", unlock=0 },
    { id="dew",    name="露白",  yuan=5,  price=1000,  rtp=1.55, judge="number", lucky=2,
      zones={ {cols=3, rows=3, label="双号对折 · 9 次"} }, skin="ink", unlock=3 },
    { id="fold",   name="对折",  yuan=10, price=2000,  rtp=1.70, judge="number", lucky=2,
      zones={ {cols=5, rows=2, label="双号对折 · 10 次"} }, skin="red", unlock=8 },
    { id="wick",   name="灯芯",  yuan=10, price=2000,  rtp=1.70, judge="symbol", target="喜",
      zones={ {cols=3, rows=4, label="找喜 · 12 次"} }, skin="amber", unlock=14 },
    { id="gild",   name="烫金",  yuan=20, price=4000,  rtp=1.85, judge="symbol", target="禄",
      zones={ {cols=4, rows=3, label="玩法一 · 找禄"}, {cols=4, rows=2, label="玩法二 · 找禄"} },
      skin="crimson", unlock=22 },
    { id="emboss", name="压纹",  yuan=20, price=4000,  rtp=1.85, judge="symbol", target="寿",
      zones={ {cols=4, rows=3, label="玩法一 · 找寿"}, {cols=4, rows=2, label="玩法二 · 找寿"} },
      skin="wedding", unlock=34 },
    { id="scroll", name="长卷",  yuan=30, price=6000,  rtp=2.10, judge="number", lucky=2,
      zones={ {cols=4, rows=4, label="玩法一 · 对号"}, {cols=4, rows=3, label="玩法二 · 对号"} },
      skin="dunhuang", unlock=48 },
    { id="glow",   name="夜光",  yuan=30, price=6000,  rtp=2.10, judge="symbol", target="福",
      zones={ {cols=4, rows=4, label="玩法一 · 找福"}, {cols=4, rows=3, label="玩法二 · 找福"} },
      skin="noir", unlock=64 },
    { id="frost",  name="霜花",  yuan=50, price=10000, rtp=2.40, judge="number", lucky=3,
      zones={ {cols=5, rows=3, label="玩法一 · 对号"},
              {cols=4, rows=3, label="玩法二 · 对号"},
              {cols=4, rows=2, label="玩法三 · 对号"} }, skin="ice", unlock=84 },
}
local TICKETS = TICKET_DEFS

-- 全局 UI 根（提前声明：ShowAd 等函数在其后定义，需先有 local 绑定）
local uiRoot_ = nil

-- 档位工具（必须在 updateHud / 大厅之前定义，Lua 的 local 作用域从声明处开始）
--- 某档位下已解锁的票
local function tierTickets(tier)
    local list = {}
    for _, tk in ipairs(TICKET_DEFS) do
        if tk.yuan == tier and (state_.totalScratched or 0) >= (tk.unlock or 0) then
            list[#list + 1] = tk
        end
    end
    return list
end

--- 该档位最早解锁时需要的刮卡数（全部未解锁时用）
local function tierUnlockNeed(tier)
    local need = nil
    for _, tk in ipairs(TICKET_DEFS) do
        if tk.yuan == tier then
            local u = tk.unlock or 0
            if need == nil or u < need then need = u end
        end
    end
    return need or 0
end

local function tiersList()
    local seen, out = {}, {}
    for _, tk in ipairs(TICKET_DEFS) do
        if not seen[tk.yuan] then
            seen[tk.yuan] = true
            out[#out + 1] = tk.yuan
        end
    end
    table.sort(out)
    return out
end


-- 柜台三选一 / 手气槽（GDD 5.6 / 6.2）
local PEEK_CELLS     = 3     -- 每张候选票购买前揭开几格（真实结果的子集）
local CANDIDATES     = 3     -- 每次给几张候选
local REROLL_COOLDOWN = 30   -- 换一批冷却（秒），且重置手气槽
local LUCK_GAIN      = 4     -- 每刮完一张 +4
local LUCK_CAP       = 40    -- 满 40 出一张运势券
local VOUCHER_MAX    = 2     -- 券上限，满了槽不再累积

-- ============================================================================
-- 0.9 音频（v1.1）：全部 pcall 包裹，任何一步失败静默降级，绝不阻塞游戏
-- 资源位于 assets/audio，运行路径 audio/xxx.wav
-- ============================================================================
local SFX_FILES = {
    tick    = "audio/tick.wav",
    win     = "audio/win.wav",
    bigwin  = "audio/bigwin.wav",
    lose    = "audio/lose.wav",
    click   = "audio/click.wav",
    buy     = "audio/buy.wav",
    wheel   = "audio/wheel.wav",
    voucher = "audio/voucher.wav",
    cash    = "audio/cash.wav",
    scratch = "audio/scratch_loop.wav",
}

local sfxSounds_ = {}
local sfxPools_  = {}   -- name → { src... , i }
local scratchSrc_ = nil
local scratchOn_ = false
local audioOK_ = false
local audioScene_ = nil

function InitAudio()
    local ok, err = pcall(function()
        -- 场景必须由上值持有，否则会被 GC 回收，SoundSource 随之失效
        audioScene_ = Scene()
        local node = audioScene_:CreateChild("Sfx")
        local lst = audioScene_:CreateChild("Listener")
        lst:CreateComponent("SoundListener")
        for name, path in pairs(SFX_FILES) do
            local snd = cache:GetResource("Sound", path)
            if snd then
                sfxSounds_[name] = snd
                local pool = { i = 1 }
                for k = 1, 4 do
                    local src = node:CreateComponent("SoundSource")
                    if src then
                        pcall(function() src.soundType = "Effect" end)
                        pool[#pool + 1] = src
                    end
                end
                if #pool > 0 then sfxPools_[name] = pool end
                if name == "scratch" then pcall(function() snd:SetLooped(true) end) end
            end
        end
        if sfxPools_.scratch and #sfxPools_.scratch > 0 then
            scratchSrc_ = sfxPools_.scratch[1]
        end
        audioOK_ = true
    end)
    if not ok then print("[audio] 初始化失败，静音运行: " .. tostring(err)) end
    return audioOK_
end

--- 播放一次音效（多实例轮转，避免连发被切断）
function SFX(name, gain, pitch)
    if not audioOK_ then return end
    if state_ and state_.sfxOn == false then return end
    local pool, snd = sfxPools_[name], sfxSounds_[name]
    if not pool or not snd then return end
    pcall(function()
        local src = pool[pool.i]
        pool.i = pool.i % #pool + 1
        if not src then return end
        local f = 0
        if pitch and pitch ~= 1 then f = snd:GetFrequency() * pitch end
        src:Play(snd, f, gain or 0.7)
    end)
end

--- 刮擦循环音：按下开、松开停
function ScratchSound(on)
    if not audioOK_ or not scratchSrc_ then return end
    if state_ and state_.sfxOn == false then return end
    pcall(function()
        if on and not scratchOn_ then
            scratchSrc_:Play(sfxSounds_.scratch, 0, 0.42)
            scratchOn_ = true
        elseif not on and scratchOn_ then
            scratchSrc_:Stop()
            scratchOn_ = false
        end
    end)
end


--- 票型：稳 / 平 / 冲（GDD 5.3）。同价、同面额、同 RTP，只改「命中格数 K」与「倍数」的分布形状。
--- 玩家看到的差别只有一条：稳型中奖率高但奖小，冲型中奖率低但一局能很大。
local STYLES = {
    { id="steady", name="稳", desc="常出小奖", kScale=1.28 },
    { id="normal", name="平", desc="中规中矩", kScale=1.0 },
    { id="wild", name="冲", desc="奖大常空", kScale=0.72 },
}

-- K 分布：[面额][票型 1稳/2平/3冲] → 分布（下标 1 = K=0）
-- 生成方式：对 baseline 做指数倾斜 E[K] = baseline × kScale，再配对应倍数池使 E[K]×E[m] ≡ 该档 RTP
local K_DIST = {
    [5] = {   -- RTP 1.5496 / 中奖率随票型 40-81%
        { 0.395638, 0.332689, 0.194107, 0.077566 },  -- steady E[K]=0.9536
        { 0.490000, 0.320000, 0.145000, 0.045000 },  -- normal E[K]=0.7450
        { 0.599919, 0.284963, 0.093918, 0.021200 },  -- wild E[K]=0.5364
    },
    [10] = {   -- RTP 1.7056 / 中奖率随票型 40-81%
        { 0.338030, 0.386905, 0.184622, 0.068321, 0.022122 },  -- steady E[K]=1.0496
        { 0.430000, 0.380000, 0.140000, 0.040000, 0.010000 },  -- normal E[K]=0.8200
        { 0.545701, 0.342946, 0.089851, 0.018256, 0.003246 },  -- wild E[K]=0.5904
    },
    [20] = {   -- RTP 1.8512 / 中奖率随票型 40-81%
        { 0.296405, 0.398912, 0.196293, 0.085858, 0.022532 },  -- steady E[K]=1.1392
        { 0.390000, 0.400000, 0.150000, 0.050000, 0.010000 },  -- normal E[K]=0.8900
        { 0.510452, 0.367212, 0.096586, 0.022582, 0.003168 },  -- wild E[K]=0.6408
    },
    [30] = {   -- RTP 2.1216 / 中奖率随票型 40-81%
        { 0.239806, 0.402155, 0.214483, 0.099746, 0.043810 },  -- steady E[K]=1.3056
        { 0.330000, 0.420000, 0.170000, 0.060000, 0.020000 },  -- normal E[K]=1.0200
        { 0.452766, 0.400515, 0.112675, 0.027640, 0.006404 },  -- wild E[K]=0.7344
    },
    [50] = {   -- RTP 2.3712 / 中奖率随票型 40-81%
        { 0.194005, 0.395639, 0.232145, 0.113574, 0.064637 },  -- steady E[K]=1.4592
        { 0.280000, 0.430000, 0.190000, 0.070000, 0.030000 },  -- normal E[K]=1.1400
        { 0.402900, 0.425445, 0.129260, 0.032745, 0.009650 },  -- wild E[K]=0.8208
    },
}

-- 倍数池：[票型] → { {倍数, 概率} ... }。E[m] = RTP / E[K] 与面额无关，所以只需三套
local MULT_POOLS = {
    { {1, 0.596321}, {1.5, 0.214500}, {2, 0.108510}, {3, 0.048789}, {5, 0.021340}, {10, 0.007712}, {30, 0.002225}, {100, 0.000487}, {300, 0.000097}, {800, 0.000019} },   -- steady E[m]=1.6250
    { {1, 0.550000}, {1.5, 0.220000}, {2, 0.120000}, {3, 0.060000}, {5, 0.030000}, {10, 0.013000}, {30, 0.005000}, {100, 0.001500}, {300, 0.000400}, {800, 0.000100} },   -- normal E[m]=2.0800
    { {1, 0.511798}, {1.5, 0.221248}, {2, 0.127515}, {3, 0.068905}, {5, 0.037993}, {10, 0.018801}, {30, 0.008924}, {100, 0.003371}, {300, 0.001110}, {800, 0.000335} },   -- wild E[m]=2.8892
}

-- 票面皮肤（对齐美术圣经 v2.1；纯代码可画）
local SKIN = {
    zodiac   = { paper={246,238,220,255}, frame={176,64,52,255},  ink={42,32,24,255},  accent={198,52,44,255} },
    green    = { paper={240,236,216,255}, frame={38,92,72,255},   ink={30,44,36,255},  accent={158,64,48,255} },
    ink      = { paper={238,234,220,255}, frame={70,74,66,255},   ink={34,36,32,255},  accent={120,110,80,255} },
    red      = { paper={248,232,216,255}, frame={172,44,40,255},  ink={46,26,20,255},  accent={198,146,52,255} },
    amber    = { paper={244,232,204,255}, frame={150,104,32,255}, ink={44,34,18,255},  accent={196,140,44,255} },
    crimson  = { paper={246,226,206,255}, frame={150,32,32,255},  ink={44,22,18,255},  accent={196,156,58,255} },
    wedding  = { paper={250,228,224,255}, frame={190,58,86,255},  ink={52,24,32,255},  accent={214,140,72,255} },
    dunhuang = { paper={240,224,196,255}, frame={158,90,44,255},  ink={48,34,22,255},  accent={64,104,132,255} },
    noir     = { paper={224,222,220,255}, frame={40,38,44,255},   ink={28,26,32,255},  accent={170,140,60,255} },
    ice      = { paper={238,244,250,255}, frame={52,104,142,255}, ink={28,40,52,255},  accent={110,168,204,255} },
}

-- HOT 全收票（GDD 第 4 章）：面额 200，8% 全收 16 格
local HOT = {
    name = "HOT 全收", price = 200,
    amounts = { 20,20,20,20,20,20, 60,60,60,60, 200,200,200, 600,600, 2000 },
    hotChance = 0.08, dollarCells = 3, dollarChance = 0.06, normalChance = 0.03,
}

-- 转盘：金额按 SCALE（当前主力档票价）动态折算，避免后期变成零钱
local WHEEL = {
    { name="金币小", short="", type="coin",     mult=1,  prob=0.3000, color={184,115,51,255} },
    { name="免费票", short="+5 票", type="ticket", value=5, prob=0.1500, color={76,175,80,255} },
    { name="金币中", short="", type="coin",     mult=3,  prob=0.1500, color={192,192,192,255} },
    { name="再来一次", short="再转", type="respin", value=0, prob=0.1500, color={156,39,176,255} },
    { name="钻石",   short="+10 钻", type="diamond", value=10, prob=0.1000, color={33,150,243,255} },
    { name="金币大", short="", type="coin",     mult=10, prob=0.0500, color={255,215,0,255} },
    { name="员工碎片", short="+1 碎片", type="fragment", value=1, prob=0.0800, color={255,152,0,255} },
    { name="大奖",   short="", type="jackpot",  mult=60, prob=0.0200, color={244,67,54,255} },
}

--- 当前缩放基准：已解锁票中的最高票价
local function SCALE()
    local best = 1000
    for _, tk in ipairs(TICKET_DEFS) do
        if (state_.totalScratched or 0) >= (tk.unlock or 0) and tk.price > best then best = tk.price end
    end
    return best
end

--- 扇区实际数值（转盘结算与绘制共用）
local function wheelValue(w)
    if w.mult then return math.floor(w.mult * SCALE()) end
    return w.value or 0
end

--- 扇区显示文案
local function wheelLabel(w)
    if w.mult then
        return "+" .. fmtShort(wheelValue(w))
    end
    return w.short
end

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
    R   = { prod=10,   upBase=2000 },
    SR  = { prod=75,   upBase=16000 },
    SSR = { prod=600,  upBase=120000 },
    UR  = { prod=4000, upBase=800000 },
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
-- v1.1 重构：金币必须稀缺。任何「按秒给钱」的机制一律不进游戏。
local ECO = {
    ticketRecoverSec = 30,  ticketCap = 20,
    energyRecoverSec = 300, energyCap = 30,
    offlineCapHours = 8,
    upgradeRatio = 1.55,
    brushRadius = 30, revealThreshold = 1.0,
    gridCols = 18, gridRows = 18,
    bankruptcyTickets = 3, bankruptcyCoins = 3000, bankruptcyDailyCap = 3,
    -- 打烊散客：离线上限按「店铺等级 × 600 币/小时 × 等级倍率」，最高 8h 约 1.68 万
    offlineBasePerHour = 600,
}

-- 店铺等级（v1.1 金币主出口 · 目标感来源）
-- 每一级都改变玩家看得见的东西：离线收入 / 柜台预揭 / 每日免费票 / 手气速度 / 票价折扣
local SHOP_LEVELS = {
    { lv=1, name="街边小摊", cost=0,       offlineMul=1.0, peek=0, freeTicket=0, luckAdd=0, voucherMax=0, desc="一块木板，两沓票" },
    { lv=2, name="巷口小店", cost=30000,   offlineMul=1.3, peek=0, freeTicket=1, luckAdd=1, voucherMax=0, desc="有了招牌和一盏灯" },
    { lv=3, name="街面门市", cost=120000,  offlineMul=1.7, peek=1, freeTicket=1, luckAdd=1, voucherMax=0, desc="玻璃柜台，多看一眼票面" },
    { lv=4, name="二层店铺", cost=450000,  offlineMul=2.2, peek=1, freeTicket=3, luckAdd=2, voucherMax=0, desc="楼上能坐人，老客有地方待" },
    { lv=5, name="连锁总店", cost=1800000, offlineMul=2.8, peek=2, freeTicket=3, luckAdd=2, voucherMax=1, desc="三家分店，券能多存一张" },
    { lv=6, name="传奇展厅", cost=6000000, offlineMul=3.5, peek=2, freeTicket=5, luckAdd=3, voucherMax=2, desc="整条街都知道这块招牌" },
}

-- 刮刀（v1.1 金币第二出口 · 直接改手感）
-- 半径越大，一次划开越多格；radius 直接覆盖 ECO.brushRadius
local KNIVES = {
    { id="wood",  name="废木片",   cost=0,       radius=26, tint={168,140,96},  desc="边缘毛糙，刮得慢" },
    { id="plastic",name="塑料卡",  cost=20000,   radius=30, tint={150,190,210}, desc="会员卡，比木片顺手" },
    { id="steel", name="钢尺",     cost=120000,  radius=35, tint={196,204,212}, desc="文具店买的，刮得又快又平" },
    { id="gold",  name="鎏金刮刀", cost=600000,  radius=40, tint={240,198,96},  desc="刮痕带金边，手感极顺" },
    { id="jade",  name="玉柄刀",   cost=2500000, radius=46, tint={150,232,196}, desc="刀过之处，箔屑如雪" },
}

--- 当前店铺等级数据
local function shopData()
    local lv = math.max(1, math.min(#SHOP_LEVELS, state_.shopLv or 1))
    return SHOP_LEVELS[lv]
end

--- 当前刮刀数据
local function knifeData()
    for _, k in ipairs(KNIVES) do
        if k.id == (state_.knife or "wood") then return k end
    end
    return KNIVES[1]
end

--- 运势券上限（店铺可扩容）
function voucherMax() return VOUCHER_MAX + (shopData().voucherMax or 0) end

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

local function pickMult(styleIdx)
    local pool = MULT_POOLS[styleIdx] or MULT_POOLS[2]
    local r, acc = rng(), 0
    for _, t in ipairs(pool) do
        acc = acc + t[2]
        if r < acc then return t[1] end
    end
    return 1.0
end

local function pickK(yuan, styleIdx)
    local byStyle = K_DIST[yuan] or K_DIST[10]
    local dist = byStyle[styleIdx] or byStyle[2]
    local r, acc = rng(), 0
    for i, p in ipairs(dist) do
        acc = acc + p
        if r < acc then return i - 1 end
    end
    return 0
end

--- 大数简写：万 / 亿（GDD 14.7）
function fmtShort(n)
    n = math.floor(n)
    if n >= 100000000 then
        local v = n / 100000000
        if v >= 10 then return string.format("%.0f亿", v) end
        return string.format("%.1f亿", v)
    elseif n >= 10000 then
        local v = n / 10000
        if v >= 100 then return string.format("%.0f万", v) end
        return string.format("%.1f万", v)
    end
    return tostring(n)
end

--- 多局票生成：先抽命中格数 K → 每格抽倍数 m → 倒填符号 / 号码
--- EV = E[K] × E[m] ≡ 该档 RTP（三档票型严格相等，见 K_DIST 注释）
--- @param styleIdx number 1=稳 2=平 3=冲
--- @param useVoucher boolean 运势券：保证至少 1 格命中，且该格 m ≥ 2.0
--- @param peekCount number 预揭格数（购买前即揭开，计入已刮进度）
local function generateTicket(tk, styleIdx, useVoucher, peekCount)
    styleIdx = styleIdx or 2
    local total = 0
    for _, z in ipairs(tk.zones) do total = total + z.cols * z.rows end

    local k = pickK(tk.yuan, styleIdx)
    if state_ and (state_.totalScratched or 0) == 0 then k = 2 end   -- 首张票必中（GDD 14.6）
    if useVoucher and k < 1 then k = 1 end
    if k > total then k = total end
    if k > 5 then k = 5 end

    local hitSet = {}
    local placed, guard = 0, 0
    while placed < k and guard < 500 do
        guard = guard + 1
        local i = math.floor(rng() * total) + 1
        if not hitSet[i] then hitSet[i] = true; placed = placed + 1 end
    end

    -- 幸运号（number 判定）
    local lucky = {}
    if tk.judge == "number" then
        for i = 1, (tk.lucky or 1) do
            local v, ok
            repeat
                ok = true
                v = math.floor(rng() * 39) + 2
                for _, x in ipairs(lucky) do if x == v then ok = false end end
            until ok
            lucky[i] = v
        end
    end
    local target = tk.target or "福"

    local cells = {}
    local idx = 1
    for zi, z in ipairs(tk.zones) do
        for c = 1, z.cols * z.rows do
            local isHit = hitSet[idx] == true
            local mult = pickMult(styleIdx)
            local amount = math.floor(tk.price * mult)
            local val
            if tk.judge == "number" then
                if isHit then
                    val = lucky[math.floor(rng() * #lucky) + 1]
                else
                    local bad = true
                    while bad do
                        val = math.floor(rng() * 39) + 2
                        bad = false
                        for _, x in ipairs(lucky) do if x == val then bad = true end end
                    end
                end
            else
                if isHit then
                    val = target
                else
                    val = target
                    while val == target do val = SYMBOLS[math.floor(rng() * #SYMBOLS) + 1] end
                end
            end
            cells[idx] = { zone = zi, val = val, hit = isHit, mult = mult,
                           amount = amount, revealed = false }
            idx = idx + 1
        end
    end

    -- 新手首张票：金额也固定（2 格 × 1 倍 = 2×票价），第一眼体验可预期
    if state_ and (state_.totalScratched or 0) == 0 then
        local cnt = 0
        for _, c in ipairs(cells) do
            if c.hit and cnt < 2 then
                c.mult = 1.0
                c.amount = tk.price
                cnt = cnt + 1
            end
        end
    end

    -- 运势券：保证有一笔「像样的中奖」——命中格里至少一格 m ≥ 2.0
    if useVoucher and k > 0 then
        local hasBig = false
        for _, c in ipairs(cells) do
            if c.hit and c.mult >= 2.0 then hasBig = true; break end
        end
        if not hasBig then
            local hits = {}
            for i, c in ipairs(cells) do if c.hit then hits[#hits + 1] = i end end
            local pick = hits[math.floor(rng() * #hits) + 1]
            local c = cells[pick]
            c.mult = 2.0
            c.amount = math.floor(tk.price * c.mult)
        end
    end

    -- 预揭：随机抽 N 格提前揭开（是真实结果的子集，不改分布，GDD 5.6）
    local peeked = {}
    peekCount = math.min(peekCount or 0, total)
    local guard2 = 0
    while #peeked < peekCount and guard2 < 300 do
        guard2 = guard2 + 1
        local i = math.floor(rng() * total) + 1
        if not cells[i].revealed then
            cells[i].revealed = true
            peeked[#peeked + 1] = i
        end
    end

    local payout, hitCount = 0, 0
    for _, c in ipairs(cells) do
        if c.hit then payout = payout + c.amount; hitCount = hitCount + 1 end
    end

    return { kind = "multi", ticket = tk, styleIdx = styleIdx, cells = cells, lucky = lucky,
             target = target, payout = payout, hitCount = hitCount, total = total,
             zones = tk.zones, peeked = peeked, usedVoucher = useVoucher == true }
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

--- 单名店员的手气贡献
local function staffOneBonus(rec)
    return 1 + math.floor(((rec.level or 1) - 1) / 5)
end

--- 店员手艺（v1.1）：店员不再产币，改为提升手气获取
--- 每名已部署店员每张票额外 +1 手气；每 5 级再 +1；大橘 UR 全局 ×1.5
local function staffLuckBonus()
    local n, hasUR = 0, false
    for _, rec in pairs(state_.owned) do
        if type(rec) == "table" and rec.deployed then
            n = n + staffOneBonus(rec)
            if rec.id == "ur_daju" then hasUR = true end
        end
    end
    if hasUR then n = math.floor(n * 1.5) end
    return n
end

--- 兼容旧调用：产出恒为 0（v1.1 起游戏里不存在「按秒给钱」）
local function totalProduction() return 0 end

-- ============================================================================
-- 3. 状态 + 存档
-- ============================================================================

function defaultState()
    return {
        coins=3000, diamonds=60, tickets=3, energy=30, fragments=0,
        ticketRemainMs=0, energyRemainMs=0,
        totalScratched=0, totalWon=0, spinsToday=0,
        bankruptcyDay=0, bankruptcyCount=0,
        owned={},       -- staffId → { id, rarity, level, deployed }
        shards={ UR=0,SSR=0,SR=0,R=0 },
        lastSeen=os.time(),
        ads={ day=0, total=0, byPlacement={}, lastTs=0 },
        seenTutorial=false,
        luckGauge=0,         -- 手气槽 0..LUCK_CAP，每刮完一张 +4
        vouchers=0,          -- 运势券 0..VOUCHER_MAX
        counterTier=5,       -- 柜台当前档位（元）
        lastReroll=0,        -- 换一批冷却
        shopLv=1,            -- 店铺等级 1..6（金币主出口）
        knife="wood",        -- 当前刮刀
        ownedKnives={ wood=true },
        freeTicketDay=0,     -- 每日免费票领取日
        sfxOn=true,          -- 音效开关
        ver=23,
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
    -- v2.1 面额重定标：旧存档的金币量级是 1/200，补到能买第一张 5 元票
    if (tonumber(d.ver) or 0) < 21 then
        if d.coins < 5000 then d.coins = 5000 end
        if d.tickets < 20 then d.tickets = 20 end
    end
    -- v2.2 手气槽 / 运势券
    if (tonumber(d.ver) or 0) < 22 then
        if type(d.luckGauge) ~= "number" then d.luckGauge = 0 end
        if type(d.vouchers) ~= "number" then d.vouchers = 0 end
        if type(d.counterTier) ~= "number" then d.counterTier = 5 end
    end
    -- v2.3 经济重构：店铺等级 / 刮刀。老存档的巨额金币留着 —— 正好用来升级店铺
    if type(d.shopLv) ~= "number" then d.shopLv = 1 end
    if type(d.knife) ~= "string" then d.knife = "wood" end
    if type(d.ownedKnives) ~= "table" then d.ownedKnives = { wood=true } end
    if d.ownedKnives.wood ~= true then d.ownedKnives.wood = true end
    if type(d.freeTicketDay) ~= "number" then d.freeTicketDay = 0 end
    if d.sfxOn == nil then d.sfxOn = true end
    d.ver = 23
    state_ = d
    return true
end

--- 离线结算（打烊散客：店铺等级 × 基础 × 倍率，8h 封顶）
--- v1.1：不再是「员工产出 × 秒数」，那条公式会把金币变成废纸
function settleOffline()
    local now = os.time()
    local away = now - (state_.lastSeen or now)
    if away < 300 then return nil end
    local sd = shopData()
    local cappedSec = math.min(away, ECO.offlineCapHours * 3600)
    local perHour = math.floor(ECO.offlineBasePerHour * sd.offlineMul * sd.lv)
    local coins = math.floor(cappedSec / 3600 * perHour)
    if coins <= 0 then return nil end
    state_.coins = state_.coins + coins
    return { coins=coins, away=away, capped = away > ECO.offlineCapHours * 3600,
             prod=perHour, shop=sd }
end

--- 破产兜底（GDD 8.x：金币<5 且 票=0 且 电=0）
function checkBankruptcy()
    local day = math.floor(os.time() / 86400)
    if state_.bankruptcyDay ~= day then
        state_.bankruptcyDay = day
        state_.bankruptcyCount = 0
    end
    if state_.coins >= 1000 or state_.tickets > 0 or state_.energy > 0 then return nil end
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

local nvgCtx_ = nil
local offlineBill_ = nil
local bankBill_ = nil

local scratch_ = {
    mode = "multi",
    result = nil,
    zones = {},            -- { rect={x,y,w,h}, cols, rows }
    cellRects = {},        -- 全局格索引 → {x,y,w,h}
    revealed = {},         -- 全局格索引 → true
    revealedCount = 0,
    total = 0,
    foil = {},             -- 兼容占位
    barW = 240,
    pointerDown = false, lastX = 0, lastY = 0,
    settled = false, settleDelay = 0, lastTouch = 0, hitFlash = 0,
}

-- 飘字（每格命中时的即时反馈）
local floats_ = {}
local function addFloat(x, y, text, color)
    table.insert(floats_, { x = x, y = y, text = text, life = 1.0, color = color or { 255, 226, 140 } })
end
local function updateFloats(dt)
    for i = #floats_, 1, -1 do
        local f = floats_[i]
        f.life = f.life - dt * 1.15
        f.y = f.y - dt * 34
        if f.life <= 0 then table.remove(floats_, i) end
    end
end
local function drawFloats(nvg)
    for _, f in ipairs(floats_) do
        local al = math.floor(250 * math.min(1, f.life))
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 17)
        nvgTextAlign(nvg, 18)
        nvgFillColor(nvg, nvgRGBA(f.color[1], f.color[2], f.color[3], al))
        nvgText(nvg, f.x, f.y, f.text)
    end
end

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
    InitAudio()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("TouchMove", "HandleTouchMove")
    SubscribeToEvent("TouchEnd", "HandleTouchEnd")

    -- 全局渲染钩子：每帧 UI 绘制完成后回调（UI.QueueOverlay 会在每帧开头被清空，用不了）
    UI.SetInspectorRenderHook(function(nvg)
        if not nvg then return end
        pcall(function()
            if state_.screen == "lobby" then DrawLobbyAmbience(nvg) end
            if state_.screen == "scratch" then
                if not scratch_.settled then DrawFoil(nvg) end
                if (scratch_.hitFlash or 0) > 0.01 then
                    nvgBeginPath(nvg)
                    nvgRect(nvg, 0, 0, UI.GetWidth(), UI.GetHeight())
                    nvgFillColor(nvg, nvgRGBA(255, 236, 170, math.floor(46 * scratch_.hitFlash)))
                    nvgFill(nvg)
                end
            end
            drawParticles(nvg)
            drawFloats(nvg)
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
    print("=== 好运游戏厅 v0.9 启动 ===")
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
                    UI.Label { text = "🌙 打烊期间", fontSize = 20, fontColor = { 245,240,230,255 } },
                    UI.Label { text = "散客带走 " .. fmt(bill.coins) .. " 币的票", fontSize = 22, fontColor = { 255,215,0,255 } },
                    UI.Label { text = string.format("%s · 离开 %d 小时 %d 分 · 约 %d 币/小时",
                        bill.shop and bill.shop.name or "小店",
                        math.floor(bill.away/3600), math.floor(bill.away%3600/60),
                        bill.prod or 600), fontSize = 12, fontColor = { 200,185,150,230 } },
                    UI.Label { text = "升级店铺 · 打烊收入更高", fontSize = 10, fontColor = { 168,150,116,225 } },
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

    -- 飘字 / 命中闪光衰减
    updateFloats(dtMs / 1000)
    if (scratch_.hitFlash or 0) > 0 then
        scratch_.hitFlash = math.max(0, scratch_.hitFlash - dtMs / 1000 * 2.2)
    end

    -- 刮卡：刮满后延迟开奖；剩余 <5% 且停手 2 秒 → 扫尾补齐
    if state_.screen == "scratch" then
        if scratch_.settleDelay and scratch_.settleDelay > 0 then
            scratch_.settleDelay = scratch_.settleDelay - dtMs / 1000
            if scratch_.settleDelay <= 0 then SettleScratch() end
        elseif not scratch_.settled and scratch_.total > 0 then
            local ratio = scratch_.revealedCount / scratch_.total
            if ratio >= 0.95 and not scratch_.pointerDown
                and os.clock() - (scratch_.lastTouch or 0) > 2.0 then
                RevealAll()
            end
        end
    end

    -- 转盘动画推进（实际绘制交给全局渲染钩子，见 StartInner）
    if state_.screen == "wheel" and wheelAnim_.spinning then
        wheelAnim_.elapsed = wheelAnim_.elapsed + dtMs / 1000
        local t = math.min(1, wheelAnim_.elapsed / WHEEL_SPIN_SEC)
        local eased = 1 - ((1 - t)^(4))
        wheelAnim_.angle = wheelAnim_.startAngle + (wheelAnim_.targetAngle - wheelAnim_.startAngle) * eased
        -- 指针拨片音：越转越慢
        wheelTickAcc_ = (wheelTickAcc_ or 0) + dtMs
        if wheelTickAcc_ >= 55 + 320 * t then
            wheelTickAcc_ = 0
            SFX("wheel", 0.30, 1.0 + (t > 0.7 and -0.05 or 0))
        end
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
    local ratio = scratch_.revealedCount / math.max(1, scratch_.total)
    local pct = math.floor(ratio * 100)
    if uiRoot_ then
        local lbl = uiRoot_:FindById("scratchPct")
        if lbl then
            if pct >= 100 then
                lbl:SetText("已刮 100% · 正在开奖")
            else
                lbl:SetText(string.format("刮开 %d%% · 全部刮开即开奖", pct))
            end
        end
        local bar = uiRoot_:FindById("scratchBar")
        if bar then bar:SetWidth(math.max(1, math.floor((scratch_.barW or 260) * math.min(100, pct) / 100))) end
        local hint = uiRoot_:FindById("scratchHint")
        if hint then
            if ratio >= 0.95 and pct < 100 then
                hint:SetText("快刮完了 · 松手 2 秒自动补齐")
            else
                hint:SetText("手指划过即可刮开 · 每格都是一次判定")
            end
        end
    end
end

--- 刮开落在 (lx,ly) 下的格子；渐进擦除，擦满才揭示（v1.1 真实感）
local function scratchAt(lx, ly)
    local changed = false
    local radius = (knifeData().radius or ECO.brushRadius)
    local speed = radius / 26      -- 刀越大，单次擦拭越狠
    for i = 1, scratch_.total do
        if not scratch_.revealed[i] then
            local r = scratch_.cellRects[i]
            -- 圆心到矩形最近距离
            local nx = math.max(r.x, math.min(lx, r.x + r.w))
            local ny = math.max(r.y, math.min(ly, r.y + r.h))
            local dx, dy = lx - nx, ly - ny
            if dx * dx + dy * dy <= radius * radius then
                local inside = (lx >= r.x and lx <= r.x + r.w and ly >= r.y and ly <= r.y + r.h)
                local e = scratch_.erase[i] or 0
                local ne = math.min(1, e + (inside and 0.62 or 0.24) * speed)
                scratch_.erase[i] = ne
                changed = true
                if ne >= 1 then
                    scratch_.revealed[i] = true
                    scratch_.revealedCount = scratch_.revealedCount + 1
                    local c = scratch_.result.cells[i]
                    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
                    if c.hit then
                        local big = c.mult >= 10
                        spawnParticles(cx, cy, big and 110 or 24, big)
                        if big then flashAlpha_ = math.max(flashAlpha_ or 0, 0.75) end
                        addFloat(cx, cy - r.h * 0.2, "+" .. fmtShort(c.amount),
                            big and { 255, 226, 120 } or { 255, 210, 130 })
                        scratch_.hitFlash = math.min(1.0, (scratch_.hitFlash or 0) + (big and 0.6 or 0.22))
                        SFX("tick", big and 0.62 or 0.42, 1.0 + (i % 5) * 0.03)
                    else
                        addFloat(cx, cy - r.h * 0.2, "没中", { 150, 140, 124 })
                        SFX("tick", 0.20, 0.90)
                    end
                end
            end
        end
    end
    if changed then
        scratch_.lastTouch = os.clock()
        updateScratchProgress()
        if scratch_.revealedCount >= scratch_.total then RevealAll() end
    end
    return changed
end

function HandleTouchBegin(eventType, eventData)
    if adCtx_ then return end
    local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
    touchStart_ = { x = lx, y = ly, t = os.clock() }
    if state_.screen ~= "scratch" or scratch_.settled then return end
    scratch_.pointerDown = true
    scratch_.lastX, scratch_.lastY = lx, ly
    ScratchSound(true)
    scratchAt(lx, ly)
end

function HandleTouchMove(eventType, eventData)
    if adCtx_ then return end
    if not scratch_.pointerDown or state_.screen ~= "scratch" or scratch_.settled then return end
    local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
    local dx, dy = lx - scratch_.lastX, ly - scratch_.lastY
    local dist = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.floor(dist / ((knifeData().radius or ECO.brushRadius) * 0.5)))
    for i = 1, steps do
        local t = i / steps
        scratchAt(scratch_.lastX + dx * t, scratch_.lastY + dy * t)
    end
    scratch_.lastX, scratch_.lastY = lx, ly
end

function HandleTouchEnd(eventType, eventData)
    scratch_.pointerDown = false
    ScratchSound(false)
    -- 轻点（几乎没移动）→ 按钮点击音
    if touchStart_ then
        local lx, ly = toLogical(eventData:GetInt("X")), toLogical(eventData:GetInt("Y"))
        local dx, dy = lx - touchStart_.x, ly - touchStart_.y
        if dx * dx + dy * dy < 100 and (os.clock() - touchStart_.t) < 0.6 then
            if state_.screen ~= "scratch" or scratch_.settled then SFX("click", 0.5) end
        end
        touchStart_ = nil
    end
end

-- ============================================================================
-- 8. 蒙版 / 转盘 / 氛围渲染
-- ============================================================================

--- 大厅氛围：顶部暖光 + 灯串 + 暗角（画在 UI 之上，只用极低透明度，不挡操作）
function DrawLobbyAmbience(nvg)
    local W, H = UI.GetWidth(), UI.GetHeight()
    local t = os.clock()
    -- 顶部暖光（多层圆模拟径向渐变）
    for k = 1, 7 do
        nvgBeginPath(nvg)
        nvgCircle(nvg, W * 0.5, -60, 70 + k * 52)
        nvgFillColor(nvg, nvgRGBA(255, 198, 118, math.floor(9 - k)))
        nvgFill(nvg)
    end
    -- 灯串：五盏，轻微摆动
    for i = 0, 4 do
        local x = W * (0.10 + i * 0.20)
        local y = 30 + math.sin(t * 1.1 + i * 0.9) * 2.4
        for k = 3, 1, -1 do
            nvgBeginPath(nvg)
            nvgCircle(nvg, x, y, 3.5 * k + 3)
            nvgFillColor(nvg, nvgRGBA(255, 188, 108, 7))
            nvgFill(nvg)
        end
        nvgBeginPath(nvg)
        nvgCircle(nvg, x, y, 3.2)
        nvgFillColor(nvg, nvgRGBA(255, 226, 172, 216))
        nvgFill(nvg)
    end
    -- 左右暗角，压出纵深
    for i = 1, 5 do
        local w = 8 + i * 9
        nvgBeginPath(nvg)
        nvgRect(nvg, 0, 0, w, H)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 9))
        nvgFill(nvg)
        nvgBeginPath(nvg)
        nvgRect(nvg, W - w, 0, w, H)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 9))
        nvgFill(nvg)
    end
end

function DrawFoil(nvg)
    for i = 1, scratch_.total do
        if not scratch_.revealed[i] then
            local r = scratch_.cellRects[i]
            local e = (scratch_.erase and scratch_.erase[i]) or 0
            local a = math.floor(255 * (1 - e * 0.88))
            if a > 6 then
                -- 银灰底
                nvgBeginPath(nvg)
                nvgRoundedRect(nvg, r.x, r.y, r.w, r.h, 3)
                nvgFillColor(nvg, nvgRGBA(176, 182, 194, a))
                nvgFill(nvg)
                -- 上半道高光，模拟拉丝反光
                nvgBeginPath(nvg)
                nvgRoundedRect(nvg, r.x + 1, r.y + 1, r.w - 2, r.h * 0.42, 2)
                nvgFillColor(nvg, nvgRGBA(206, 212, 224, math.floor(a * 0.41)))
                nvgFill(nvg)
                -- 右下暗边
                nvgBeginPath(nvg)
                nvgRect(nvg, r.x + 1, r.y + r.h - 2, r.w - 2, 1)
                nvgFillColor(nvg, nvgRGBA(140, 146, 158, math.floor(a * 0.43)))
                nvgFill(nvg)
                -- 擦到一半：边缘留碎屑，像被磨下来的一层
                if e > 0.1 then
                    for k = 1, 3 do
                        local px = r.x + ((i * 37 + k * 61) % 100) / 100 * r.w
                        local py = r.y + ((i * 53 + k * 29) % 100) / 100 * r.h
                        nvgBeginPath(nvg)
                        nvgCircle(nvg, px, py, 1.2 + (k % 2) * 0.9)
                        nvgFillColor(nvg, nvgRGBA(214, 220, 232, math.floor(a * 0.55)))
                        nvgFill(nvg)
                    end
                end
            end
        end
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
        nvgFontSize(nvg, 11)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 245))
        nvgTextAlign(nvg, 18)
        nvgText(nvg, tx, ty, wheelLabel(s))
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
    if stat then stat:SetText("已刮 " .. state_.totalScratched .. " 张 · " .. shopData().name) end

    local a1 = uiRoot_:FindById("a1Btn") --[[@as Button?]]
    if a1 and state_.ads then
        a1:SetText("补票 +20（" .. (state_.ads.byPlacement.A1 or 0) .. "/8）")
    end

    -- 手气槽
    local g, v = state_.luckGauge or 0, state_.vouchers or 0
    local lt = uiRoot_:FindById("luckText") --[[@as Label?]]
    if lt then
        if v >= voucherMax() then
            lt:SetText("运势券已满 " .. v .. "/" .. voucherMax() .. " · 先用掉一张")
        elseif g >= LUCK_CAP then
            lt:SetText("手气槽已满 · 下一张出券")
        else
            lt:SetText("手气槽 " .. g .. "/" .. LUCK_CAP .. " · 再 "
                .. math.ceil((LUCK_CAP - g) / math.max(1, LUCK_GAIN + (shopData().luckAdd or 0) + staffLuckBonus()))
                .. " 张有券")
        end
    end
    local lv = uiRoot_:FindById("luckVoucher") --[[@as Label?]]
    if lv then lv:SetText("券 " .. v .. "/" .. voucherMax()); lv:SetFontColor(v > 0 and C.goldL or C.dim) end
    local lb = uiRoot_:FindById("luckBar")
    if lb then lb:SetWidth(math.max(4, math.floor((UI.GetWidth() - 48) * g / LUCK_CAP))) end

    -- 金币入口（大厅店铺条 / 店铺页顶栏）
    local lc = uiRoot_:FindById("lobbyCoins") --[[@as Label?]]
    if lc then lc:SetText("金币 " .. fmtShort(state_.coins)) end
    local sc = uiRoot_:FindById("shopCoinLabel") --[[@as Label?]]
    if sc then sc:SetText("金币 " .. fmt(state_.coins)) end

    -- 票架各档状态（解锁数会随刮卡数变化）
    local unlockedN = 0
    for _, tk in ipairs(TICKET_DEFS) do
        if (state_.totalScratched or 0) >= (tk.unlock or 0) then unlockedN = unlockedN + 1 end
    end
    local hint = uiRoot_:FindById("counterHint") --[[@as Label?]]
    if hint then hint:SetText("已解锁 " .. unlockedN .. "/" .. #TICKET_DEFS .. " 款") end
    for _, tier in ipairs(tiersList()) do
        local btn = uiRoot_:FindById("tier_" .. tier) --[[@as Button?]]
        if btn then
            local pool = tierTickets(tier)
            local open = #pool > 0
            local names = {}
            for i = 1, math.min(3, #pool) do names[#names + 1] = pool[i].name end
            if open then
                btn:SetText(tier .. " 元    " .. table.concat(names, " / ")
                    .. (#pool > 3 and (" 等 " .. #pool .. " 款") or ""))
            else
                btn:SetText(tier .. " 元    刮 " .. tierUnlockNeed(tier) .. " 张解锁")
            end
            -- Button 无 SetBackgroundColor，状态靠文本表达；点击时再判定
        end
    end
end

--- 刮卡柜台（选票）
-- ============================================================================
-- 9.5 柜台三选一（GDD 系统 A / 系统 B）
-- ============================================================================

local peekState_ = { tier = 5, cands = {}, rerollAt = 0, voucherUsed = false }

--- 生成 3 张同档候选票：稳 / 平 / 冲 各一张，顺序打乱
--- @param useVoucher boolean 是否用运势券（三张都按券规则生成，选中即消耗）
local function rollCandidates(tier, useVoucher)
    local pool = tierTickets(tier)
    if #pool == 0 then return {} end
    local order = { 1, 2, 3 }
    -- 打乱票型顺序（Fisher-Yates）
    for i = #order, 2, -1 do
        local j = math.floor(rng() * i) + 1
        order[i], order[j] = order[j], order[i]
    end
    local cands = {}
    for _, styleIdx in ipairs(order) do
        local tk = pool[math.floor(rng() * #pool) + 1]
        -- 券只对一张票生效（第一张），其余按普通生成——避免券价值被三选一稀释
        local res = generateTicket(tk, styleIdx, false, PEEK_CELLS + (shopData().peek or 0))
        cands[#cands + 1] = { tk = tk, styleIdx = styleIdx, result = res }
    end
    if useVoucher then
        -- 券：重掷第一张为「有保底」的票
        local tk = pool[math.floor(rng() * #pool) + 1]
        local res = generateTicket(tk, cands[1].styleIdx, true, PEEK_CELLS + (shopData().peek or 0))
        cands[1] = { tk = tk, styleIdx = cands[1].styleIdx, result = res, vouched = true }
    end
    return cands
end

--- 一张候选卡片
local function candidateCard(cand, idx)
    local tk = cand.tk
    local st = STYLES[cand.styleIdx]
    local res = cand.result
    local skin = SKIN[tk.skin] or SKIN.green
    local styleColor = ({ {112,196,148,255}, {212,175,55,255}, {228,120,90,255} })[cand.styleIdx]

    -- 预揭格：小方块，命中 → 金底显示金额；未命中 → 纸底显示值
    local peekCells = {}
    for _, ci in ipairs(res.peeked) do
        local c = res.cells[ci]
        local bg = c.hit and { 212, 175, 55, 255 } or { 236, 228, 208, 255 }
        local fg = c.hit and { 38, 28, 10, 255 } or { 120, 108, 88, 255 }
        peekCells[#peekCells + 1] = UI.Panel {
            width = 46, height = 46, borderRadius = 5,
            backgroundColor = bg, borderWidth = 1,
            borderColor = c.hit and { 255, 236, 168, 255 } or { 176, 162, 136, 255 },
            justifyContent = "center", alignItems = "center", gap = 0,
            children = {
                UI.Label { text = tostring(c.val), fontSize = 13,
                    fontColor = c.hit and { 40, 30, 12, 255 } or { 74, 64, 48, 255 } },
                UI.Label { text = c.hit and fmtShort(c.amount) or "—", fontSize = 9,
                    fontColor = c.hit and { 92, 60, 10, 255 } or { 168, 156, 132, 255 } },
            },
        }
    end

    local peekRow = UI.Panel { flexDirection = "row", gap = 5, children = peekCells }

    return UI.Panel {
        width = "100%", padding = 10, gap = 6,
        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
        backgroundColor = { 42, 34, 24, 255 }, borderRadius = 12,
        borderWidth = 1,
        borderColor = cand.vouched and { 232, 200, 110, 255 } or { 92, 76, 48, 255 },
        children = {
            -- 左：票型徽章 + 票名
            UI.Panel { gap = 3, width = 68, children = {
                UI.Panel { width = 30, height = 22, borderRadius = 4,
                    backgroundColor = styleColor, justifyContent = "center", alignItems = "center",
                    children = { UI.Label { text = st.name, fontSize = 13, fontColor = { 30, 24, 12, 255 } } } },
                UI.Label { text = tk.name, fontSize = 13,
                    fontColor = { skin.paper[1], skin.paper[2], skin.paper[3], 255 } },
                UI.Label { text = tk.yuan .. "元 · " .. res.total .. " 格", fontSize = 9, fontColor = { 176, 160, 130, 255 } },
                UI.Label { text = cand.vouched and "★ 运势券" or st.desc, fontSize = 8,
                    fontColor = cand.vouched and { 240, 206, 130, 255 } or { 150, 136, 108, 235 } },
            }},
            -- 中：预揭
            UI.Panel { gap = 3, alignItems = "center", children = {
                UI.Label { text = "已揭开 " .. #res.peeked .. " 格", fontSize = 9, fontColor = { 150, 134, 104, 255 } },
                peekRow,
            }},
            -- 右：选择
            UI.Button {
                text = "选这张", width = 74, height = 46, fontSize = 13,
                backgroundColor = C.gold, textColor = { 38, 28, 10, 255 }, borderRadius = 9,
                onClick = function() chooseCandidate(cand) end,
            },
        },
    }
end

--- 选中一张候选 → 进入刮卡
function chooseCandidate(cand)
    if not StartTicket(cand.tk, cand.styleIdx, cand.result) then return end
    if cand.vouched and (state_.vouchers or 0) > 0 then
        state_.vouchers = state_.vouchers - 1
    end
    state_.lastStyle = cand.styleIdx
    peekState_.cands = {}   -- 这一批已用过一张，下次进柜台重新生成
    saveGame()
end

--- 柜台页
function BuildCounter(tier)
    tier = tier or state_.counterTier or 5
    state_.counterTier = tier
    state_.screen = "counter"
    if #peekState_.cands == 0 or peekState_.tier ~= tier then
        peekState_.tier = tier
        peekState_.cands = rollCandidates(tier, false)
        peekState_.voucherUsed = false
    end
    local W = UI.GetWidth()
    local topPad = math.floor(UI.GetHeight() * 0.105)
    local pool = tierTickets(tier)
    local price = #pool > 0 and pool[1].price or 0

    local cards = {}
    for i, c in ipairs(peekState_.cands) do
        cards[#cards + 1] = candidateCard(c, i)
    end
    if #cards == 0 then
        cards[1] = UI.Label { text = "该档位还没有可用票种", fontSize = 13, fontColor = C.dim }
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        paddingTop = topPad, paddingLeft = 14, paddingRight = 14, paddingBottom = 18,
        gap = 10,
        children = {
            -- 顶栏
            UI.Panel { width = "100%", flexDirection = "row",
                justifyContent = "space-between", alignItems = "center", children = {
                UI.Button { text = "←", width = 40, height = 34, fontSize = 15,
                    backgroundColor = C.card2, textColor = C.text, borderRadius = 8,
                    onClick = function() peekState_.cands = {}; BuildLobby() end },
                UI.Panel { alignItems = "flex-end", gap = 2, children = {
                    UI.Label { text = tier .. " 元档 · 柜台", fontSize = 16, fontColor = C.goldL },
                    UI.Label { text = "三张票 · 同价 " .. fmt(price) .. " 币 · 各已揭开 " .. (PEEK_CELLS + (shopData().peek or 0)) .. " 格",
                        fontSize = 10, fontColor = C.dim },
                }},
            }},
            -- 手气槽
            luckPanel(),
            -- 候选
            UI.Panel { width = "100%", gap = 8, children = cards },
            UI.Panel { width = "100%", alignItems = "center", children = {
                UI.Label { text = "预揭的格是这张票真实结果的一部分 · 买前就能看到", fontSize = 9,
                    fontColor = { 140, 126, 100, 230 } },
            }},
            -- 底部（贴底，避免中间空一大块）
            UI.Panel { position = "absolute", left = 14, right = 14, bottom = 18,
                flexDirection = "row", gap = 8, alignItems = "center", children = {
                UI.Button { id = "voucherBtn",
                    text = (state_.vouchers or 0) > 0 and ("用运势券重掷（" .. state_.vouchers .. "）") or "运势券 0 张",
                    width = "48%", height = 44, fontSize = 12,
                    backgroundColor = (state_.vouchers or 0) > 0 and { 92, 68, 22, 255 } or { 30, 26, 20, 255 },
                    textColor = (state_.vouchers or 0) > 0 and { 246, 220, 150, 255 } or { 110, 100, 84, 255 },
                    borderRadius = 9, disabled = (state_.vouchers or 0) <= 0,
                    onClick = function() useVoucherReroll() end },
                UI.Button { id = "rerollBtn", text = "换一批", width = "48%", height = 44, fontSize = 12,
                    backgroundColor = C.card2, textColor = C.text, borderRadius = 9,
                    borderWidth = 1, borderColor = { 100, 82, 46, 255 },
                    onClick = function() rerollCandidates() end },
            }},
        },
    }
    UI.SetRoot(uiRoot_)
    updateHud()
end

--- 手气槽条（大厅与柜台共用）
function luckPanel()
    local g = state_.luckGauge or 0
    local v = state_.vouchers or 0
    local txt
    if v >= voucherMax() then
        txt = "运势券已满 " .. v .. "/" .. voucherMax() .. " · 先用掉一张再攒"
    elseif g >= LUCK_CAP then
        txt = "手气槽已满 · 下一张出券"
    else
        txt = "手气槽 " .. g .. "/" .. LUCK_CAP .. " · 再 " .. math.ceil((LUCK_CAP - g) / LUCK_GAIN) .. " 张有券"
    end
    return UI.Panel {
        width = "100%", padding = 10, gap = 5,
        backgroundColor = { 46, 34, 44, 255 }, borderRadius = 10,
        borderWidth = 1, borderColor = { 118, 86, 108, 255 },
        children = {
            UI.Panel { width = "100%", flexDirection = "row",
                justifyContent = "space-between", alignItems = "center", children = {
                UI.Label { id = "luckText", text = txt, fontSize = 11, fontColor = { 236, 206, 236, 255 } },
                UI.Label { id = "luckVoucher", text = "券 " .. v .. "/" .. voucherMax(), fontSize = 11,
                    fontColor = v > 0 and C.goldL or C.dim },
            }},
            UI.Panel { width = "100%", height = 6, backgroundColor = { 28, 22, 28, 255 },
                borderRadius = 3,
                children = { UI.Panel { id = "luckBar",
                    width = math.max(4, math.floor((UI.GetWidth() - 48) * g / LUCK_CAP)), height = 6,
                    backgroundColor = { 214, 150, 220, 255 }, borderRadius = 3 } } },
        },
    }
end

--- 换一批：冷却 15 秒，且清空手气槽（防止无限刷候选，GDD 5.2）
function rerollCandidates()
    local now = os.time()
    local left = (peekState_.rerollAt or 0) - now
    if left > 0 then
        ShowToast("换一批冷却中 · 还要 " .. left .. " 秒")
        return
    end
    peekState_.rerollAt = now + REROLL_COOLDOWN
    state_.luckGauge = 0
    peekState_.cands = rollCandidates(peekState_.tier, false)
    peekState_.voucherUsed = false
    local keep = state_.screen
    BuildCounter(peekState_.tier)
    state_.screen = keep
    ShowToast("已换一批 · 手气槽已清空")
end

--- 用运势券重掷：消耗 1 张，第一张候选保证「至少 1 格命中且该格 ≥2 倍票面」
function useVoucherReroll()
    if (state_.vouchers or 0) <= 0 then
        ShowToast("还没有运势券 · 再刮 " .. math.ceil((LUCK_CAP - (state_.luckGauge or 0)) / LUCK_GAIN) .. " 张")
        return
    end
    state_.vouchers = state_.vouchers - 1
    peekState_.cands = rollCandidates(peekState_.tier, true)
    peekState_.voucherUsed = true
    BuildCounter(peekState_.tier)
    ShowToast("已用 1 张运势券 · 第一张必有像样的中奖")
end

function BuildLobby()
    state_.screen = "lobby"
    saveGame()
    local topPad = math.floor(UI.GetHeight() * 0.105)

    -- 票架：5 个档位，全部可见（看得见买不起 = 最便宜的长线钩子，GDD 5.8）
    local shopNow = shopData()
    local shopNext = SHOP_LEVELS[shopNow.lv + 1]
    local tierBtns = {}
    for _, tier in ipairs(tiersList()) do
        local pool = tierTickets(tier)
        local need = tierUnlockNeed(tier)
        local open = #pool > 0
        local names = {}
        for i = 1, math.min(3, #pool) do names[#names + 1] = pool[i].name end
        local label
        if open then
            label = tier .. " 元    " .. table.concat(names, " / ")
                .. (#pool > 3 and (" 等 " .. #pool .. " 款") or "")
        else
            label = tier .. " 元    刮 " .. need .. " 张解锁"
        end
        tierBtns[#tierBtns + 1] = UI.Button {
            id = "tier_" .. tier,
            text = label,
            width = "100%", height = 42, fontSize = 12,
            backgroundColor = open and { 56, 42, 24, 255 } or { 34, 29, 23, 255 },
            textColor = open and { 246, 232, 196, 255 } or { 126, 114, 96, 255 },
            borderRadius = 9, borderWidth = 1,
            borderColor = open and { 158, 122, 56, 255 } or { 58, 50, 40, 255 },
            onClick = function()
                if open then BuildCounter(tier)
                else ShowToast("再刮 " .. math.max(0, need - (state_.totalScratched or 0)) .. " 张解锁 " .. tier .. " 元档") end
            end,
        }
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        justifyContent = "space-between",
        children = {
            -- 顶栏
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 8,
                paddingLeft = 16, paddingRight = 16,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Panel { gap = 3, children = {
                        UI.Label { text = "好运游戏厅", fontSize = 20, fontColor = C.goldL },
                        UI.Label { id = "statLabel", text = "", fontSize = 10, fontColor = C.dim },
                    }},
                    UI.Panel { alignItems = "flex-end", gap = 4, children = {
                        UI.Label { id = "coinsLabel", text = "金币 " .. fmt(state_.coins), fontSize = 16, fontColor = C.gold },
                        UI.Label { id = "ticketsLabel", text = "票 " .. state_.tickets .. " · 电 " .. state_.energy,
                            fontSize = 11, fontColor = C.green },
                    }},
                },
            },
            -- 主体
            UI.Panel {
                width = "100%", paddingLeft = 14, paddingRight = 14, gap = 8,
                children = {
                    -- 店铺入口（金币出口 · 长期目标）
                    UI.Panel { width="100%", padding=11, flexDirection="row",
                        justifyContent="space-between", alignItems="center",
                        backgroundColor = { 48, 38, 24, 255 }, borderRadius=12,
                        borderWidth=1, borderColor={ 128, 96, 48, 255 },
                        pointerEvents = "auto",
                        onClick = function() BuildShop() end,
                        children = {
                            UI.Panel { gap=2, children = {
                                UI.Label { text="店铺 · " .. shopNow.name, fontSize=13, fontColor=C.goldL },
                                UI.Label { text = shopNext
                                        and ("下一级 " .. shopNext.name .. " · " .. fmtShort(shopNext.cost) .. " 币")
                                        or "已是最亮的招牌", fontSize=9, fontColor=C.dim },
                            }},
                            UI.Panel { alignItems="flex-end", gap=1, children = {
                                UI.Label { id="lobbyCoins", text="金币 " .. fmtShort(state_.coins),
                                    fontSize=12, fontColor=C.gold },
                                UI.Label { text="进去看看 ›", fontSize=10, fontColor={206,174,110,255} },
                            }},
                        }},
                    -- 今日免费票（店铺等级加成 · 每日一次）
                    (function()
                        local freeN = 1 + shopNow.freeTicket
                        local claimed = state_.freeTicketDay == todayIndex()
                        if claimed then
                            return UI.Panel { width="100%", padding=8, flexDirection="row",
                                justifyContent="space-between", alignItems="center",
                                backgroundColor={30,28,24,255}, borderRadius=9,
                                children={
                                    UI.Label { text="今日免费票已领 · 明天再来", fontSize=10, fontColor={120,112,98,235} },
                                    UI.Label { text="店铺 Lv." .. shopNow.lv, fontSize=9, fontColor={132,120,98,225} },
                                }}
                        end
                        return UI.Panel { width="100%", padding=9, flexDirection="row",
                            justifyContent="space-between", alignItems="center",
                            backgroundColor={54,44,22,255}, borderRadius=9,
                            borderWidth=1, borderColor={196,154,68,255},
                            pointerEvents="auto",
                            onClick=function()
                                if state_.freeTicketDay == todayIndex() then return end
                                state_.freeTicketDay = todayIndex()
                                state_.tickets = state_.tickets + freeN
                                saveGame(); BuildLobby()
                                SFX("buy", 0.7)
                                ShowToast("领到今日免费票 ×" .. freeN)
                            end,
                            children={
                                UI.Label { text="今日免费票 ×" .. freeN, fontSize=11, fontColor=C.goldL },
                                UI.Label { text="点这里领 ›", fontSize=10, fontColor={236,200,120,255} },
                            }}
                    end)(),
                    luckPanel(),
                    UI.Label { id = "ticketTimer", text = "", fontSize = 9,
                        fontColor = { 138, 124, 98, 235 } },
                    -- 票架
                    UI.Panel {
                        width = "100%", padding = 10, gap = 6,
                        backgroundColor = C.card, borderRadius = 14,
                        borderWidth = 1, borderColor = { 96, 74, 38, 255 },
                        children = {
                            UI.Panel { width = "100%", flexDirection = "row",
                                justifyContent = "space-between", alignItems = "center", children = {
                                UI.Label { text = "彩票柜台 · 选档位", fontSize = 13, fontColor = C.text },
                                UI.Label { id = "counterHint", text = "", fontSize = 9, fontColor = C.dim },
                            } },
                            UI.Panel { width = "100%", gap = 5, children = tierBtns },
                            UI.Label { text = "进柜台后从 3 张候选里挑 1 张 · 每张已揭开 3 格",
                                fontSize = 9, fontColor = { 146, 130, 102, 230 } },
                        },
                    },
                    -- 幸运转盘
                    UI.Panel { width = "100%", padding = 12,
                        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                        backgroundColor = { 40, 34, 54, 255 }, borderRadius = 12,
                        borderWidth = 1, borderColor = { 108, 78, 148, 255 },
                        children = {
                            UI.Panel { gap = 3, children = {
                                UI.Label { text = "幸运转盘", fontSize = 14, fontColor = { 226, 192, 255, 255 } },
                                UI.Label { id = "energyTimer", text = "", fontSize = 10, fontColor = { 190, 175, 215, 225 } },
                            }},
                            UI.Button { text = "去转", width = 78, height = 38, fontSize = 13,
                                backgroundColor = { 108, 72, 160, 255 }, textColor = { 250, 242, 255, 255 },
                                borderRadius = 9, onClick = function() BuildWheel() end },
                        },
                    },
                },
            },
            -- 底栏
            UI.Panel {
                width = "100%", paddingLeft = 14, paddingRight = 14, paddingTop = 6, paddingBottom = 26,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center", gap = 7,
                children = {
                    UI.Button { text = "手机", width = "27%", height = 44, fontSize = 13,
                        backgroundColor = { 44, 52, 68, 255 }, textColor = { 200, 220, 255, 255 },
                        borderRadius = 10, onClick = function() BuildPhone() end },
                    UI.Button { id = "a1Btn", text = "补票 +20", width = "33%", height = 44, fontSize = 12,
                        backgroundColor = { 44, 60, 44, 255 }, textColor = { 172, 228, 180, 255 },
                        borderRadius = 10, onClick = function() ShowAd("A1", updateHud) end },
                    UI.Button { text = "玩法", width = "27%", height = 44, fontSize = 13,
                        backgroundColor = C.card2, textColor = C.text, borderRadius = 10,
                        borderWidth = 1, borderColor = { 110, 88, 48, 255 },
                        onClick = function() ShowTutorial() end },
                },
            },
            UI.Panel { position = "absolute", bottom = 4, left = 0, right = 0,
                alignItems = "center", pointerEvents = "none",
                children = { UI.Label { id = "toast", text = "", fontSize = 11, fontColor = { 255, 220, 130, 235 } } } },
        },
    }
    UI.SetRoot(uiRoot_)
    updateHud()
    if not state_.seenTutorial then ShowTutorial() end
end

-- ============================================================================
-- 7.5 店铺（金币主出口）
-- ============================================================================

local SHOP_PAL = {
    { wall={96,76,52},  roof={56,42,30},  sign={152,112,58},  lamp={255,196,110} },
    { wall={118,94,62}, roof={68,50,32},  sign={182,138,72},  lamp={255,214,128} },
    { wall={136,106,70},roof={60,56,52},  sign={200,152,80},  lamp={255,222,146} },
    { wall={156,120,80},roof={52,50,54},  sign={218,170,90},  lamp={255,230,168} },
    { wall={178,136,88},roof={46,44,48},  sign={236,190,102}, lamp={255,238,188} },
    { wall={204,158,98},roof={38,36,42},  sign={255,216,122}, lamp={255,248,212} },
}

--- 店铺外观：完全用 Panel 拼，等级越高层数越多、灯越亮
local function shopFacade(sd)
    local pal = SHOP_PAL[sd.lv] or SHOP_PAL[1]
    local kids = {}
    -- 夜空底
    kids[#kids+1] = UI.Panel { position="absolute", left=0, right=0, top=0, bottom=0,
        backgroundColor = { 16, 18, 30, 255 }, borderRadius = 12 }
    -- 远处灯笼（3 级起）
    if sd.lv >= 2 then
        for i = 1, math.min(6, sd.lv + 1) do
            kids[#kids+1] = UI.Panel { position="absolute", top=8 + (i % 2) * 5,
                left = (8 + i * 14) .. "%", width=8, height=8, borderRadius=4,
                backgroundColor = { pal.lamp[1], pal.lamp[2], pal.lamp[3], 190 } }
        end
    end
    -- 地面
    kids[#kids+1] = UI.Panel { position="absolute", left=0, right=0, bottom=0, height=26,
        backgroundColor = { 30, 27, 24, 255 }, borderTopWidth=1, borderColor={64,54,42,255} }
    -- 建筑主体
    local bh = 92 + sd.lv * 8
    kids[#kids+1] = UI.Panel { position="absolute", bottom=26, left="15%", width="70%", height=bh,
        backgroundColor = { pal.wall[1], pal.wall[2], pal.wall[3], 255 },
        borderWidth=1, borderColor={ pal.roof[1], pal.roof[2], pal.roof[3], 255 } }
    -- 屋顶压条
    kids[#kids+1] = UI.Panel { position="absolute", bottom=26+bh-6, left="13%", width="74%", height=10,
        backgroundColor = { pal.roof[1], pal.roof[2], pal.roof[3], 255 }, borderRadius=2 }
    -- 招牌
    kids[#kids+1] = UI.Panel { position="absolute", bottom=26+bh-26, left="24%", width="52%", height=22,
        backgroundColor = { pal.sign[1], pal.sign[2], pal.sign[3], 255 }, borderRadius=4,
        justifyContent="center", alignItems="center",
        children = { UI.Label { text="好 运 杂 货", fontSize=10, fontColor={38,26,12,255} } } }
    -- 二楼窗（4 级起）
    if sd.lv >= 4 then
        kids[#kids+1] = UI.Panel { position="absolute", bottom=26+bh-62, left="28%", width="18%", height=18,
            backgroundColor={ pal.lamp[1], pal.lamp[2], pal.lamp[3], 210 }, borderRadius=2 }
        kids[#kids+1] = UI.Panel { position="absolute", bottom=26+bh-62, left="54%", width="18%", height=18,
            backgroundColor={ pal.lamp[1], pal.lamp[2], pal.lamp[3], 210 }, borderRadius=2 }
    end
    -- 门（暖光）
    kids[#kids+1] = UI.Panel { position="absolute", bottom=26, left="40%", width="20%", height=bh*0.46,
        backgroundColor = { pal.lamp[1], pal.lamp[2], pal.lamp[3], 220 },
        borderTopLeftRadius=20, borderTopRightRadius=20 }
    -- 门口台阶
    kids[#kids+1] = UI.Panel { position="absolute", bottom=26, left="36%", width="28%", height=5,
        backgroundColor={ pal.roof[1], pal.roof[2], pal.roof[3], 255 } }
    -- 雨棚（2 级起，条纹）
    if sd.lv >= 3 then
        for i = 0, 5 do
            kids[#kids+1] = UI.Panel { position="absolute", bottom=26+bh*0.5, left=(17 + i*11) .. "%",
                width="11%", height=9,
                backgroundColor = i % 2 == 0 and { 178, 62, 52, 255 } or { 226, 214, 190, 255 } }
        end
    end
    return UI.Panel { width="100%", height=186, borderRadius=12,
        overflow="hidden", children = kids }
end

function BuildShop()
    state_.screen = "shop"
    local sd = shopData()
    local nxt = SHOP_LEVELS[sd.lv + 1]
    local canLv = nxt and state_.coins >= nxt.cost

    -- 店铺效果一行摘要
    local function effLine(s)
        return "打烊 ×" .. string.format("%.1f", s.offlineMul)
            .. (s.peek > 0 and ("  ·  预揭 +" .. s.peek .. " 格") or "")
            .. (s.freeTicket > 0 and ("  ·  日赠 " .. s.freeTicket .. " 张") or "")
            .. (s.luckAdd > 0 and ("  ·  手气 +" .. s.luckAdd) or "")
            .. (s.voucherMax > 0 and ("  ·  券上限 +" .. s.voucherMax) or "")
    end

    -- 刮刀横排
    local knifeCards = {}
    for _, k in ipairs(KNIVES) do
        local owned = state_.ownedKnives and state_.ownedKnives[k.id]
        local equipped = state_.knife == k.id
        local affordable = state_.coins >= k.cost
        knifeCards[#knifeCards + 1] = UI.Panel {
            width = "18.4%", padding = 5, gap = 3, alignItems = "center",
            backgroundColor = equipped and { 74, 60, 26, 255 } or { 34, 32, 38, 255 },
            borderRadius = 8, borderWidth = equipped and 2 or 1,
            borderColor = equipped and C.gold or (owned and { 90, 84, 76, 255 } or { 58, 54, 50, 255 }),
            children = {
                -- 刀身小图
                UI.Panel { width = 26, height = 30, borderRadius = 3,
                    backgroundColor = { k.tint[1], k.tint[2], k.tint[3], 255 },
                    borderWidth = 1, borderColor = { 20, 20, 20, 160 } },
                UI.Label { text = k.name, fontSize = 8,
                    fontColor = equipped and C.goldL or (owned and { 210, 205, 196, 255 } or { 132, 126, 116, 255 }) },
                UI.Label { text = "R" .. k.radius, fontSize = 7, fontColor = { 130, 126, 118, 230 } },
                UI.Button {
                    text = equipped and "使用中" or (owned and "换上" or fmtShort(k.cost)),
                    width = "100%", height = 22, fontSize = 8,
                    disabled = equipped or (not owned and not affordable),
                    backgroundColor = equipped and { 88, 72, 30, 255 }
                        or (owned and { 56, 78, 60, 255 } or { 52, 46, 38, 255 }),
                    textColor = equipped and C.gold or { 226, 220, 208, 255 },
                    borderRadius = 5,
                    onClick = function()
                        if owned then
                            state_.knife = k.id
                            saveGame()
                            BuildShop()
                            ShowToast("换上了「" .. k.name .. "」· 刮擦半径 " .. k.radius)
                        elseif state_.coins >= k.cost then
                            state_.coins = state_.coins - k.cost
                            state_.ownedKnives[k.id] = true
                            state_.knife = k.id
                            saveGame()
                            BuildShop()
                            ShowToast("买下「" .. k.name .. "」· 刮得更快了")
                        else
                            ShowToast("金币不够 · 还差 " .. fmt(k.cost - state_.coins))
                        end
                    end,
                },
            },
        }
    end

    local kids = {
        -- 顶栏
        UI.Panel { width="100%", paddingTop=math.floor(UI.GetHeight()*0.105), paddingBottom=6,
            paddingLeft=16, paddingRight=16, flexDirection="row",
            justifyContent="space-between", alignItems="center", children = {
            UI.Button { text="←", width=40, height=36, fontSize=16,
                backgroundColor={40,36,32,255}, textColor=C.text, borderRadius=8,
                onClick = function() BuildLobby() end },
            UI.Label { text="店铺", fontSize=17, fontColor=C.text },
            UI.Label { id="shopCoinLabel", text="金币 " .. fmt(state_.coins), fontSize=13, fontColor=C.gold },
        }},
        UI.ScrollView { flexGrow=1, flexBasis=0, scrollY=true, width="100%",
            showScrollbar=true,
            children = { UI.Panel { width="100%", paddingLeft=14, paddingRight=14, paddingBottom=24, gap=10, children = {
                -- 店铺外观 + 名字
                UI.Panel { width="100%", gap=6, children = {
                    shopFacade(sd),
                    UI.Panel { width="100%", flexDirection="row", justifyContent="space-between",
                        alignItems="flex-end", children = {
                        UI.Panel { gap=2, children = {
                            UI.Label { text="Lv." .. sd.lv .. "  " .. sd.name, fontSize=16, fontColor=C.goldL },
                            UI.Label { text=sd.desc, fontSize=10, fontColor=C.dim },
                        }},
                        UI.Label { text=effLine(sd), fontSize=9, fontColor={180,164,130,235} },
                    }},
                }},
                -- 升级卡
                nxt and UI.Panel { width="100%", padding=12, gap=7,
                    backgroundColor = canLv and { 56, 44, 20, 255 } or { 36, 33, 28, 255 },
                    borderRadius=12, borderWidth=1,
                    borderColor = canLv and C.gold or { 76, 68, 56, 255 },
                    children = {
                        UI.Panel { width="100%", flexDirection="row", justifyContent="space-between",
                            alignItems="center", children = {
                            UI.Label { text="升级到「" .. nxt.name .. "」", fontSize=13,
                                fontColor = canLv and C.goldL or C.text },
                            UI.Label { text=fmt(nxt.cost) .. " 币", fontSize=12,
                                fontColor = canLv and C.gold or { 150, 138, 118, 255 } },
                        }},
                        UI.Label { text=nxt.desc, fontSize=10, fontColor={176,162,138,235} },
                        UI.Label { text="升级后：" .. effLine(nxt), fontSize=9.5,
                            fontColor={200,182,142,245} },
                        UI.Button {
                            text = canLv and "升级" or ("还差 " .. fmt(nxt.cost - state_.coins)),
                            width="100%", height=40, fontSize=13,
                            disabled = not canLv,
                            backgroundColor = canLv and { 122, 92, 34, 255 } or { 44, 40, 34, 255 },
                            textColor = canLv and { 255, 236, 186, 255 } or { 118, 110, 98, 255 },
                            borderRadius=9, borderWidth=1,
                            borderColor = canLv and C.gold or { 62, 56, 48, 255 },
                            onClick = function()
                                local cost = nxt.cost
                                if state_.coins >= cost then
                                    state_.coins = state_.coins - cost
                                    state_.shopLv = sd.lv + 1
                                    saveGame()
                                    BuildShop()
                                    ShowToast("店铺升级 · " .. SHOP_LEVELS[sd.lv + 1].name)
                                end
                            end,
                        },
                    }} or UI.Panel { width="100%", padding=12, alignItems="center",
                        backgroundColor={ 56, 44, 20, 255 }, borderRadius=12,
                        borderWidth=1, borderColor=C.gold,
                        children = { UI.Label { text="已经是顶配店铺 · 这条街没有比你更亮的招牌了",
                            fontSize=11, fontColor=C.goldL } } },
                -- 刮刀
                UI.Panel { width="100%", padding=10, gap=8,
                    backgroundColor={32,30,34,255}, borderRadius=12,
                    borderWidth=1, borderColor={70,64,56,255}, children = {
                    UI.Panel { width="100%", flexDirection="row", justifyContent="space-between",
                        alignItems="center", children = {
                        UI.Label { text="刮刀", fontSize=13, fontColor=C.text },
                        UI.Label { text="半径越大 · 一刀划开越多格", fontSize=9, fontColor=C.dim },
                    }},
                    UI.Panel { width="100%", flexDirection="row", justifyContent="space-between",
                        children = knifeCards },
                }},
                UI.Label { text="金币的用处只有两个：升级店铺、换更好的刮刀。都花完，才叫本事。",
                    fontSize=9, fontColor={132,124,110,225}, textAlign="center" },
                }}}},
    }

    uiRoot_ = UI.Panel { width="100%", height="100%", backgroundColor=C.bg, children = kids }
    UI.SetRoot(uiRoot_)
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
                    UI.Label { text = "1. 大厅挑档位（5-50 元），进柜台看 3 张候选票", fontSize = 12, fontColor = C.text },
                    UI.Label { text = "2. 每张票已提前揭开 3 格真实结果——照着挑你喜欢的", fontSize = 12, fontColor = C.text },
                    UI.Label { text = "3. 稳型中奖多、奖小；冲型奖大但常空手", fontSize = 12, fontColor = C.text },
                    UI.Label { text = "4. 刮开银色涂层，每刮一格就是一次判定，全部刮完开奖", fontSize = 12, fontColor = C.text },
                    UI.Label { text = "5. 每张 +4 手气，满 40 得运势券，用券必出一笔大奖", fontSize = 12, fontColor = C.text },
                    UI.Label { text = "6. 金币往上只有两个去处：升级店铺、换更好的刮刀", fontSize = 12, fontColor = C.text },
                    UI.Button {
                        text = "音效：" .. ((state_.sfxOn ~= false) and "开" or "关"),
                        height = 34, width = "100%", fontSize = 12,
                        backgroundColor = { 50, 44, 36, 255 }, textColor = C.dim, borderRadius = 8,
                        onClick = function(self)
                            state_.sfxOn = not (state_.sfxOn ~= false)
                            saveGame()
                            self:SetText("音效：" .. (state_.sfxOn and "开" or "关"))
                            if state_.sfxOn then SFX("click", 0.6) end
                        end,
                    },
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
-- 10. 刮卡（多局票 · v2.1）
-- ============================================================================

--- 进场：有免费票优先免费用，没有则用金币购买
local function enterTicket(price, name)
    if state_.tickets >= 1 then
        state_.tickets = state_.tickets - 1
        SFX("buy", 0.6)
        return true
    end
    if state_.coins >= price then
        state_.coins = state_.coins - price
        saveGame()
        ShowToast("已花 " .. fmt(price) .. " 金币买票")
        SFX("buy", 0.7)
        return true
    end
    ShowToast("票和金币都不够 · 先转个盘或看广告")
    return false
end

--- 开始刮一张票
--- @param prebuilt table|nil 柜台里已生成好的结果（含预揭格），选中后直接使用，保证预揭与实际一致
function StartTicket(tk, styleIdx, prebuilt)
    if not enterTicket(tk.price, tk.name) then return false end
    local res = prebuilt or generateTicket(tk, styleIdx or 2, false, PEEK_CELLS + (shopData().peek or 0))
    scratch_ = {
        mode = "multi", result = res,
        zones = {}, cellRects = {}, revealed = {}, erase = {}, revealedCount = 0,
        total = 0, foil = {}, barW = 240,
        pointerDown = false, lastX = 0, lastY = 0,
        settled = false, settleDelay = 0, lastTouch = 0, hitFlash = 0,
    }
    floats_ = {}
    buildMultiScreen()
    return true
end

-- 兼容旧入口
function StartScratch(tk) StartTicket(tk) end

--- 多局票界面：票面（纸色 + 边框 + 幸运号）→ 若干玩法区 → 逐格刮开
function buildMultiScreen()
    state_.screen = "scratch"
    local cur = scratch_.result
    local tk = cur.ticket
    local W, H = UI.GetWidth(), UI.GetHeight()
    local topPad = math.floor(H * 0.105)
    local skin = SKIN[tk.skin] or SKIN.green

    local headerH = 44
    local cardX = 10
    local cardW = W - 20
    local cardY = topPad + headerH + 2
    local bottomH = 88
    local cardH = H - cardY - bottomH

    local nZones = #cur.zones
    local totalRows = 0
    for _, z in ipairs(cur.zones) do totalRows = totalRows + z.rows end

    local titleH, zoneGap, gap = 14, 4, 3
    local padT, padB = 58, 6

    local maxCols = 1
    for _, z in ipairs(cur.zones) do if z.cols > maxCols then maxCols = z.cols end end

    -- 解出格边长：同时满足高度与宽度约束
    local fixedH = padT + padB + nZones * titleH + (nZones - 1) * zoneGap + (totalRows - nZones) * gap
    local cellByH = math.floor((cardH - fixedH) / math.max(1, totalRows))
    local cellByW = math.floor((cardW - 24) / maxCols)
    local cell = math.max(26, math.min(cellByH, cellByW, 66))

    -- 溢出保护：任何分辨率下都不许把格子画到票面外
    while cell > 26 do
        local yEnd = cardY + padT
        for _, z in ipairs(cur.zones) do
            yEnd = yEnd + titleH + (z.rows * cell + (z.rows - 1) * gap) + zoneGap
        end
        if yEnd - zoneGap <= cardY + cardH - 2 then break end
        cell = cell - 2
    end

    scratch_.zones, scratch_.cellRects = {}, {}
    local titlePos = {}
    local y = cardY + padT
    local gi = 1
    for zi, z in ipairs(cur.zones) do
        local zw = z.cols * cell + (z.cols - 1) * gap
        local zh = z.rows * cell + (z.rows - 1) * gap
        local zx = math.floor((W - zw) / 2)
        titlePos[zi] = { x = zx, y = y }
        local zy = y + titleH
        scratch_.zones[zi] = { rect = { x = zx, y = zy, w = zw, h = zh }, cols = z.cols, rows = z.rows }
        for r = 0, z.rows - 1 do
            for c = 0, z.cols - 1 do
                scratch_.cellRects[gi] = {
                    x = zx + c * (cell + gap), y = zy + r * (cell + gap),
                    w = cell, h = cell,
                }
                gi = gi + 1
            end
        end
        y = zy + zh + zoneGap
    end
    scratch_.total = cur.total
    scratch_.revealed, scratch_.revealedCount = {}, 0
    scratch_.barW = cardW - 40
    -- 柜台预揭的格：进入时就是已刮状态（是这张票真实结果的一部分）
    for _, pi in ipairs(cur.peeked or {}) do
        scratch_.revealed[pi] = true
        scratch_.revealedCount = scratch_.revealedCount + 1
    end

    -- 格子控件（内容预先排好，被银色涂层盖住）
    local widgets = {}
    local isNum = (tk.judge == "number")
    for i = 1, cur.total do
        local rc = scratch_.cellRects[i]
        local c = cur.cells[i]
        local numSize = math.max(11, math.min(26, math.floor(cell * 0.42)))
        local amtSize = math.max(9, math.min(14, math.floor(cell * 0.24)))
        local valColor = isNum and { 42, 36, 28, 255 } or (SYMBOL_COLOR[c.val] or { 60, 50, 40, 255 })
        table.insert(widgets, UI.Panel {
            position = "absolute", left = rc.x, top = rc.y, width = rc.w, height = rc.h,
            backgroundColor = { skin.paper[1] - 6, skin.paper[2] - 6, skin.paper[3] - 8, 255 },
            borderRadius = 3, borderWidth = 1,
            borderColor = { skin.frame[1], skin.frame[2], skin.frame[3], 70 },
            justifyContent = "center", alignItems = "center", gap = 1,
            pointerEvents = "none",
            children = {
                UI.Label { text = tostring(c.val), fontSize = numSize, fontColor = valColor },
                UI.Label { text = fmtShort(c.amount), fontSize = amtSize,
                    fontColor = c.hit and { 178, 46, 34, 255 } or { 128, 112, 88, 255 } },
            },
        })
    end

    -- 区标题
    local titles = {}
    for zi, z in ipairs(cur.zones) do
        local tp = titlePos[zi]
        table.insert(titles, UI.Panel {
            position = "absolute", left = tp.x, top = tp.y,
            width = scratch_.zones[zi].rect.w, height = titleH,
            pointerEvents = "none",
            children = {
                UI.Label { text = z.label, fontSize = 11, fontColor = { skin.ink[1], skin.ink[2], skin.ink[3], 210 } },
            },
        })
    end

    -- 幸运号 / 目标符号（横排胶囊）
    local headKids = {}
    if isNum then
        table.insert(headKids, UI.Label { text = "幸运号", fontSize = 9,
            fontColor = { skin.ink[1], skin.ink[2], skin.ink[3], 190 } })
        for _, v in ipairs(cur.lucky) do
            table.insert(headKids, UI.Panel {
                width = 30, height = 26, borderRadius = 4,
                backgroundColor = { 255, 250, 238, 255 },
                borderWidth = 1, borderColor = { skin.frame[1], skin.frame[2], skin.frame[3], 150 },
                justifyContent = "center", alignItems = "center",
                children = { UI.Label { text = tostring(v), fontSize = 15, fontColor = { 170, 40, 30, 255 } } },
            })
        end
    else
        table.insert(headKids, UI.Label { text = "找这个", fontSize = 9,
            fontColor = { skin.ink[1], skin.ink[2], skin.ink[3], 190 } })
        table.insert(headKids, UI.Panel {
            width = 30, height = 26, borderRadius = 4,
            backgroundColor = { 255, 250, 238, 255 },
            borderWidth = 1, borderColor = { skin.frame[1], skin.frame[2], skin.frame[3], 150 },
            justifyContent = "center", alignItems = "center",
            children = { UI.Label { text = cur.target, fontSize = 17,
                fontColor = SYMBOL_COLOR[cur.target] or { 170, 40, 30, 255 } } },
        })
    end

    -- 票据流水号（用票 id 稳定生成，同一款票每次都是同一个前缀，像真的印刷批次）
    local hseed = 0
    for i = 1, #tk.id do hseed = (hseed * 31 + tk.id:byte(i)) % 1000000 end
    local serial = string.format("NO.%03d%03d", hseed, (cur.total * 137 + tk.yuan * 7) % 1000)

    -- 票头：左票名 / 右幸运号
    local topRow = UI.Panel {
        position = "absolute", left = cardX + 14, top = cardY + 8,
        width = cardW - 28, height = 46,
        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
        pointerEvents = "none",
        children = {
            UI.Panel {
                gap = 1,
                children = {
                    UI.Label { text = tk.name .. " · " .. tk.yuan .. " 元", fontSize = 16,
                        fontColor = { skin.ink[1], skin.ink[2], skin.ink[3], 255 } },
                    UI.Label { text = "共 " .. cur.total .. " 次机会 · " .. serial, fontSize = 8.5,
                        fontColor = { skin.frame[1], skin.frame[2], skin.frame[3], 200 } },
                },
            },
            UI.Panel { flexDirection = "row", alignItems = "center", gap = 4, children = headKids },
        },
    }

    -- 纸纹：七道极淡横线，让票面不像纯色块
    local paperLines = {}
    for k = 1, 7 do
        paperLines[#paperLines + 1] = UI.Panel {
            position = "absolute", left = cardX + 10,
            top = math.floor(cardY + 58 + k * ((cardH - 70) / 8)),
            width = cardW - 20, height = 1,
            backgroundColor = { skin.ink[1], skin.ink[2], skin.ink[3], 11 },
            pointerEvents = "none",
        }
    end

    uiRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundColor = C.bg,
        children = {
            -- 顶栏
            UI.Panel {
                width = "100%", paddingTop = topPad, paddingBottom = 4,
                paddingLeft = 12, paddingRight = 12, height = topPad + headerH,
                flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = {
                    UI.Button { text = "‹", width = 40, height = 36, fontSize = 22,
                        backgroundColor = { 44, 34, 22, 255 }, textColor = C.goldL, borderRadius = 10,
                        onClick = function() BuildLobby() end },
                    UI.Label { text = tk.name .. " · " .. fmt(tk.price) .. " 币", fontSize = 15, fontColor = C.goldL },
                    UI.Label { text = "票 " .. state_.tickets, fontSize = 12, fontColor = C.green },
                },
            },
            -- 票面
            UI.Panel {
                position = "absolute", left = cardX, top = cardY, width = cardW, height = cardH,
                backgroundColor = skin.paper, borderRadius = 8,
                borderWidth = 2, borderColor = { skin.frame[1], skin.frame[2], skin.frame[3], 255 },
                pointerEvents = "none",
            },
            UI.Panel {
                position = "absolute", left = cardX + 4, top = cardY + 4, width = cardW - 8, height = cardH - 8,
                borderRadius = 6, borderWidth = 1,
                borderColor = { skin.frame[1], skin.frame[2], skin.frame[3], 90 },
                pointerEvents = "none",
            },
            topRow,
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = paperLines },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = titles },
            UI.Panel { position = "absolute", left = 0, top = 0, width = W, height = H,
                pointerEvents = "none", children = widgets },
            -- 底部：进度 + 提示
            UI.Panel {
                position = "absolute", left = 16, right = 16, bottom = 14, gap = 5, alignItems = "center",
                pointerEvents = "none",
                children = {
                    UI.Label { id = "scratchPct", text = "刮开 0% · 全部刮开即开奖", fontSize = 11, fontColor = C.dim },
                    UI.Panel { width = "100%", height = 5, backgroundColor = { 38, 30, 20, 255 }, borderRadius = 3,
                        children = { UI.Panel { id = "scratchBar", width = 1, height = 5,
                            backgroundColor = C.gold, borderRadius = 3 } } },
                    UI.Label { id = "scratchHint", text = "用手指刮开银色涂层",
                        fontSize = 10, fontColor = { 150, 132, 100, 220 } },
                },
            },
        },
    }
    UI.SetRoot(uiRoot_)
    updateHud()
end

--- 好运十倍界面：中奖号码常显 + 10 个我的号码（2×5）
function RevealAll()
    if scratch_.settled or state_.screen ~= "scratch" then return end
    scratch_.settled = true
    ScratchSound(false)
    for i = 1, scratch_.total do
        scratch_.revealed[i] = true
        scratch_.erase[i] = 1
    end
    scratch_.revealedCount = scratch_.total
    updateScratchProgress()
    scratch_.settleDelay = 0.65   -- 让玩家先看清整张票
end

function SettleScratch()
    local cur = scratch_.result
    local tk = cur.ticket
    local payout = cur.payout
    state_.totalScratched = state_.totalScratched + 1

    -- 手气槽：每张固定基础 +4，另加店铺与店员加成（不看广告、不看结果，无套利空间）
    local luckGain = LUCK_GAIN + (shopData().luckAdd or 0) + staffLuckBonus()
    local gaugeMsg = nil
    state_.luckGauge = (state_.luckGauge or 0) + luckGain
    if state_.luckGauge >= LUCK_CAP then
        if (state_.vouchers or 0) < voucherMax() then
            state_.vouchers = (state_.vouchers or 0) + 1
            state_.luckGauge = 0
            gaugeMsg = "手气槽满 · 得 1 张运势券"
            SFX("voucher", 0.8)
        else
            state_.luckGauge = LUCK_CAP
            gaugeMsg = "运势券已满 · 先用掉一张再攒"
        end
    end

    if payout > 0 then
        state_.coins = state_.coins + payout
        state_.totalWon = state_.totalWon + payout
        local bigHit = payout >= tk.price * 8
        spawnParticles(UI.GetWidth() / 2, UI.GetHeight() * 0.42, bigHit and 240 or 70, bigHit)
        if bigHit then flashAlpha_ = 1.0 end
        SFX(bigHit and "bigwin" or "win", bigHit and 0.9 or 0.7)
    else
        SFX("lose", 0.55)
    end

    local hitOnes = {}
    for _, c in ipairs(cur.cells) do
        if c.hit then table.insert(hitOnes, fmtShort(c.amount)) end
    end

    local st = STYLES[cur.styleIdx or 2]
    local ink      = { 62, 50, 36, 255 }
    local inkSub   = { 112, 96, 74, 255 }
    local inkFaint = { 156, 140, 116, 255 }
    local inkRed   = { 172, 42, 30, 255 }
    local inkGreen = { 52, 108, 62, 255 }
    local dashed   = "· · · · · · · · · · · · · · · · · ·"

    local stamp = "——"
    pcall(function() stamp = os.date("%Y-%m-%d  %H:%M") end)

    local kids = {
        UI.Label { text = "好 运 游 戏 厅", fontSize = 10, fontColor = inkFaint, textAlign = "center" },
        UI.Label { text = "兑 奖 凭 证", fontSize = 9, fontColor = { 176, 160, 132, 255 }, textAlign = "center" },
        UI.Label { text = dashed, fontSize = 8, fontColor = { 196, 182, 156, 255 }, textAlign = "center" },
        UI.Label { text = tk.name .. " · " .. tk.yuan .. " 元 · " .. st.name .. "型", fontSize = 11,
            fontColor = ink, textAlign = "center" },
        UI.Label { text = "共 " .. cur.total .. " 次机会", fontSize = 9, fontColor = inkFaint, textAlign = "center" },
        UI.Label { text = payout > 0 and ("＋" .. fmt(payout)) or "0",
            fontSize = payout > 0 and 38 or 30,
            fontColor = payout > 0 and inkRed or { 150, 140, 124, 255 }, textAlign = "center" },
        UI.Label { text = payout > 0 and "金币已入账" or "这张没中",
            fontSize = 11, fontColor = payout > 0 and inkGreen or inkFaint, textAlign = "center" },
        UI.Label { text = #hitOnes > 0
                and ("中奖 " .. #hitOnes .. " 格：" .. table.concat(hitOnes, " · "))
                or "一格都没对上",
            fontSize = 10, fontColor = inkSub, textAlign = "center" },
    }

    -- 手气槽进度（确定性承诺：永远知道还差几张）
    local gv = state_.luckGauge or 0
    table.insert(kids, UI.Label {
        text = gaugeMsg or ("手气槽 " .. gv .. "/" .. LUCK_CAP .. "（本张 +" .. luckGain .. "）· 再 "
            .. math.ceil((LUCK_CAP - gv) / math.max(1, luckGain)) .. " 张有券"),
        fontSize = 9, fontColor = gaugeMsg and { 132, 88, 148, 255 } or inkFaint, textAlign = "center",
    })

    table.insert(kids, UI.Label { text = dashed, fontSize = 8,
        fontColor = { 196, 182, 156, 255 }, textAlign = "center" })

    table.insert(kids, goldBtn(payout > 0 and "收下 · 再挑一张" or "再挑一张", function()
        BuildCounter(tk.yuan)
    end, { height = 44 }))

    if payout > 0 then
        table.insert(kids, UI.Button {
            id = "doubleBtn",
            text = "看广告 · 再领 " .. fmt(payout) .. " 币",
            width = "100%", height = 38, fontSize = 12,
            backgroundColor = { 86, 122, 78, 255 }, textColor = { 240, 252, 236, 255 },
            borderRadius = 9, borderWidth = 1, borderColor = { 112, 152, 100, 255 },
            onClick = function(self)
                ShowAd("A2", function()
                    self:SetText("已再领一份")
                    self:SetDisabled(true)
                    updateHud()
                end, payout)
            end,
        })
    end

    table.insert(kids, UI.Button {
        text = "回大厅", width = "100%", height = 34, fontSize = 11,
        backgroundColor = { 0, 0, 0, 0 }, textColor = inkSub, borderRadius = 8,
        onClick = function() BuildLobby() end,
    })
    table.insert(kids, UI.Label { text = stamp .. "    谢谢惠顾", fontSize = 8,
        fontColor = { 180, 166, 142, 255 }, textAlign = "center" })

    local banner = UI.Panel {
        id = "resultBanner",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 208 },
        justifyContent = "center", alignItems = "center", padding = 20,
        children = {
            UI.Panel {
                width = "100%", maxWidth = 340, paddingTop = 18, paddingBottom = 14,
                paddingLeft = 18, paddingRight = 18, gap = 6, alignItems = "stretch",
                backgroundColor = { 248, 242, 226, 255 },
                borderRadius = 14, borderWidth = 1,
                borderColor = payout > 0 and { 196, 158, 78, 255 } or { 196, 184, 160, 255 },
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
        local v = wheelValue(s)
        state_.coins = state_.coins + v
        msg = "+" .. fmt(v) .. " 金币"
        if v >= SCALE() * 8 then
            spawnParticles(UI.GetWidth()/2, UI.GetHeight()*0.325, 220, true)
            flashAlpha_ = 1.0
        end
    elseif s.type == "jackpot" then
        local v = wheelValue(s)
        state_.coins = state_.coins + v
        msg = "头奖 +" .. fmt(v) .. " 金币"
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
        return staffOneBonus(a) > staffOneBonus(b)
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
                        UI.Label { text = "Lv." .. rec.level .. " · 手气 +" .. staffOneBonus(rec) .. "/张", fontSize = 12, fontColor = { 200, 200, 210, 255 } },
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
                    UI.Label { text = "手气 +" .. staffLuckBonus() .. "/张", fontSize = 13, fontColor = { 255, 215, 0, 255 } },
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
