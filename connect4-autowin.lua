--[[
    ENI • Connect 4 Auto-Win  v4  (interface NextUI)
    - Moteur bitboard SYNCHRONE : ~14 ms de CPU max par coup (sous une frame) => zero freeze
    - Priorites : victoire immediate > blocage > double menace > negamax alpha-beta
    - Lecture du plateau a la demande (pas de GetChildren en boucle)
    - GUI NextUI (diser.me/nextui) : cards, icones Lucide, themes live, bouton mobile
    - Joue via RaycastDrop(stationId, colonne 0-6)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local LP = Players.LocalPlayer
local Events = ReplicatedStorage:WaitForChild("Events")
local RaycastDrop = Events:WaitForChild("RaycastDrop")

local NEXTUI_SRC = "https://diser.me/nextui/source.lua"

local CONFIG = {
    budget     = 0.014,  -- CPU max par coup (synchrone, < 1 frame)
    budgetMin  = 0.006,
    budgetMax  = 0.040,
    autoTune   = true,   -- ajuste tout seul le budget pour rester fluide
    maxDepth   = 14,
    minDelay   = 0.12,
    maxDelay   = 0.32,
    loopWait   = 0.08,
    boardEvery = 0.35,
}

----------------------------------------------------------------------
-- 0b. Textes bilingues (FR / EN)
----------------------------------------------------------------------
local STRINGS = {
    fr = {
        subtitle   = "Connect 4 • Auto-Win",
        tab_bot    = "Bot", tab_board = "Plateau", tab_cfg = "Réglages",
        sec_auto   = "Auto-Win",
        on         = "Jouer à ma place",
        on_desc    = "Le bot pose son pion dès que c'est mon tour.",
        think      = "Réflexion",
        think_desc = "Temps de calcul par coup.",
        tune       = "Réglage auto du temps",
        tune_desc  = "Reste sous une frame sur les machines faibles.",
        dmin       = "Délai minimum",
        dmax       = "Délai maximum",
        sec_state  = "État",
        waiting    = "En attente d'une partie.",
        depth      = "Profondeur",
        analysis   = "Analyse",
        no_calc    = "Aucun coup calculé pour l'instant.",
        sec_board  = "Ma position",
        board      = "Plateau",
        legend     = "🟨 toi   •   🟥 adversaire   •   ⬛ case vide",
        chip_one   = "1 jeton",
        chip_many  = "%d jetons",
        refresh    = "Rafraîchir maintenant",
        refresh_d  = "Force la lecture du plateau.",
        sec_look   = "Apparence",
        theme      = "Thème",
        glass      = "Glass",
        glass_desc = "Fenêtre translucide avec flou.",
        stars      = "Étoiles",
        lang       = "Langue",
        lang_desc  = "Change la langue de l'interface.",
        sec_ctl    = "Contrôle",
        hide       = "Masquer la fenêtre",
        hide_touch = "Rouvre-la avec le bouton flottant.",
        hide_pc    = "Raccourci : Insert ou R-Shift.",
        stop       = "Arrêter le bot",
        stop_desc  = "Maintiens pour confirmer.",
        st_missing = "État du jeu introuvable.",
        st_off     = "Bot désactivé.",
        st_sit     = "Assieds-toi à une table pour commencer.",
        st_opp     = "Tour adverse...",
        st_mine    = "À moi de jouer.",
        st_drop    = "Pion lâché en colonne %d.",
        st_error   = "Erreur : %s",
        tag_win    = "Victoire forcée",
        tag_double = "Double menace",
        tag_block  = "Blocage obligatoire",
        tag_lost   = "Position perdue",
        tag_eval   = "Évaluation %d",
        an_line    = "%s\nProfondeur %d  •  %d noeuds  •  %d ms\nCoup visé : colonne %d",
        notif_desc = "Colonne %d (%d demi-coups)",
        wm_prof    = "Prof",
    },
    en = {
        subtitle   = "Connect 4 • Auto-Win",
        tab_bot    = "Bot", tab_board = "Board", tab_cfg = "Settings",
        sec_auto   = "Auto-Win",
        on         = "Play for me",
        on_desc    = "The bot drops a chip as soon as it is my turn.",
        think      = "Think time",
        think_desc = "Calculation time per move.",
        tune       = "Auto-tune time",
        tune_desc  = "Stays under one frame on weak devices.",
        dmin       = "Minimum delay",
        dmax       = "Maximum delay",
        sec_state  = "Status",
        waiting    = "Waiting for a match.",
        depth      = "Depth",
        analysis   = "Analysis",
        no_calc    = "No move computed yet.",
        sec_board  = "My board",
        board      = "Board",
        legend     = "🟨 you   •   🟥 opponent   •   ⬛ empty",
        chip_one   = "1 chip",
        chip_many  = "%d chips",
        refresh    = "Refresh now",
        refresh_d  = "Forces a board read.",
        sec_look   = "Appearance",
        theme      = "Theme",
        glass      = "Glass",
        glass_desc = "See-through window with blur.",
        stars      = "Stars",
        lang       = "Language",
        lang_desc  = "Switches the interface language.",
        sec_ctl    = "Controls",
        hide       = "Hide window",
        hide_touch = "Reopen it with the floating button.",
        hide_pc    = "Hotkey: Insert or R-Shift.",
        stop       = "Stop the bot",
        stop_desc  = "Hold to confirm.",
        st_missing = "Game state not found.",
        st_off     = "Bot disabled.",
        st_sit     = "Sit at a table to start.",
        st_opp     = "Opponent's turn...",
        st_mine    = "My turn.",
        st_drop    = "Chip dropped in column %d.",
        st_error   = "Error: %s",
        tag_win    = "Forced win",
        tag_double = "Double threat",
        tag_block  = "Must block",
        tag_lost   = "Losing position",
        tag_eval   = "Evaluation %d",
        an_line    = "%s\nDepth %d  •  %d nodes  •  %d ms\nTarget column %d",
        notif_desc = "Column %d (%d ply)",
        wm_prof    = "Depth",
    },
}

-- Interface en anglais par defaut ; le menu "Language" permet de passer en francais.
local lang = "en"

local function T(key, ...)
    local set = STRINGS[lang] or STRINGS.fr
    local s = set[key] or STRINGS.fr[key] or key
    if select("#", ...) > 0 then return string.format(s, ...) end
    return s
end

----------------------------------------------------------------------
-- 0. Nettoyage des anciennes instances du bot
----------------------------------------------------------------------
local MARK = {}

local function killOldBots()
    local me = coroutine.running()
    local prev = getgenv().__ENI_MARK
    for _, th in ipairs(getallthreads()) do
        if th ~= me and isexecutorthread(th) and coroutine.status(th) == "suspended" then
            local ok, cs = pcall(debug.getcallstack, th)
            local isBot = false
            if ok and type(cs) == "table" then
                for fi = 1, math.min(#cs, 3) do
                    local oku, ups = pcall(debug.getupvalues, cs[fi].func)
                    if oku and type(ups) == "table" then
                        for _, u in ipairs(ups) do
                            if prev and u == prev then isBot = true end
                        end
                    end
                end
            end
            if isBot then pcall(coroutine.close, th) end
        end
    end
end
killOldBots()
getgenv().__ENI_MARK = MARK

-- detruit les fenetres NextUI / GUI laissees par une ancienne execution
local function clearOldGui()
    local ok, hui = pcall(gethui)
    local cont = ok and hui or game:GetService("CoreGui")
    if cont then
        for _, n in ipairs({ "NextUI", "NextUIWatermark" }) do
            local g = cont:FindFirstChild(n)
            if g then pcall(function() g:Destroy() end) end
        end
    end
    local old = LP.PlayerGui:FindFirstChild("ENI_AutoWin")
    if old then pcall(function() old:Destroy() end) end
end
clearOldGui()

----------------------------------------------------------------------
-- 1. Table d'etat interne du jeu
----------------------------------------------------------------------
local STATE = nil

local function findState()
    for _, evName in ipairs({ "TurnChanged", "ColumnFull", "MatchStart", "MatchEnd" }) do
        local ev = Events:FindFirstChild(evName)
        if ev then
            local okC, cons = pcall(getconnections, ev.OnClientEvent)
            if okC and cons then
                for _, c in ipairs(cons) do
                    local okF, fn = pcall(getconnectionfunction, c)
                    if okF and type(fn) == "function" then
                        local okU, ups = pcall(debug.getupvalues, fn)
                        if okU and ups then
                            for _, u in ipairs(ups) do
                                if type(u) == "table"
                                    and rawget(u, "isMyTurn") ~= nil
                                    and rawget(u, "inMatch") ~= nil then
                                    return u
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

----------------------------------------------------------------------
-- 2. Lecture du plateau (1 = moi, 2 = adversaire)
----------------------------------------------------------------------
local function readBoard(state)
    local board = {}
    for c = 1, 7 do board[c] = {} end
    local count = 0
    local sid = tostring(state.stationId or "")
    local myChip = state.myChip
    local boardPart = state.board
    local folder = boardPart and boardPart.Parent
    if not folder then return board, 0 end
    for _, ch in ipairs(folder:GetChildren()) do
        local col = ch:GetAttribute("C4Column")
        local row = ch:GetAttribute("C4Row")
        local chipSid = ch:GetAttribute("C4StationId")
        local chipName = ch:GetAttribute("C4ChipName")
        if typeof(col) == "number" and typeof(row) == "number" and tostring(chipSid or "") == sid then
            local c = col + 1
            local r = 6 - row
            if c >= 1 and c <= 7 and r >= 1 and r <= 6 then
                board[c][r] = (chipName == myChip) and 1 or 2
                count += 1
            end
        end
    end
    return board, count
end

----------------------------------------------------------------------
-- 3. Moteur bitboard
----------------------------------------------------------------------
local ROWS, COLS = 6, 7
local ORDER = { 4, 3, 5, 2, 6, 1, 7 }
local CENTER = { 2, 3, 5, 7, 5, 3, 2 }
local WIN = 1000000
local INF = math.huge

local H  = { 0, 0, 0, 0, 0, 0, 0, 0 }
local M1 = { 0, 0, 0, 0, 0, 0, 0, 0 }
local M2 = { 0, 0, 0, 0, 0, 0, 0, 0 }

local sDeadline, sAbort, sNodes = 0, false, 0

local bit = bit32.lshift
local band = bit32.band

local function ray(m, c, r, dc, dr)
    local n = 1
    local cc, rr = c + dc, r + dr
    while cc >= 1 and cc <= COLS and rr >= 0 and rr <= 5 and band(m[cc], bit(1, rr)) ~= 0 do
        n += 1; cc += dc; rr += dr
    end
    cc, rr = c - dc, r - dr
    while cc >= 1 and cc <= COLS and rr >= 0 and rr <= 5 and band(m[cc], bit(1, rr)) ~= 0 do
        n += 1; cc -= dc; rr -= dr
    end
    return n
end

local function winsAt(m, c, r)
    return ray(m, c, r, 0, 1) >= 4
        or ray(m, c, r, 1, 0) >= 4
        or ray(m, c, r, 1, 1) >= 4
        or ray(m, c, r, 1, -1) >= 4
end

local function popcount(x)
    local n = 0
    while x ~= 0 do
        x = band(x, x - 1)
        n += 1
    end
    return n
end

local function evalFor(p)
    local me = (p == 1) and M1 or M2
    local op = (p == 1) and M2 or M1
    local score = 0
    for c = 1, 7 do
        score += (popcount(me[c]) - popcount(op[c])) * CENTER[c]
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            me[c] += b
            if winsAt(me, c, h) then score += 850 end
            me[c] -= b
            op[c] += b
            if winsAt(op, c, h) then score -= 1000 end
            op[c] -= b
        end
    end
    return score
end

local function negamax(depth, alpha, beta, p)
    sNodes += 1
    if sNodes % 64 == 0 and os.clock() > sDeadline then sAbort = true end
    if sAbort then return 0 end
    if depth <= 0 then return evalFor(p) end

    local me = (p == 1) and M1 or M2
    local op = (p == 1) and M2 or M1

    local threats, forced = 0, 0
    for i = 1, 7 do
        local c = ORDER[i]
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            me[c] += b
            local winNow = winsAt(me, c, h)
            me[c] -= b
            if winNow then return WIN + depth end
            op[c] += b
            if winsAt(op, c, h) then
                threats += 1
                forced = c
            end
            op[c] -= b
        end
    end

    if threats >= 2 then return -(WIN + depth) end

    if threats == 1 then
        local c = forced
        local h = H[c]
        local b = bit(1, h)
        H[c] = h + 1
        me[c] += b
        local score = -negamax(depth - 1, -beta, -alpha, 3 - p)
        me[c] -= b
        H[c] = h
        return score
    end

    local best = -INF
    local any = false

    for i = 1, 7 do
        local c = ORDER[i]
        local h = H[c]
        if h < ROWS then
            any = true
            local b = bit(1, h)
            H[c] = h + 1
            me[c] += b
            local score = -negamax(depth - 1, -beta, -alpha, 3 - p)
            me[c] -= b
            H[c] = h
            if score > best then best = score end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
    end

    if not any then return 0 end
    return best
end

local function myWinCols()
    local cols = {}
    for c = 1, 7 do
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            M1[c] += b
            if winsAt(M1, c, h) then cols[#cols + 1] = c end
            M1[c] -= b
        end
    end
    return cols
end

local function searchBest(board)
    for c = 1, 7 do
        H[c] = 0; M1[c] = 0; M2[c] = 0
    end

    local stones = 0
    for c = 1, 7 do
        for r = 1, 6 do
            local v = board[c][r]
            if v then
                H[c] = r
                if v == 1 then M1[c] += bit(1, r - 1) else M2[c] += bit(1, r - 1) end
                stones += 1
            end
        end
    end

    if stones == 0 then return 4, 0, 0, 0, 0 end

    for i = 1, 7 do
        local c = ORDER[i]
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            M1[c] += b
            local w = winsAt(M1, c, h)
            M1[c] -= b
            if w then return c, WIN, 1, 0, 0 end
        end
    end

    for i = 1, 7 do
        local c = ORDER[i]
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            M2[c] += b
            local w = winsAt(M2, c, h)
            M2[c] -= b
            if w then return c, 500000, 1, 0, 0 end
        end
    end

    for i = 1, 7 do
        local c = ORDER[i]
        local h = H[c]
        if h < ROWS then
            local b = bit(1, h)
            H[c] = h + 1
            M1[c] += b
            local wins = myWinCols()
            M1[c] -= b
            H[c] = h
            if #wins >= 2 then return c, 400000, 2, 0, 0 end
        end
    end

    sNodes = 0
    sAbort = false
    local t0 = os.clock()
    sDeadline = t0 + CONFIG.budget

    local bestCol, bestScore, reached = 4, 0, 0

    for depth = 2, CONFIG.maxDepth do
        sNodes = 0
        sAbort = false
        local alpha = -INF
        local dBestCol, dBestScore = nil, -INF

        for i = 1, 7 do
            local c = ORDER[i]
            local h = H[c]
            if h < ROWS then
                local b = bit(1, h)
                H[c] = h + 1
                M1[c] += b
                local score
                if winsAt(M1, c, h) then
                    score = WIN
                else
                    score = -negamax(depth - 1, -INF, -alpha, 2)
                end
                M1[c] -= b
                H[c] = h
                if score > dBestScore then
                    dBestScore = score
                    dBestCol = c
                end
                if score > alpha then alpha = score end
                if sAbort then break end
            end
        end

        if not sAbort and dBestCol then
            bestCol, bestScore, reached = dBestCol, dBestScore, depth
        end
        if sAbort then break end
        if bestScore >= 900000 then break end
        if os.clock() > sDeadline then break end
    end

    return bestCol, bestScore, reached, sNodes, math.floor((os.clock() - t0) * 1000)
end

-- plateau lisible : une ligne par rang, du haut vers le bas
local SELF_GLYPH, FOE_GLYPH, FREE_GLYPH = "🟨", "🟥", "⬛"
local function boardToText(board)
    local lines = {}
    for r = 6, 1, -1 do
        local row = {}
        for c = 1, 7 do
            local v = board[c][r]
            row[c] = (v == 1 and SELF_GLYPH) or (v == 2 and FOE_GLYPH) or FREE_GLYPH
        end
        table.insert(lines, table.concat(row))
    end
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- 4. Etat du bot
----------------------------------------------------------------------
local autoOn = false
local lastCount = -1
local lastFire = 0
local firedThisTurn = false
local lastStation = nil
local lastRead = 0
local UIRef = nil
local setToggle
local forceRefresh = false
local notifiedTurn = false
local lastBuild = 0
local forceRebuild = false

local cache = { status = nil, board = nil, chips = nil, analysis = nil, depth = nil }

----------------------------------------------------------------------
-- 5. UI NextUI
----------------------------------------------------------------------
local function findNextGui()
    local ok, hui = pcall(gethui)
    local cont = ok and hui or game:GetService("CoreGui")
    if not cont then return nil end
    return cont:FindFirstChild("NextUI")
end

local function guiAlive(ref)
    if not ref then return false end
    local ok, alive = pcall(function()
        local g = findNextGui()
        return g ~= nil and g.Parent ~= nil
    end)
    return ok and alive
end

local function isTouchDevice()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- taille de fenetre adaptee a l'ecran (PC large, mobile presque plein ecran)
local function computeWindowSize()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    if vp.X < 240 or vp.Y < 240 then vp = Vector2.new(1280, 720) end

    local touch = isTouchDevice()
    local wRatio = touch and 0.94 or 0.60
    local hRatio = touch and 0.78 or 0.72

    local w = math.floor(vp.X * wRatio)
    local h = math.floor(vp.Y * hRatio)

    w = math.clamp(w, 460, 1040)
    h = math.clamp(h, 400, 820)

    w = math.min(w, math.floor(vp.X) - 20)
    h = math.min(h, math.floor(vp.Y) - 20)

    return Vector2.new(math.max(w, 320), math.max(h, 300)), touch, vp
end

local function buildUI()
    local NextUI = loadstring(game:HttpGet(NEXTUI_SRC))()
    NextUI.TitleCase = false

    -- textes plus gros et jamais coupes (tooltip au dela de la limite)
    NextUI.TextScale = 1.2
    NextUI.TipLength = 64
    NextUI.ButtonTipLength = 64

    local size, touch, vp = computeWindowSize()

    local Window = NextUI:CreateWindow({
        Title = "ENI",
        SubTitle = T("subtitle"),
        Theme = "Rose",
        Size = size,
        MinSize = Vector2.new(
            math.min(440, math.floor(size.X * 0.62)),
            math.min(360, math.floor(size.Y * 0.62))
        ),
        TabWidth = math.clamp(math.floor(size.X * 0.19), 150, 200),
        Search = false,
        Profile = not touch and size.Y > 460,
        Stars = true,
        Resizable = true,
        MobileButton = touch and true or "Auto",
        Collapsible = true,
    })

    local TabBot   = Window:AddTab({ Title = T("tab_bot"), Icon = "bot" })
    local TabBoard = Window:AddTab({ Title = T("tab_board"), Icon = "layout-grid" })
    local TabCfg   = Window:AddTab({ Title = T("tab_cfg"), Icon = "settings" })

    ------------------------------------------------------------------
    -- Bot
    ------------------------------------------------------------------
    local CardPlay = TabBot:AddSection({ Title = T("sec_auto"), Icon = "play" })

    local tgBot = CardPlay:AddToggle({
        Title = T("on"),
        Description = T("on_desc"),
        Style = "Switch",
        Flag = "eni_on",
        Default = true,
        Callback = function(v) setToggle(v) end,
    })

    CardPlay:AddSlider({
        Title = T("think"),
        Description = T("think_desc"),
        Min = 6, Max = 45, Default = math.floor(CONFIG.budget * 1000 + 0.5),
        Increment = 1, Suffix = " ms", Flag = "eni_ms",
        Callback = function(v)
            CONFIG.budget = v / 1000
            if CONFIG.budget > CONFIG.budgetMax then CONFIG.budgetMax = CONFIG.budget end
        end,
    })

    CardPlay:AddToggle({
        Title = T("tune"),
        Description = T("tune_desc"),
        Style = "Switch",
        Flag = "eni_autotune",
        Default = true,
        Callback = function(v) CONFIG.autoTune = v end,
    })

    CardPlay:AddSlider({
        Title = T("dmin"), Min = 0, Max = 1, Default = CONFIG.minDelay,
        Increment = 0.02, Suffix = " s", Flag = "eni_dmin",
        Callback = function(v) CONFIG.minDelay = v end,
    })

    CardPlay:AddSlider({
        Title = T("dmax"), Min = 0.05, Max = 1.5, Default = CONFIG.maxDelay,
        Increment = 0.02, Suffix = " s", Flag = "eni_dmax",
        Callback = function(v) CONFIG.maxDelay = math.max(v, CONFIG.minDelay) end,
    })

    local CardState = TabBot:AddSection({ Title = T("sec_state"), Icon = "activity" })
    local lblStatus = CardState:AddLabel(T("waiting"))
    local prgDepth  = CardState:AddProgress({ Title = T("depth"), Min = 0, Max = 12, Default = 0 })
    local paraEval  = CardState:AddParagraph({ Title = T("analysis"), Content = T("no_calc") })

    ------------------------------------------------------------------
    -- Plateau
    ------------------------------------------------------------------
    local CardBoard = TabBoard:AddSection({ Title = T("sec_board"), Icon = "layout-grid", Side = "Full" })
    local paraBoard = CardBoard:AddParagraph({ Title = T("board"), Content = "..." })
    CardBoard:AddLabel(T("legend"))
    local lblChips  = CardBoard:AddLabel(T("chip_many", 0))
    CardBoard:AddButton({
        Title = T("refresh"),
        Description = T("refresh_d"),
        Callback = function() forceRefresh = true end,
    })

    ------------------------------------------------------------------
    -- Réglages
    ------------------------------------------------------------------
    local CardLook = TabCfg:AddSection({ Title = T("sec_look"), Icon = "sliders-horizontal" })
    CardLook:AddDropdown({
        Title = T("theme"),
        Values = { "Rose", "Crimson", "Onyx", "Dark", "Darker", "Light", "Aqua", "Lagoon", "Amethyst", "Emerald", "Toxic", "Noir" },
        Default = "Rose",
        Flag = "eni_theme",
        Callback = function(v) NextUI:SetTheme(v) end,
    })
    CardLook:AddDropdown({
        Title = T("lang"),
        Description = T("lang_desc"),
        Values = { "Français", "English" },
        Default = (lang == "fr") and "Français" or "English",
        Flag = "eni_lang",
        Callback = function(v)
            local nextLang = (v == "English") and "en" or "fr"
            if nextLang == lang then return end
            lang = nextLang
            forceRebuild = true
        end,
    })
    CardLook:AddToggle({
        Title = T("glass"),
        Description = T("glass_desc"),
        Style = "Switch",
        Flag = "eni_glass",
        Default = false,
        Callback = function(v) NextUI:SetGlass(v) end,
    })
    CardLook:AddToggle({
        Title = T("stars"),
        Style = "Switch",
        Flag = "eni_stars",
        Default = true,
        Callback = function(v) Window:SetStars(v) end,
    })

    local Watermark = nil
    local wmDepth = nil
    pcall(function()
        Watermark = NextUI:CreateWatermark({ Title = "ENI", Position = "TopRight" })
        wmDepth = Watermark:Add(T("wm_prof"), 0)
    end)

    local CardCtl = TabCfg:AddSection({ Title = T("sec_ctl"), Icon = "pause" })
    CardCtl:AddButton({
        Title = T("hide"),
        Description = touch and T("hide_touch") or T("hide_pc"),
        Callback = function() pcall(function() Window:Toggle() end) end,
    })
    CardCtl:AddButton({
        Title = T("stop"),
        Description = T("stop_desc"),
        Hold = true,
        Callback = function() setToggle(false); forceRefresh = true end,
    })

    ------------------------------------------------------------------
    local guiRefs = nil

    return {
        NextUI = NextUI,
        Window = Window,
        guiRefs = guiRefs,
        setStatus = function(s) lblStatus:Set(s) end,
        setBoard  = function(s) paraBoard:Set(T("board"), s) end,
        setChips  = function(n) lblChips:Set(n > 1 and T("chip_many", n) or T("chip_one")) end,
        setEval   = function(s) paraEval:Set(T("analysis"), s) end,
        setDepth  = function(d) prgDepth:Set(math.clamp(d, 0, 12)) end,
        setWm     = function(d) if wmDepth then pcall(function() wmDepth:Set(d) end) end end,
        syncToggle = function(v)
            local ok, cur = pcall(function() return tgBot:Get() end)
            if ok and cur ~= v then pcall(function() tgBot:Set(v) end) end
        end,
        notify = function(kind, title, content)
            pcall(function()
                if kind == "success" then NextUI:Success(title, content)
                elseif kind == "warning" then NextUI:Warning(title, content)
                else NextUI:Info(title, content) end
            end)
        end,
    }
end

----------------------------------------------------------------------
-- 6. Marche / arret
----------------------------------------------------------------------
setToggle = function(on)
    on = on and true or false
    if autoOn == on then return end
    autoOn = on
    lastStation = nil
    firedThisTurn = false
    if UIRef then pcall(UIRef.syncToggle, on) end
end

----------------------------------------------------------------------
-- 7. Boucle du bot
----------------------------------------------------------------------
local function setStatus(s)
    if cache.status == s then return end
    cache.status = s
    if UIRef then pcall(UIRef.setStatus, s) end
end

local function setBoardText(txt)
    if cache.board == txt then return end
    cache.board = txt
    if UIRef then pcall(UIRef.setBoard, txt) end
end

local function setChips(n)
    if cache.chips == n then return end
    cache.chips = n
    if UIRef then pcall(UIRef.setChips, n) end
end

local function setAnalysis(txt)
    if cache.analysis == txt then return end
    cache.analysis = txt
    if UIRef then pcall(UIRef.setEval, txt) end
end

local function ensureGui()
    if forceRebuild then
        forceRebuild = false
        UIRef = nil
        clearOldGui()
        cache.status, cache.board, cache.chips, cache.analysis = nil, nil, nil, nil
    end
    if guiAlive(UIRef) then return false end
    if os.clock() - lastBuild < 1 then return false end
    lastBuild = os.clock()
    cache.status, cache.board, cache.chips, cache.analysis = nil, nil, nil, nil
    local ok, res = pcall(buildUI)
    if ok then
        UIRef = res
        pcall(UIRef.syncToggle, autoOn)
        return true
    end
    UIRef = nil
    warn("[ENI] interface impossible: " .. tostring(res))
    return false
end

local function loop()
    while true do
        task.wait(CONFIG.loopWait)
        MARK.tick = (MARK.tick or 0) + 1
        local ok, err = pcall(function()
            ensureGui()

            if not STATE then STATE = findState() end
            if not STATE then setStatus(T("st_missing")); return end

            if STATE.stationId ~= lastStation then
                lastStation = STATE.stationId
                firedThisTurn = false
                lastCount = -1
                lastRead = 0
                notifiedTurn = false
            end

            if not STATE.isMyTurn then firedThisTurn = false end
            if not STATE.inMatch then lastCount = -1; notifiedTurn = false end

            local now = os.clock()
            local needRead = forceRefresh or STATE.isMyTurn or (now - lastRead > CONFIG.boardEvery)
            local board, count = nil, -1
            if needRead then
                forceRefresh = false
                board, count = readBoard(STATE)
                lastRead = now
                setBoardText(boardToText(board))
                setChips(count)
            end

            if not autoOn then setStatus(T("st_off")); return end
            if not STATE.inMatch or not STATE.seated then
                setStatus(T("st_sit"))
                return
            end
            if not STATE.isMyTurn then setStatus(T("st_opp")); return end
            if not board then
                board, count = readBoard(STATE)
                setBoardText(boardToText(board))
                setChips(count)
            end

            if count ~= lastCount then
                firedThisTurn = false
                lastCount = count
                notifiedTurn = false
            end
            setStatus(T("st_mine"))

            if firedThisTurn or now - lastFire < 0.2 then return end

            local t0 = os.clock()
            local col, score, depth, nodes, ms = searchBest(board)
            local dt = os.clock() - t0

            if CONFIG.autoTune then
                if dt > CONFIG.budget * 1.4 then
                    CONFIG.budget = math.max(CONFIG.budgetMin, CONFIG.budget * 0.85)
                elseif dt < CONFIG.budget * 0.5 then
                    CONFIG.budget = math.min(CONFIG.budgetMax, CONFIG.budget * 1.15)
                end
            end

            local tag, kind
            if score >= 900000 then tag, kind = T("tag_win"), "success"
            elseif score == 400000 then tag, kind = T("tag_double"), "success"
            elseif score == 500000 then tag, kind = T("tag_block"), "warning"
            elseif score <= -900000 then tag, kind = T("tag_lost"), "warning"
            else tag, kind = T("tag_eval", score), "info" end

            if UIRef then
                pcall(UIRef.setDepth, depth)
                pcall(UIRef.setWm, depth)
            end
            setAnalysis(T("an_line", tag, depth, nodes, ms, col))

            if (kind == "success") and not notifiedTurn and UIRef then
                notifiedTurn = true
                pcall(UIRef.notify, kind, tag, T("notif_desc", col, depth))
            end

            local delay = CONFIG.minDelay + math.random() * (CONFIG.maxDelay - CONFIG.minDelay)
            task.wait(delay)

            local _, count2 = readBoard(STATE)
            if STATE.inMatch and STATE.isMyTurn and count2 == count then
                RaycastDrop:FireServer(STATE.stationId, col - 1)
                firedThisTurn = true
                lastFire = os.clock()
                lastCount = count
                setStatus(T("st_drop", col))
            end
        end)
        if not ok then
            cache.status = nil
            setStatus(T("st_error", tostring(err):sub(1, 70)))
        end
    end
end

----------------------------------------------------------------------
-- 8. Demarrage
----------------------------------------------------------------------
ensureGui()
STATE = findState()
setToggle(true)

task.spawn(loop)

getgenv().__ENI_C4 = {
    searchBest = searchBest,
    readBoard = readBoard,
    findState = findState,
    getState = function() return STATE end,
    setToggle = setToggle,
    isOn = function() return autoOn end,
    ui = function() return UIRef end,
    setLang = function(l)
        if STRINGS[l] and l ~= lang then lang = l; forceRebuild = true end
    end,
    getLang = function() return lang end,
}

print("[ENI Auto-Win v4] pret - NextUI")
