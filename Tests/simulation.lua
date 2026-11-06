-- Real modules and compression, isolated WoW clients. Transport: GUILD/WHISPER only.
local time, clients, wire, sent, protectedCalls = 100, {}, {}, 0, 0
local deliveryFilter
local guilds = { "Чиллзон", "Чиллзон Навсегда" }
local modules = { "Libs/LibStub.lua", "Libs/LibDeflate.lua", "Core.lua", "Chat.lua", "Protocol.lua", "Roster.lua", "Network.lua", "Transfers.lua", "Union.lua", "Stats.lua", "Presence.lua", "UI.lua" }
local function expect(value, message) assert(value, message) end
local function eq(a, b, message) assert(a == b, (message or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function UIObject()
    local o = { shown = true, scripts = {}, text = "", checked = false }
    local methods = {}
    function methods:SetScript(k, f) self.scripts[k] = f end
    function methods:HookScript(k, f)
        assert(type(k) == "string" and type(f) == "function", "HookScript requires a script name and callback")
        self.hookCounts = self.hookCounts or {}; self.hookCounts[k] = (self.hookCounts[k] or 0) + 1
        local previous = self.scripts[k]
        self.scripts[k] = function(self, ...) if previous then previous(self, ...) end; f(self, ...) end
    end
    function methods:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end
    function methods:RegisterForClicks(...) self.clickButtons = { ... } end
    function methods:CreateFontString()
        local label = UIObject(); label.parent = self
        self.fontStrings = self.fontStrings or {}; self.fontStrings[#self.fontStrings + 1] = label
        return label
    end
    function methods:CreateTexture()
        local texture = UIObject(); texture.parent = self
        self.textures = self.textures or {}; self.textures[#self.textures + 1] = texture
        return texture
    end
    function methods:SetText(s) self.text = s; if self.lines then self.lines = {} end end
    function methods:GetText() return self.text end
    function methods:SetTextColor(...) self.textColor = { ... } end
    function methods:SetSize(w, h) self.width, self.height = w, h end
    function methods:GetWidth() return self.width or 140 end
    function methods:GetHeight() return self.height or 140 end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:ClearAllPoints() self.point = nil end
    function methods:GetCenter() return self.centerX or 100, self.centerY or 200 end
    function methods:GetEffectiveScale() return self.effectiveScale or 1 end
    function methods:SetTexture(path) self.texture = path end
    function methods:SetVertexColor(...) self.vertexColor = { ... } end
    function methods:SetColorTexture(...) self.colorTexture = { ... }; self.texture = nil end
    function methods:SetNormalTexture(asset)
        assert(asset ~= nil and asset ~= "", "SetNormalTexture requires a texture asset; use ClearNormalTexture to remove it")
        self.normalTexture = asset
    end
    function methods:Enable() self.enabled = true end
    function methods:Disable() self.enabled = false end
    function methods:SetFocus() self.focus = true end
    function methods:ClearFocus() self.focus = false end
    function methods:HasFocus() return self.focus == true end
    function methods:SetChecked(v) self.checked = v end
    function methods:GetChecked() return self.checked end
    function methods:SetShown(v)
        v = v and true or false
        local changed = self.shown ~= v; self.shown = v
        local callback = self.scripts[v and "OnShow" or "OnHide"]
        if changed and callback then callback(self) end
    end
    function methods:IsShown() return self.shown end
    function methods:Show() self:SetShown(true) end
    function methods:Hide() self:SetShown(false) end
    function methods:GetFrameLevel() return 1 end
    function methods:AddMessage(s) self.messages = self.messages or {}; self.messages[#self.messages + 1] = s end
    function methods:AddLine(...) self.lines = self.lines or {}; self.lines[#self.lines + 1] = { ... } end
    function methods:Clear() self.messages = {} end
    function methods:GetScrollOffset() return self.scrollOffset or 0 end
    function methods:SetScrollOffset(v) self.scrollOffset = v end
    function methods:AtBottom() return (self.scrollOffset or 0) == 0 end
    function methods:ScrollToBottom() self.scrollOffset = 0 end
    function methods:ScrollUp() self.scrollOffset = (self.scrollOffset or 0) + 1 end
    function methods:ScrollDown() self.scrollOffset = math.max(0, (self.scrollOffset or 0) - 1) end
    return setmetatable(o, { __index = function(_, k)
        if methods[k] then return methods[k] end
        if k:match("^[A-Z]") then return function() end end
    end })
end
local function NewClient(name, guild, rank, savedDB)
    local c = { name = name, guild = guild, rank = rank or 2, live = true, log = {}, rows = {}, allFrames = {} }
    clients[#clients + 1] = c
    local E = setmetatable({}, { __index = _G }); E._G = E
    E.ChillZoneUnionDB = savedDB
    E.GetTime = function() return time end
    E.GetServerTime = function() return 1800000000 + math.floor(time) end
    E.GetRealmName = function() return "ForeverRealm" end
    E.GetNormalizedRealmName = E.GetRealmName
    E.UnitFactionGroup = function() return "Alliance" end
    E.UnitFullName = function() return name:match("^(%S+)%s+(.+)$") end
    E.GetGuildInfo = function() return c.guild and guilds[c.guild] end
    E.InCombatLockdown = function() return c.combat == true end
    E.GetCursorPosition = function() return c.cursorX or 100, c.cursorY or 200 end
    E.IsShiftKeyDown = function() return c.shift == true end
    E.CanGuildInvite = function()
        if c.invitePermission ~= nil then return c.invitePermission end
        return c.rank <= 1
    end
    E.issecretvalue = function(v) return type(v) == "table" and v.secret == true end
    E.ChatFrame_OpenChat = function(text) c.command = text end
    E.GuildLeave = function() protectedCalls = protectedCalls + 1 end
    E.GuildInvite = E.GuildLeave
    E.C_GuildInfo = { GuildRoster = function() end, Leave = E.GuildLeave, Invite = E.GuildLeave,
        IsGuildOfficer = function() return c.rank <= 1 end }
    E.GetNumGuildMembers = function() return #c.rows end
    E.GetGuildRosterInfo = function(i)
        local r = c.rows[i]
        if r.secret then return { secret = true } end
        return r.name .. "-ForeverRealm", r.rankName or "Участник", r.rank, r.level or 20, "Жрец", r.zone or "Штормград", "public", "PRIVATE", r.online, nil, "PRIEST"
    end
    E.CreateFrame = function(kind, frameName, parent, template)
        local f = UIObject(); c.allFrames[#c.allFrames + 1] = f
        f.frameType, f.parent, f.template = kind, parent, template
        if frameName then E[frameName] = f end
        return f
    end
    E.UIParent, E.Minimap, E.GameTooltip = UIObject(), UIObject(), UIObject()
    local tooltipSetText = E.GameTooltip.SetText
    E.GameTooltip.SetText = function(self, text, ...)
        local count = select("#", ...)
        assert(count == 0 or count >= 3, "GameTooltip:SetText requires complete RGB arguments when a color is supplied")
        if count >= 3 then
            for i = 1, 3 do assert(type(select(i, ...)) == "number", "GameTooltip:SetText color component must be a number") end
        end
        tooltipSetText(self, text)
    end
    E.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            assert(type(owner) == "table" and owner.frameType == "Button", "context menu requires a button owner")
            assert(type(generator) == "function", "context menu requires a description generator")
            local native = c.reuseContextFrame and c.pooledContextFrame or UIObject()
            if c.reuseContextFrame then c.pooledContextFrame = native end
            native:Show()
            local description = { entries = {}, titles = {} }
            local context = { owner = owner, native = native, description = description }
            c.contextMenu = context
            function description:CreateTitle(text)
                assert(type(text) == "string", "menu title must be text"); self.titles[#self.titles + 1] = text
            end
            function description:CreateDivider(...) assert(select("#", ...) == 0, "menu divider takes no arguments") end
            function description:CreateButton(text, callback)
                assert(type(text) == "string" and (callback == nil or type(callback) == "function"), "menu button requires text and optional responder")
                local entry = { text = text, callback = callback, enabled = true }
                function entry:SetEnabled(enabled) assert(type(enabled) == "boolean", "menu enabled state must be boolean"); self.enabled = enabled end
                setmetatable(entry, { __index = function(_, key) error("unsupported menu entry method: " .. tostring(key)) end })
                self.entries[#self.entries + 1] = entry
                return entry
            end
            setmetatable(description, { __index = function(_, key) error("unsupported menu description method: " .. tostring(key)) end })
            generator(owner, description)
            return native
        end,
    }
    E.UISpecialFrames, E.SlashCmdList, E.RAID_CLASS_COLORS = {}, {}, { PRIEST = { r = 1, g = 1, b = 1 } }
    E.DEFAULT_CHAT_FRAME = { AddMessage = function(_, line) c.log[#c.log + 1] = line end }
    E.NUM_CHAT_WINDOWS = 3
    E.ChatTypeInfo = { GUILD = { r = 0.25, g = 1, b = 0.25 } }
    c.chatFrames = { E.DEFAULT_CHAT_FRAME, UIObject(), UIObject() }
    local chatNames = { "Общий", "Гильдия", "Бой" }
    for i, frame in ipairs(c.chatFrames) do E["ChatFrame" .. i], frame.name = frame, chatNames[i] end
    E.GetChatWindowInfo = function(i) return chatNames[i] end
    E.GetChatWindowMessages = function(i) if i == 1 or i == 2 then return "GUILD", "SAY" else return "COMBAT_LOG" end end
    E.date = os.date
    E.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        InChatMessagingLockdown = function() return c.locked == true end,
    }
    local function Send(prefix, message, dist, target, logged)
        assert(#message <= 255, "oversized WoW payload: " .. #message)
        assert(dist == "GUILD" or dist == "WHISPER", "unsupported transport")
        if logged then
            local payload = message:match("^[^~]+~%d+~%d+~(.*)$")
            local first, last = payload:byte(1), payload:byte(-1)
            assert(not (first >= 128 and first <= 191), "logged part starts inside UTF-8 character")
            if payload:sub(1, 1) == "Z" then error("logged player chat was compressed") end
            local tail = payload:match("([\192-\244][\128-\191]*)$")
            if tail then
                local lead = tail:byte(1)
                local need = lead < 224 and 2 or lead < 240 and 3 or 4
                assert(#tail == need, "logged part ends inside UTF-8 character")
            end
        end
        if c.throttle then c.throttle = c.throttle - 1; if c.throttle <= 0 then c.throttle = nil end; return 3 end
        if c.locked then return 11 end
        sent = sent + 1
        wire[#wire + 1] = { from = c, prefix = prefix, text = message, dist = dist, target = target, logged = logged, guild = c.guild }
        return 0
    end
    E.C_ChatInfo.SendAddonMessage = function(...) return Send(...) end
    E.C_ChatInfo.SendAddonMessageLogged = function(prefix, message, dist, target) return Send(prefix, message, dist, target, true) end
    local U = {}
    for _, module in ipairs(modules) do
        local f, error = loadfile("ChillZoneUnion/" .. module)
        assert(f, error); setfenv(f, E); f("ChillZoneUnion", U)
    end
    c.U, c.E = U, E
    U.frame.scripts.OnEvent(U.frame, "ADDON_LOADED", "ChillZoneUnion")
    return c
end
local function SetRosters(extra)
    for _, c in ipairs(clients) do
        if c.guild then
            c.rows = {}
            for _, p in ipairs(clients) do if p.guild == c.guild then c.rows[#c.rows + 1] = { name = p.name, rank = p.rank, online = p.live, level = 35 } end end
            for i = 1, extra or 0 do
                c.rows[#c.rows + 1] = { name = "Игрок" .. i .. " Фамилия" .. i, rank = 2, online = false, level = i % 60 + 1, zone = "Лес Элвинн" }
            end
            c.U.ReadRoster()
        end
    end
end
local function Step(seconds, duplicate)
    for i = 1, math.ceil(seconds * 10) do
        time = time + 0.1
        for _, c in ipairs(clients) do if c.live then c.U.frame.scripts.OnUpdate(c.U.frame, 0.1) end end
        local batch = wire; wire = {}
        for _, p in ipairs(batch) do
            for _, c in ipairs(clients) do
                if c.live and ((p.dist == "GUILD" and c.guild == p.guild) or (p.dist == "WHISPER" and c.U.Fold(c.name) == c.U.Fold(p.target or ""))) and (not deliveryFilter or deliveryFilter(p, c)) then
                    local event = p.logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON"
                    c.U.frame.scripts.OnEvent(c.U.frame, event, p.prefix, p.text, p.dist, p.from.name .. "-ForeverRealm")
                    if duplicate then c.U.frame.scripts.OnEvent(c.U.frame, event, p.prefix, p.text, p.dist, p.from.name .. "-ForeverRealm") end
                end
            end
        end
    end
end
local function Count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local a = NewClient("Ази Фелл", 1, 0)
local a2 = NewClient("Борис Тихий", 1, 2)
local b = NewClient("Антон Другой", 2, 0)
local b2 = NewClient("Василий Второй", 2, 1)
SetRosters(0)
for _, c in ipairs(clients) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
Step(5)
eq(a.U.GatewayName(), a.name, "source election")
eq(b.U.GatewayName(), b.name, "destination election")
expect(not a2.U.Link(b.name), "ordinary member initiated guild setup")
expect(a.U.Link(b2.name), "guild master could not start setup")
Step(50, true)
expect(a.U.Connected() and b.U.Connected(), "link not established")
expect(a2.U.Connected() and b2.U.Connected(), "guildmates did not learn the link")
eq(Count(a2.U.db.rosters[2].rows), 2, "remote roster not shared")
eq(Count(b2.U.db.rosters[1].rows), 2, "reverse roster not shared")
print("PASS one-click GM-to-officer handshake, no target confirmation, two-way roster")

local before = #b2.U.history
a2.U.SendChat("Привет двум гильдиям! |Hitem:123|h[Предмет]|h"); Step(8, true)
eq(#b2.U.history, before + 1, "remote chat duplicate or missing")
eq(#a.U.history, 1, "local chat duplicate")
eq(#a2.U.history, 1, "self echo duplicate")
eq(b2.U.history[#b2.U.history].name, a2.name, "chat author changed")
print("PASS shared chat and duplicate delivery")
local long = string.rep("Длинное сообщение ", 20)
local lengthBefore = #b2.U.history
a2.U.SendChat(long); Step(12, true)
eq(#b2.U.history, lengthBefore + 1, "long Cyrillic chat missing")
eq(b2.U.history[#b2.U.history].text, a2.U.Trim(long), "long chat corrupted")
print("PASS UTF-8 plaintext fragmentation for logged chat")

for _, c in ipairs({ a, a2 }) do c.U.frame.scripts.OnEvent(c.U.frame, "CHAT_MSG_GUILD", "Обычный гильдейский чат", a2.name .. "-ForeverRealm") end
Step(8, true)
eq(#b2.U.history, before + 3, "native /g relay")
eq(#a.U.history, 3, "native own line duplicate")
local h = #b2.U.history
a.U.frame.scripts.OnEvent(a.U.frame, "CHAT_MSG_GUILD", { secret = true }, { secret = true }); Step(3)
eq(#b2.U.history, h, "secret native chat leaked")
print("PASS native chat bridge and secret values")

SetRosters(1000)
a.U.snapshotDue, b.U.snapshotDue = 0, 0
Step(130, true)
eq(Count(a2.U.db.rosters[2].rows), 1002, "large remote roster incomplete")
eq(Count(b2.U.db.rosters[1].rows), 1002, "large reverse roster incomplete")
expect(a.U.QueueSize() < 30 and b.U.QueueSize() < 30, "roster queue never drained")
print("PASS 2,004 members, compression and multipart snapshots")

local keep = a.U.own
a.rows[1].secret = true
expect(not a.U.ReadRoster(), "partial secret roster accepted")
eq(a.U.own, keep, "partial roster overwrote last complete snapshot")
a.rows[1].secret = nil
print("PASS incomplete roster preserves cached membership")

local old = #b2.U.history
a.throttle = 2
a.U.SendChat("Сообщение после ограничения"); Step(18)
eq(#b2.U.history, old + 1, "throttled message dropped")
a.locked = true
a.U.SendChat("Нельзя отправить во время блокировки"); Step(1)
eq(#b2.U.history, old + 1, "lockdown chat was sent")
a.locked = false
print("PASS retry after API throttling and chat lockdown")

local falseTicket = { 1, "123.456", a2.name, 2, a.name, a.U.stamp() }
expect(not a.U.TransferMessage("TICKET", falseTicket, a2.name, false), "forged guild master accepted")
a.U.CreateTransfer(a2.name); Step(12)
local id
for k, t in pairs(a2.U.Tickets()) do if t.member == a2.name then id = k end end
expect(id and b2.U.Tickets()[id], "transfer proposal did not reach both guilds")
a2.U.AcceptTransfer(id, true); Step(8)
eq(b2.U.Tickets()[id].state, "accepted", "consent did not arrive")
a2.U.LeaveForTransfer(id)
eq(a2.command, "/gquit", "native leave command not prepared")
eq(protectedCalls, 0, "an automatic protected action occurred")
a2.guild = nil
a2.U.frame.scripts.OnEvent(a2.U.frame, "PLAYER_GUILD_UPDATE", "player")
Step(10)
eq(b2.U.Tickets()[id].state, "ready", "guildless READY not relayed")
b2.U.InviteTransfer(id)
eq(b2.command, "/ginvite " .. a2.name, "native invite command missing")
eq(protectedCalls, 0, "invite executed without player's Enter")
a2.guild = 2
a2.U.frame.scripts.OnEvent(a2.U.frame, "PLAYER_GUILD_UPDATE", "player")
SetRosters(1000); Step(5)
eq(a2.U.Tickets()[id].state, "done", "join not recognized")
eq(b2.U.Tickets()[id].state, "done", "destination not completed")
print("PASS master permission, consent, guildless transfer, manual commands")

eq(a.U.me, "Ази Фелл", "surname was mistaken for a realm")
eq(a.U.Name("Ази Фелл-ForeverRealm"), "Ази Фелл", "realm suffix normalization")
local count = #b.U.history
b.U.Receive(b.U.PREFIX, "100.1~1~1~RCHAT~" .. b.U.Pack({ 1, "Ази Фелл", "fake" }), "WHISPER", "Посторонний Игрок-ForeverRealm")
eq(#b.U.history, count, "stranger injected chat")
for _, raw in ipairs({ "1.1~0~1~RCHAT~", "1.1~1~999~Zbad", "oops", "1.1~1~1~Zgarbage", "1.1~1~1~RCHAT~999999:bad" }) do
    b.U.Receive(b.U.PREFIX, raw, "WHISPER", a.name)
end
print("PASS full names, malformed packets, untrusted senders")
eq(a.U.Fold("АЗИ ЁЛКА"), "ази ёлка", "Cyrillic search folding")
eq(select("#", a.U.SafeDisplay("А|Б\nВ")), 1, "display escaping returned a replacement count as an extra native API argument")
eq(a.U.SafeDisplay("А|Б\nВ"), "А||Б В", "display escaping changed text content")
expect(a.U.ChatText("|cff00ff00|Hitem:123:0|h[Предмет]|h|r"):find("|Hitem:123:0|h", 1, true), "item hyperlink lost")
expect(not a.U.ChatText("|Tbad:9999|t"):find("|Tbad", 1, true) or a.U.ChatText("|Tbad:9999|t"):find("||Tbad", 1, true), "arbitrary texture not escaped")

for _, c in ipairs(clients) do
    c.U.Toggle(); c.U.RefreshChat(); c.U.Refresh()
    local window, foundTabs, close = c.E.ChillZoneUnionWindow, {}, nil
    expect(window and window.scripts.OnShow and window.scripts.OnUpdate, "window construction stopped before content and refresh handlers were ready")
    for _, f in ipairs(c.allFrames) do
        local title = f.text:match("^Общий чат") or f.text
        if f.parent == window and (title == "Переходы" or title == "Связь" or title == "Общий чат" or title == "Состав") then
            expect(type(f.scripts.OnClick) == "function", "tab has no click handler: " .. f.text)
            foundTabs[title] = true; f.scripts.OnClick(f)
        end
        if f.parent == window and f.template == "UIPanelCloseButton" then close = f end
    end
    for _, title in ipairs({ "Состав", "Общий чат", "Переходы", "Связь" }) do expect(foundTabs[title], "missing tab: " .. title) end
    expect(close and type(close.scripts.OnClick) == "function", "window close button missing")
    close.scripts.OnClick(close); expect(not window:IsShown(), "window close button did not close the panel")
    c.U.Toggle(); expect(window:IsShown(), "window could not reopen after close")
end
print("PASS UI construction and tabs")
do
    local input
    for _, f in ipairs(a2.allFrames) do if f.frameType == "EditBox" and f.width == 780 then input = f end end
    expect(input, "chat input not found")
    a2.locked = true; input:SetText("Не потерять черновик")
    input.scripts.OnEnterPressed(input)
    eq(input:GetText(), "Не потерять черновик", "rejected chat erased the draft")
    a2.locked = false
    input.scripts.OnEnterPressed(input)
    eq(input:GetText(), "", "accepted chat did not clear input")
    Step(8)
end

local a3 = NewClient("Григорий Третий", 1, 1)
SetRosters(1000); a3.U.frame.scripts.OnEvent(a3.U.frame, "PLAYER_LOGIN"); Step(30)
a.live = false
SetRosters(1000); Step(100)
eq(a3.U.GatewayName(), a3.name, "new source bridge not elected")
expect(a3.U.Connected(), "connection not recovered after source bridge left")
local last = #b2.U.history
a3.U.SendChat("После смены посредника"); Step(12)
eq(#b2.U.history, last + 1, "chat failed after failover")
print("PASS automatic bridge failover")

-- A new alphabetically earlier member must not preempt an established bridge.
do
    local early = NewClient("Аарон Первый", 1, 2)
    SetRosters(1000); early.U.frame.scripts.OnEvent(early.U.frame, "PLAYER_LOGIN")
    Step(35)
    eq(a3.U.GatewayName(), a3.name, "working gateway was preempted by newcomer")
    eq(early.U.GatewayName(), a3.name, "newcomer did not adopt working gateway")
    expect(early.U.Connected(), "new installation did not receive connection automatically")
    local n = #b2.U.history
    early.U.SendChat("Новый участник без настройки"); Step(12)
    eq(#b2.U.history, n + 1, "new participant not connected to shared chat")
end
print("PASS stable gateway and automatic setup of new installations")

-- Entirely fresh worlds cover startup and handshakes without inherited contacts.
local function FreshPair()
    clients, wire, deliveryFilter = {}, {}, nil
    time = time + 100
    local gm = NewClient("Алексей Глава", 1, 0)
    local officer = NewClient("Борис Офицер", 2, 1)
    SetRosters(0)
    for _, c in ipairs(clients) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    Step(3)
    return gm, officer
end
do
    local gm, officer = FreshPair()
    expect(gm.U.Link(officer.name), "initial setup rejected")
    local dropped = 0
    deliveryFilter = function(p, recipient)
        if recipient == gm and p.from == officer and p.dist == "WHISPER" and p.text:find("challenge", 1, true) and dropped == 0 then dropped = dropped + 1; return false end
        return true
    end
    Step(55, true)
    eq(dropped, 1, "loss test did not drop handshake packet")
    expect(gm.U.Connected() and officer.U.Connected(), "lost handshake response was not retried")
    deliveryFilter = nil
end
print("PASS handshake retry after response loss")
do
    local gm, otherGM = FreshPair()
    otherGM.rank = 0; SetRosters(0)
    expect(gm.U.Link(otherGM.name), "first simultaneous link rejected")
    expect(otherGM.U.Link(gm.name), "second simultaneous link rejected")
    Step(55, true)
    expect(gm.U.Connected() and otherGM.U.Connected(), "simultaneous setup requests stalled")
end
print("PASS simultaneous one-click setup")
do
    local gm, ordinary = FreshPair()
    ordinary.rank = 2; SetRosters(0)
    expect(gm.U.Link(ordinary.name), "ordinary recipient probe rejected at source")
    Step(65)
    expect(not gm.U.Connected(), "ordinary recipient accepted officer setup")
    expect(gm.U.SetupState().state == "error", "non-officer failure not shown")
end
print("PASS officer requirement and visible setup error")
do
    local gm, officer = FreshPair()
    expect(gm.U.Link("Нет Такого"), "offline-target setup was not started")
    Step(85)
    expect(not gm.U.Connected(), "offline target connected")
    eq(gm.U.SetupState().state, "error", "offline-target timeout not visible")
end
print("PASS offline recipient timeout")
do
    local gm, officer = FreshPair()
    officer.invitePermission = false
    expect(gm.U.Link(officer.name), "setup with real officer was rejected")
    Step(50)
    expect(gm.U.Connected(), "officer without invitation rights could not connect guilds")
    expect(not officer.U.CanInvite(), "officer acquired invitation rights from setup")
end
print("PASS officer setup without unrelated invitation permission")
do
    local gm, officer = FreshPair()
    expect(gm.U.Link("борис офицер"), "lowercase target setup was rejected")
    Step(55)
    expect(gm.U.Connected() and officer.U.Connected(), "lowercase officer name did not connect")
    eq(gm.U.db.setupContact, officer.name, "canonical officer name was not saved")
end
print("PASS case-insensitive officer name")
do
    clients, wire, deliveryFilter = {}, {}, nil
    time = time + 100
    local member = NewClient("Аарон Участник", 1, 2)
    local gm = NewClient("Борис Глава", 1, 0)
    local officer = NewClient("Виктор Офицер", 2, 1)
    SetRosters(0)
    for _, c in ipairs(clients) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    Step(5)
    eq(gm.U.GatewayName(), member.name, "test setup did not select separate source gateway")
    expect(gm.U.Link(officer.name), "non-gateway guild master could not start setup")
    Step(55)
    expect(gm.U.Connected() and member.U.Connected() and officer.U.Connected(), "master setup did not propagate to its elected gateway")
end
print("PASS setup by guild master who is not the gateway")
do
    local gm, officer = FreshPair()
    local oldOwn = gm.U.own
    gm.U.own = {}; gm.rows[1].secret = true
    -- Established transport is not proof that the first complete native roster is ready.
    gm.U.AddContact(officer.name, 2); officer.U.AddContact(gm.name, 1)
    gm.U.remote = { name = officer.name, at = time }
    gm.U.snapshotDue, gm.U.lastSnapshot = 0, nil
    for i = 1, 8 do
        gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
        Step(1)
    end
    expect(not gm.U.lastSnapshot, "failed initial scan advanced lastSnapshot")
    expect(gm.U.snapshotDue < time + 10, "failed scan postponed retry three minutes")
    gm.rows[1].secret = nil
    for i = 1, 15 do
        gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
        Step(1)
    end
    expect(gm.U.lastSnapshot ~= nil, "ready roster was starved by continuing events")
    expect(officer.U.db.rosters[1], "first snapshot did not arrive promptly after readiness")
end
print("PASS delayed initial roster and continuous roster events")
do
    local gm, officer = FreshPair()
    gm.U.ClearQueue()
    for i = 1, 1499 do expect(gm.U.Queue("TEST", { "x" }, "GUILD", nil, false), "could not fill test queue") end
    local n, history = gm.U.QueueSize(), #gm.U.history
    expect(not gm.U.SendChat(string.rep("Длинный текст ", 20)), "full queue accepted a multipart chat")
    eq(gm.U.QueueSize(), n, "partial multipart chat was left in full queue")
    eq(#gm.U.history, history, "failed queueing echoed an unsent message")
    gm.U.ClearQueue()
end
print("PASS atomic queue capacity and rejected-message echo")

local function LinkedPair()
    local gm, officer = FreshPair()
    expect(gm.U.Link(officer.name), "could not initiate linked test pair")
    Step(50)
    expect(gm.U.Connected() and officer.U.Connected(), "test pair not connected")
    return gm, officer
end
local function FindText(c, needle)
    local n = 0
    for _, h in ipairs(c.U.history) do if h.text == needle then n = n + 1 end end
    return n
end
local function Kind(p)
    local _, part, count, encoded = p.text:match("^([^~]+)~(%d+)~(%d+)~(.*)$")
    if tonumber(part) ~= 1 or tonumber(count) ~= 1 then return nil end
    local raw
    if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
    elseif encoded:sub(1, 1) == "Z" then
        local D = p.from.U.Deflate
        local compressed = D:DecodeForWoWAddonChannel(encoded:sub(2))
        raw = compressed and D:DecompressDeflate(compressed)
    end
    return raw and raw:match("^([A-Z]+)~")
end
do
    local gm, officer = LinkedPair()
    local row = { guild = 1, name = gm.name, text = "Тест вкладок", time = gm.U.stamp(), status = "delivered" }
    local main, guild = #officer.log, #(officer.chatFrames[2].messages or {})
    eq(officer.U.DisplayChat(row, false), 2, "auto routing did not use both guild-enabled tabs")
    eq(#officer.log, main + 1, "main guild-enabled tab missed message")
    eq(#officer.chatFrames[2].messages, guild + 1, "guild tab missed message")
    eq(#(officer.chatFrames[3].messages or {}), 0, "combat-only tab received guild text")
    expect(officer.log[#officer.log]:find("|Hplayer:" .. gm.name, 1, true), "author is not clickable")
    expect(officer.log[#officer.log]:find("[Гильдия]", 1, true), "guild-style prefix missing")
    expect(not officer.log[#officer.log]:find("[Чиллзон Навсегда]", 1, true), "long separate guild prefix retained")
    expect(officer.U.SetChatWindow("гильдия"), "could not select chat tab case-insensitively")
    main, guild = #officer.log, #officer.chatFrames[2].messages
    eq(officer.U.DisplayChat(row, false), 1, "chosen tab ignored")
    eq(#officer.log, main, "chosen-tab message leaked into unselected main tab")
    eq(#officer.chatFrames[2].messages, guild + 1, "chosen tab missed message")
    eq(officer.U.DisplayChat(row, true), 0, "native guild line duplicated")
    row.replayed = true
    eq(officer.U.DisplayChat(row, false), 0, "history catchup spammed native tabs")
    officer.U.SetGuildBadge(true)
    expect(officer.U.ChatLine(row):find("[1]", 1, true), "optional guild marker missing")
    officer.U.SetChatWindow(nil)
end
print("PASS native-style chat tabs, player links, optional badges and no duplicate native/replay output")
do
    local gm, officer = LinkedPair()
    expect(gm.U.SendChat("Два одинаковых"), "first identical message refused")
    Step(3)
    expect(gm.U.SendChat("Два одинаковых"), "second identical message refused")
    Step(6, true)
    eq(FindText(officer, "Два одинаковых"), 2, "legitimate identical texts were deduplicated")
    local ids = {}
    for _, h in ipairs(officer.U.history) do if h.text == "Два одинаковых" then ids[h.id] = true end end
    eq(Count(ids), 2, "logical message IDs were reused")
end
print("PASS stable message IDs preserve repeated legitimate text")
do
    local gm, officer = LinkedPair()
    local dropped = 0
    deliveryFilter = function(p, recipient)
        if recipient == gm and p.from == officer and Kind(p) == "ACK" and dropped == 0 then dropped = 1; return false end
        return true
    end
    expect(gm.U.SendChat("Потерянное подтверждение"), "message refused")
    Step(18, true)
    eq(dropped, 1, "ACK-loss test did not drop an ACK")
    eq(FindText(officer, "Потерянное подтверждение"), 1, "ACK retry produced a duplicate message")
    local last = gm.U.history[#gm.U.history]
    eq(last.status, "delivered", "gateway acceptance was not acknowledged after retry")
    deliveryFilter = nil
end
print("PASS acknowledgement retry without duplicate chat")
do
    local gm, officer = LinkedPair()
    deliveryFilter = function(p) return p.dist ~= "WHISPER" end
    expect(gm.U.SendChat("Короткий обрыв"), "temporary outage rejected local message")
    Step(8)
    eq(FindText(officer, "Короткий обрыв"), 0, "outage filter did not block message")
    eq(gm.U.history[#gm.U.history].status, "pending", "temporary outage not shown pending")
    deliveryFilter = nil; Step(18, true)
    eq(FindText(officer, "Короткий обрыв"), 1, "short-outage message was not recovered")
    eq(gm.U.history[#gm.U.history].status, "delivered", "recovered message not acknowledged")
end
print("PASS bounded outbox recovers a short interruption")
do
    local gm, officer = LinkedPair()
    deliveryFilter = function(p) return p.dist ~= "WHISPER" end
    expect(gm.U.SendChat("Истекшее сообщение"), "long-outage message refused")
    Step(38)
    eq(gm.U.history[#gm.U.history].status, "local-only", "expired message not marked unconfirmed")
    eq(FindText(officer, "Истекшее сообщение"), 0, "expired message reached remote during blocked link")
    deliveryFilter = nil; Step(100)
    eq(FindText(officer, "Истекшее сообщение"), 0, "expired message unexpectedly leaked through replay or queued fragments")
end
print("PASS expired messages cannot be sent minutes later")
do
    local gm, officer = LinkedPair()
    expect(gm.U.SendChat("История до входа"), "history source message refused")
    Step(10)
    local original
    for _, h in ipairs(officer.U.history) do if h.text == "История до входа" then original = h end end
    expect(original and original.id, "history source has no stable ID")
    local newcomer = NewClient("Гость Поздний", 2, 2)
    SetRosters(0); newcomer.U.frame.scripts.OnEvent(newcomer.U.frame, "PLAYER_LOGIN")
    Step(55)
    local recovered
    for _, h in ipairs(newcomer.U.history) do if h.text == "История до входа" then recovered = h end end
    expect(recovered, "new installation did not receive recent guild history")
    eq(recovered.id, original.id, "history changed logical identity")
    eq(recovered.time, original.time, "history changed original timestamp")
    expect(recovered.replayed, "backfill not distinguished from live traffic")
    for _, line in ipairs(newcomer.log) do
        expect(not line:find("История до входа", 1, true), "backfill spammed main chat")
        expect(not line:find("Посредник:", 1, true) and not line:find("загружен", 1, true), "ordinary startup printed technical chatter")
    end
end
print("PASS recent history backfill preserves time and stays silent")
do
    local gm, officer = LinkedPair()
    gm.rows[1].zone, gm.rows[1].level = "Западный Край", 42
    gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
    Step(12)
    eq(officer.U.db.rosters[1].rows[gm.name].zone, "Западный Край", "fast location update missing")
    eq(officer.U.db.rosters[1].rows[gm.name].level, 42, "fast level update missing")
    gm.rows[#gm.rows + 1] = { name = "Гость Персонаж", rank = 2, level = 20, online = true }
    gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
    Step(12)
    expect(officer.U.db.rosters[1].rows["Гость Персонаж"].online, "membership delta missing")
    gm.rows[2].online = false; gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
    Step(12)
    expect(not officer.U.db.rosters[1].rows["Гость Персонаж"].online, "online delta missing")
    expect(officer.U.RosterFresh(1), "active heartbeat not treated as fresh")
    deliveryFilter = function(p) return p.dist ~= "WHISPER" end
    Step(30)
    expect(not officer.U.RosterFresh(1), "stale cached presence remained marked current")
    eq(Count(officer.U.db.rosters[1].rows), 2, "stale presence erased cached membership")
    deliveryFilter = nil; Step(75)
    expect(officer.U.RosterFresh(1), "presence did not become fresh after recovery")
end
print("PASS fast membership/online/location deltas and honest stale presence")
do
    local gm, officer = LinkedPair()
    local priorFull = officer.U.db.rosters[1].fullAt
    local dropped = 0
    deliveryFilter = function(p, recipient)
        if p.from == gm and recipient == officer and p.dist == "WHISPER" and Kind(p) == "DELTA" and dropped == 0 then dropped = 1; return false end
        return true
    end
    gm.rows[1].level = 51; gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
    Step(32)
    eq(dropped, 1, "delta-gap test did not drop a delta")
    eq(officer.U.db.rosters[1].rows[gm.name].level, 51, "revision gap was not repaired by a full snapshot")
    expect(officer.U.db.rosters[1].fullAt > priorFull, "revision gap did not request a fresh baseline")
    deliveryFilter = nil
end
print("PASS missing roster revision triggers repair")
do
    local gm, officer = LinkedPair()
    expect(gm.U.SetAnnouncement("Сбор в 20:00"), "GM announcement rejected")
    Step(15)
    eq(officer.U.GetAnnouncement().text, "Сбор в 20:00", "common announcement not synchronized")
    expect(not officer.U.SetAnnouncement("Подмена"), "ordinary officer acquired GM announcement powers")
    expect(gm.U.SetAnnouncement("Изменено"), "announcement update rejected")
    expect(gm.U.SetAnnouncement(""), "announcement clear rejected")
    Step(15)
    expect(not gm.U.GetAnnouncement() and not officer.U.GetAnnouncement(), "announcement tombstone did not clear both guilds")
    officer.U.db.memberNotices = true
    local before = #officer.log
    gm.rows[#gm.rows + 1] = { name = "Новый Участник", rank = 2, level = 15, online = true }
    gm.U.frame.scripts.OnEvent(gm.U.frame, "GUILD_ROSTER_UPDATE")
    Step(15)
    local joined = 0
    for i = before + 1, #officer.log do if officer.log[i]:find("Новый Участник вступил", 1, true) then joined = joined + 1 end end
    eq(joined, 1, "membership notice missing or repeated")
end
print("PASS shared announcement, GM permission, clearing and optional member notices")
do
    local gm, officer = LinkedPair()
    gm.U.OpenRoster()
    local pane
    for _, frame in ipairs(gm.allFrames) do if frame.frameType == "ScrollingMessageFrame" then pane = frame end end
    expect(pane, "shared history pane not created")
    pane:SetScrollOffset(10)
    gm.U.Chat(1, "Друг Игрок", "Не прыгать вниз", false, { id = "1:scroll:test", at = gm.U.stamp(), status = "pending" })
    eq(pane:GetScrollOffset(), 11, "new message changed the reader's place")
    gm.U.ChatStatus("1:scroll:test", "delivered")
    eq(pane:GetScrollOffset(), 11, "ACK redraw moved scroll position")
    expect(type(gm.U.OpenRoster) == "function", "bindable roster action missing")
    eq(gm.U.GUILD_LEADERS[1], "Вован Дубан", "configured leader name missing")
    local named = NewClient("Вован Дубан", 1, 2)
    SetRosters(0)
    expect(not named.U.IsMaster(), "configured name alone granted GM powers")
end
print("PASS scroll preservation, roster binding action and leader name without privilege bypass")
do
    local gm, officer = LinkedPair()
    expect(gm.U.SendChat("История сохранилась на другом берегу"), "source history message refused")
    Step(10)
    local id, at
    for _, h in ipairs(gm.U.history) do if h.text == "История сохранилась на другом берегу" then id, at = h.id, h.time end end
    expect(id, "source history missing")
    gm.U.history, gm.U.chatByID, gm.U.chatSeen = {}, {}, {}
    gm.U.RequestHistory(); Step(40)
    local recovered
    for _, h in ipairs(gm.U.history) do if h.id == id then recovered = h end end
    expect(recovered and recovered.replayed, "remote cache did not restore source-side conversation")
    eq(recovered.time, at, "source-side recovery changed original time")
    officer.rank = 0; SetRosters(0); Step(12)
    expect(officer.U.SetAnnouncement("Объявление второй гильдии"), "second GM announcement rejected")
    Step(15)
    eq(gm.U.GetAnnouncement().text, "Объявление второй гильдии", "opposite cache missed announcement")
    officer.U.db.announcement = nil
    gm.U.ExtensionSync(); Step(18)
    expect(officer.U.GetAnnouncement(), "cached foreign-origin announcement was not returned")
    eq(officer.U.GetAnnouncement().text, "Объявление второй гильдии", "returned announcement changed text")
end
print("PASS surviving opposite-guild cache restores full conversation and announcement")
for _, rank in ipairs({ 0, 1, 2 }) do
    clients, wire, deliveryFilter = {}, {}, nil
    time = time + 100
    local c = NewClient("Тест Ранг" .. rank, 1, rank)
    c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
    local b = c.U.minimapButton
    expect(b and b.icon, "minimap button missing for rank" .. rank)
    expect(b.icon.texture:find("Media\\minimap", 1, true), "custom guild icon not used")
    b.scripts.OnClick(b, "LeftButton")
    local window = c.E.ChillZoneUnionWindow
    expect(window and window:IsShown(), "fresh player could not open guild window")
    local function StatusDot(parent)
        for _, texture in ipairs(parent.textures or {}) do
            if type(texture.texture) == "string" and texture.texture:find("Media\\status-dot", 1, true) then return texture end
        end
    end
    expect(not StatusDot(b), "minimap button still has an unwanted connection status dot")
    for _, texture in ipairs(b.textures or {}) do
        expect(not texture.colorTexture, "minimap button still has a solid-color status overlay")
    end
    local headerStatus
    for _, frame in ipairs(c.allFrames) do
        if frame.parent == window then headerStatus = headerStatus or StatusDot(frame) end
    end
    expect(headerStatus, "circular connection status texture missing from header")
    local function ExpectStatus(r, g, blue)
        expect(not headerStatus.colorTexture, "SetColorTexture replaced the circular header status image with a square")
        expect(headerStatus.vertexColor, "header status texture has no color tint")
        for i, expected in ipairs({ r, g, blue, 1 }) do eq(headerStatus.vertexColor[i], expected, "header status tint mismatch") end
    end
    local oldConnected = c.U.Connected
    c.U.Connected = function() return true end; c.U.Refresh(); ExpectStatus(0.3, 0.85, 0.57)
    c.E.GameTooltip.lines = {}; b.scripts.OnEnter(b)
    eq(c.E.GameTooltip.lines[1][1], "Союз на связи", "minimap tooltip lost connection status")
    for _, line in ipairs(c.E.GameTooltip.lines) do
        expect(not line[1]:find("Перетащите", 1, true) and not line[1]:find("сбросить положение", 1, true), "minimap tooltip still shows unwanted movement instructions")
    end
    expect(c.E.GameTooltip:IsShown(), "minimap connection tooltip not shown")
    b.scripts.OnLeave(b); expect(not c.E.GameTooltip:IsShown(), "minimap tooltip did not hide")
    c.U.Connected = oldConnected; c.U.Refresh(); ExpectStatus(0.7, 0.72, 0.76)
    local searchBox, contactBox, connect
    for _, frame in ipairs(c.allFrames) do
        if frame.frameType == "EditBox" and frame.width == 280 then searchBox = frame end
        if frame.frameType == "EditBox" and frame.width == 350 then contactBox = frame end
        if frame.text == "Подключить" then connect = frame end
    end
    expect(searchBox.parent:IsShown() and not contactBox.parent:IsShown(), "minimap did not open the shared roster for fresh player")
    b.scripts.OnClick(b, "LeftButton")
    expect(not window:IsShown(), "second left click did not hide roster")
    b.scripts.OnClick(b, "RightButton")
    expect(window:IsShown() and contactBox.parent:IsShown(), "right click did not open settings")
    SetRosters(0); c.U.Refresh()
    if rank ~= 0 then expect(connect.enabled == false, "minimap button granted setup permission to ordinary player/officer") end
    window:Hide(); c.locked = true
    b.scripts.OnClick(b, "LeftButton")
    expect(window:IsShown() and searchBox.parent:IsShown(), "chat lockdown blocked opening the roster")
    c.locked = false; window:Hide()
    c.E.Minimap.effectiveScale = 2; c.cursorX, c.cursorY = 200, 600
    b.scripts.OnDragStart(b)
    expect(math.abs(c.U.db.minimapAngle - 90) < 0.001, "drag cursor ignored effective scale")
    b.scripts.OnClick(b, "LeftButton")
    expect(not window:IsShown(), "dragging triggered a click")
    b.scripts.OnDragStop(b); b.scripts.OnClick(b, "RightButton")
    expect(not window:IsShown(), "drag release triggered a settings click")
    Step(0.2); b.scripts.OnClick(b, "LeftButton")
    expect(window:IsShown(), "click suppression did not expire")
    c.shift = true; b.scripts.OnClick(b, "RightButton"); c.shift = false
    eq(c.U.db.minimapAngle, 225, "reset gesture did not restore default angle")
    for _, bad in ipairs({ "broken", math.huge, 0/0 }) do
        c.U.db.minimapAngle = bad
        b.scripts.OnUpdate(b, 2.1)
        eq(c.U.db.minimapAngle, 225, "invalid saved minimap angle not repaired")
    end
end
print("PASS custom minimap button for every rank, fresh members, settings, drag scale and click suppression")

local function UnionWorld()
    clients, wire, deliveryFilter = {}, {}, nil
    time = time + 100
    local owner = NewClient("Вован Дубан", 1, 0)
    local otherGM = NewClient("Борис Навсегда", 2, 0)
    local member = NewClient("Участник Дальний", 2, 2)
    local homeBackup = NewClient("Яков Чиллзон", 1, 1)
    local remoteBackup = NewClient("Яков Навсегда", 2, 1)
    SetRosters(0)
    for _, c in ipairs(clients) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    Step(5)
    expect(owner.U.Link(otherGM.name), "union owner could not establish ordinary guild link")
    Step(50)
    for _, c in ipairs(clients) do expect(c.U.Connected(), "union transfer fixture not connected") end
    return owner, otherGM, member, homeBackup, remoteBackup
end
local function MemberTicket(c, name, excluded)
    for id, ticket in pairs(c.U.Tickets()) do if ticket.member == name and id ~= excluded then return id, ticket end end
end
local function SelectRosterMember(c, name, guild)
    c.U.OpenRoster()
    local move, selected
    for _, frame in ipairs(c.allFrames) do
        if frame.row and frame.row.name == name and frame.row.guild == guild then frame.scripts.OnClick(frame); selected = true end
        if frame.text == "Предложить переход" then move = frame end
    end
    expect(selected and move, "remote member or transfer action missing from shared roster")
    return move
end
do
    local owner, otherGM, member, homeBackup = UnionWorld()
    eq(owner.U.UNION_LEADER, owner.name, "union owner configuration missing")
    expect(owner.U.IsUnionLeader() and member.U.IsUnionLeader(owner.name, 1), "configured native GM was not recognized across guilds")
    expect(not otherGM.U.IsUnionLeader(), "another native GM acquired union-wide transfer authority")
    expect(not otherGM.U.CreateTransfer(homeBackup.name, 1), "another native GM proposed a remote transfer")
    owner.rank = 2; owner.U.own[owner.name].rank = 2
    expect(not owner.U.IsUnionLeader() and not owner.U.IsMaster() and not owner.U.CanInvite(), "configured name granted native rights after demotion")
    expect(not owner.U.CreateTransfer(member.name, 2), "configured name without rank0 proposed a remote transfer")
    owner.rank = 0; owner.U.own[owner.name].rank = 0
    local cache = owner.U.db.rosters[2]
    local cachedAt = cache.at; cache.at = owner.U.stamp() - 601
    expect(not owner.U.CreateTransfer(member.name, 2), "stale remote roster authorized a transfer")
    cache.at = cachedAt
    local target = cache.rows[member.name]
    target.online = false
    expect(not owner.U.CreateTransfer(member.name, 2), "offline remote member received a transfer request")
    target.online = true
    expect(not owner.U.CreateTransfer(otherGM.name, 2), "remote guild master was offered a transfer")

    local disabled = SelectRosterMember(otherGM, homeBackup.name, 1)
    expect(disabled.enabled == false, "another native GM received the remote roster transfer action")
    local move = SelectRosterMember(owner, member.name, 2)
    expect(move.enabled == true, "configured union owner cannot propose a transfer from a remote roster row")
    move.scripts.OnClick(move); Step(12, true)
    local declinedID, declined = MemberTicket(member, member.name)
    expect(declinedID and owner.U.Tickets()[declinedID] and otherGM.U.Tickets()[declinedID], "reverse roster proposal did not reach both guilds and member")
    eq(declined.source, 2, "reverse proposal has wrong source")
    eq(declined.dest, 1, "reverse proposal has wrong destination")
    eq(declined.authorityGuild, 1, "reverse proposal lost union owner authority guild")
    member.U.AcceptTransfer(declinedID, false); Step(8, true)
    eq(owner.U.Tickets()[declinedID].state, "declined", "remote member decline did not reach union owner")
    expect(not member.command and not owner.command, "declining a transfer prepared an unintended native command")

    expect(owner.U.CreateTransfer(member.name, 2), "second remote transfer proposal was refused")
    Step(12, true)
    local id, ticket = MemberTicket(member, member.name, declinedID)
    expect(id and ticket.state == "proposed", "remote member did not receive second consent request")
    member.U.AcceptTransfer(id, true); Step(8, true)
    eq(owner.U.Tickets()[id].state, "accepted", "reverse consent did not reach destination guild")
    member.U.LeaveForTransfer(id)
    eq(member.command, "/gquit", "reverse transfer did not prepare manual native leave")
    eq(protectedCalls, 0, "reverse transfer executed a protected guild action")
    member.guild = nil; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    Step(10)
    eq(owner.U.Tickets()[id].state, "ready", "reverse guildless READY did not reach destination")
    owner.U.InviteTransfer(id)
    eq(owner.command, "/ginvite " .. member.name, "reverse transfer did not prepare manual destination invite")
    eq(protectedCalls, 0, "reverse invite ran without player's Enter")
    member.guild = 1; member.U.frame.scripts.OnEvent(member.U.frame, "PLAYER_GUILD_UPDATE", "player")
    SetRosters(0); Step(8)
    eq(member.U.Tickets()[id].state, "done", "reverse member join was not recognized")
    eq(owner.U.Tickets()[id].state, "done", "reverse destination did not complete transfer")
end
print("PASS configured union owner reverse roster transfer, decline, consent and manual native commands")

do
    local owner, otherGM, member, homeBackup, remoteBackup = UnionWorld()
    local function Fields(id)
        return { 2, id or owner.U.NewID(), member.name, 1, owner.name, owner.U.stamp(), 1 }
    end
    local f = Fields()
    expect(not owner.U.TransferMessage("UTICKET", f, homeBackup.name, false), "forged own-guild union owner sender accepted")
    expect(not otherGM.U.TransferMessage("UTICKET", f, "Посторонний Игрок", true), "untrusted sender injected a reverse proposal")
    local authority = otherGM.U.db.rosters[1]
    local at = authority.at; authority.at = otherGM.U.stamp() - 600
    expect(otherGM.U.IsUnionLeader(owner.name, 1), "exactly600-second authority cache rejected")
    authority.at = otherGM.U.stamp() - 601
    expect(not otherGM.U.IsUnionLeader(owner.name, 1), "expired authority cache granted union rights")
    expect(not otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "stale authority cache accepted a reverse proposal")
    authority.at = at
    authority.rows[owner.name].rank = 1
    expect(not otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "revoked native GM rank still authorized a reverse proposal")
    authority.rows[owner.name].rank = 0
    otherGM.U.own[member.name].online = false
    expect(not otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "source accepted an offline target")
    otherGM.U.own[member.name].online = true
    local peer = otherGM.U.peers[member.name]; otherGM.U.peers[member.name] = nil
    expect(not otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "source accepted a target without live addon presence")
    otherGM.U.peers[member.name] = peer
    local peerAt = peer.at; peer.at = otherGM.U.clock() - 66
    expect(not otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "source accepted expired addon presence")
    peer.at = peerAt
    expect(otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "valid reverse packet refused after authority checks")
    expect(otherGM.U.TransferMessage("UTICKET", f, owner.name, true), "identical reverse retransmission was not idempotent")
    local conflict = Fields(f[2]); conflict[3] = remoteBackup.name; conflict[6] = f[6]
    expect(not otherGM.U.TransferMessage("UTICKET", conflict, owner.name, true), "conflicting member reused an existing ticket ID")
    eq(otherGM.U.Tickets()[f[2]].member, member.name, "conflicting ID changed original transfer identity")
    local malformed = Fields(); malformed[7] = 2
    expect(not otherGM.U.TransferMessage("UTICKET", malformed, owner.name, true), "wrong authority guild accepted")
    malformed = Fields(); malformed[3] = otherGM.name
    expect(not otherGM.U.TransferMessage("UTICKET", malformed, owner.name, true), "source accepted a remote request to move its GM")

    local phantom = "Игрок Безаддона"
    for _, c in ipairs(clients) do
        if c.guild == 2 then c.rows[#c.rows + 1] = { name = phantom, rank = 2, online = true, level = 20 }; c.U.ReadRoster() end
    end
    otherGM.U.snapshotDue = 0; Step(15)
    expect(owner.U.db.rosters[2].rows[phantom], "online non-addon fixture did not reach shared roster")
    owner.U.CreateTransfer(phantom, 2); Step(12)
    expect(not MemberTicket(otherGM, phantom), "source received an actionable proposal for an online player without addon")
    eq(protectedCalls, 0, "authorization rejection executed a protected action")
end
print("PASS reverse transfer native rank, cache age, addon presence, sender and immutable ticket identity validation")

do
    local owner, otherGM, member, homeBackup = UnionWorld()
    local dropped = 0
    deliveryFilter = function(p)
        if p.dist == "WHISPER" and p.from == owner and Kind(p) == "UTICKET" then dropped = dropped + 1; return false end
        return true
    end
    expect(owner.U.CreateTransfer(member.name, 2), "resend fixture reverse proposal rejected")
    Step(8)
    local id = MemberTicket(homeBackup, member.name)
    expect(dropped > 0 and id and not member.U.Tickets()[id], "failover fixture did not lose initial reverse delivery")
    owner.live = false; SetRosters(0); deliveryFilter = nil
    Step(120, true)
    eq(homeBackup.U.GatewayName(), homeBackup.name, "authority guild did not replace offline gateway")
    expect(member.U.Tickets()[id] and member.U.Tickets()[id].state == "proposed", "reverse proposal resend did not survive authority gateway failover")
    member.U.AcceptTransfer(id, true); Step(12, true)
    eq(homeBackup.U.Tickets()[id].state, "accepted", "reverse consent did not return to replacement gateway")
    eq(protectedCalls, 0, "reverse failover executed a protected action")
end
print("PASS reverse transfer resend through replacement authority gateway")

local function SetupClient(name, rank, savedDB)
    clients, wire, deliveryFilter = {}, {}, nil
    time = time + 100
    return NewClient(name or "Вован Дубан", 1, rank or 0, savedDB)
end
local function SetupWindow(c)
    return c.E.ChillZoneUnionWindow and c.E.ChillZoneUnionWindow:IsShown()
end
local function ExpectSetupTab(c)
    expect(SetupWindow(c), "first verified union leader login did not open setup")
    local contact
    for _, frame in ipairs(c.allFrames) do if frame.frameType == "EditBox" and frame.width == 350 then contact = frame end end
    expect(contact and contact.parent:IsShown(), "automatic introduction opened a different tab instead of connection setup")
end
do
    local owner = SetupClient()
    expect(not SetupWindow(owner), "ADDON_LOADED opened setup before actual login")
    owner.U.frame.scripts.OnEvent(owner.U.frame, "PLAYER_LOGIN")
    expect(not SetupWindow(owner), "leader introduction opened before native guild roster verified rank")
    SetRosters(0)
    owner.U.frame.scripts.OnEvent(owner.U.frame, "GUILD_ROSTER_UPDATE")
    owner.U.minimapButton.scripts.OnUpdate(owner.U.minimapButton, 2.1)
    ExpectSetupTab(owner)
    expect(owner.U.db.setupIntroSeen[owner.U.Fold(owner.name)], "leader introduction was not persisted per character")
    owner.E.ChillZoneUnionWindow:Hide()
    owner.U.frame.scripts.OnEvent(owner.U.frame, "GUILD_ROSTER_UPDATE")
    owner.U.minimapButton.scripts.OnUpdate(owner.U.minimapButton, 2.1)
    expect(not SetupWindow(owner), "roster refresh reopened completed introduction")
    owner.U.frame.scripts.OnEvent(owner.U.frame, "PLAYER_LOGIN")
    expect(not SetupWindow(owner), "repeated login reopened completed introduction")
    local savedDB = owner.E.ChillZoneUnionDB
    local reloaded = SetupClient(nil, nil, savedDB)
    SetRosters(0); reloaded.U.frame.scripts.OnEvent(reloaded.U.frame, "PLAYER_LOGIN")
    reloaded.U.minimapButton.scripts.OnUpdate(reloaded.U.minimapButton, 2.1)
    expect(not SetupWindow(reloaded), "interface reload ignored persisted introduction state")
end
do
    for _, identity in ipairs({ { "Вован Дубан", 2 }, { "Другой Глава", 0 }, { "Офицер Союза", 1 }, { "Участник Союза", 2 } }) do
        local c = SetupClient(identity[1], identity[2])
        SetRosters(0)
        expect(not SetupWindow(c), "roster readiness opened an introduction before login")
        c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
        c.U.minimapButton.scripts.OnUpdate(c.U.minimapButton, 2.1)
        expect(not SetupWindow(c), "unverified configured name or another guild member received leader setup popup")
        expect(not c.U.db.setupIntroSeen or not c.U.db.setupIntroSeen[c.U.Fold(c.name)], "ordinary character was marked as having seen leader introduction")
    end
    local owner = SetupClient()
    owner.U.db.setupIntroSeen = { [owner.U.Fold("Офицер Союза")] = true }
    SetRosters(0); owner.U.frame.scripts.OnEvent(owner.U.frame, "PLAYER_LOGIN")
    ExpectSetupTab(owner)
    expect(owner.U.db.setupIntroSeen[owner.U.Fold("Офицер Союза")], "leader introduction overwrote another character's state")
end
do
    local owner = SetupClient()
    owner.combat = true; SetRosters(0)
    owner.U.frame.scripts.OnEvent(owner.U.frame, "PLAYER_LOGIN")
    owner.U.minimapButton.scripts.OnUpdate(owner.U.minimapButton, 2.1)
    expect(not SetupWindow(owner), "automatic introduction opened during combat")
    expect(not owner.U.db.setupIntroSeen or not owner.U.db.setupIntroSeen[owner.U.Fold(owner.name)], "deferred introduction was marked complete before display")
    owner.combat = false; owner.U.minimapButton.scripts.OnUpdate(owner.U.minimapButton, 2.1)
    ExpectSetupTab(owner)
    for _, linked in ipairs({ "contact", "connected" }) do
        local c = SetupClient()
        SetRosters(0)
        if linked == "contact" then c.U.db.contacts["Борис Навсегда"] = { guild = 2, at = c.U.stamp(), addon = true }
        else c.U.Connected = function() return true end end
        c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
        c.U.minimapButton.scripts.OnUpdate(c.U.minimapButton, 2.1)
        expect(not SetupWindow(c), "existing guild link received unnecessary first-run introduction")
        expect(c.U.db.setupIntroSeen[c.U.Fold(c.name)], "existing link did not complete the introductory state")
    end
end
print("PASS one-time verified leader setup on actual login, delayed roster, per-character reload persistence and combat deferral")

do
    local c = SetupClient("Обзор Тест", 2)
    SetRosters(0); c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
    local function Row(name, guild, rank, rankName, level, zone, online)
        return { name = name, guild = guild, rank = rank, rankName = rankName, level = level, zone = zone, online = online, class = "PRIEST" }
    end
    c.U.own = {
        [c.name] = Row(c.name, 1, 3, "А Участник", 5, "Болото", true),
        ["Альфа А"] = Row("Альфа А", 1, 2, "А Ветеран", 20, "Зимние Ключи", true),
        ["Гамма Г"] = Row("Гамма Г", 1, 0, "Я Глава", 40, "А Старая локация", false),
        ["Дубль Д"] = Row("Дубль Д", 1, 1, "Я Офицер", 30, "Арктика", true),
    }
    c.U.db.rosters[1] = { rows = c.U.own, at = c.U.stamp() }
    c.U.db.rosters[2] = { at = c.U.stamp(), rows = {
        ["Бета Б"] = Row("Бета Б", 2, 0, "Я Глава", 60, "Болото", true),
        ["Дубль Д"] = Row("Дубль Д", 2, 1, "А Офицер", 30, "Арктика", true),
        ["Эхо Э"] = Row("Эхо Э", 2, 2, "З Ветеран", 10, "Ясеневый лес", true),
    } }
    local remoteFresh = true
    c.U.RosterFresh = function(guild) return guild == 1 or remoteFresh end
    c.U.OpenRoster()
    local headers, offline = {}, nil
    for _, frame in ipairs(c.allFrames) do
        if frame.sortTitle then headers[frame.sortTitle] = frame end
        if frame.frameType == "CheckButton" and frame.parent and frame.parent.move then offline = frame end
    end
    expect(offline, "offline roster toggle not found")
    offline:SetChecked(true); offline.scripts.OnClick(offline)
    local function Order(expected, reason)
        local actual = {}
        for _, frame in ipairs(c.allFrames) do if frame.row and frame:IsShown() then actual[#actual + 1] = frame.row.name .. "@" .. frame.row.guild end end
        eq(table.concat(actual, ","), table.concat(expected, ","), reason)
    end
    local A, B, G, D1, D2, O, E = "Альфа А@1", "Бета Б@2", "Гамма Г@1", "Дубль Д@1", "Дубль Д@2", "Обзор Тест@1", "Эхо Э@2"
    Order({ A, B, D1, D2, O, E, G }, "default roster lost online-first ordering and stable cross-guild ties")
    local function Click(title)
        local header = headers[title]
        expect(header and type(header.scripts.OnClick) == "function", "sortable roster header missing: " .. title)
        header.scripts.OnClick(header)
    end
    Click("Имя / класс"); Order({ A, B, G, D1, D2, O, E }, "name ascending is not alphabetical")
    eq(headers["Имя / класс"]:GetText(), "Имя / класс", "sort header contains unsupported arrow characters")
    expect(headers["Имя / класс"].sortArrow and headers["Имя / класс"].sortArrow:IsShown(), "active ascending sort arrow not shown")
    expect(headers["Имя / класс"].sortArrow.texture:find("Media\\arrow-up", 1, true), "ascending direction does not use arrow texture")
    Click("Имя / класс"); Order({ E, O, D1, D2, G, B, A }, "name descending or stable ties incorrect")
    expect(headers["Имя / класс"].sortArrow.texture:find("Media\\arrow-down", 1, true), "descending direction does not use arrow texture")
    Click("Ур."); Order({ B, G, D1, D2, A, E, O }, "first level click no longer sorts highest first")
    expect(not headers["Имя / класс"].sortArrow:IsShown(), "inactive column still shows a direction arrow")
    Click("Ур."); Order({ O, E, A, D1, D2, G, B }, "level reverse did not sort lowest first")
    Click("Звание"); Order({ B, G, D1, D2, A, E, O }, "rank sorted translated labels instead of numeric native hierarchy")
    Click("Звание"); Order({ O, A, E, D1, D2, B, G }, "reverse native rank ordering or stable ties incorrect")
    Click("Локация"); Order({ D1, D2, B, O, A, E, G }, "location ascending used hidden offline zone instead of displayed presence")
    Click("Локация"); Order({ G, E, A, B, O, D1, D2 }, "location descending group or alphabetic direction incorrect")
    remoteFresh = false; Click("Локация")
    Order({ D1, O, A, G, B, D2, E }, "stale remote locations were sorted as current zones")
    for _, frame in ipairs(c.allFrames) do
        if frame.row and frame.row.guild == 2 then eq(frame.zone:GetText(), "Нет свежих данных", "stale row displays an old zone") end
        if frame.row and frame.row.name == "Гамма Г" then eq(frame.zone:GetText(), "Не в сети", "offline row displays a cached zone") end
    end
    Click("Локация"); Order({ B, D2, E, G, A, O, D1 }, "reverse stale/offline groups did not preserve stable names")
end
print("PASS clickable name, level, numeric rank and displayed-location sorting with reverse directions and stable mixed-guild ties")

do
    for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local file = assert(io.open("ChillZoneUnion/Media/arrow-" .. direction .. ".tga", "rb"), "arrow texture missing: " .. direction)
        local bytes = file:read("*a"); file:close()
        eq(bytes:byte(3), 2, "arrow texture is not an uncompressed color TGA")
        local width, height = bytes:byte(13) + bytes:byte(14) * 256, bytes:byte(15) + bytes:byte(16) * 256
        eq(width, 32, "unsupported arrow texture width"); eq(height, 32, "unsupported arrow texture height")
        eq(bytes:byte(17), 32, "arrow texture lost alpha channel")
        eq(#bytes, 18 + width * height * 4, "arrow texture pixel data incomplete")
        for _, pixel in ipairs({ 0, width - 1, width * (height - 1), width * height - 1 }) do
            eq(bytes:byte(18 + pixel * 4 + 4), 0, "arrow texture corner is not transparent")
        end
    end
    for _, c in ipairs(clients) do
        local function SupportedText(object)
            for _, glyph in ipairs({ "↑", "↓", "←", "→" }) do expect(not object.text:find(glyph, 1, true), "unsupported arrow glyph in visible UI text: " .. object.text) end
            for _, label in ipairs(object.fontStrings or {}) do SupportedText(label) end
        end
        for _, frame in ipairs(c.allFrames) do SupportedText(frame) end
    end
end
print("PASS transparent arrow texture assets and font-independent direction indicators")

local function StatsFixture()
    local c = SetupClient("Статистика Игрок", 2)
    SetRosters(0); c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN")
    local function Row(name, guild, class, online)
        return { name = name, guild = guild, class = class, online = online, rank = 2, rankName = "Участник", level = 20, zone = "Лес Элвинн" }
    end
    c.U.own = {
        [c.name] = Row(c.name, 1, "PRIEST", true),
        ["Маг Чиллзон"] = Row("Маг Чиллзон", 1, "MAGE", false),
        ["Воин Чиллзон"] = Row("Воин Чиллзон", 1, "WARRIOR", true),
        ["Неизвестный Чиллзон"] = Row("Неизвестный Чиллзон", 1, nil, true),
    }
    c.U.db.rosters[1] = { rows = c.U.own, at = c.U.stamp() }
    c.U.db.rosters[2] = { at = c.U.stamp(), rows = {
        ["Маг Навсегда"] = Row("Маг Навсегда", 2, "MAGE", true),
        ["Жрец Навсегда"] = Row("Жрец Навсегда", 2, "PRIEST", false),
        ["Неизвестный Навсегда"] = Row("Неизвестный Навсегда", 2, "", false),
        ["Рыцарь Навсегда"] = Row("Рыцарь Навсегда", 2, "DEATHKNIGHT", true),
    } }
    local freshness = { [1] = true, [2] = true }
    c.U.RosterFresh = function(guild) return freshness[guild] end
    c.U.RosterState = function(guild) return { fresh = freshness[guild], at = c.U.stamp(), age = freshness[guild] and 0 or 300, status = freshness[guild] and "connected" or "stale" } end
    return c, freshness
end
local function ClassRow(stats, token)
    for _, row in ipairs(stats.rows) do if row.class == token then return row end end
end
do
    local c, freshness = StatsFixture()
    local stats = c.U.ClassStatistics()
    eq(stats.total, 8, "union class statistics missed guild members")
    eq(stats.online, 5, "union online class count treated offline characters as online")
    expect(stats.complete and stats.onlineComplete, "two fresh complete rosters reported as incomplete")
    for _, guild in ipairs({ 1, 2 }) do eq(stats.guilds[guild].total, 4, "per-guild class total incorrect") end
    eq(stats.guilds[1].online, 3, "own online class total incorrect")
    eq(stats.guilds[2].online, 2, "remote online class total incorrect")
    local priest, mage, unknown, extra, druid = ClassRow(stats, "PRIEST"), ClassRow(stats, "MAGE"), ClassRow(stats, "UNKNOWN"), ClassRow(stats, "DEATHKNIGHT"), ClassRow(stats, "DRUID")
    expect(priest and mage and unknown and extra and druid, "standard, unknown or observed extra class missing")
    eq(priest.total, 2, "priests not combined across guilds"); eq(priest.online, 1, "offline remote priest counted online")
    eq(mage.total, 2, "mages not combined across guilds"); eq(mage.online, 1, "offline own mage counted online")
    eq(mage.guilds[1].total, 1, "own class subtotal missing"); eq(mage.guilds[1].online, 0, "zero online class count changed to unknown")
    eq(unknown.total, 2, "nil and empty class tokens were lost"); eq(unknown.online, 1, "unknown class presence incorrect")
    eq(extra.total, 1, "observed additional class was lost")
    eq(druid.total, 0, "absent known class does not show zero"); eq(druid.online, 0, "known absent class online count is not zero")
    local seen, sum = {}, 0
    for _, row in ipairs(stats.rows) do expect(not seen[row.class], "class token appears twice"); seen[row.class] = true; sum = sum + row.total end
    eq(sum, stats.total, "class counts do not add up to full union roster")
    for _, raw in ipairs({ false, 7, {} }) do
        c.U.own["Неизвестный Чиллзон"].class = raw
        eq(ClassRow(c.U.ClassStatistics(), "UNKNOWN").total, 2, "nonstring class token escaped unknown group")
    end
    c.U.own["Неизвестный Чиллзон"].class = nil

    freshness[2] = false
    stats = c.U.ClassStatistics()
    eq(stats.total, 8, "stale remote roster erased known membership")
    expect(stats.complete and not stats.onlineComplete and stats.online == nil, "stale remote presence was presented as current online total")
    eq(stats.knownOnline, 3, "known online subtotal includes stale remote presence")
    eq(stats.guilds[2].total, 4, "stale remote guild lost known member count")
    expect(stats.guilds[2].online == nil, "stale remote online count should be unknown")
    eq(ClassRow(stats, "MAGE").total, 2, "stale roster lost cached class membership")
    expect(ClassRow(stats, "MAGE").online == nil, "stale class online count shown as a precise number")

    c.U.db.rosters[2] = nil
    stats = c.U.ClassStatistics()
    expect(not stats.complete and stats.total == nil and stats.online == nil, "missing remote roster reported precise union totals")
    eq(stats.knownTotal, 4, "missing remote roster discarded own known subtotal")
    expect(not stats.guilds[2].known and stats.guilds[2].total == nil, "missing guild reported as zero members")
    expect(ClassRow(stats, "DRUID").total == nil, "unknown remote class population reported as zero")
    eq(ClassRow(stats, "DRUID").knownTotal, 0, "known absent class subtotal incorrect")
    freshness[2] = true; c.U.db.rosters[2] = { rows = {}, at = c.U.stamp() }
    stats = c.U.ClassStatistics()
    expect(stats.complete and stats.guilds[2].known, "known empty remote roster treated as missing")
    eq(stats.guilds[2].total, 0, "known empty remote roster not zero")
    eq(stats.total, 4, "empty remote guild changed own member count")
    eq(ClassRow(stats, "DRUID").total, 0, "known absent class did not return to zero after roster became complete")
end
print("PASS union class totals, fresh online counts, unknown tokens, extra classes, missing and stale roster semantics")
do
    local c, freshness = StatsFixture()
    c.U.OpenRoster()
    local search, offline, guildFilter, openStats, back
    for _, frame in ipairs(c.allFrames) do
        if frame.frameType == "EditBox" and frame.width == 280 then search = frame end
        if frame.frameType == "CheckButton" and frame.parent and frame.parent.move then offline = frame end
        if frame.text == "Весь союз" then guildFilter = frame end
        if frame.text == "По классам" then openStats = frame end
        if frame.text == "К списку" then back = frame end
    end
    expect(search and offline and guildFilter and openStats and back, "class statistics navigation missing for ordinary member")
    expect(not c.U.IsMaster() and not c.U.IsOfficer(), "statistics UI fixture unexpectedly has officer privileges")
    search:SetText("Воин Чиллзон"); search.scripts.OnTextChanged(search, true)
    offline:SetChecked(false); offline.scripts.OnClick(offline)
    guildFilter.scripts.OnClick(guildFilter)
    local visibleRoster = 0
    for _, frame in ipairs(c.allFrames) do if frame.row and frame:IsShown() then visibleRoster = visibleRoster + 1 end end
    eq(visibleRoster, 1, "roster filters did not restrict class statistics independence fixture")
    openStats.scripts.OnClick(openStats)
    expect(back.parent:IsShown() and not search.parent:IsShown(), "ordinary member could not open separate class statistics page")
    local function VisibleClass(token)
        for _, frame in ipairs(c.allFrames) do if frame.statsRow and frame.statsRow.class == token and frame:IsShown() then return frame end end
        error("visible class statistics row missing: " .. token)
    end
    local priest, mage, druid = VisibleClass("PRIEST"), VisibleClass("MAGE"), VisibleClass("DRUID")
    eq(priest.guild1:GetText(), "1 / 1", "own class statistics depend on roster search")
    eq(priest.guild2:GetText(), "0 / 1", "remote class statistics depend on selected roster guild")
    eq(priest.union:GetText(), "1 / 2", "union class statistics ignore neither guild nor offline members")
    eq(mage.union:GetText(), "1 / 2", "offline roster toggle removed offline mage from class totals")
    eq(druid.union:GetText(), "0 / 0", "known absent class is not shown as zero in UI")

    c.U.db.rosters[2].rows["Жрец Навсегда"].online = true
    c.U.db.rosters[2].rows["Еще Маг"] = { name = "Еще Маг", guild = 2, class = "MAGE", online = false, rank = 2, rankName = "Участник", level = 15, zone = "Болото" }
    c.U.Refresh()
    eq(VisibleClass("PRIEST").union:GetText(), "2 / 2", "class page did not refresh changed online presence while open")
    eq(VisibleClass("MAGE").guild2:GetText(), "1 / 2", "class page did not refresh changed remote membership while open")
    eq(VisibleClass("MAGE").union:GetText(), "1 / 3", "class page refresh lost total across both guilds")
    freshness[2] = false; c.U.Refresh()
    eq(VisibleClass("MAGE").guild2:GetText(), "? / 2", "stale remote class online count not visibly unknown")
    eq(VisibleClass("PRIEST").union:GetText(), "1 + ? / 2", "union class UI presents stale online total as precise")
    c.U.db.rosters[2] = nil; c.U.Refresh()
    eq(VisibleClass("MAGE").guild2:GetText(), "? / ?", "missing guild population presented as zero in UI")
    eq(VisibleClass("MAGE").union:GetText(), "? / 1 + ?", "missing guild class UI lost known subtotal or unknown marker")
    eq(VisibleClass("DRUID").union:GetText(), "? / ?", "missing remote roster cannot certify absence of a class")
    back.scripts.OnClick(back)
    expect(search.parent:IsShown() and not back.parent:IsShown(), "class statistics back button did not return to member list")
    eq(search:GetText(), "Воин Чиллзон", "class statistics navigation discarded roster search")
    c.U.OpenClassStats()
    expect(back.parent:IsShown(), "public class statistics action did not reopen the page")
end
print("PASS ordinary-member class statistics navigation, independence from roster filters and live/unknown counter updates")
do
    local c = StatsFixture()
    local byName = {
        ["Маг Навсегда"] = { known = true, version = "0.4.4-test", live = true, lastSeen = c.U.stamp() },
    }
    c.U.AddonInfo = function(name) return byName[name] or { known = false } end
    c.U.OpenRoster()
    local function RosterRow(name)
        for _, frame in ipairs(c.allFrames) do if frame.row and frame.row.name == name and frame:IsShown() then return frame end end
        error("badge fixture roster row missing: " .. name)
    end
    local function HasTooltipLine(text)
        for _, line in ipairs(c.E.GameTooltip.lines or {}) do if line[1] == text then return true end end
        return false
    end
    local mage = RosterRow("Маг Навсегда")
    expect(mage.addonBadge and mage.addonBadge:IsShown(), "known addon badge not visible")
    eq(mage.addonBadge:GetText(), "CZ", "addon badge does not use font-safe Latin letters")
    eq(mage.name:GetText(), "Маг Навсегда", "addon version leaked into roster name")
    for i, expected in ipairs({ 0.45, 0.85, 0.78 }) do eq(mage.addonBadge.textColor[i], expected, "live addon badge tint incorrect") end
    mage.scripts.OnEnter(mage)
    expect(c.E.GameTooltip:IsShown() and HasTooltipLine("ChillZoneUnion: 0.4.4-test"), "addon version missing from row tooltip")
    expect(HasTooltipLine("Аддон подтверждён сейчас"), "live addon confirmation absent from tooltip")
    byName["Маг Навсегда"].live = false; byName["Маг Навсегда"].lastSeen = c.U.stamp() - 300
    c.U.Refresh()
    expect(mage.addonBadge:IsShown(), "cached addon metadata lost its badge")
    for i, expected in ipairs({ 0.45, 0.50, 0.53 }) do eq(mage.addonBadge.textColor[i], expected, "cached addon badge not dimmed") end
    expect(HasTooltipLine("Сведения сохранены") and not HasTooltipLine("Аддон подтверждён сейчас"), "hovered tooltip did not update when presence became cached")
    byName["Маг Навсегда"].version = "0.4.4-next"; c.U.Refresh()
    expect(HasTooltipLine("ChillZoneUnion: 0.4.4-next") and not HasTooltipLine("ChillZoneUnion: 0.4.4-test"), "hovered tooltip retained previous addon version")
    mage.scripts.OnLeave(mage); expect(not c.E.GameTooltip:IsShown(), "roster tooltip did not hide on leave")
    local unknown = RosterRow("Воин Чиллзон")
    expect(unknown.addonBadge and not unknown.addonBadge:IsShown(), "unknown addon status received a positive badge")
    unknown.scripts.OnEnter(unknown)
    expect(HasTooltipLine("Статус аддона неизвестен"), "missing metadata is not described as unknown")
    for _, line in ipairs(c.E.GameTooltip.lines) do expect(not c.U.Fold(line[1]):find("нет аддона", 1, true), "unknown presence was described as no addon") end
    unknown.scripts.OnLeave(unknown)
    local search
    for _, frame in ipairs(c.allFrames) do if frame.frameType == "EditBox" and frame.width == 280 then search = frame end end
    search:SetText("Маг Навсегда"); search.scripts.OnTextChanged(search, true)
    local reused = RosterRow("Маг Навсегда"); reused.scripts.OnEnter(reused)
    expect(HasTooltipLine("ChillZoneUnion: 0.4.4-next"), "known row tooltip fixture did not show version")
    search:SetText("Воин Чиллзон"); search.scripts.OnTextChanged(search, true)
    eq(RosterRow("Воин Чиллзон"), reused, "tooltip test did not recycle the same roster button")
    eq(c.E.GameTooltip:GetText(), "Воин Чиллзон", "recycled row tooltip retained previous member name")
    expect(not reused.addonBadge:IsShown() and HasTooltipLine("Статус аддона неизвестен") and not HasTooltipLine("ChillZoneUnion: 0.4.4-next"), "recycled row attributed old member's addon version to another member")
end
print("PASS Latin addon badge, live/cached tint, unknown status and refreshed version tooltip")

local function ObserveAddonJobs(c)
    local jobs, original = {}, c.U.QueueBatch
    c.U.QueueBatch = function(batch)
        local accepted = original(batch)
        if accepted then for _, job in ipairs(batch) do if job.kind == "ADDONS" then jobs[#jobs + 1] = job end end end
        return accepted
    end
    return jobs
end
local function HelloPresence(c, name, version)
    c.U.Handle("HELLO", { c.guild, version, c.U.Pack({}), "", "", 0 }, "GUILD", name, c.U.NewID())
end
do
    local owner, otherGM, member, homeBackup = UnionWorld()
    Step(8)
    for _, c in ipairs(clients) do
        local self = c.U.AddonInfo(c.name, c.guild)
        expect(self.known and self.live and self.version == c.U.VERSION, "native own roster did not show current addon version")
    end
    local originalVersion = member.U.VERSION
    expect(owner.U.AddonInfo(member.name, 2).known and owner.U.AddonInfo(member.name, 2).live, "initial addon metadata did not cross guild boundary")
    eq(homeBackup.U.AddonInfo(member.name, 2).version, originalVersion, "ordinary guild member missed remote addon metadata")
    local jobs = ObserveAddonJobs(otherGM)
    local before = #jobs
    for _ = 1, 20 do HelloPresence(otherGM, member.name, originalVersion) end
    Step(6)
    eq(#jobs, before, "unchanged HELLO versions caused repeated metadata publications")
    member.U.VERSION = "0.4.4-test"; member.U.SayHello(); Step(2)
    eq(otherGM.U.AddonInfo(member.name, 2).version, member.U.VERSION, "validated native HELLO version was not captured immediately")
    Step(12)
    eq(owner.U.AddonInfo(member.name, 2).version, member.U.VERSION, "version delta did not reach remote gateway")
    eq(homeBackup.U.AddonInfo(member.name, 2).version, member.U.VERSION, "version delta did not reach ordinary remote reader")
    local delta = false
    for _, job in ipairs(jobs) do if job.fields[4] == "D" then delta = true end end
    expect(delta, "changed addon version did not use a presence delta")

    local cached = owner.U.AddonInfo(member.name, 2)
    expect(cached.known and cached.live, "live presence fixture not current")
    local fresh = owner.U.RosterFresh
    owner.U.RosterFresh = function(guild) return guild ~= 2 and fresh(guild) or false end
    expect(owner.U.AddonInfo(member.name, 2).known and not owner.U.AddonInfo(member.name, 2).live, "stale roster presented cached addon data as live")
    owner.U.RosterFresh = fresh
    local connected = owner.U.Connected; owner.U.Connected = function() return false end
    expect(owner.U.AddonInfo(member.name, 2).known and not owner.U.AddonInfo(member.name, 2).live, "disconnected addon metadata stayed live")
    owner.U.Connected = connected
    member.live = false; SetRosters(0); Step(12)
    expect(owner.U.AddonInfo(member.name, 2).known and not owner.U.AddonInfo(member.name, 2).live, "offline guild member lost version history or remained live")
    member.live = true; SetRosters(0); member.U.SayHello(); Step(15)
    expect(owner.U.AddonInfo(member.name, 2).live, "addon presence did not recover when member returned")
    otherGM.live = false; SetRosters(0); Step(110)
    expect(member.U.GatewayName() ~= otherGM.name and owner.U.Connected(), "presence failover fixture did not replace remote gateway")
    local recovered = owner.U.AddonInfo(member.name, 2)
    expect(recovered.known and recovered.live and recovered.version == member.U.VERSION, "addon metadata did not survive gateway failover and new snapshot")
    deliveryFilter = function(p) return p.dist ~= "WHISPER" end; Step(80)
    expect(owner.U.AddonInfo(member.name, 2).known and not owner.U.AddonInfo(member.name, 2).live, "lost bridge did not dim cached addon confirmation")
    deliveryFilter = nil; Step(100)
    expect(owner.U.AddonInfo(member.name, 2).live, "presence did not recover after bridge reconnect")
end
print("PASS native HELLO addon versions, quiet heartbeats, remote deltas, offline/stale state and gateway reconnect")

do
    local owner, otherGM, member, homeBackup = UnionWorld()
    Step(8)
    local jobs = ObserveAddonJobs(otherGM)
    for _, c in ipairs(clients) do
        if c.guild == 2 then
            for i = 1, 85 do c.rows[#c.rows + 1] = { name = string.format("Фантом%03d Игрок", i), rank = 2, online = true, level = 20 } end
            c.U.ReadRoster()
        end
    end
    for _, c in ipairs(clients) do if c.guild == 2 then for i = 1, 85 do c.U.PresenceHello(string.format("Фантом%03d Игрок", i), "0.4.4-batch") end end end
    otherGM.U.snapshotDue = 0; Step(45)
    local multipart, publishedPages = false, 0
    for _, job in ipairs(jobs) do
        if job.fields[4] == "F" and tonumber(job.fields[7]) >= 3 then multipart = true; publishedPages = publishedPages + 1 end
    end
    expect(multipart and publishedPages <= 12, "many new addon observations were not coalesced into bounded multipage snapshots")
    for _, c in ipairs({ owner, homeBackup }) do
        for _, i in ipairs({ 1, 40, 41, 80, 85 }) do
            local name = string.format("Фантом%03d Игрок", i)
            local info = c.U.AddonInfo(name, 2)
            expect(info.known and info.live and info.version == "0.4.4-batch", "batched snapshot missing a member across page boundaries")
            expect(not c.U.db.contacts[name] and not c.U.TrustedPeer(name), "addon metadata granted guild bridge trust")
            expect(not c.U.IsUnionLeader(name, 2), "addon version granted union leadership")
        end
    end
    eq(otherGM.U.GatewayName(), otherGM.name, "addon metadata observations displaced established gateway")
    eq(owner.U.db.rosters[2].rows["Фантом001 Игрок"].rank, 2, "addon metadata changed native roster rank")
end
print("PASS coalesced multipage addon snapshots for ordinary readers without contacts or role escalation")

do
    local gm, officer = FreshPair()
    deliveryFilter = function(p) return not (p.from == officer and Kind(p) == "ADDONS") end
    expect(gm.U.Link(officer.name), "legacy metadata fixture could not connect")
    Step(55)
    expect(gm.U.Connected(), "missing remote addon metadata broke ordinary guild connection")
    local jobs = ObserveAddonJobs(gm)
    Step(25)
    eq(#jobs, 0, "legacy remote without ADDONS caused a repeating full metadata publication storm")
    deliveryFilter = nil
end
print("PASS legacy bridge without presence metadata remains connected without publication storms")

do
    local owner, otherGM, member = UnionWorld()
    Step(8)
    local savedDB, version = member.E.ChillZoneUnionDB, member.U.AddonInfo(otherGM.name, 2).version
    expect(version, "reload fixture never observed own guildmate addon")
    local reloaded = SetupClient(member.name, 2, savedDB)
    reloaded.guild = 2; reloaded.U.UpdateIdentity()
    local contacts = Count(reloaded.U.db.contacts)
    reloaded.U.frame.scripts.OnEvent(reloaded.U.frame, "PLAYER_LOGIN")
    reloaded.U.PresenceTick()
    expect(reloaded.U.db.addonPresence[2][otherGM.name] and reloaded.U.db.addonPresence[2][otherGM.name].version == version, "initial unloaded own roster erased saved addon metadata")
    local cached = reloaded.U.AddonInfo(owner.name, 1)
    expect(cached.known and not cached.live, "reload treated saved remote version as a live confirmation")
    reloaded.rows = {
        { name = reloaded.name, rank = 2, online = true, level = 20 },
        { name = otherGM.name, rank = 0, online = true, level = 20 },
    }
    reloaded.U.ReadRoster()
    local ownCached = reloaded.U.AddonInfo(otherGM.name, 2)
    expect(ownCached.known and ownCached.version == version and not ownCached.live, "own saved version did not survive reload pending fresh HELLO")
    eq(Count(reloaded.U.db.contacts), contacts, "restoring addon metadata created a contact")
    expect(not reloaded.U.IsMaster() and not reloaded.U.CanInvite(), "cached addon data granted native permissions")
end
print("PASS saved addon versions survive unloaded roster reload while current liveness and permissions reset")
do
    local owner, otherGM, member = UnionWorld()
    Step(8)
    local newcomer = NewClient("Яна Новая", 1, 2)
    expect(not newcomer.U.db.rosters[2], "late-join metadata fixture unexpectedly has a remote roster")
    SetRosters(0); newcomer.U.frame.scripts.OnEvent(newcomer.U.frame, "PLAYER_LOGIN")
    Step(60)
    expect(newcomer.U.db.rosters[2] and newcomer.U.db.rosters[2].rows[member.name], "new ordinary member did not receive foreign roster")
    local info = newcomer.U.AddonInfo(member.name, 2)
    expect(info.known and info.live and info.version == member.U.VERSION, "late-join metadata replay was lost before foreign roster arrived")
end
print("PASS late ordinary installation receives current foreign addon metadata after initial roster synchronization")
do
    local owner, otherGM, member, homeBackup, remoteBackup = UnionWorld()
    Step(8); owner.U.PresenceReset()
    local initialContacts = Count(owner.U.db.contacts)
    local initialMemberTrust = owner.U.TrustedPeer(member.name)
    local function Record(name, version, live)
        return owner.U.Pack({ name or member.name, version or "0.4.4-a", live or "1", owner.U.stamp() })
    end
    local function Fields(rev, records, page, pages, mode, base, epoch)
        return { 2, epoch or "9000.1", rev, mode or "F", base or 0, page or 1, pages or 1, owner.U.stamp(), owner.U.Pack(records or { Record() }) }
    end
    local function Take(fields, sender, remote)
        return owner.U.PresenceMessage("ADDONS", fields, sender or otherGM.name, remote ~= false)
    end
    expect(not Take(Fields(1), "Посторонний Игрок"), "untrusted sender supplied addon snapshot")
    expect(not Take(Fields(1), remoteBackup.name), "noncurrent remote gateway supplied addon snapshot")
    local own = Fields(1); own[1] = 1; own[9] = owner.U.Pack({ Record(homeBackup.name) })
    expect(not Take(own, homeBackup.name, false), "ordinary own guild member impersonated addon snapshot publisher")
    expect(not Take(Fields(1, { Record("Посторонний Игрок") })), "presence snapshot accepted a character outside verified guild roster")
    for _, version in ipairs({ "bad|Hitem:1|h", "bad version", string.rep("a", 41), "" }) do
        local raw = owner.U.Pack({ member.name, version, "1", owner.U.stamp() })
        expect(not Take(Fields(1, { raw })), "presence snapshot accepted malformed addon version")
    end
    expect(not Take(Fields(1, { Record(nil, nil, "yes") })), "presence snapshot accepted invalid live flag")
    expect(not Take(Fields(1, { Record(), Record() })), "presence snapshot accepted duplicate character rows")
    local malformed = Fields(1); malformed[6] = 2; malformed[7] = 1
    expect(not Take(malformed), "presence snapshot accepted page beyond page count")
    malformed = Fields(1); malformed[7] = 39
    expect(not Take(malformed), "presence snapshot accepted excessive page count")
    malformed = Fields(1); malformed[8] = owner.U.stamp() + 61
    expect(not Take(malformed), "presence snapshot accepted future publication timestamp")
    local oversized = {}; for _ = 1, 41 do oversized[#oversized + 1] = Record() end
    expect(not Take(Fields(1, oversized)), "presence snapshot accepted oversized application page")
    expect(Take(Fields(1)), "valid presence baseline rejected")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-a", "valid baseline version was not applied")

    expect(Take(Fields(2, { Record(nil, "0.4.4-b") }, 1, 3)), "first partial snapshot page rejected")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-a", "partial snapshot became visible before atomic completion")
    expect(Take(Fields(2, { Record(otherGM.name) }, 2, 3)), "second partial snapshot page rejected")
    expect(not Take(Fields(2, { Record("Посторонний Игрок") }, 3, 3)), "malformed final snapshot page was accepted")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-a", "failed multipart snapshot changed accepted metadata")
    expect(Take(Fields(3, { Record(otherGM.name) }, 2, 3)), "out-of-order second snapshot page rejected")
    expect(Take(Fields(3, { Record(remoteBackup.name) }, 3, 3)), "out-of-order third snapshot page rejected")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-a", "out-of-order partial snapshot leaked new metadata")
    expect(Take(Fields(3, { Record(nil, "0.4.4-b") }, 1, 3)), "complete out-of-order snapshot rejected")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-b", "completed multipart snapshot did not replace baseline")
    expect(Take(Fields(4, { Record(nil, "0.4.4-c") }, 1, 1, "D", 3)), "contiguous presence delta rejected")
    expect(not Take(Fields(6, { Record(nil, "0.4.4-gap") }, 1, 1, "D", 5)), "presence delta gap was applied without matching baseline")
    expect(not Take(Fields(3)), "delayed older full snapshot rolled back presence revision")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-c", "invalid delta or replay changed version")
    expect(Take(Fields(1, { Record(nil, "0.4.4-d") }, 1, 1, "F", 0, "9000.2")), "replacement publisher epoch baseline rejected")
    expect(not Take(Fields(999, { Record(nil, "0.4.4-old") })), "retired publisher epoch was allowed to roll back version")
    expect(Take(Fields(2, { Record(nil, "0.4.4-next") }, 1, 2, "F", 0, "9000.2")), "duplicate-page fixture rejected initial page")
    expect(not Take(Fields(2, { Record(nil, "0.4.4-conflict") }, 1, 2, "F", 0, "9000.2")), "conflicting duplicate page was accepted")
    eq(owner.U.AddonInfo(member.name, 2).version, "0.4.4-d", "conflicting duplicate modified accepted snapshot")
    eq(Count(owner.U.db.contacts), initialContacts, "presence metadata validation created bridge contacts")
    eq(owner.U.TrustedPeer(member.name), initialMemberTrust, "accepted addon version changed remote bridge trust")
    expect(not owner.U.IsUnionLeader(member.name, 2), "accepted addon version granted union owner role")

    local packed = owner.U.RowPack(otherGM.U.own[member.name])
    eq(#owner.U.Unpack(packed), 7, "addon metadata changed legacy seven-field roster row wire format")
    local legacyRows = {}
    for _, row in pairs(otherGM.U.own) do legacyRows[#legacyRows + 1] = owner.U.RowPack(row) end
    expect(owner.U.TakeRoster({ 2, "legacy-roster", 1, 1, #legacyRows, owner.U.Pack(legacyRows) }, otherGM.name), "legacy roster snapshot no longer accepted alongside addon metadata")
    eq(owner.U.db.rosters[2].rows[member.name].class, "PRIEST", "legacy roster class field was displaced by addon metadata")
    eq(protectedCalls, 0, "presence handling executed a protected action")
end
print("PASS presence sender/schema validation, atomic multipart snapshots, revision and epoch replay protection and legacy roster wire compatibility")
do
    local c = SetupClient("Игрок01 Тест", 2)
    c.rows = {}
    for i = 1, 20 do
        c.rows[#c.rows + 1] = { name = string.format("Игрок%02d Тест", i), rank = 2, rankName = "Ранг " .. i,
            online = true, level = i, zone = "Локация " .. i }
    end
    c.U.ReadRoster(); c.U.OpenRoster()
    local rowButtons = {}
    for _, frame in ipairs(c.allFrames) do if frame.row and frame.bg and frame.name then rowButtons[#rowButtons + 1] = frame end end
    eq(#rowButtons, 11, "tooltip fault fixture did not create a full visible roster page")
    local roster = rowButtons[1].parent
    local nativeSetText = c.E.GameTooltip.SetText
    c.E.GameTooltip.SetText = function() error("injected native tooltip failure") end
    local function FailsAfterCommit(action)
        local ok, error = pcall(action)
        expect(not ok and tostring(error):find("injected native tooltip failure", 1, true), "tooltip fault did not reach the native call")
    end
    local function ExpectHighlights(wanted)
        local highlighted = 0
        for i, button in ipairs(rowButtons) do
            if button.bg.colorTexture[4] == 0.45 then highlighted = highlighted + 1; eq(i, wanted, "previous row remained selected after tooltip failure") end
        end
        eq(highlighted, wanted and 1 or 0, "tooltip failure left multiple or missing selected rows")
    end
    for _, index in ipairs({ 9, 6, 3 }) do
        for _, button in ipairs(rowButtons) do button.czuHovered = nil end
        rowButtons[index].czuHovered = true
        FailsAfterCommit(function() rowButtons[index].scripts.OnClick(rowButtons[index]) end)
        ExpectHighlights(index)
        expect(roster.selection:GetText():find(string.format("Игрок%02d Тест", index), 1, true), "selection footer remained stale after tooltip failure")
        expect(roster.move.enabled == false, "tooltip failure interrupted transfer permission update")
    end
    FailsAfterCommit(function() roster.scripts.OnMouseWheel(roster, -1) end)
    for i, button in ipairs(rowButtons) do
        local index = i + 3
        local name = string.format("Игрок%02d Тест", index)
        eq(button.row.name, name, "tooltip failure left lower roster row data at previous scroll offset")
        eq(button.name:GetText(), name, "tooltip failure left lower roster name unpainted")
        eq(button.level:GetText(), tostring(index), "tooltip failure left lower roster level unpainted")
        eq(button.zone:GetText(), "Локация " .. index, "tooltip failure left lower roster location unpainted")
        eq(button.rank:GetText(), "Ранг " .. index, "tooltip failure left lower roster rank unpainted")
    end
    eq(roster.range:GetText(), "4–14 из 20", "tooltip failure interrupted scroll range footer")
    ExpectHighlights(nil)
    FailsAfterCommit(function() roster.scripts.OnMouseWheel(roster, 1) end)
    eq(roster.range:GetText(), "1–11 из 20", "tooltip failure interrupted reverse scroll footer")
    ExpectHighlights(3)
    c.E.GameTooltip.SetText = nativeSetText
    c.U.Refresh()
end
print("PASS strict native tooltip arguments, single-value display escaping and complete roster repaint despite tooltip failure")

local function FindRosterButton(c, name, guild)
    for _, frame in ipairs(c.allFrames) do if frame.row and frame.row.name == name and frame.row.guild == guild and frame:IsShown() then return frame end end
    error("context menu roster target missing: " .. name)
end
local function OpenRosterMenu(c, name, guild)
    local button = FindRosterButton(c, name, guild)
    local registered = false
    for _, click in ipairs(button.clickButtons or {}) do if click == "RightButtonUp" or click == "AnyUp" then registered = true end end
    expect(registered, "roster button does not receive native right clicks")
    button.scripts.OnClick(button, "RightButton")
    expect(c.contextMenu and c.contextMenu.owner == button and c.contextMenu.native:IsShown(), "native roster context menu did not open on right click")
    return c.contextMenu, button
end
local function MenuEntry(context, title)
    for _, entry in ipairs(context.description.entries) do if entry.text == title then return entry end end
end
local function ActivateMenu(context, title)
    local entry = MenuEntry(context, title)
    expect(entry and entry.enabled and type(entry.callback) == "function", "enabled context menu action missing: " .. title)
    entry.callback(); context.native:Hide()
    return entry
end
do
    local owner, otherGM, member, homeBackup = UnionWorld()
    owner.U.OpenRoster()
    local context, row = OpenRosterMenu(owner, member.name, 2)
    eq(context.description.titles[1], member.name, "native context menu lost full character name")
    ActivateMenu(context, "Шепнуть")
    eq(owner.command, "/w " .. member.name .. " ", "context whisper did not prepare full-name native command")
    context = OpenRosterMenu(owner, member.name, 2); ActivateMenu(context, "Пригласить в группу")
    eq(owner.command, "/invite " .. member.name, "context party invite did not prepare manual native command")
    eq(protectedCalls, 0, "context menu performed an automatic protected action")
    owner.command = "unchanged"
    row.scripts.OnDoubleClick(row, "RightButton")
    eq(owner.command, "unchanged", "right double click accidentally opened whisper")
    row.scripts.OnClick(row, "LeftButton")
    local highlighted = 0
    for _, frame in ipairs(owner.allFrames) do if frame.row and frame.bg.colorTexture[4] == 0.45 then highlighted = highlighted + 1; eq(frame.row.name, member.name, "left click left another member selected") end end
    eq(highlighted, 1, "left click did not preserve a single selected member")
    row.scripts.OnDoubleClick(row, "LeftButton")
    eq(owner.command, "/w " .. member.name .. " ", "left double click no longer prepares whisper")

    context, row = OpenRosterMenu(owner, member.name, 2)
    local captured = MenuEntry(context, "Шепнуть").callback
    local original = row.row; row.row = owner.U.own[homeBackup.name]
    owner.command = nil; captured()
    expect(owner.command == nil or owner.command == "/w " .. member.name .. " ", "recycled roster button redirected captured action to a different member")
    row.row = original; owner.U.CloseRosterContextMenu(); owner.U.Refresh()
    context = OpenRosterMenu(owner, member.name, 2); captured = MenuEntry(context, "Шепнуть").callback
    owner.U.CloseRosterContextMenu(); owner.command = nil; captured()
    expect(not owner.command, "closed context menu still acted through a retained responder")
    context = OpenRosterMenu(owner, member.name, 2); captured = MenuEntry(context, "Шепнуть").callback
    owner.U.db.rosters[2].rows[member.name] = nil; owner.command = nil; captured()
    expect(not owner.command, "context action did not revalidate current guild membership")
    owner.U.db.rosters[2].rows[member.name] = original; owner.U.CloseRosterContextMenu(); owner.U.Refresh()

    context = OpenRosterMenu(owner, member.name, 2)
    local transfer = MenuEntry(context, "Предложить переход")
    expect(transfer and transfer.enabled, "configured union leader lacks remote context transfer action")
    local before = Count(owner.U.Tickets())
    owner.rank = 2; owner.U.own[owner.name].rank = 2; transfer.callback()
    eq(Count(owner.U.Tickets()), before, "context transfer responder trusted stale union leader permissions")
    owner.rank = 0; owner.U.own[owner.name].rank = 0; owner.U.CloseRosterContextMenu()
    context = OpenRosterMenu(owner, member.name, 2); ActivateMenu(context, "Предложить переход"); Step(12)
    local reverse
    for _, ticket in pairs(member.U.Tickets()) do if ticket.member == member.name and ticket.master == owner.name and ticket.source == 2 and ticket.dest == 1 then reverse = ticket end end
    expect(reverse, "authorized remote context transfer did not reach member consent workflow")

    otherGM.U.OpenRoster(); context = OpenRosterMenu(otherGM, member.name, 2)
    expect(MenuEntry(context, "Предложить переход").enabled, "native guild master lacks own-guild context transfer")
    ActivateMenu(context, "Предложить переход"); Step(12)
    local normal
    for _, ticket in pairs(member.U.Tickets()) do if ticket.member == member.name and ticket.master == otherGM.name and ticket.source == 2 and ticket.dest == 1 then normal = ticket end end
    expect(normal, "own guild master context transfer did not use normal consent workflow")
    homeBackup.U.OpenRoster(); context = OpenRosterMenu(homeBackup, member.name, 2)
    transfer = MenuEntry(context, "Предложить переход")
    expect(not transfer or transfer.enabled == false, "ordinary officer acquired remote guild administration from context menu")
    member.U.OpenRoster(); context = OpenRosterMenu(member, otherGM.name, 2)
    transfer = MenuEntry(context, "Предложить переход")
    expect(not transfer or transfer.enabled == false, "ordinary member could propose moving guild master")
    eq(protectedCalls, 0, "context transfer executed protected commands without participant input")
end
print("PASS native right-click character actions, immutable full-name targets, current authorization and ordinary consent workflow")

do
    local owner, otherGM, member = UnionWorld()
    owner.U.OpenRoster()
    local target = FindRosterButton(owner, member.name, 2)
    local roster, search, guildFilter, offline, sortHeader, close = target.parent
    for _, frame in ipairs(owner.allFrames) do
        if frame.frameType == "EditBox" and frame.width == 280 then search = frame end
        if frame.text == "Весь союз" then guildFilter = frame end
        if frame.frameType == "CheckButton" and frame.parent == roster then offline = frame end
        if frame.sortTitle == "Имя / класс" then sortHeader = frame end
        if frame.template == "UIPanelCloseButton" then close = frame end
    end
    local function Closes(action, reason)
        local context = OpenRosterMenu(owner, member.name, 2)
        action(); expect(not context.native:IsShown(), reason)
    end
    Closes(function() roster.scripts.OnMouseWheel(roster, -1) end, "scrolling left old character context menu open")
    Closes(function() search:SetText(member.name); search.scripts.OnTextChanged(search, true) end, "search change left character context menu open")
    search:SetText(""); search.scripts.OnTextChanged(search, true)
    Closes(function() guildFilter.scripts.OnClick(guildFilter) end, "guild filter left character context menu open")
    guildFilter.scripts.OnClick(guildFilter); guildFilter.scripts.OnClick(guildFilter)
    Closes(function() offline:SetChecked(true); offline.scripts.OnClick(offline) end, "offline filter left character context menu open")
    Closes(function() sortHeader.scripts.OnClick(sortHeader) end, "sorting left character context menu open")
    Closes(function() owner.U.OpenChat() end, "tab switch left character context menu open")
    owner.U.OpenRoster()
    Closes(function() close.scripts.OnClick(close) end, "closing main window left character context menu open")
    owner.U.OpenRoster()
    owner.reuseContextFrame = true
    local pooled, latest, responders = nil, nil, {}
    for _, target in ipairs({ { member.name, 2 }, { owner.name, 1 }, { member.name, 2 } }) do
        local context = OpenRosterMenu(owner, target[1], target[2])
        if pooled then eq(context.native, pooled, "native context fixture did not reuse the same pooled frame") end
        pooled, latest = context.native, context.native.czuRosterContext
        expect(latest and latest.active, "reused native menu did not attach latest active context")
        local entry = MenuEntry(context, "Шепнуть")
        if entry and entry.callback then responders[#responders + 1] = entry.callback end
    end
    eq(pooled.hookCounts.OnHide, 1, "reused native menu accumulated hide hooks and captured old contexts")
    pooled:Hide()
    expect(pooled.czuRosterContext == nil and not latest.active, "pooled menu hide did not invalidate its latest context")
    owner.command = nil
    for _, responder in ipairs(responders) do responder() end
    expect(not owner.command, "pooled menu hide left an old or latest responder active")
    owner.reuseContextFrame = false
    owner.E.MenuUtil = nil
    target = FindRosterButton(owner, member.name, 2); target.scripts.OnClick(target, "RightButton")
    local fallback = owner.E.ChillZoneUnionRosterMenu
    expect(fallback and fallback:IsShown(), "client without MenuUtil has no roster context fallback")
    local whisper
    for _, frame in ipairs(owner.allFrames) do if frame.parent == fallback and frame.text == "Шепнуть" then whisper = frame end end
    expect(whisper and whisper.enabled ~= false, "fallback context menu lacks whisper action")
    whisper.scripts.OnClick(whisper)
    eq(owner.command, "/w " .. member.name .. " ", "fallback context menu changed character target")
    expect(not fallback:IsShown(), "fallback context menu did not close after action")
end
print("PASS context menu invalidation on scroll, filters, sorting, tab/window close and legacy fallback")
print("ALL SCENARIOS PASSED; packets=" .. sent .. "; automatic protected actions=" .. protectedCalls)
