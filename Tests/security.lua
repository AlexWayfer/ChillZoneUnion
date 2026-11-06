-- Adversarial wire regressions. Attackers retain their actual native guild and
-- their own server-stamped character name; no trusted contacts are injected.
local file = io.open("tests/simulation.lua", "rb") or io.open("ChillZoneUnion/Tests/simulation.lua", "rb")
assert(file, "simulation harness missing from tests or packaged addon")
local source = file:read("*a"); file:close()
local boundary = assert(source:find("\nlocal a = NewClient", 1, true), "simulation harness boundary missing")
local factory = assert(loadstring(source:sub(1, boundary - 1) .. "\n" .. [[
return { NewClient = NewClient, Step = Step, SetRosters = SetRosters, Count = Count,
    Reset = function() clients, wire, deliveryFilter = {}, {}, nil; time = time + 100 end,
    SetFilter = function(filter) deliveryFilter = filter end }
]]))
local H = factory()
local failures, sequence = 0, 100000
local function Check(label, vulnerable, detail)
    print((vulnerable and "VULNERABLE " or "PASS ") .. label .. " | " .. detail)
    if vulnerable then failures = failures + 1 end
end
local function SendEncoded(from, target, encoded, distribution)
    sequence = sequence + 1
    local id, size = tostring(sequence) .. ".1", 210
    local count = math.ceil(#encoded / size)
    for part = 1, count do
        local message = id .. "~" .. part .. "~" .. count .. "~" .. encoded:sub((part - 1) * size + 1, part * size)
        from.E.C_ChatInfo.SendAddonMessage(from.U.PREFIX, message, distribution or "WHISPER", target)
    end
end
local function Send(from, target, kind, fields, distribution)
    SendEncoded(from, target, "R" .. kind .. "~" .. from.U.Pack(fields), distribution)
end
local function Listen(attacker, responder)
    local buffers, received = {}, {}
    attacker.U.frame.scripts.OnEvent = function(_, event, prefix, message, distribution, stampedSender)
        if event ~= "CHAT_MSG_ADDON" and event ~= "CHAT_MSG_ADDON_LOGGED" then return end
        if prefix ~= attacker.U.PREFIX then return end
        local sender = attacker.U.Name(stampedSender)
        local id, part, count, body = message:match("^([%d%.]+)~(%d+)~(%d+)~(.*)$")
        if not id then return end
        part, count = tonumber(part), tonumber(count)
        local key = sender .. ":" .. id
        local batch = buffers[key] or { n = 0, parts = {} }; buffers[key] = batch
        if not batch.parts[part] then batch.parts[part] = body; batch.n = batch.n + 1 end
        if batch.n ~= count then return end
        buffers[key] = nil
        local encoded, raw = table.concat(batch.parts)
        if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
        elseif encoded:sub(1, 1) == "Z" then
            local zipped = attacker.U.Deflate:DecodeForWoWAddonChannel(encoded:sub(2))
            raw = zipped and attacker.U.Deflate:DecompressDeflate(zipped)
        end
        local kind, payload
        if raw then kind, payload = raw:match("^([A-Z]+)~(.*)$") end
        local fields = payload and attacker.U.Unpack(payload)
        if not fields then return end
        received[#received + 1] = { kind = kind, fields = fields, sender = sender }
        if responder then responder(kind, fields, sender) end
    end
    return received
end
local function HasHistory(c, text, author)
    for _, row in ipairs(c.U.history) do if row.text == text and (not author or row.name == author) then return true end end
    return false
end

do
    H.Reset()
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0)
    officer.rows[#officer.rows + 1] = { name = "Глава Навсегда", rank = 0, online = false, level = 60 }
    officer.U.ReadRoster()
    officer.U.frame.scripts.OnEvent(officer.U.frame, "PLAYER_LOGIN")
    assert(outsider.guild == nil and outsider.U.guild == nil and not officer.U.own[outsider.name], "outsider unexpectedly belongs to native guild roster")
    local nonce = "999.1"
    local received = Listen(outsider, function(kind, fields, sender)
        if kind == "LINK" and fields[2] == "challenge" then
            Send(outsider, sender, "LINK", { "2", "prove", 1, nonce, fields[5] })
        elseif kind == "PING" then
            Send(outsider, sender, "PONG", { 1, outsider.name, outsider.U.Pack({ outsider.name }) })
        end
    end)
    Send(outsider, officer.name, "LINK", { "2", "hello", 1, nonce, "" })
    H.Step(35)
    local trusted = officer.U.TrustedPeer(outsider.name) ~= nil
    officer.U.frame.scripts.OnEvent(officer.U.frame, "CHAT_MSG_GUILD", "PRIVATE guild-only test message", officer.name .. "-ForeverRealm")
    H.Step(12)
    local rosterLeaked, chatLeaked = false, false
    for _, packet in ipairs(received) do
        if packet.kind == "ROSTER" then rosterLeaked = true end
        if packet.kind == "CHAT" and packet.fields[3] == "PRIVATE guild-only test message" then chatLeaked = true end
    end
    Send(outsider, officer.name, "CHAT", { 1, "Невиновный Глава", "FORGED outsider author", "1:outsider:1", officer.U.stamp() })
    H.Step(5)
    local forged = HasHistory(officer, "FORGED outsider author", "Невиновный Глава")
    Check("unsolicited outsider LINK", trusted or rosterLeaked or chatLeaked or forged,
        "actualGuild=nil trusted=" .. tostring(trusted) .. " roster=" .. tostring(rosterLeaked) .. " chat=" .. tostring(chatLeaked) .. " forgedAuthor=" .. tostring(forged))
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Участник Чиллзон", 1, 2)
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member, officer }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(4)
    assert(gm.U.Link(officer.name), "legitimate guild-master setup failed")
    H.Step(50)
    assert(gm.U.Connected() and member.rank == 2 and not member.U.IsMaster(), "legitimate bridge fixture not established")
    assert(gm.U.RosterFresh(2) and not gm.U.db.rosters[2].rows["Вне Гильдии"], "author-membership test lacks a fresh verified foreign roster")
    Send(officer, gm.name, "CHAT", { 2, "Вне Гильдии", "FORGED nonexistent guild author", "2:bridge:nonmember", gm.U.stamp() })
    H.Step(2)
    Check("active approved peer author membership", HasHistory(gm, "FORGED nonexistent guild author"), "foreignRosterFresh=true nonexistentAuthorAccepted=" .. tostring(HasHistory(gm, "FORGED nonexistent guild author")))
    assert(not gm.U.TrustedPeer(outsider.name), "outsider was trusted before guild member packet")
    Send(member, nil, "CONTACT", { outsider.name, 2 }, "GUILD"); H.Step(3)
    local contactTrusted = gm.U.TrustedPeer(outsider.name) ~= nil
    Send(outsider, gm.name, "CHAT", { 2, "Невиновный Офицер", "FORGED via member CONTACT", "2:outsider:1", gm.U.stamp() })
    H.Step(5)
    local forged = HasHistory(gm, "FORGED via member CONTACT", "Невиновный Офицер")
    Check("ordinary guild member CONTACT", contactTrusted or forged,
        "nativeMemberRank=2 actualOutsiderGuild=nil trusted=" .. tostring(contactTrusted) .. " forgedAuthor=" .. tostring(forged))
    local second = H.NewClient("Другой Посторонний", nil, 2)
    Send(member, nil, "HELLO", { 1, member.U.VERSION, member.U.Pack({ second.name }), "", member.name, 0 }, "GUILD")
    H.Step(3)
    local helloTrusted = gm.U.TrustedPeer(second.name) ~= nil
    Send(second, gm.name, "CHAT", { 2, "Невиновный Офицер", "FORGED via member HELLO", "2:outsider:2", gm.U.stamp() })
    H.Step(4)
    Check("ordinary guild member HELLO contacts", helloTrusted or HasHistory(gm, "FORGED via member HELLO"),
        "nativeMemberRank=2 actualOutsiderGuild=nil trusted=" .. tostring(helloTrusted) .. " forgedAuthor=" .. tostring(HasHistory(gm, "FORGED via member HELLO")))
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Участник Чиллзон", 1, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    local raw = string.rep("A", 262144)
    local zipped = member.U.Deflate:CompressDeflate(raw, { level = 9 })
    local encoded = "Z" .. member.U.Deflate:EncodeForWoWAddonChannel(zipped)
    local inflated, original = 0, gm.U.Deflate.DecompressDeflate
    local limited, boundedCalls, boundedCap, boundedError = gm.U.Deflate.DecompressDeflateLimited, 0, nil, nil
    gm.U.Deflate.DecompressDeflate = function(self, ...)
        local result = original(self, ...)
        if result then inflated = math.max(inflated, #result) end
        return result
    end
    if limited then gm.U.Deflate.DecompressDeflateLimited = function(self, bytes, cap)
        boundedCalls, boundedCap = boundedCalls + 1, cap
        local result, status = limited(self, bytes, cap)
        boundedError = status
        if result then inflated = math.max(inflated, #result) end
        return result, status
    end end
    SendEncoded(member, nil, encoded, "GUILD"); H.Step(4)
    gm.U.Deflate.DecompressDeflate = original
    gm.U.Deflate.DecompressDeflateLimited = limited
    Check("compressed output bounded before allocation", inflated > 25000 or boundedCalls ~= 1 or boundedCap ~= 25000 or boundedError ~= -18,
        "encodedBytes=" .. #encoded .. " observedInflatedBytes=" .. inflated .. " boundedCalls=" .. boundedCalls .. " cap=" .. tostring(boundedCap) .. " status=" .. tostring(boundedError))
end

do
    H.Reset()
    local c = H.NewClient("Проверка Декодера", 1, 2)
    local D = c.U.Deflate
    assert(type(D.DecompressDeflateLimited) == "function", "bounded decoder API missing")
    for _, config in ipairs({ { level = 0 }, { level = 9, strategy = "fixed" }, { level = 9, strategy = "dynamic" } }) do
        local raw = string.rep("A", 25000)
        local compressed = D:CompressDeflate(raw, config)
        assert(D:DecompressDeflateLimited(compressed, 25000) == raw, "bounded decoder rejects valid exact-limit output")
        local result, status = D:DecompressDeflateLimited(D:CompressDeflate(raw .. "B", config), 25000)
        assert(result == nil and status == -18, "bounded decoder failed to stop output above limit")
        assert(D:DecompressDeflateLimited(compressed:sub(1, -2), 25000) == nil, "bounded decoder accepted truncated stream")
    end
    local function Stored(raw, final)
        local len = #raw; local complement = 65535 - len
        return string.char(final and 1 or 0, len % 256, math.floor(len / 256), complement % 256, math.floor(complement / 256)) .. raw
    end
    local twoBlocks = Stored(string.rep("A", 12500), false) .. Stored(string.rep("B", 12500), true)
    assert(#D:DecompressDeflateLimited(twoBlocks, 25000) == 25000, "bounded decoder lost cumulative exact-limit multi-block output")
    local result, status = D:DecompressDeflateLimited(twoBlocks .. "unused", 24999)
    assert(result == nil and status == -18, "bounded decoder reset its output budget between blocks")
    assert(D:DecompressDeflateLimited(string.char(7), 25000) == nil, "bounded decoder accepted invalid block type")
    assert(D:DecompressDeflateLimited(D:CompressDeflate(""), 0) == "", "zero-cap decoder rejects valid empty output")
    for _, cap in ipairs({ -1, 25001, 1.5, "25000" }) do
        result, status = D:DecompressDeflateLimited(D:CompressDeflate("A"), cap)
        assert(result == nil and status == -18, "bounded decoder accepted an invalid output cap")
    end
    local sharedCalls, shared = 0, { DecompressDeflate = function() return string.rep("X", 262144) end }
    local env = setmetatable({ LibStub = {
        GetLibrary = function() sharedCalls = sharedCalls + 1; return shared, 999999 end,
        NewLibrary = function() sharedCalls = sharedCalls + 1; return shared end,
    } }, { __index = _G })
    local loader, private = assert(loadfile("ChillZoneUnion/Libs/LibDeflate.lua")), {}
    setfenv(loader, env); loader("ChillZoneUnion", private)
    assert(sharedCalls == 0 and private.Deflate ~= shared and type(private.Deflate.DecompressDeflateLimited) == "function", "shared newer LibDeflate replaced private bounded decoder")
    print("PASS bounded decoder stored/fixed/dynamic limits, cumulative blocks, malformed input and private library isolation")
end

do
    H.Reset()
    local old = {
        contacts = { ["Посторонний Игрок"] = { guild = 2, addon = true, approved = true, at = 1800000000 } },
        rosters = { [2] = { at = 1800000000, rows = { ["Посторонний Игрок"] = { name = "Посторонний Игрок", rank = 0, guild = 2, online = true } } } },
        approvedRelays = { ["Участник Чиллзон"] = true },
        tickets = { forged = { member = "Участник Чиллзон" } },
        announcement = { text = "untrusted old announcement", guild = 2 },
        addonPresence = { [2] = { ["Посторонний Игрок"] = { version = "0.4.6-beta", lastSeen = 1800000000 } } },
        bridgeGuildChat = false, showGuildBadge = true, memberNotices = true,
        minimapAngle = 42, chatFrameName = "Гильдия",
    }
    local c = H.NewClient("Участник Чиллзон", 1, 2, { realms = { ["ForeverRealm:Alliance"] = old } })
    assert(c.U.PREFIX == "CZUnion2" and c.U.db.trustSchema == 2, "defensive protocol/schema migration missing")
    assert(not c.U.TrustedPeer("Посторонний Игрок") and H.Count(c.U.db.contacts) == 0 and H.Count(c.U.db.rosters) == 0, "old unverified contacts or foreign roster survived migration")
    assert(H.Count(c.U.Tickets()) == 0 and c.U.db.announcement == nil and H.Count(c.U.db.addonPresence) == 0, "old foreign action/presence state survived migration")
    assert(H.Count(c.U.db.approvedRelays) == 0, "old cached ordinary relay permissions survived migration")
    assert(c.U.db.bridgeGuildChat == false and c.U.db.showGuildBadge == true and c.U.db.memberNotices == true
        and c.U.db.minimapAngle == 42 and c.U.db.chatFrameName == "Гильдия", "security migration discarded display/chat preferences")
    print("PASS legacy unverified cache migration resets trust and foreign state while preserving preferences")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local member = H.NewClient("Аарон Участник", 1, 2)
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    H.SetRosters(0)
    for _, c in ipairs({ gm, member, officer }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(gm.U.GatewayName() ~= member.name and not gm.U.CanRelay(member.name), "unapproved ordinary member was elected as a relay")
    assert(gm.U.Link(officer.name), "native officer fixture could not initiate legitimate bridge")
    H.Step(55)
    assert(gm.U.Connected(), "approved bridge did not connect for relay injection fixture")
    Send(member, nil, "RELAY", { member.name, "1" }, "GUILD")
    Send(member, nil, "HELLO", { 1, member.U.VERSION, member.U.Pack({}), officer.name, member.name, 0 }, "GUILD")
    H.Step(3)
    Send(member, nil, "REMOTE", { "CHAT", member.U.Pack({ 2, officer.name, "FORGED unapproved REMOTE", "2:relay:forged", gm.U.stamp() }), officer.name }, "GUILD")
    H.Step(3)
    assert(not gm.U.CanRelay(member.name) and gm.U.GatewayName() == gm.name, "ordinary member authorized itself or preempted native officer relay")
    assert(not HasHistory(gm, "FORGED unapproved REMOTE"), "ordinary nonrelay injected a trusted REMOTE envelope")
    print("PASS native ordinary member cannot self-approve relay, steal election or inject REMOTE")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local backup = H.NewClient("Связной Чиллзон", 1, 2)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    local otherBackup = H.NewClient("Связной Навсегда", 2, 2)
    H.SetRosters(0)
    for _, c in ipairs({ gm, backup, otherGM, otherBackup }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(gm.U.AuthorizeRelay(backup.name, true) and otherGM.U.AuthorizeRelay(otherBackup.name, true), "native officers could not authorize local backups")
    assert(gm.U.Link(otherGM.name), "native officers could not approve initial bridge")
    H.Step(55)
    -- These are deliberate native-officer endorsements, not injected DB state.
    assert(gm.U.ApproveContact(otherBackup.name, 2, true) and otherGM.U.ApproveContact(backup.name, 1, true), "native officers could not endorse counterpart backup identities")
    H.Step(5)
    assert(backup.U.CanRelay() and otherBackup.U.CanRelay(), "explicit local backup approval did not reach ordinary members")
    assert(backup.U.Link(otherBackup.name), "explicitly endorsed backups could not perform their direct pairing")
    H.Step(35)
    gm.live, otherGM.live = false, false; H.SetRosters(0); H.Step(150)
    assert(backup.U.GatewayName() == backup.name and otherBackup.U.GatewayName() == otherBackup.name
        and backup.U.Connected() and otherBackup.U.Connected(), "explicitly approved backups could not maintain union after native officers logged out")
    assert(not backup.U.IsMaster() and not backup.U.CanInvite() and not otherBackup.U.IsMaster(), "relay approval granted unrelated native guild powers")
    local unused = H.NewClient("Аарон Новый", 1, 1)
    H.SetRosters(0); unused.U.frame.scripts.OnEvent(unused.U.frame, "PLAYER_LOGIN"); H.Step(35)
    assert(backup.U.GatewayName() == backup.name and backup.U.Connected(), "new alphabetically earlier unpaired native officer displaced working approved ordinary relay")
    local fresh = H.NewClient("Новый Участник", 1, 2)
    H.SetRosters(0); fresh.U.frame.scripts.OnEvent(fresh.U.frame, "PLAYER_LOGIN"); H.Step(25)
    assert(H.Count(fresh.U.db.contacts) == 0 and not fresh.U.CanRelay(backup.name) and not fresh.U.Connected(), "ordinary relay HELLO bootstrapped unsigned trust into fresh installation")
    gm.live = true; H.SetRosters(0)
    assert(gm.U.ShareTrust() and not fresh.U.ShareTrust(), "trust sharing is not restricted to native guild officers")
    H.Step(5); backup.U.SayHello(); H.Step(50)
    assert(fresh.U.TrustedPeer(otherBackup.name) == 2 and fresh.U.CanRelay(backup.name) and fresh.U.Connected(), "native officer settings did not bootstrap fresh client to already paired relay")
    otherBackup.U.SendChat("Verified trust sync shared chat"); H.Step(12)
    assert(HasHistory(fresh, "Verified trust sync shared chat"), "fresh client cannot read normal shared chat after officer trust sync")
    fresh.U.OpenSettings()
    assert(fresh.U.linkApprovalControls.share.enabled == false, "ordinary member can click officer trust-sharing control")
    Send(fresh, nil, "RELAYSET", { 1, fresh.U.Pack({ fresh.name }) }, "GUILD"); H.Step(2)
    assert(not gm.U.CanRelay(fresh.name), "ordinary member replaced authoritative relay grant set")
    for _, fields in ipairs({
        { 1, gm.U.Pack({ backup.name, "Нет В Гильдии" }) },
        { 2, gm.U.Pack({ backup.name }) },
        { 1, gm.U.Pack({ backup.name, backup.name }) },
    }) do
        Send(gm, nil, "RELAYSET", fields, "GUILD"); H.Step(2)
        assert(fresh.U.CanRelay(backup.name), "malformed officer relay set partially changed previously valid permissions")
    end
    H.SetFilter(function(packet, recipient)
        return not (packet.from == gm and recipient == fresh and packet.text:find("~RRELAY~", 1, true))
    end)
    assert(gm.U.AuthorizeRelay(backup.name, false), "native officer could not revoke local backup")
    H.Step(3)
    assert(fresh.U.CanRelay(backup.name), "empty relay-set test did not simulate a lost incremental revoke")
    H.SetFilter(nil)
    assert(gm.U.ShareTrust(), "native officer could not share authoritative empty relay set")
    H.Step(5)
    assert(not fresh.U.CanRelay(backup.name), "authoritative empty relay set did not clear stale own-guild backup approval")
    print("PASS explicitly officer-approved ordinary backups reconnect after both officers leave without native privilege escalation")
    print("PASS fresh-client native officer trust sync, shared chat, atomic relay-set validation and authoritative empty revocation")
end

do
    H.Reset()
    local officer = H.NewClient("Офицер Навсегда", 2, 1)
    local outsider = H.NewClient("Посторонний Игрок", nil, 2)
    H.SetRosters(0); officer.U.frame.scripts.OnEvent(officer.U.frame, "PLAYER_LOGIN")
    Send(outsider, officer.name, "LINK", { "2", "hello", 1, "888.1", "" }); H.Step(2)
    local request = officer.U.PendingLink()
    assert(request and request.name == outsider.name and not officer.U.TrustedPeer(outsider.name), "unverified inbound request was not held pending explicit officer action")
    officer.U.OpenSettings()
    local controls, input = officer.U.linkApprovalControls
    for _, frame in ipairs(officer.allFrames) do if frame.frameType == "EditBox" and frame.width == 350 then input = frame end end
    assert(controls.accept.enabled and controls.info:GetText():find(outsider.name, 1, true)
        and controls.info:GetText():find("не проверена", 1, true), "approval UI did not identify unverified requester and claimed guild")
    input:SetText("Другой Персонаж"); input.scripts.OnTextChanged(input, true)
    local recorded, actualAccept = nil, officer.U.AcceptLink
    officer.U.AcceptLink = function(name) recorded = name; return false end
    controls.accept.scripts.OnClick(controls.accept)
    assert(recorded == outsider.name, "approval button used editable connection input instead of captured requester")
    local staleCallback = controls.accept.scripts.OnClick
    officer.U.DeclineLink(outsider.name); H.Step(1)
    Send(outsider, officer.name, "LINK", { "2", "hello", 1, "888.2", "" }); H.Step(2)
    recorded = nil; staleCallback()
    assert(recorded == nil, "stale approval button authorized a replacement inbound request")
    officer.U.Refresh()
    local currentCallback = controls.accept.scripts.OnClick
    officer.rank = 2; officer.U.own[officer.name].rank = 2
    recorded = nil; currentCallback()
    assert(recorded == nil, "approval button retained authority after native officer demotion")
    assert(not controls.accept:IsShown() and not controls.decline:IsShown(), "ordinary member can still see trust approval controls")
    officer.U.AcceptLink = actualAccept
    print("PASS explicit approval UI captures unverified requester and rejects edited, replaced or demoted authorization")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    H.SetRosters(0)
    for i = 1, 33 do gm.rows[#gm.rows + 1] = { name = "Резерв" .. i .. " Участник", rank = 2, online = false, level = 20 } end
    gm.U.ReadRoster()
    for i = 1, 32 do assert(gm.U.AuthorizeRelay("Резерв" .. i .. " Участник", true), "officer could not authorize an allowed backup within cap") end
    assert(not gm.U.AuthorizeRelay("Резерв33 Участник", true) and H.Count(gm.U.db.approvedRelays) == 32, "officer backup authorization cap exceeded 32")
    print("PASS native officer relay approvals remain bounded to 32 own-guild members")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local relay = H.NewClient("Персонаж Связной", 1, 2)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ gm, relay, otherGM }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3)
    assert(gm.U.AuthorizeRelay(relay.name, true), "source guild could not approve its native member")
    H.Step(3)
    assert(relay.U.CanRelay() and relay.U.db.approvedRelays[relay.name] == 1, "source relay approval has no issuing-guild scope")
    relay.guild = 2; relay.U.frame.scripts.OnEvent(relay.U.frame, "PLAYER_GUILD_UPDATE", "player")
    H.SetRosters(0); H.Step(3)
    assert(relay.U.guild == 2 and not relay.U.CanRelay(), "character inherited old guild's relay grant after moving to other guild")
    assert(otherGM.U.AuthorizeRelay(relay.name, true), "destination native officer could not issue a fresh relay grant")
    H.Step(3)
    assert(relay.U.CanRelay() and relay.U.db.approvedRelays[relay.name] == 2, "destination grant did not replace old guild scope")
    print("PASS relay authorization is scoped to issuing guild and cannot follow a character into the other guild")
end

do
    H.Reset()
    local gm = H.NewClient("Глава Чиллзон", 1, 0)
    local otherGM = H.NewClient("Глава Навсегда", 2, 0)
    H.SetRosters(0)
    for _, c in ipairs({ gm, otherGM }) do c.U.frame.scripts.OnEvent(c.U.frame, "PLAYER_LOGIN") end
    H.Step(3); assert(gm.U.Link(otherGM.name), "officer-alt fixture could not establish original pair"); H.Step(55)
    local alt = H.NewClient("Другой Офицер", 1, 1, gm.E.ChillZoneUnionDB)
    H.SetRosters(0); alt.U.frame.scripts.OnEvent(alt.U.frame, "PLAYER_LOGIN"); H.Step(5)
    local contact = alt.U.db.contacts[otherGM.name]
    assert(alt.U.db == gm.U.db and contact.pairedBy[gm.name] == true and not contact.pairedBy[alt.name], "per-character pairing fixture does not share cache without sharing proof")
    assert(alt.U.CanRelay() and alt.U.GatewayName() ~= alt.name, "second native-officer alt inherited another character's pairing readiness")
    gm.live = false; H.SetRosters(0); H.Step(100)
    assert(alt.U.GatewayName() == nil and not alt.U.Connected(), "unpaired officer alt silently became a gateway after original character logged out")
    assert(alt.U.Link(otherGM.name), "officer alt could not request its own explicit pairing")
    H.Step(55)
    assert(alt.U.Connected() and alt.U.db.contacts[otherGM.name].pairedBy[alt.name] == true,
        "officer alt's own pairing did not establish readiness")
    print("PASS shared account cache does not transfer pairing proof to another native-officer character")
end

assert(failures == 0, "security regressions observed: " .. failures)
print("ALL SECURITY SCENARIOS PASSED")
