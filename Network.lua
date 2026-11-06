local _, U = ...
U.peers, U.links, U.inboundLinks, U.pings, U.probes = {}, {}, {}, {}, {}
U.setup = { state = "idle", message = "Глава гильдии может указать офицера второй гильдии и нажать «Соединить»." }
local lastHello, lastPing, lastClean, lastAsk, lastChat = -100, -100, -100, -100, -100
local remoteSeen, nativeHint, legacyTried = {}, -100, {}
local lastLinkReply, replyWindow, replyCount = {}, -100, 0
local HANDSHAKE_TIMEOUT, LINK_RETRY, PEER_FOR = 180, 4, 65
local outbox, localPending, chatSeen, syncRequests = {}, {}, {}, {}
local historyReplyAt, historyGuildDue, historyRemoteDue = {}, nil, nil
local historyGuildAt, historyRemoteAt, lastBufferTick, lastGateway = -100, -100, -100, nil
local everConnected, disconnectedAt, outageNotified, wasConnected = false, nil, false, false
local OUTBOX_FOR, HISTORY_FOR, HISTORY_LIMIT = 30, 300, 100
local outboxSequence, nativeReadyAt = 0, 0
local QueueCross, RequestHistory, HistoryTick, BufferTick
local function IsTextKind(kind)
    return kind == "CHAT" or kind == "NATIVE" or kind == "HREC" or kind == "ANNOUNCE" or kind == "ANNSTATE"
end
function U.OtherGuild() return U.guild == 1 and 2 or 1 end
function U.IsTrustOfficer(name)
    local row = U.guild and U.own and U.own[name or U.me]
    return row ~= nil and (row.rank == 0 or row.rank == 1)
end
function U.CanRelay(name)
    name = name or U.me
    if not U.guild or not U.own or not U.own[name] then return false end
    return U.IsTrustOfficer(name) or U.db and U.db.approvedRelays and U.db.approvedRelays[name] == U.guild or false
end
function U.TrustedPeer(name)
    if not U.db or not U.guild or not name or U.own[name] then return nil end
    local c = U.db.contacts[name]
    if c and c.approved == true and c.guild == U.OtherGuild() then return c.guild end
end
function U.TrustedTransferPeer(name)
    return U.TransferPeer and U.TransferPeer(name) or nil
end
function U.CanStartLink(name)
    if not U.guild or not U.own or not U.own[U.me] then return false end
    if name == nil then return U.IsTrustOfficer() end
    name = U.Name(name)
    if not name or name == U.me or U.own[name] then return false end
    return U.IsTrustOfficer() or U.CanRelay() and U.TrustedPeer(name) == U.OtherGuild() or false
end
local function Contact(name, guild, share, approve)
    name, guild = U.Name(name), tonumber(guild)
    if not name or name == U.me or U.own[name] or not U.GUILDS[guild] or guild == U.guild then return false end
    local old = U.db.contacts[name]
    if not approve and (not old or old.approved ~= true or old.guild ~= guild) then return false end
    local fresh = not old or old.addon ~= true or old.guild ~= guild
    U.db.contacts[name] = { guild = guild, at = U.stamp(), addon = true, approved = true,
        pairedBy = old and old.guild == guild and old.approved == true and old.pairedBy or nil }
    local contacts = {}
    for n, c in pairs(U.db.contacts) do contacts[#contacts + 1] = { name = n, at = c.at or 0, addon = c.addon == true } end
    table.sort(contacts, function(a, b)
        if a.addon ~= b.addon then return a.addon end
        if a.at ~= b.at then return a.at > b.at end
        return a.name < b.name
    end)
    for i = 31, #contacts do U.db.contacts[contacts[i].name] = nil end
    if share and (fresh or approve) and U.IsTrustOfficer() then U.Queue("CONTACT", { name, guild }, "GUILD", nil, true) end
    return true
end
function U.AddContact(name, guild, share) return Contact(name, guild, share, false) end
function U.ApproveContact(name, guild, share) return Contact(name, guild, share, true) end
local function PairReady(name)
    name = name or U.me
    if not U.CanRelay(name) then return false end
    if name ~= U.me then return U.peers[name] and U.peers[name].pairReady == true or false end
    for _, contact in pairs(U.db.contacts) do
        if contact.approved == true and type(contact.pairedBy) == "table" and contact.pairedBy[U.me] == true
            and contact.guild == U.OtherGuild() then return true end
    end
    return false
end
function U.AuthorizeRelay(name, allowed)
    name = U.Name(name)
    if not U.IsTrustOfficer() or not name or not U.own[name] or U.IsTrustOfficer(name) or type(allowed) ~= "boolean" then return false end
    if allowed and not (U.db.approvedRelays and U.db.approvedRelays[name] == U.guild) then
        local count = 0
        for member, guild in pairs(U.db.approvedRelays or {}) do if guild == U.guild and U.own[member] then count = count + 1 end end
        if count >= 32 then U.Print("Можно назначить не более 32 резервных связных одной гильдии.") return false end
    end
    if not U.Queue("RELAY", { name, allowed and "1" or "0" }, "GUILD", nil, true) then return false end
    U.db.approvedRelays = U.db.approvedRelays or {}
    U.db.approvedRelays[name] = allowed and U.guild or nil
    if U.Refresh then U.Refresh() end
    return true
end
function U.ShareTrust()
    if not U.IsTrustOfficer() then return false end
    local jobs, relays = {}, {}
    for name, contact in pairs(U.db.contacts) do
        if contact.approved == true and contact.guild == U.OtherGuild() then
            jobs[#jobs + 1] = { kind = "CONTACT", fields = { name, contact.guild }, dist = "GUILD", priority = true }
        end
    end
    for name, guild in pairs(U.db.approvedRelays or {}) do
        if guild == U.guild and U.own[name] and not U.IsTrustOfficer(name) then relays[#relays + 1] = name end
    end
    table.sort(relays)
    if #relays > 32 then return false end
    jobs[#jobs + 1] = { kind = "RELAYSET", fields = { U.guild, U.Pack(relays) }, dist = "GUILD", priority = true }
    if not U.QueueBatch(jobs) then return false end
    U.Print("Подтверждённые контакты и разрешения отправлены участникам своей гильдии, которые сейчас в игре с аддоном.")
    return true
end
-- Membership alone does not prove that a player runs this addon.
function U.LearnRosterContacts() end
local function Alive(name)
    if not name or not U.guild then return false end
    local row = U.own[name]
    if not row or not row.online then return false end
    if name == U.me then return true end
    local p = U.peers[name]
    return p and p.guild == U.guild and U.clock() - p.at < PEER_FOR
end
function U.GatewayName()
    if not U.guild or not Alive(U.me) then return nil end
    local best, since
    local function Consider(name, started)
        if not best or started < since or (started == since and name < best) then best, since = name, started end
    end
    if PairReady() and U.remote and U.clock() - U.remote.at < PEER_FOR and U.gatewaySince then Consider(U.me, U.gatewaySince) end
    for name, p in pairs(U.peers) do
        if PairReady(name) and Alive(name) and p.remote and p.leader == name then Consider(name, p.since or 0) end
    end
    if best then return best end
    best = PairReady() and U.me or nil
    for name in pairs(U.peers) do if PairReady(name) and Alive(name) and (not best or name < best) then best = name end end
    return best
end
function U.IsGateway() return U.guild ~= nil and U.GatewayName() == U.me end
function U.CandidateNames()
    local names = {}
    if PairReady() and Alive(U.me) then names[1] = U.me end
    for name in pairs(U.peers) do if PairReady(name) and Alive(name) then names[#names + 1] = name end end
    table.sort(names)
    while #names > 8 do table.remove(names) end
    return U.Pack(names)
end
function U.LearnCandidates(raw, guild)
    local names = U.Unpack(raw, 8)
    if names then for _, name in ipairs(names) do U.AddContact(name, guild) end end
end
function U.Connected()
    local gateway = U.GatewayName()
    if not gateway then return false end
    if gateway == U.me then return U.remote ~= nil and U.clock() - U.remote.at < PEER_FOR end
    return U.linkState ~= nil and U.linkState.gateway == gateway and U.clock() - U.linkState.at < PEER_FOR
end
function U.SetupState()
    if U.Connected() then
        return { state = "connected", target = U.setup.target or U.db.setupContact, message = "Гильдии соединены. Общий чат работает; состав загружается или обновляется." }
    end
    if U.setup.state == "connected" then
        return { state = "connecting", target = U.setup.target, message = "Восстанавливаем связь со второй гильдией…" }
    end
    return U.setup
end
local function Setup(state, target, message)
    U.setup = { state = state, target = target, message = message }
    if U.Refresh then U.Refresh() end
end
function U.NetworkReset()
    if U.PresenceReset then U.PresenceReset() end
    for id in pairs(outbox) do if U.CancelQueued then U.CancelQueued("out:" .. id) end end
    outbox, localPending, chatSeen, syncRequests = {}, {}, {}, {}
    historyGuildDue, historyRemoteDue, lastGateway = nil, nil, nil
    wasConnected, disconnectedAt, outageNotified = false, nil, false
    U.peers, U.remote, U.linkState, U.gatewaySince = {}, nil, nil, nil
    U.links, U.inboundLinks, U.probes, U.pings = {}, {}, {}, {}
    U.own = {}
    U.ClearQueue()
    lastHello, lastPing, U.snapshotDue = -100, -100, 0
end
function U.SayHello()
    if not U.guild or not U.me then return false end
    local contacts, list = {}, {}
    for n, c in pairs(U.db.contacts) do
        if c.approved == true and c.guild ~= U.guild and c.addon == true then list[#list + 1] = { name = n, at = c.at or 0 } end
    end
    table.sort(list, function(a, b) if a.at == b.at then return a.name < b.name end return a.at > b.at end)
    for i = 1, math.min(3, #list) do contacts[#contacts + 1] = list[i].name end
    local gateway = U.GatewayName()
    local remote = gateway == U.me and U.remote and U.clock() - U.remote.at < PEER_FOR and U.remote.name or ""
    local queued = U.Queue("HELLO", { U.guild, U.VERSION, U.Pack(contacts), remote, gateway or "", remote ~= "" and (U.gatewaySince or 0) or 0, PairReady() and "1" or "0" }, "GUILD", nil, true)
    if queued then lastHello = U.clock() end
    return queued
end
function U.OnRosterReady()
    U.SayHello(); lastPing = -100
    nativeReadyAt = U.clock() + 2
    if RequestHistory then RequestHistory(false) end
end
local function SendPing(name, introduction)
    if not U.guild or not U.CanRelay() or not Alive(U.me) or not U.TrustedPeer(name) or (not introduction and not U.IsGateway()) then return false end
    if U.Queue("PING", { U.guild, U.CandidateNames(), U.GatewayName() or "" }, "WHISPER", name, true) then
        U.probes[name] = { at = U.clock(), untilAt = U.clock() + 30 }
        U.pings[name] = U.clock()
        return true
    end
    return false
end
function U.SetRemote(name, paired)
    if paired and U.CanRelay() and U.TrustedPeer(name) then
        local contact = U.db.contacts[name]
        if type(contact.pairedBy) ~= "table" then contact.pairedBy = {} end
        contact.pairedBy[U.me] = true
    end
    if not U.IsGateway() or not U.TrustedPeer(name) then return false end
    local changed = not U.remote or U.remote.name ~= name
    if not U.gatewaySince then U.gatewaySince = U.stamp() end
    U.remote = { name = name, at = U.clock() }
    U.linkState = { name = name, gateway = U.me, at = U.clock() }
    U.AddContact(name, U.OtherGuild(), changed)
    if changed then
        U.snapshotDue = 0
        U.SayHello()
        if RequestHistory then RequestHistory(true) end
        if U.ExtensionSync then U.ExtensionSync("remote") end
    end
    if U.setup.state == "connecting" or U.setup.state == "idle" then Setup("connected", U.setup.target or name, "Гильдии соединены. Можно писать в общий чат.") end
    return true
end
local function ValidNonce(n) return U.Text(n, 40) and n ~= "" and n:match("^[%d%.]+$") ~= nil end
local function LinkSend(name, mode, nonce, challenge)
    return U.Queue("LINK", { "2", mode, U.guild, nonce, challenge or "" }, "WHISPER", name, true)
end
local function ReplyLink(name, mode, nonce, challenge)
    local now = U.clock()
    if now - replyWindow > 10 then replyWindow, replyCount = now, 0 end
    if replyCount >= 40 or now - (lastLinkReply[name] or -100) < 0.2 then return false end
    if LinkSend(name, mode, nonce, challenge) then
        lastLinkReply[name], replyCount = now, replyCount + 1
        return true
    end
    return false
end
function U.Link(name)
    if not U.guild then
        Setup("error", nil, "Персонаж должен состоять в одной из двух гильдий союза.")
        U.Print(U.setup.message); return false
    end
    if not U.own[U.me] then
        U.RequestRoster()
        Setup("error", name, "Состав вашей гильдии ещё загружается. Повторите через несколько секунд.")
        U.Print(U.setup.message); return false
    end
    if not U.CanStartLink(name) then
        Setup("error", name, "Новое соединение настраивает глава или офицер с игровым рангом 0–1. Одобренный ретранслятор может подключаться только к ранее одобренным контактам.")
        U.Print(U.setup.message); return false
    end
    name = U.Name(name)
    if not name or name == U.me or U.own[name] then
        Setup("error", name, "Укажите полное имя офицера второй гильдии: Имя Фамилия.")
        U.Print(U.setup.message); return false
    end
    if U.ChatLocked() then
        Setup("error", name, "Игра временно ограничила обмен сообщениями. Повторите после снятия ограничения.")
        U.Print(U.setup.message); return false
    end
    local active = U.links[name]
    if active and U.clock() < active.untilAt then
        Setup("connecting", name, "Ожидаем ответа офицера " .. U.SafeDisplay(name) .. "…")
        return true
    end
    local nonce = U.NewID()
    if not LinkSend(name, "hello", nonce, "") then
        Setup("error", name, "Очередь сообщений заполнена. Повторите соединение через несколько секунд.")
        U.Print(U.setup.message); return false
    end
    U.links[name] = { outbound = true, nonce = nonce, guild = U.OtherGuild(), phase = "hello", at = U.clock(), untilAt = U.clock() + HANDSHAKE_TIMEOUT, nextAt = U.clock() + LINK_RETRY }
    U.db.setupContact = name
    Setup("connecting", name, "Ожидаем подтверждения соединения от " .. U.SafeDisplay(name) .. "…")
    U.Print("Соединяем гильдии через " .. U.SafeDisplay(name) .. ". Новый контакт должен один раз подтвердить запрос на второй стороне после проверки полного имени.")
    return true
end
local function InboundLink(name)
    name = U.Name(name)
    if not name then return nil end
    if U.inboundLinks[name] then return name, U.inboundLinks[name] end
    for canonical, request in pairs(U.inboundLinks) do
        if U.Fold(canonical) == U.Fold(name) then return canonical, request end
    end
end
function U.PendingLink()
    if not U.IsTrustOfficer() then return nil end
    local chosen, request
    for name, pending in pairs(U.inboundLinks) do
        if not pending.approved and U.clock() <= pending.untilAt and (not request or pending.at < request.at or pending.at == request.at and name < chosen) then
            chosen, request = name, pending
        end
    end
    if request then return { name = chosen, guild = request.guild, untilAt = request.untilAt } end
end
function U.AcceptLink(name)
    local canonical, request = InboundLink(name)
    if not U.IsTrustOfficer() or not request or request.approved or U.clock() > request.untilAt or U.ChatLocked() then return false end
    request.approved, request.challenge = true, U.NewID()
    request.untilAt = U.clock() + HANDSHAKE_TIMEOUT
    ReplyLink(canonical, "challenge", request.nonce, request.challenge)
    if U.Refresh then U.Refresh() end
    return true
end
function U.DeclineLink(name)
    local canonical, request = InboundLink(name)
    if not U.IsTrustOfficer() or not request or U.clock() > request.untilAt then return false end
    U.inboundLinks[canonical] = nil
    ReplyLink(canonical, "error", request.nonce, "declined")
    if U.Refresh then U.Refresh() end
    return true
end
local function OutgoingLink(sender, nonce, guild)
    local direct = U.links[sender]
    if direct then return direct end
    local folded = U.Fold(sender)
    for name, pending in pairs(U.links) do
        if U.Fold(name) == folded and pending.outbound and pending.nonce == nonce
            and pending.guild == guild and U.clock() <= pending.untilAt then
            U.links[name], U.links[sender] = nil, pending
            if U.setup.target == name then U.setup.target = sender end
            if U.db.setupContact == name then U.db.setupContact = sender end
            return pending
        end
    end
end
local function TakeLink(f, sender)
    if #f ~= 5 or f[1] ~= "2" or not U.guild or U.own[sender] or not ValidNonce(f[4]) then return end
    local mode, guild, nonce, challenge = f[2], tonumber(f[3]), f[4], f[5]
    if guild ~= U.OtherGuild() then return end
    if mode == "hello" then
        if challenge ~= "" then return end
        if not U.own[U.me] then U.RequestRoster(); ReplyLink(sender, "wait", nonce, "roster"); return end
        if not U.CanRelay() then ReplyLink(sender, "error", nonce, "officer"); return end
        local p = U.inboundLinks[sender]
        if p and p.nonce == nonce and U.clock() <= p.untilAt then
            if p.approved then ReplyLink(sender, "challenge", nonce, p.challenge)
            else ReplyLink(sender, "wait", nonce, "approval") end
            return
        end
        local n = 0; for _ in pairs(U.inboundLinks) do n = n + 1 end
        if n >= 12 then return end
        local approved = U.TrustedPeer(sender) == guild
        if not approved and not U.IsTrustOfficer() then ReplyLink(sender, "error", nonce, "approval"); return end
        p = { nonce = nonce, guild = guild, approved = approved, at = U.clock(), untilAt = U.clock() + HANDSHAKE_TIMEOUT }
        U.inboundLinks[sender] = p
        if approved then
            p.challenge = U.NewID(); ReplyLink(sender, "challenge", nonce, p.challenge)
        else
            Setup("approval", sender, "Запрос соединения от " .. U.SafeDisplay(sender) .. ". Внешняя гильдия и ранг не проверены игрой. Проверьте полное имя с руководителем второй гильдии, затем подтвердите или отклоните запрос.")
            ReplyLink(sender, "wait", nonce, "approval")
        end
    elseif mode == "prove" then
        local p = U.inboundLinks[sender]
        if not p or not p.approved or p.nonce ~= nonce or p.challenge ~= challenge or U.clock() > p.untilAt or not U.CanRelay() then return end
        -- A challenge proves only liveness. A local native officer must first approve
        -- the exact external endpoint; authorized relay operators remain trusted.
        if not p.completed then
            p.completed = true
            U.ApproveContact(sender, guild, true)
            U.SetRemote(sender, true)
            U.SayHello()
            lastPing = -100
        end
        ReplyLink(sender, "ready", nonce, challenge)
        -- A setup officer may not be the elected bridge. Introduce the bridge
        -- through this proved endpoint before unknown bridges can contact it.
        SendPing(sender, true)
    else
        local p = OutgoingLink(sender, nonce, guild)
        if not p or not p.outbound or p.nonce ~= nonce or p.guild ~= guild or U.clock() > p.untilAt then return end
        if not U.CanStartLink(sender) then U.links[sender] = nil; return end
        if mode == "challenge" then
            if not ValidNonce(challenge) or (p.challenge and p.challenge ~= challenge) then return end
            p.challenge, p.phase, p.nextAt = challenge, "prove", U.clock() + LINK_RETRY
            LinkSend(sender, "prove", nonce, challenge)
            Setup("connecting", sender, "Офицер ответил. Проверяем соединение…")
        elseif mode == "ready" then
            if p.phase ~= "prove" or not p.challenge or p.challenge ~= challenge then return end
            U.ApproveContact(sender, guild, true); U.links[sender] = nil
            U.SetRemote(sender, true)
            U.SayHello(); lastPing = -100
            Setup("connecting", sender, "Ответ проверен. Соединяем общий чат гильдий…")
            SendPing(sender, true)
        elseif mode == "wait" and p.phase == "hello" and challenge == "roster" then
            Setup("connecting", sender, "У офицера ещё загружается состав гильдии. Повторяем соединение…")
        elseif mode == "wait" and p.phase == "hello" and challenge == "approval" then
            Setup("connecting", sender, "Ожидаем однократного подтверждения точного имени на второй стороне. Внешняя гильдия и роль не могут быть проверены этим аддоном автоматически.")
        elseif mode == "error" and (challenge == "declined" or challenge == "approval") then
            U.links[sender] = nil
            Setup("error", sender, challenge == "declined" and "Вторая сторона отклонила запрос соединения." or "Новый контакт должен подтвердить настоящий глава или офицер второй гильдии.")
            U.Print(U.setup.message)
        elseif mode == "error" and p.phase == "hello" and challenge == "officer" then
            U.links[sender] = nil
            Setup("error", sender, "Этот персонаж не является офицером второй гильдии. Укажите её главу или офицера.")
            U.Print(U.setup.message)
        end
    end
end
local function LinkTick(now)
    for name, p in pairs(U.links) do
        if now > p.untilAt then
            U.links[name] = nil
            if U.setup.target == name then
                Setup("error", name, "Соединение не подтверждено за 3 минуты. Проверьте полное имя, онлайн, одинаковую актуальную версию аддона и подтверждение запроса на второй стороне.")
                U.Print(U.setup.message)
            end
        elseif now >= p.nextAt then
            if U.CanStartLink(name) then LinkSend(name, p.phase == "prove" and "prove" or "hello", p.nonce, p.challenge or "") end
            p.nextAt = now + LINK_RETRY
        end
    end
    for name, p in pairs(U.inboundLinks) do if now > p.untilAt then U.inboundLinks[name] = nil end end
end
function U.Status()
    if not U.guild then return "Вы не в одной из гильдий союза." end
    if not U.own[U.me] then return "Загружается состав вашей гильдии…" end
    local gateway, remote = U.GatewayName(), nil
    if U.Connected() then remote = gateway == U.me and U.remote.name or U.linkState.name end
    return "Гильдия: " .. U.GUILDS[U.guild] .. ". Посредник: " .. tostring(gateway) .. ". Связь: " .. (remote or "ожидание второй гильдии") .. ". В очереди: " .. U.QueueSize()
end

local function StableID()
    return tostring(U.guild) .. ":" .. U.me .. ":" .. U.NewID()
end
local function RecordFields(entry)
    return { entry.guild, entry.name, entry.text, entry.id, entry.time or entry.at }
end
local function ValidateRecord(f, guild)
    if #f ~= 5 or tonumber(f[1]) ~= guild or not U.Name(f[2]) or not U.Text(f[3], 1200) then return nil end
    if not U.Text(f[4], 240) or f[4] == "" or f[4]:find("[%c|]") or f[4]:sub(1, 2) ~= tostring(guild) .. ":" then return nil end
    local at = tonumber(f[5])
    if not at or at > U.stamp() + 60 or U.stamp() - at > HISTORY_FOR then return nil end
    return at
end
local function Status(id, state, announce)
    local seen = chatSeen[id]
    if seen and seen.state == "delivered" and state ~= "delivered" then return end
    chatSeen[id] = { at = U.clock(), state = state }
    if state ~= "pending" then localPending[id] = nil end
    if U.ChatStatus then U.ChatStatus(id, state) end
    if announce and U.IsGateway() then
        U.Queue("STATE", { id, state }, "GUILD", nil, true, false, nil, true, U.clock() + OUTBOX_FOR)
    end
end
local function ShowRecord(f, native, state, replayed)
    local id, at = f[4], tonumber(f[5])
    local previous = chatSeen[id]
    if previous and previous.state ~= "pending" and state == "pending" then state = previous.state end
    chatSeen[id] = { at = U.clock(), state = state }
    if state == "pending" then
        localPending[id] = U.clock() + math.max(0, OUTBOX_FOR - (U.stamp() - at))
    else localPending[id] = nil end
    U.Chat(tonumber(f[1]), U.Name(f[2]), f[3], native, { id = id, at = at, status = state, replayed = replayed == true })
end
local function Recent()
    if U.ChatRecent then return U.ChatRecent(HISTORY_LIMIT, U.stamp() - HISTORY_FOR) end
    return U.history or {}
end
function U.ChatOutboxCount()
    local n = 0; for _ in pairs(outbox) do n = n + 1 end; return n
end
QueueCross = function(f)
    if not U.IsGateway() then return false end
    local id, now = f[4], U.clock()
    if outbox[id] then return true end
    local known = chatSeen[id]
    if known and known.state ~= "pending" then return false end
    local remaining = OUTBOX_FOR - (U.stamp() - tonumber(f[5]))
    if remaining <= 0 or U.ChatOutboxCount() >= 100 then Status(id, "local-only", true); return false end
    outboxSequence = outboxSequence + 1
    outbox[id] = { fields = f, untilAt = now + math.min(OUTBOX_FOR, remaining), nextAt = now, order = outboxSequence, id = id }
    return true
end
local function AcceptAck(f)
    if #f ~= 2 or tonumber(f[1]) ~= U.guild or not U.Text(f[2], 240) then return false end
    local id = f[2]
    if not outbox[id] and not chatSeen[id] then return false end
    outbox[id] = nil
    if U.CancelQueued then U.CancelQueued("out:" .. id) end
    Status(id, "delivered", true)
    return true
end
BufferTick = function(now)
    for id, untilAt in pairs(localPending) do
        if now >= untilAt then Status(id, "local-only", false) end
    end
    for id, item in pairs(outbox) do
        if now >= item.untilAt then
            outbox[id] = nil
            if U.CancelQueued then U.CancelQueued("out:" .. id) end
            Status(id, "local-only", true)
        end
    end
    if not U.IsGateway() or not U.Connected() or now - lastBufferTick < 0.5 then return end
    lastBufferTick = now
    local pending = {}
    for _, item in pairs(outbox) do if now >= item.nextAt then pending[#pending + 1] = item end end
    table.sort(pending, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
    for i = 1, math.min(3, #pending) do
        local item = pending[i]
        if U.Queue("CHAT", item.fields, "WHISPER", U.remote.name, true, true, nil, true, item.untilAt, "out:" .. item.id) then
            -- Allow the queued fragments to leave before repeating a missing acknowledgement.
            item.nextAt = now + math.max(3, U.QueueSize() * 0.2 + 2)
        else item.nextAt = now + 1 end
    end
end
local function KnownIDs()
    local ids = {}
    for _, entry in ipairs(Recent()) do if entry.id then ids[#ids + 1] = entry.id end end
    while #ids > HISTORY_LIMIT do table.remove(ids, 1) end
    return U.Pack(ids)
end
RequestHistory = function(remote)
    if remote then historyRemoteDue = U.clock() else historyGuildDue = U.clock() end
end
function U.RequestHistory() RequestHistory(false); RequestHistory(true) end
local function SendHistory(f, dist, target)
    if #f ~= 4 or not U.Name(f[4]) or not U.IsGateway() then return false end
    local knownList, since = U.Unpack(f[3], HISTORY_LIMIT), tonumber(f[2])
    if not knownList or not since then return false end
    since = math.max(U.stamp() - HISTORY_FOR, math.min(since, U.stamp()))
    local key = dist == "GUILD" and "guild" or target
    if U.clock() - (historyReplyAt[key] or -100) < 10 then return true end
    local known, jobs, bytes, candidates, sentIDs = {}, {}, 0, {}, {}
    for _, id in ipairs(knownList) do if #id > 240 then return false end; known[id] = true end
    for _, entry in ipairs(Recent()) do
        if entry.id and not known[entry.id] and entry.status == "delivered" and (entry.time or 0) >= since then candidates[#candidates + 1] = entry end
    end
    local count = 0
    for _, entry in ipairs(candidates) do
        local fields = RecordFields(entry)
        local size = #U.Pack(fields) + 40
        if count >= 20 or bytes + size > 12000 then break end
        jobs[#jobs + 1] = { kind = "HREC", fields = fields, dist = dist, target = target,
            priority = false, logged = true, requiresGateway = true, expiresAt = U.clock() + OUTBOX_FOR }
        sentIDs[#sentIDs + 1] = entry.id
        bytes, count = bytes + size, count + 1
    end
    jobs[#jobs + 1] = { kind = "HEND", fields = { U.guild, count < #candidates and "1" or "0", U.Pack(sentIDs), f[4] }, dist = dist, target = target,
        priority = false, requiresGateway = true, expiresAt = U.clock() + OUTBOX_FOR }
    if not U.QueueBatch(jobs) then return false end
    historyReplyAt[key] = U.clock()
    return true
end
HistoryTick = function(now)
    if not U.guild or not U.own[U.me] then return end
    if historyGuildDue and now >= historyGuildDue and now - historyGuildAt >= 10 then
        local f = { U.guild, U.stamp() - HISTORY_FOR, KnownIDs(), U.me }
        local queued
        if U.IsGateway() then queued = true
        else queued = U.Queue("HREQ", f, "GUILD", nil, true, false, nil, false, now + OUTBOX_FOR) end
        if queued then
            historyGuildAt = now
            if U.IsGateway() then historyGuildDue = nil else historyGuildDue = now + 15 end
        end
    end
    if historyRemoteDue and now >= historyRemoteDue and now - historyRemoteAt >= 10 and U.IsGateway() and U.Connected() then
        if U.Queue("HREQ", { U.guild, U.stamp() - HISTORY_FOR, KnownIDs(), U.me }, "WHISPER", U.remote.name, true, false, nil, true, now + OUTBOX_FOR) then
            historyRemoteAt, historyRemoteDue = now, now + 15
        end
    end
end
local function HistoryEnd(f, remote)
    if #f ~= 4 or U.Name(f[4]) ~= U.me or (f[2] ~= "0" and f[2] ~= "1") then return false end
    local ids = U.Unpack(f[3], 20)
    if not ids then return false end
    local missing = f[2] == "1"
    for _, id in ipairs(ids) do if not chatSeen[id] then missing = true end end
    if remote then historyRemoteDue = missing and U.clock() + 2 or nil
    else historyGuildDue = missing and U.clock() + 2 or nil end
    return true
end
function U.RequestFullRoster(guild, source, reason)
    if guild ~= U.OtherGuild() or not U.guild then return false end
    local now = U.clock()
    if now - (syncRequests[guild] or -100) < 10 then return false end
    local queued
    if U.IsGateway() and U.Connected() then
        queued = U.Queue("ASK", { U.guild }, "WHISPER", U.remote.name, true, false, nil, true)
    elseif not U.IsGateway() then queued = U.Queue("SYNC", { guild }, "GUILD", nil, true) end
    if queued then syncRequests[guild] = now end
    return queued == true
end
function U.Emit(kind, fields, logged)
    if not U.guild then return false end
    local chat = kind == "CHAT" or kind == "NATIVE"
    local jobs = { { kind = kind, fields = fields, dist = "GUILD", priority = true, logged = logged,
        expiresAt = chat and U.clock() + OUTBOX_FOR or nil, requiresGateway = kind == "NATIVE" } }
    if not chat and U.IsGateway() and U.Connected() then
        jobs[#jobs + 1] = { kind = kind, fields = fields, dist = "WHISPER", target = U.remote.name, priority = true, logged = logged, requiresGateway = true }
    end
    if not U.QueueBatch(jobs) then return false end
    U.HandleOwn(kind, fields, U.me, true)
    return true
end
function U.SendChat(text)
    if not U.guild then U.Print("Персонаж не состоит в гильдии союза.") return false end
    if not U.own[U.me] then U.RequestRoster(); U.Print("Состав гильдии ещё загружается. Повторите через несколько секунд.") return false end
    if not U.Text(text, 1200) then U.Print("Сообщение слишком длинное: максимум 1200 байт.") return false end
    text = U.Trim(text):gsub("[\r\n]", " ")
    if text == "" then return false end
    if U.clock() - lastChat < 1.5 then U.Print("Подождите полторы секунды между сообщениями.") return false end
    if U.ChatLocked() then U.Print("Forever временно ограничил обмен сообщениями. Повторите после снятия ограничения.") return false end
    if not U.Emit("CHAT", { U.guild, U.me, text, StableID(), U.stamp() }, true) then U.Print("Очередь сообщений заполнена. Сообщение не отправлено; повторите позже.") return false end
    lastChat = U.clock()
    return true
end
function U.HandleOwn(kind, f, sender, mine)
    if kind == "ADDONS" then
        if U.PresenceMessage then U.PresenceMessage(kind, f, sender, false) end
        return false
    end
    if kind == "CHAT" or kind == "NATIVE" then
        if not ValidateRecord(f, U.guild) then return false end
        if kind == "CHAT" and U.Name(f[2]) ~= sender then return false end
        if kind == "NATIVE" and (sender ~= U.GatewayName() or not U.own[U.Name(f[2])]) then return false end
        local forwarding = kind ~= "NATIVE" or U.db.bridgeGuildChat
        ShowRecord(f, kind == "NATIVE", forwarding and "pending" or "local-only", false)
        if U.IsGateway() then
            if forwarding then QueueCross(f) else Status(f[4], "local-only", true) end
        end
        return true
    elseif kind == "STATE" then
        if sender == U.GatewayName() and #f == 2 and chatSeen[f[1]] and (f[2] == "delivered" or f[2] == "local-only") then Status(f[1], f[2], false) end
        return false
    elseif kind == "HREQ" then
        if tonumber(f[1]) == U.guild and U.Name(f[4]) == sender and U.IsGateway() then SendHistory(f, "GUILD") end
        return false
    elseif kind == "HREC" then
        local guild = tonumber(f[1])
        if sender == U.GatewayName() and U.GUILDS[guild] and ValidateRecord(f, guild) then ShowRecord(f, guild == U.guild, "delivered", true) end
        return false
    elseif kind == "HEND" then
        if sender == U.GatewayName() and tonumber(f[1]) == U.guild then HistoryEnd(f, false) end
        return false
    elseif kind == "SYNC" then
        if U.IsGateway() and #f == 1 then U.RequestFullRoster(tonumber(f[1]), nil, "guild request") end
        return false
    end
    if U.TransferMessage(kind, f, sender, false) then return true end
    return U.ExtensionMessage and U.ExtensionMessage(kind, f, sender, false) == true or false
end
local function ActiveRemote()
    if not U.guild or not U.Connected() then return nil end
    return U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
end
local function KnownAuthor(name, guild)
    if not U.RosterFresh(guild) then return false end
    local cache = U.db.rosters[guild]
    local rows = guild == U.guild and U.own or cache and cache.rows
    return rows ~= nil and rows[name] ~= nil
end
function U.HandleRemote(kind, f, source, direct)
    local guild = U.TrustedPeer(source)
    if not guild then return false end
    if kind == "ADDONS" then return U.PresenceMessage and U.PresenceMessage(kind, f, source, true) == true or false end
    if kind == "ROSTER" then
        if tonumber(f[1]) ~= guild then return false end
        return U.TakeRoster(f, source)
    elseif kind == "DELTA" then
        if tonumber(f[1]) ~= guild or not U.TakeRosterDelta then return false end
        return U.TakeRosterDelta(f, source)
    elseif kind == "CHAT" or kind == "HREC" then
        if source ~= ActiveRemote() then return false end
        local recordGuild = guild
        if kind == "HREC" then
            local expected = U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
            if not U.Connected() or expected ~= source then return false end
            recordGuild = tonumber(f[1])
            if not U.GUILDS[recordGuild] or not ValidateRecord(f, recordGuild) then return false end
            if recordGuild == U.guild then
                local existing = U.chatByID and U.chatByID[f[4]]
                if existing and (existing.guild ~= recordGuild or existing.name ~= U.Name(f[2]) or existing.text ~= f[3]) then return false end
                -- A forgotten body cannot attest a changed row. Let guildmates
                -- with a retained matching body validate the unchanged replay.
                if not existing and U.chatSeen and U.chatSeen[f[4]] then return true end
            end
        end
        if not ValidateRecord(f, recordGuild) then return false end
        if not KnownAuthor(U.Name(f[2]), recordGuild) then return false end
        ShowRecord(f, kind == "HREC" and recordGuild == U.guild, "delivered", kind == "HREC")
        if direct and kind == "CHAT" then
            U.Queue("ACK", { guild, f[4] }, "WHISPER", source, true, false, nil, true, U.clock() + OUTBOX_FOR)
        end
        return true
    end
    if U.TransferMessage(kind, f, source, true) then return true end
    return U.ExtensionMessage and U.ExtensionMessage(kind, f, source, true) == true or false
end
function U.Handle(kind, f, dist, sender, id)
    if kind == "LINK" and dist == "WHISPER" then TakeLink(f, sender); return end
    if dist == "GUILD" then
        if not U.guild or not U.own[sender] then return end
        if kind == "HELLO" then
            if (#f ~= 4 and #f ~= 6 and #f ~= 7) or tonumber(f[1]) ~= U.guild then return end
            if #f == 7 and f[7] ~= "0" and f[7] ~= "1" then return end
            local fresh = not U.peers[sender]
            local remote, leader = U.Name(f[4]), #f >= 6 and U.Name(f[5]) or sender
            local since = #f >= 6 and tonumber(f[6]) or 0
            if not since or since < 0 or since > U.stamp() + 60 then since = 0 end
            -- A native officer can endorse the endpoint in this very HELLO.
            -- Apply that endorsement before checking the advertised connection.
            local contacts = U.Unpack(f[3], 3)
            if contacts then for _, name in ipairs(contacts) do
                if U.IsTrustOfficer(sender) then U.ApproveContact(name, U.OtherGuild())
                else U.AddContact(name, U.OtherGuild()) end
            end end
            if not U.CanRelay(sender) or not remote or U.TrustedPeer(remote) ~= U.OtherGuild() then remote = nil end
            U.peers[sender] = { at = U.clock(), guild = U.guild, remote = remote, leader = leader, since = since,
                pairReady = #f == 7 and f[7] == "1" and U.CanRelay(sender) }
            if U.PresenceHello then U.PresenceHello(sender, f[2]) end
            local gateway = U.GatewayName()
            if sender == gateway then
                if remote then
                    U.AddContact(remote, U.OtherGuild())
                    U.linkState = { name = remote, gateway = sender, at = U.clock() }
                elseif U.linkState and U.linkState.gateway == sender then U.linkState = nil end
            end
            if U.linkState and U.linkState.gateway ~= gateway then U.linkState = nil end
            if fresh and U.IsGateway() then
                U.SayHello()
                if U.ExtensionSync then U.ExtensionSync("guild") end
                if U.remote and U.clock() - lastAsk > 10 then
                    lastAsk = U.clock()
                    U.Queue("ASK", { U.guild }, "WHISPER", U.remote.name, true, false, nil, true)
                    SendPing(U.remote.name)
                end
            end
        elseif kind == "CONTACT" then
            if #f == 2 and tonumber(f[2]) == U.OtherGuild() and U.IsTrustOfficer(sender) then U.ApproveContact(f[1], f[2]); lastPing = -100 end
        elseif kind == "RELAY" then
            local name = #f == 2 and U.Name(f[1])
            if not name or not U.IsTrustOfficer(sender) or not U.own[name] or U.IsTrustOfficer(name) or (f[2] ~= "0" and f[2] ~= "1") then return end
            U.db.approvedRelays = U.db.approvedRelays or {}
            U.db.approvedRelays[name] = f[2] == "1" and U.guild or nil
            if U.Refresh then U.Refresh() end
        elseif kind == "RELAYSET" then
            if #f ~= 2 or tonumber(f[1]) ~= U.guild or not U.IsTrustOfficer(sender) then return end
            local names = U.Unpack(f[2], 32)
            if not names then return end
            local approved = {}
            for _, name in ipairs(names) do
                if U.Name(name) ~= name or not U.own[name] or U.IsTrustOfficer(name) or approved[name] then return end
                approved[name] = U.guild
            end
            for name, guild in pairs(U.db.approvedRelays or {}) do
                if (guild == 1 or guild == 2) and guild ~= U.guild and not approved[name] then approved[name] = guild end
            end
            U.db.approvedRelays = approved
            if U.Refresh then U.Refresh() end
        elseif kind == "REMOTE" then
            if #f ~= 3 or sender ~= U.GatewayName() then return end
            local fields = U.Unpack(f[2])
            if fields then U.HandleRemote(f[1], fields, U.Name(f[3])) end
        elseif U.HandleOwn(kind, f, sender) and kind ~= "CHAT" and kind ~= "NATIVE" and U.IsGateway() and U.Connected() then
            U.Queue(kind, f, "WHISPER", U.remote.name, true, IsTextKind(kind), nil, true)
        end
        return
    end
    if kind == "READY" and U.TrustedTransferPeer(sender) then
        if U.IsGateway() and U.TransferMessage(kind, f, sender, true) then
            U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, true, false, nil, true)
        end
        return
    end
    local guild = U.TrustedPeer(sender)
    if not guild then return end
    if kind == "PING" then
        if (#f ~= 2 and #f ~= 3) or tonumber(f[1]) ~= guild then return end
        U.AddContact(sender, guild)
        U.LearnCandidates(f[2], guild)
        U.Queue("PONG", { U.guild, U.GatewayName() or U.me, U.CandidateNames() }, "WHISPER", sender, true)
        local senderGateway = #f == 3 and U.Name(f[3]) or sender
        if senderGateway == sender and U.IsGateway() then U.SetRemote(sender) end
    elseif kind == "PONG" then
        if #f ~= 3 or tonumber(f[1]) ~= guild or not U.Name(f[2]) then return end
        local probe = U.probes[sender]
        if not probe or U.clock() > probe.untilAt then return end
        U.probes[sender] = nil
        U.AddContact(sender, guild, true)
        U.LearnCandidates(f[3], guild)
        if f[2] ~= sender then
            if U.AddContact(f[2], guild, true) then SendPing(f[2]) end
        elseif U.IsGateway() then U.SetRemote(sender) end
    elseif kind == "ASK" then
        if U.IsGateway() and U.clock() - (U.lastSnapshot or -100) > 10 then U.snapshotDue = 0 end
    elseif kind == "ACK" then
        if U.IsGateway() then AcceptAck(f) end
    elseif kind == "HREQ" then
        if U.IsGateway() and tonumber(f[1]) == guild and U.Name(f[4]) == sender then SendHistory(f, "WHISPER", sender) end
    elseif kind == "HEND" then
        if U.IsGateway() and tonumber(f[1]) == guild then HistoryEnd(f, true) end
    elseif kind == "READY" then
        if U.IsGateway() and U.TransferMessage(kind, f, sender, true) then
            U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, true, false, nil, true)
        end
    elseif U.IsGateway() then
        local key = sender .. ":" .. id
        if remoteSeen[key] then return end
        remoteSeen[key] = U.clock()
        if U.HandleRemote(kind, f, sender, true) then
            local priority = kind ~= "ROSTER" and kind ~= "DELTA" and kind ~= "HREC" and kind ~= "ADDONS"
            U.Queue("REMOTE", { kind, U.Pack(f), sender }, "GUILD", nil, priority, IsTextKind(kind), nil, true,
                kind == "HREC" and U.clock() + OUTBOX_FOR or nil)
        end
    end
end
function U.NetworkTick()
    local now = U.clock()
    LinkTick(now)
    BufferTick(now)
    if now - lastClean > 15 then
        lastClean = now; U.ProtocolClean()
        for k, t in pairs(remoteSeen) do if now - t > 180 then remoteSeen[k] = nil end end
        for k, t in pairs(lastLinkReply) do if now - t > 60 then lastLinkReply[k] = nil end end
        for k, p in pairs(U.probes) do if now > p.untilAt then U.probes[k] = nil end end
        for id, row in pairs(chatSeen) do if now - row.at > HISTORY_FOR then chatSeen[id] = nil end end
    end
    if not U.guild then return end
    if now - lastHello > 20 then U.SayHello() end
    if U.remote and now - U.remote.at > PEER_FOR then
        U.remote, U.gatewaySince = nil, nil
        if U.linkState and U.linkState.gateway == U.me then U.linkState = nil end
    end
    local gateway = U.GatewayName()
    if U.linkState and U.linkState.gateway ~= gateway then U.linkState = nil end
    if gateway ~= lastGateway then
        lastGateway = gateway
        if gateway == U.me then
            for _, entry in ipairs(Recent()) do
                if entry.guild == U.guild and entry.id and entry.status == "pending" and U.stamp() - (entry.time or 0) < OUTBOX_FOR then QueueCross(RecordFields(entry)) end
            end
        end
    end
    local connected = U.Connected()
    if connected then
        everConnected, disconnectedAt, outageNotified = true, nil, false
        if not wasConnected then RequestHistory(false); if U.IsGateway() then RequestHistory(true) end end
    elseif everConnected then
        disconnectedAt = disconnectedAt or now
        if now - disconnectedAt >= 60 and not outageNotified then
            outageNotified = true
            U.Print("Связь со второй гильдией временно недоступна. Аддон восстановит её автоматически.")
        end
    end
    wasConnected = connected and true or false
    HistoryTick(now)
    if U.PresenceTick then U.PresenceTick() end
    if gateway ~= U.me then U.remote, U.gatewaySince = nil, nil; return end
    if now - lastPing < 15 then return end
    lastPing = now
    if U.remote then SendPing(U.remote.name); return end
    local list = {}
    for name, c in pairs(U.db.contacts) do
        -- Old caches get one migration probe per login; new candidates are confirmed addon users.
        local eligible = c.approved == true and (c.addon == true or (c.addon == nil and not legacyTried[name]))
        if c.guild ~= U.guild and not U.own[name] and eligible and now - (U.pings[name] or -100) > 90 then list[#list + 1] = name end
    end
    table.sort(list, function(a, b)
        local ca, cb = U.db.contacts[a], U.db.contacts[b]
        if (ca.addon == true) ~= (cb.addon == true) then return ca.addon == true end
        if (ca.at or 0) ~= (cb.at or 0) then return (ca.at or 0) > (cb.at or 0) end
        return a < b
    end)
    for i = 1, math.min(3, #list) do
        local name = list[i]
        if SendPing(name) and U.db.contacts[name].addon == nil then legacyTried[name] = true end
    end
end
U.On("CHAT_MSG_GUILD", function(text, sender)
    if not U.guild or not U.IsGateway() or U.clock() < nativeReadyAt then return end
    if not U.Text(text, 1200) or not U.Public(sender) then
        if U.clock() - nativeHint > 120 then nativeHint = U.clock(); U.Print("Forever скрыл содержимое /г от аддонов. Для общего чата используйте /czu.") end
        return
    end
    sender = U.Name(sender)
    if not sender or not U.own[sender] then return end
    U.Emit("NATIVE", { U.guild, sender, text, StableID(), U.stamp() }, true)
end)
