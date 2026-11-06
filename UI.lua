local _, U = ...
local window, page, selected, selectedTicket
local offset, ticketOffset, guildFilter = 0, 0, 0
local sortKey, sortDirection, sortHeaders = nil, 1, {}
local pages, rows, ticketRows, tabs = {}, {}, {}, {}
local classRows, classTotals, classGuildStates = {}, {}, {}
local classOffset, classRange, classSummary = 0
local search, offline, counts, guildCounts, status, guildButton, chatBox, chatLog, chatJump, announcementBanner
local acceptButton, declineButton, leaveButton, inviteButton, ticketInfo
local contact, connectButton, setupHint, setupProgress, diagnostics, leaderInfo
local badgeCheck, noticesCheck, chatWindowButton, announcementEdit, announcementSave, announcementClear, announcementHint
local headerDot, headerState
local announcementDirty, unread = false, 0
local seenHistory, renderedLines, renderedKeys = {}, {}, {}
local RenderRoster, RenderTickets, RenderLinks, RenderClassStats, Build

local function Label(parent, text, x, y, width, font)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    t:SetPoint("TOPLEFT", x, y); t:SetWidth(width); t:SetJustifyH("LEFT"); t:SetText(text)
    return t
end
local function Button(parent, text, x, y, width, action)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24); b:SetPoint("TOPLEFT", x, y); b:SetText(text); b:SetScript("OnClick", action)
    return b
end
local ARROW_MEDIA = "Interface\\AddOns\\ChillZoneUnion\\Media\\arrow-"
local function ArrowText(direction, size)
    size = size or 12
    return "|T" .. ARROW_MEDIA .. direction .. ":" .. size .. ":" .. size .. ":0:0|t"
end
local function Edit(parent, x, y, width, hint)
    local b = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    b:SetSize(width, 26); b:SetPoint("TOPLEFT", x, y); b:SetAutoFocus(false); b:SetMaxBytes(1200)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if hint then Label(parent, hint, x, y + 23, width, "GameFontNormalSmall") end
    return b
end
local function Enable(button, on) if on then button:Enable() else button:Disable() end end
local function Age(at)
    if not at then return "нет данных" end
    local s = math.max(0, U.stamp() - at)
    if s < 60 then return "только что" end
    return math.floor(s / 60) .. " мин назад"
end
local function GuildRows(guild)
    if guild == U.guild then return U.own end
    local cache = U.db.rosters[guild]
    return cache and cache.rows or {}
end
local function Fresh(guild)
    if U.RosterFresh then return U.RosterFresh(guild) end
    return guild == U.guild and U.own[U.me] ~= nil
end
local function Color(row)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[row.class]
    if c then return c.r, c.g, c.b end
    return 0.85, 0.87, 0.9
end
local rosterTooltipOwner, rosterContext, rosterContextFallback
local function RosterAddonInfo(row)
    return row and U.AddonInfo and U.AddonInfo(row.name, row.guild) or { known = false }
end
local function ShowRosterTooltip(button)
    if rosterContext then return end
    local row = button.row
    if not row or not button:IsShown() then return end
    local info = RosterAddonInfo(row)
    rosterTooltipOwner = button
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(U.SafeDisplay(row.name), 1, 1, 1)
    GameTooltip:AddLine(U.SafeDisplay(U.GUILDS[row.guild]), 0.72, 0.77, 0.82)
    if info.known == true then
        local version = U.Text(info.version, 40) and info.version or "версия неизвестна"
        GameTooltip:AddLine("ChillZoneUnion: " .. U.SafeDisplay(version), 0.85, 0.9, 0.95)
        GameTooltip:AddLine(info.live and "Аддон подтверждён сейчас" or "Сведения сохранены",
            info.live and 0.45 or 0.6, info.live and 0.85 or 0.65, info.live and 0.78 or 0.68)
        if not info.live and type(info.lastSeen) == "number" then
            GameTooltip:AddLine("Последнее подтверждение: " .. Age(info.lastSeen), 0.6, 0.65, 0.68)
        end
    else
        GameTooltip:AddLine("Статус аддона неизвестен", 0.65, 0.68, 0.72)
    end
    GameTooltip:Show()
end
function U.RosterRowEnter(button)
    if rosterContext then button.czuHovered = nil; return end
    if rosterTooltipOwner and rosterTooltipOwner ~= button then rosterTooltipOwner.czuHovered = nil end
    button.czuHovered = true
    ShowRosterTooltip(button)
end
function U.RosterRowLeave(button)
    button.czuHovered = nil
    if rosterTooltipOwner == button then
        rosterTooltipOwner = nil
        GameTooltip:Hide()
    end
end
local function Connection()
    if not U.guild then return "Вне гильдии", 0.55, 0.58, 0.62 end
    if U.Connected() then return "Союз на связи", 0.3, 0.85, 0.57 end
    local setup = U.SetupState and U.SetupState()
    if setup and setup.state == "connecting" then return "Соединяемся", 0.95, 0.72, 0.3 end
    return "Ожидаем связь", 0.7, 0.72, 0.76
end
local function RefreshConnection()
    local text, r, g, b = Connection()
    if headerDot then headerDot:SetVertexColor(r, g, b, 1) end
    if headerState then headerState:SetText(text) end
end
local function ChatOffset()
    local n = chatLog and chatLog:GetScrollOffset()
    return type(n) == "number" and math.max(0, n) or 0
end
local function AtBottom()
    if not chatLog then return true end
    local bottom = chatLog:AtBottom()
    if type(bottom) == "boolean" then return bottom end
    return ChatOffset() == 0
end
local function ReadingChat()
    return window and window:IsShown() and page == "chat" and AtBottom()
end
local function UpdateUnread()
    if tabs.chat then tabs.chat:SetText(unread > 0 and ("Общий чат (" .. (unread > 99 and "99+" or unread) .. ")") or "Общий чат") end
    if chatJump then
        chatJump:SetText((unread > 0 and ("К новым (" .. unread .. ") ") or "В конец ") .. ArrowText("down"))
        chatJump:SetShown(unread > 0 or not AtBottom())
    end
end
local function MarkRead()
    if ReadingChat() then unread = 0 end
    UpdateUnread()
end
local function Switch(which)
    U.CloseRosterContextMenu()
    page = which
    for name, p in pairs(pages) do p:SetShown(name == which) end
    U.Refresh()
    if which == "chat" then U.RefreshChat(); MarkRead() end
end
local function RenderAnnouncement()
    local a = U.GetAnnouncement and U.GetAnnouncement()
    if announcementBanner then
        announcementBanner:SetText(a and a.text ~= "" and ("|cffd8c98bСообщение союза:|r " .. U.SafeDisplay(a.text)) or "|cff929ca8Сообщение союза пока не задано.|r")
    end
    return a
end

function U.CloseRosterContextMenu()
    local context = rosterContext
    rosterContext = nil
    if not context then return end
    context.active = false
    if context.menu then context.menu:Hide() end
end
local function CurrentContextRow(context)
    if rosterContext ~= context or not context.active or not window or not window:IsShown() or page ~= "roster" then return nil end
    local row = GuildRows(context.guild)[context.name]
    return row and row.name == context.name and row.guild == context.guild and row or nil
end
local function ContextCanChat(row, guild)
    return row and row.name ~= U.me and row.online == true and Fresh(guild)
end
local function ContextCanTransfer(row, guild)
    if not row or row.name == U.me or row.rank == 0 or row.online ~= true or not U.Connected() then return false end
    if guild == U.guild then
        local peer = U.peers[row.name]
        return U.IsMaster() and peer and type(peer.at) == "number" and U.clock() - peer.at <= 65 or false
    end
    local cache = U.db.rosters[guild]
    return U.IsUnionLeader() and cache and type(cache.at) == "number"
        and U.stamp() - cache.at <= 600 and cache.at <= U.stamp() + 60 or false
end
local function ContextAction(context, action)
    local row = CurrentContextRow(context)
    if not row then U.CloseRosterContextMenu(); return false end
    if action == "transfer" then
        if not ContextCanTransfer(row, context.guild) then U.CloseRosterContextMenu(); return false end
        U.CloseRosterContextMenu()
        if U.CreateTransfer(context.name, context.guild) then ticketOffset = 0; Switch("transfers"); return true end
        return false
    end
    if not ContextCanChat(row, context.guild) then U.CloseRosterContextMenu(); return false end
    U.CloseRosterContextMenu()
    ChatFrame_OpenChat((action == "invite" and "/invite " or "/w ") .. context.name .. (action == "invite" and "" or " "))
    return true
end
local function ContextEntries(context, row)
    local chat = ContextCanChat(row, context.guild) and true or false
    local entries = {
        { text = "Шепнуть", enabled = chat, action = function() return ContextAction(context, "whisper") end },
        { text = "Пригласить в группу", enabled = chat, action = function() return ContextAction(context, "invite") end },
        { text = "Предложить переход", enabled = ContextCanTransfer(row, context.guild) and true or false,
            action = function() return ContextAction(context, "transfer") end },
    }
    local info = RosterAddonInfo(row)
    if info.known == true then
        entries[#entries + 1] = { text = "ChillZoneUnion: " .. U.SafeDisplay(info.version or "версия неизвестна"), enabled = false }
        entries[#entries + 1] = { text = info.live and "Аддон подтверждён сейчас" or "Сведения сохранены", enabled = false }
    else
        entries[#entries + 1] = { text = "Статус аддона неизвестен", enabled = false }
    end
    entries[#entries + 1] = { text = "Закрыть", enabled = true, action = U.CloseRosterContextMenu }
    return entries
end
local function FallbackContextMenu(context, entries)
    if not rosterContextFallback then
        local popup = CreateFrame("Frame", "ChillZoneUnionRosterMenu", UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP"); popup:SetClampedToScreen(true); popup:EnableMouse(true)
        popup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        popup:SetBackdropColor(0.045, 0.065, 0.085, 0.98)
        popup.title = Label(popup, "", 12, -12, 276, "GameFontNormal")
        popup.guild = Label(popup, "", 12, -33, 276, "GameFontHighlightSmall")
        popup.buttons = {}
        popup:SetScript("OnHide", function(self)
            if rosterContext and rosterContext.menu == self then rosterContext.active = false; rosterContext = nil end
        end)
        table.insert(UISpecialFrames, "ChillZoneUnionRosterMenu")
        rosterContextFallback = popup
    end
    local popup = rosterContextFallback
    popup:ClearAllPoints(); popup:SetPoint("TOPLEFT", context.owner, "BOTTOMLEFT", 0, 0)
    popup:SetSize(300, 66 + #entries * 27)
    popup.title:SetText(U.SafeDisplay(context.name)); popup.guild:SetText(U.SafeDisplay(U.GUILDS[context.guild]))
    for i, entry in ipairs(entries) do
        local button = popup.buttons[i]
        if not button then button = Button(popup, "", 10, -55 - (i - 1) * 27, 280); popup.buttons[i] = button end
        button:SetText(entry.text); Enable(button, entry.enabled); button:SetScript("OnClick", entry.action); button:Show()
    end
    for i = #entries + 1, #popup.buttons do popup.buttons[i]:Hide() end
    context.menu = popup
    popup:Show()
end
function U.OpenRosterContextMenu(owner)
    U.CloseRosterContextMenu()
    local row = owner and owner.row
    if not row or not window or not window:IsShown() or page ~= "roster" then return false end
    local context = { owner = owner, name = row.name, guild = row.guild, active = true }
    rosterContext = context
    for _, button in ipairs(rows) do button.czuHovered = nil end
    rosterTooltipOwner = nil; GameTooltip:Hide()
    local entries = ContextEntries(context, row)
    if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
        context.menu = MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(U.SafeDisplay(context.name)); root:CreateTitle(U.SafeDisplay(U.GUILDS[context.guild]))
            root:CreateDivider()
            for _, entry in ipairs(entries) do
                local description = root:CreateButton(entry.text, entry.action)
                description:SetEnabled(entry.enabled)
            end
        end)
        if context.menu then
            context.menu.czuRosterContext = context
            if not context.menu.czuRosterOnHideHooked then
                context.menu.czuRosterOnHideHooked = true
                context.menu:HookScript("OnHide", function(menu)
                    local current = menu.czuRosterContext
                    menu.czuRosterContext = nil
                    if current and rosterContext == current then current.active = false; rosterContext = nil end
                end)
            end
        else U.CloseRosterContextMenu(); return false end
    else FallbackContextMenu(context, entries) end
    return true
end
function U.RosterRowClick(button, mouseButton)
    U.CloseRosterContextMenu()
    if not button.row then return end
    selected = button.row; RenderRoster()
    if mouseButton == "RightButton" then U.OpenRosterContextMenu(button) end
end
function U.RosterRowDoubleClick(button, mouseButton)
    if mouseButton ~= "LeftButton" or not button.row then return end
    U.CloseRosterContextMenu()
    local row = GuildRows(button.row.guild)[button.row.name]
    if row and ContextCanChat(row, row.guild) then ChatFrame_OpenChat("/w " .. row.name .. " ") end
end
function U.RosterRowHide(button)
    U.RosterRowLeave(button)
    if rosterContext and rosterContext.owner == button then U.CloseRosterContextMenu() end
end

RenderRoster = function()
    if not window then return end
    local all, summary, fresh = {}, {}, {}
    local onlineTotal, memberTotal, unknownOnline, unknownMembers, cached = 0, 0, false, false, false
    local needle = U.Fold(search:GetText() or "")
    for guild = 1, 2 do
        local online, total = 0, 0
        fresh[guild] = Fresh(guild)
        local cache = U.db.rosters[guild]
        local known = guild == U.guild and U.own[U.me] ~= nil or cache ~= nil
        for _, row in pairs(GuildRows(guild)) do
            total = total + 1
            if fresh[guild] and row.online then online = online + 1 end
            local text = U.Fold(row.name .. " " .. (row.rankName or "") .. " " .. (row.zone or ""))
            if (guildFilter == 0 or guildFilter == guild) and (offline:GetChecked() or not fresh[guild] or row.online)
                and (needle == "" or text:find(needle, 1, true)) then all[#all + 1] = row end
        end
        memberTotal, onlineTotal = memberTotal + total, onlineTotal + online
        if not fresh[guild] then unknownOnline = true; if known then cached = true end end
        if not known then unknownMembers = true end
        local rosterState = U.RosterState and U.RosterState(guild)
        local savedAt = rosterState and rosterState.at or (cache and cache.at)
        local suffix = not known and " • загружаем" or (not fresh[guild] and (" • сохранено " .. Age(savedAt)) or "")
        summary[#summary + 1] = U.GUILDS[guild] .. ": " .. (fresh[guild] and online or "?") .. " / " .. (known and total or "?") .. suffix
    end
    counts:SetText("В сети: " .. onlineTotal .. (unknownOnline and " + ?" or "") .. "     •     Участников: " .. memberTotal
        .. (unknownMembers and " + ?" or (cached and " (по последним данным)" or "")))
    guildCounts:SetText(table.concat(summary, "     |     "))
    local function Before(a, b)
        return sortDirection == 1 and a < b or sortDirection == -1 and a > b
    end
    local function LocationKey(row)
        if not fresh[row.guild] then return 3, "" end
        if not row.online then return 2, "" end
        return 1, U.Fold(row.zone or "")
    end
    table.sort(all, function(a, b)
        local an, bn = U.Fold(a.name), U.Fold(b.name)
        if sortKey == "level" then
            local av, bv = tonumber(a.level) or 0, tonumber(b.level) or 0
            if av ~= bv then return Before(av, bv) end
        elseif sortKey == "rank" then
            local av, bv = tonumber(a.rank) or math.huge, tonumber(b.rank) or math.huge
            if av ~= bv then return Before(av, bv) end
        elseif sortKey == "zone" then
            local ag, az = LocationKey(a)
            local bg, bz = LocationKey(b)
            if ag ~= bg then return Before(ag, bg) end
            if az ~= bz then return Before(az, bz) end
        elseif sortKey == "name" then
            if an ~= bn then return Before(an, bn) end
        else
            local ao, bo = fresh[a.guild] and a.online == true, fresh[b.guild] and b.online == true
            if ao ~= bo then return ao end
        end
        if an ~= bn then return an < bn end
        if a.guild ~= b.guild then return a.guild < b.guild end
        return a.name < b.name
    end)
    for key, header in pairs(sortHeaders) do
        header.sortArrow:SetTexture(ARROW_MEDIA .. (sortDirection == 1 and "up" or "down"))
        header.sortArrow:SetShown(sortKey == key)
    end
    offset = math.max(0, math.min(offset, math.max(0, #all - #rows)))
    local hovered
    for i, b in ipairs(rows) do
        local row = all[offset + i]
        b.row = row; b:SetShown(row ~= nil)
        if row then
            local r, g, blue = Color(row)
            local dim = fresh[row.guild] and (row.online and 1 or 0.65) or 0.75
            local addon = RosterAddonInfo(row)
            b.addonBadge:SetShown(addon.known == true)
            if addon.live then b.addonBadge:SetTextColor(0.45, 0.85, 0.78)
            else b.addonBadge:SetTextColor(0.45, 0.5, 0.53) end
            b.name:SetText(U.SafeDisplay(row.name)); b.name:SetTextColor(r * dim, g * dim, blue * dim)
            b.guild:SetText(U.GUILDS[row.guild]); b.guild:SetTextColor(0.62, 0.69, 0.73)
            b.level:SetText(tostring(row.level))
            b.zone:SetText(fresh[row.guild] and U.SafeDisplay(row.online and row.zone or "Не в сети") or "Нет свежих данных")
            b.rank:SetText(U.SafeDisplay(row.rankName))
            b.bg:SetColorTexture(0.18, 0.51, 0.46, selected and selected.name == row.name and selected.guild == row.guild and 0.45 or (i % 2 == 0 and 0.10 or 0.02))
            if b.czuHovered then hovered = b end
        else
            b.addonBadge:Hide()
            U.RosterRowLeave(b)
        end
    end
    pages.roster.range:SetText((#all > 0 and (offset + 1) or 0) .. "–" .. math.min(offset + #rows, #all) .. " из " .. #all)
    pages.roster.selection:SetText(selected and ("Выбран: " .. U.SafeDisplay(selected.name) .. " — «" .. U.GUILDS[selected.guild] .. "»") or "Выберите участника для шёпота, приглашения в группу или предложения перехода.")
    Enable(pages.roster.move, selected and selected.rank ~= 0 and selected.name ~= U.me
        and ((selected.guild == U.guild and U.IsMaster()) or (selected.guild ~= U.guild and U.IsUnionLeader())))
    if rosterContext and (not rosterContext.owner.row or rosterContext.owner.row.name ~= rosterContext.name
        or rosterContext.owner.row.guild ~= rosterContext.guild) then U.CloseRosterContextMenu() end
    if hovered then ShowRosterTooltip(hovered) end
end
local states = { proposed = "Ожидает согласия", accepted = "Согласен; ждёт выхода", ready = "Можно пригласить", declined = "Отказ", done = "Завершён" }
local function TicketPriority(t)
    if t.member == U.me and (t.state == "proposed" or t.state == "accepted") then return 1 end
    if t.dest == U.guild and t.state == "ready" and U.CanInvite() then return 2 end
    if t.state ~= "done" and t.state ~= "declined" then return 3 end
    return 4
end
RenderTickets = function()
    if not window then return end
    local all = {}
    for _, t in pairs(U.Tickets()) do if U.stamp() - t.created < 1800 then all[#all + 1] = t end end
    table.sort(all, function(a, b)
        local ap, bp = TicketPriority(a), TicketPriority(b)
        if ap ~= bp then return ap < bp end
        if a.created ~= b.created then return a.created > b.created end
        return a.id < b.id
    end)
    ticketOffset = math.max(0, math.min(ticketOffset, math.max(0, #all - #ticketRows)))
    for i, b in ipairs(ticketRows) do
        local t = all[ticketOffset + i]; b.ticket = t; b:SetShown(t ~= nil)
        if t then b:SetText(U.SafeDisplay(t.member) .. " " .. ArrowText("right", 10) .. " " .. U.GUILDS[t.dest] .. "   •   " .. (states[t.state] or t.state)) end
    end
    pages.transfers.range:SetText((#all > 0 and ticketOffset + 1 or 0) .. "–" .. math.min(ticketOffset + #ticketRows, #all) .. " из " .. #all)
    local t = selectedTicket and U.Tickets()[selectedTicket]
    if t and U.stamp() - t.created >= 1800 then t = nil end
    ticketInfo:SetText(t and (U.SafeDisplay(t.member) .. "\n" .. U.GUILDS[t.source] .. " " .. ArrowText("right", 10) .. " " .. U.GUILDS[t.dest] .. "\nГлава: " .. U.SafeDisplay(t.master) .. "\n" .. (states[t.state] or t.state)) or "Выберите переход в списке.\n\nВаши заявки и переходы, где нужно действие, показаны первыми.\n\nПредложение создаётся главой из вкладки «Состав». Участник принимает его и выходит штатной командой. Офицер второй гильдии отправляет приглашение.\n\nЗаявки действуют 30 минут.")
    local mine = t and t.member == U.me and t.source == U.guild
    Enable(acceptButton, mine and t.state == "proposed")
    Enable(declineButton, mine and t.state == "proposed")
    Enable(leaveButton, mine and t.state == "accepted")
    Enable(inviteButton, t and t.dest == U.guild and t.state == "ready" and U.CanInvite())
end
local function ClassCount(value, known)
    if value ~= nil then return tostring(value) end
    if known and known > 0 then return tostring(known) .. " + ?" end
    return "?"
end
local function ClassCountPair(record)
    return ClassCount(record.online, record.knownOnline) .. " / " .. ClassCount(record.total, record.knownTotal)
end
RenderClassStats = function()
    local data = U.ClassStatistics()
    classOffset = math.max(0, math.min(classOffset, math.max(0, #data.rows - #classRows)))
    classSummary:SetText("В сети / всего. Считаем персонажей обеих гильдий, включая офлайн; фильтры списка не влияют.")
    classRange:SetText((#data.rows > 0 and classOffset + 1 or 0) .. "-" .. math.min(classOffset + #classRows, #data.rows) .. " из " .. #data.rows)
    for guild = 1, 2 do
        local state = data.guilds[guild]
        classGuildStates[guild]:SetText(not state.known and "Нет данных" or (state.fresh and "Актуальные данные" or ("Сохранено: " .. Age(state.at))))
        classTotals[guild]:SetText(ClassCountPair(state))
    end
    classTotals.union:SetText(ClassCountPair(data))
    for index, frame in ipairs(classRows) do
        local row = data.rows[classOffset + index]
        frame.statsRow = row; frame:SetShown(row ~= nil)
        if row then
            frame.name:SetText(U.SafeDisplay(row.label))
            frame.name:SetTextColor(row.color.r, row.color.g, row.color.b)
            frame.guild1:SetText(ClassCountPair(row.guilds[1]))
            frame.guild2:SetText(ClassCountPair(row.guilds[2]))
            frame.union:SetText(ClassCountPair(row))
        end
    end
end
local function BuildClassStats(stats)
    Button(stats, "К списку", 0, 0, 130, function() Switch("roster") end)
    Label(stats, "Статистика по классам", 155, -4, 620, "GameFontNormalLarge")
    Button(stats, "Обновить", 820, 0, 130, function() U.RequestRoster(); U.snapshotDue = 0; RenderClassStats() end)
    classSummary = Label(stats, "", 0, -41, 950, "GameFontHighlightSmall")
    classSummary:SetHeight(35); classSummary:SetJustifyV("TOP")
    Label(stats, "Класс", 5, -85, 220, "GameFontNormal")
    Label(stats, U.GUILDS[1], 240, -85, 220, "GameFontNormal")
    Label(stats, U.GUILDS[2], 485, -85, 240, "GameFontNormal")
    Label(stats, "Весь союз", 750, -85, 195, "GameFontNormal")
    classGuildStates[1] = Label(stats, "", 240, -107, 220, "GameFontHighlightSmall")
    classGuildStates[2] = Label(stats, "", 485, -107, 240, "GameFontHighlightSmall")
    for i = 1, 11 do
        local frame = CreateFrame("Frame", nil, stats)
        frame:SetSize(950, 22); frame:SetPoint("TOPLEFT", 0, -130 - (i - 1) * 22)
        local background = frame:CreateTexture(nil, "BACKGROUND"); background:SetAllPoints()
        background:SetColorTexture(0.18, 0.51, 0.46, i % 2 == 0 and 0.10 or 0.02)
        frame.name = Label(frame, "", 5, -4, 220)
        frame.guild1 = Label(frame, "", 240, -4, 220)
        frame.guild2 = Label(frame, "", 485, -4, 240)
        frame.union = Label(frame, "", 750, -4, 195)
        classRows[i] = frame
    end
    stats:EnableMouseWheel(true)
    stats:SetScript("OnMouseWheel", function(_, delta) classOffset = classOffset - delta * 3; RenderClassStats() end)
    Label(stats, "Всего персонажей", 5, -397, 220, "GameFontNormal")
    classTotals[1] = Label(stats, "", 240, -397, 220, "GameFontNormal")
    classTotals[2] = Label(stats, "", 485, -397, 240, "GameFontNormal")
    classTotals.union = Label(stats, "", 750, -397, 195, "GameFontNormal")
    classRange = Label(stats, "", 750, -435, 195, "GameFontHighlightSmall")
    local note = Label(stats, "? — данных пока нет. У сохранённого состава онлайн неизвестен.\nЕсли классы не помещаются, прокрутите колесом мыши.", 0, -435, 730, "GameFontHighlightSmall")
    note:SetHeight(34); note:SetJustifyV("TOP")

end
RenderLinks = function()
    if not window then return end
    local ready = U.guild and U.own[U.me] ~= nil
    if not U.guild then setupHint:SetText("Персонаж должен состоять в «Чиллзон» или «Чиллзон Навсегда».")
    elseif not ready then setupHint:SetText("Получаем состав и права вашей гильдии. Подождите несколько секунд.")
    elseif not U.IsMaster() then setupHint:SetText("Первое соединение настраивает глава гильдии. Остальные участники получают настройки от согильдийцев и подключаются автоматически.")
    elseif U.ChatLocked() then setupHint:SetText("Игра временно ограничила обмен сообщениями. Соединение станет доступно после снятия ограничения.")
    else setupHint:SetText("Связь настраивается один раз.\n1. Офицер второй гильдии должен быть в игре с аддоном.\n2. Введите его полное имя и нажмите «Подключить».\n3. Ждите «Союз на связи». Офицер ответит автоматически.") end
    Enable(contact, ready and U.IsMaster())
    Enable(connectButton, ready and U.IsMaster() and not U.ChatLocked())
    if U.SetupState then
        local setup = U.SetupState()
        local text = setup.message or "Ожидаем соединение со второй гильдией."
        if U.Connected() then
            local cache = U.db.rosters[U.OtherGuild()]
            text = text .. "\n" .. (cache and ("Состав второй гильдии: " .. Age(cache.at) .. ".") or "Получаем состав второй гильдии…")
        end
        setupProgress:SetText(text)
    elseif U.LinkProgress then setupProgress:SetText(U.LinkProgress())
    else setupProgress:SetText(U.Connected() and "Общий чат подключён. Состав загружается автоматически." or "Ожидаем соединение со второй гильдией.") end
    diagnostics:SetText("Состояние соединения\n" .. U.Status() .. "\nВерсия аддона: " .. U.VERSION)
    badgeCheck:SetChecked(U.db.showGuildBadge == true)
    noticesCheck:SetChecked(U.db.memberNotices == true)
    chatWindowButton:SetText("Чат: " .. U.SafeDisplay(U.db.chatFrameName or "автоматически"))
    local a = RenderAnnouncement()
    local master = ready and U.IsMaster()
    Enable(announcementEdit, master); Enable(announcementSave, master); Enable(announcementClear, master)
    if not announcementDirty and not announcementEdit:HasFocus() then announcementEdit:SetText(a and a.text or "") end
    announcementHint:SetText(master and "Сообщение видят обе гильдии. «Убрать» очищает его для всех." or "Сообщение видят обе гильдии. Изменить его может глава гильдии.")
    local leader = U.ExpectedLeader and U.ExpectedLeader(1) or (U.GUILD_LEADERS and U.GUILD_LEADERS[1])
    local leaderText = leader and ("Глава «Чиллзон»: " .. U.SafeDisplay(leader)) or ""
    if U.IsUnionLeader() then leaderText = leaderText .. "\nВы руководитель союза. Переходы доступны в обе стороны." end
    leaderInfo:SetText(leaderText)
end

function U.RefreshChat()
    local reading = ReadingChat()
    local nextSeen, lines, keys, added = {}, {}, {}, 0
    for i, h in ipairs(U.history) do
        local key = h.id or h
        nextSeen[key], keys[i] = true, key
        if not seenHistory[key] then
            added = added + 1
            if not reading and h.name ~= U.me and not h.replayed then unread = unread + 1 end
        end
        if chatLog then lines[i] = U.ChatLine and U.ChatLine(h, true) or (U.SafeDisplay(h.name) .. ": " .. U.ChatText(h.text)) end
    end
    seenHistory = nextSeen
    if chatLog then
        local oldOffset, bottom, prefix = ChatOffset(), AtBottom(), #lines >= #renderedLines
        for i, line in ipairs(renderedLines) do if keys[i] ~= renderedKeys[i] or lines[i] ~= line then prefix = false; break end end
        if prefix then
            for i = #renderedLines + 1, #lines do chatLog:AddMessage(lines[i], 0.25, 1, 0.25) end
        else
            chatLog:Clear()
            for _, line in ipairs(lines) do chatLog:AddMessage(line, 0.25, 1, 0.25) end
        end
        if bottom then chatLog:ScrollToBottom()
        elseif oldOffset > 0 then chatLog:SetScrollOffset(oldOffset + added) end
        renderedLines, renderedKeys = lines, keys
        RenderAnnouncement()
    end
    if reading then unread = 0 end
    UpdateUnread()
end
function U.Refresh()
    RefreshConnection()
    if not window or not window:IsShown() then return end
    local state = Connection()
    status:SetText(state .. "  •  Общий чат: /czu текст  •  Подробности — «Связь»")
    RenderAnnouncement()
    if page == "roster" then RenderRoster()
    elseif page == "stats" then RenderClassStats()
    elseif page == "transfers" then RenderTickets()
    elseif page == "link" then RenderLinks() end
end

Build = function()
    window = CreateFrame("Frame", "ChillZoneUnionWindow", UIParent, "BackdropTemplate")
    window:SetSize(1000, 650); window:SetPoint("CENTER"); window:SetFrameStrata("DIALOG")
    window:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    window:SetBackdropColor(0.045, 0.065, 0.085, 0.98); window:SetBackdropBorderColor(0.25, 0.65, 0.58, 1)
    window:EnableMouse(true); window:SetMovable(true); window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving); window:SetScript("OnDragStop", window.StopMovingOrSizing)
    table.insert(UISpecialFrames, "ChillZoneUnionWindow")
    Label(window, "ЧИЛЛЗОН  |  СОЮЗ ГИЛЬДИЙ", 24, -22, 650, "GameFontNormalLarge")
    Label(window, "Чиллзон  •  Чиллзон Навсегда", 25, -49, 650, "GameFontHighlightSmall")
    local indicator = CreateFrame("Button", nil, window)
    indicator:SetSize(190, 24); indicator:SetPoint("TOPLEFT", 769, -43)
    indicator:SetScript("OnClick", function() Switch("link") end)
    headerDot = indicator:CreateTexture(nil, "OVERLAY"); headerDot:SetSize(7, 7); headerDot:SetPoint("LEFT", 7, 0)
    headerDot:SetTexture("Interface\\AddOns\\ChillZoneUnion\\Media\\status-dot")
    headerState = Label(indicator, "", 23, -6, 165, "GameFontHighlightSmall")
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -6, -5)
    close:SetScript("OnClick", function() window:Hide() end)
    local definitions = { { "roster", "Состав", 110 }, { "chat", "Общий чат", 160 }, { "transfers", "Переходы", 125 }, { "link", "Связь", 110 } }
    local x = 24
    for _, tab in ipairs(definitions) do
        local key = tab[1]
        tabs[key] = Button(window, tab[2], x, -78, tab[3], function() Switch(key) end); x = x + tab[3] + 8
        local p = CreateFrame("Frame", nil, window); p:SetPoint("TOPLEFT", 24, -122); p:SetPoint("BOTTOMRIGHT", -24, 54); p:Hide(); pages[key] = p
    end
    local stats = CreateFrame("Frame", nil, window)
    stats:SetPoint("TOPLEFT", 24, -122); stats:SetPoint("BOTTOMRIGHT", -24, 54); stats:Hide(); pages.stats = stats
    status = Label(window, "", 25, -628, 950, "GameFontHighlightSmall")
    local r = pages.roster
    counts = Label(r, "", 0, 0, 950, "GameFontNormal")
    guildCounts = Label(r, "", 0, -21, 950, "GameFontHighlightSmall")
    search = Edit(r, 7, -60, 280, "Поиск по имени, званию или локации")
    search:SetScript("OnTextChanged", function() U.CloseRosterContextMenu(); offset = 0; RenderRoster() end)
    guildButton = Button(r, "Весь союз", 310, -61, 180, function()
        U.CloseRosterContextMenu()
        guildFilter = (guildFilter + 1) % 3; offset = 0
        guildButton:SetText(guildFilter == 0 and "Весь союз" or U.GUILDS[guildFilter]); RenderRoster()
    end)
    offline = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate"); offline:SetSize(24, 24); offline:SetPoint("TOPLEFT", 510, -60)
    Label(r, "Показывать офлайн", 538, -67, 175, "GameFontHighlightSmall")
    offline:SetScript("OnClick", function() U.CloseRosterContextMenu(); offset = 0; RenderRoster() end)
    Button(r, "Обновить", 820, -61, 130, function() U.RequestRoster(); U.snapshotDue = 0 end)
    Button(r, "По классам", 715, -61, 95, function() U.OpenClassStats() end)
    local function SortHeader(key, title, x, width)
        local b = CreateFrame("Button", nil, r)
        b:SetSize(width, 24); b:SetPoint("TOPLEFT", x, -100)
        local label = Label(b, title, 0, -7, width - 15, "GameFontNormalSmall")
        b:SetFontString(label)
        b:SetText(title); b.sortTitle = title; sortHeaders[key] = b
        b.sortArrow = b:CreateTexture(nil, "OVERLAY")
        b.sortArrow:SetSize(10, 10); b.sortArrow:SetPoint("RIGHT", -1, 0)
        b.sortArrow:Hide()
        b:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
        b:SetScript("OnLeave", function() label:SetTextColor(1, 0.82, 0) end)
        b:SetScript("OnClick", function()
            U.CloseRosterContextMenu()
            if sortKey == key then sortDirection = -sortDirection
            else sortKey, sortDirection = key, key == "level" and -1 or 1 end
            offset = 0; RenderRoster()
        end)
        return b
    end
    SortHeader("name", "Имя / класс", 4, 290)
    SortHeader("level", "Ур.", 305, 50)
    SortHeader("zone", "Локация", 365, 225)
    SortHeader("rank", "Звание", 600, 165)
    Label(r, "Гильдия", 775, -107, 170, "GameFontNormalSmall")
    for i = 1, 11 do
        local b = CreateFrame("Button", nil, r); b:SetSize(950, 24); b:SetPoint("TOPLEFT", 0, -128 - (i - 1) * 25)
        b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
        b.addonBadge = Label(b, "CZ", 5, -6, 20, "GameFontNormalSmall"); b.addonBadge:Hide()
        b.name = Label(b, "", 29, -5, 266); b.level = Label(b, "", 320, -5, 35)
        b.zone = Label(b, "", 365, -5, 225, "GameFontHighlightSmall"); b.rank = Label(b, "", 600, -5, 165, "GameFontHighlightSmall")
        b.guild = Label(b, "", 775, -5, 170, "GameFontHighlightSmall")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", U.RosterRowClick)
        b:SetScript("OnDoubleClick", U.RosterRowDoubleClick)
        b:SetScript("OnEnter", U.RosterRowEnter)
        b:SetScript("OnLeave", U.RosterRowLeave)
        b:SetScript("OnHide", U.RosterRowHide)
        rows[i] = b
    end
    r:EnableMouseWheel(true); r:SetScript("OnMouseWheel", function(_, delta) U.CloseRosterContextMenu(); offset = offset - delta * 3; RenderRoster() end)
    Button(r, ArrowText("left"), 0, -416, 40, function() U.CloseRosterContextMenu(); offset = offset - #rows; RenderRoster() end)
    r.range = Label(r, "", 55, -422, 150, "GameFontHighlightSmall")
    Button(r, ArrowText("right"), 220, -416, 40, function() U.CloseRosterContextMenu(); offset = offset + #rows; RenderRoster() end)
    Button(r, "В группу", 525, -416, 110, function() if selected then ChatFrame_OpenChat("/invite " .. selected.name) end end)
    Button(r, "Шёпот", 645, -416, 100, function() if selected then ChatFrame_OpenChat("/w " .. selected.name .. " ") end end)
    r.move = Button(r, "Предложить переход", 755, -416, 195, function() if selected then U.CreateTransfer(selected.name, selected.guild); ticketOffset = 0; Switch("transfers") end end)
    r.selection = Label(r, "", 0, -453, 950, "GameFontHighlightSmall")

    BuildClassStats(stats)

    local c = pages.chat
    local banner = CreateFrame("Button", nil, c); banner:SetPoint("TOPLEFT", 0, 0); banner:SetSize(945, 36)
    announcementBanner = Label(banner, "", 0, 0, 945, "GameFontHighlightSmall"); announcementBanner:SetHeight(36); announcementBanner:SetJustifyV("TOP")
    banner:SetScript("OnEnter", function(self)
        local a = U.GetAnnouncement and U.GetAnnouncement()
        if not a or a.text == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Сообщение союза")
        GameTooltip:AddLine(U.SafeDisplay(a.text), 1, 1, 1, true)
        if a.author then GameTooltip:AddLine(U.SafeDisplay(a.author) .. " • " .. Age(a.at), 0.7, 0.75, 0.8) end
        GameTooltip:Show()
    end)
    banner:SetScript("OnLeave", function() GameTooltip:Hide() end)
    banner:SetScript("OnClick", function() GameTooltip:Hide(); Switch("link") end)
    Label(c, "Один чат для обеих гильдий. Нажмите имя для шёпота; ссылки на предметы работают как обычно.", 0, -43, 945, "GameFontNormalSmall")
    chatLog = CreateFrame("ScrollingMessageFrame", nil, c); chatLog:SetPoint("TOPLEFT", 0, -65); chatLog:SetSize(945, 345)
    chatLog:SetFontObject(GameFontHighlight); chatLog:SetJustifyH("LEFT"); chatLog:SetFading(false); chatLog:SetMaxLines(200)
    chatLog:EnableMouseWheel(true); chatLog:SetScript("OnMouseWheel", function(self, d)
        if d > 0 then self:ScrollUp() else self:ScrollDown() end
        MarkRead()
    end)
    chatLog:SetHyperlinksEnabled(true)
    chatLog:SetScript("OnHyperlinkClick", function(self, link, text, button) SetItemRef(link, text, button, self) end)
    chatJump = Button(c, "В конец " .. ArrowText("down"), 785, -415, 160, function() chatLog:ScrollToBottom(); MarkRead() end)
    chatBox = Edit(c, 7, -443, 780)
    if hooksecurefunc and type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", function(link)
        if chatBox:HasFocus() and U.Text(link, 1000) then chatBox:Insert(link) end
    end) end
    local function Send()
        if U.SendChat(chatBox:GetText()) then chatBox:SetText(""); chatBox:ClearFocus() end
    end
    chatBox:SetScript("OnEnterPressed", Send)
    Button(c, "Отправить", 815, -444, 130, Send)
    Label(c, "История сохраняется до перезагрузки интерфейса. Сообщения видны участникам обеих гильдий с аддоном.", 0, -483, 945, "GameFontHighlightSmall")

    local t = pages.transfers
    Label(t, "Переходы по согласию участника", 0, 0, 950, "GameFontNormal")
    for i = 1, 12 do
        local b = Button(t, "", 0, -35 - (i - 1) * 30, 590, function(self)
            if self.ticket then selectedTicket = self.ticket.id; RenderTickets() end
        end)
        ticketRows[i] = b
    end
    t:EnableMouseWheel(true); t:SetScript("OnMouseWheel", function(_, d) ticketOffset = ticketOffset - d * 3; RenderTickets() end)
    Button(t, ArrowText("left"), 0, -410, 40, function() ticketOffset = ticketOffset - #ticketRows; RenderTickets() end)
    t.range = Label(t, "", 55, -416, 150, "GameFontHighlightSmall")
    Button(t, ArrowText("right"), 220, -410, 40, function() ticketOffset = ticketOffset + #ticketRows; RenderTickets() end)
    ticketInfo = Label(t, "", 620, -35, 325); ticketInfo:SetJustifyV("TOP"); ticketInfo:SetHeight(310)
    acceptButton = Button(t, "Согласиться", 620, -370, 150, function() U.AcceptTransfer(selectedTicket, true) end)
    declineButton = Button(t, "Отказаться", 790, -370, 150, function() U.AcceptTransfer(selectedTicket, false) end)
    leaveButton = Button(t, "Подготовить выход", 620, -405, 320, function() U.LeaveForTransfer(selectedTicket) end)
    inviteButton = Button(t, "Подготовить приглашение", 620, -440, 320, function() U.InviteTransfer(selectedTicket) end)
    Label(t, "После нажатия кнопки проверьте штатную команду игры и нажмите Enter. Сам переход требует согласия участника.", 0, -483, 950, "GameFontHighlightSmall")

    local l = pages.link
    Label(l, "Связь между гильдиями", 0, 0, 565, "GameFontNormalLarge")
    setupHint = Label(l, "", 0, -36, 565); setupHint:SetHeight(68); setupHint:SetJustifyV("TOP")
    contact = Edit(l, 7, -140, 350, "Полное имя офицера второй гильдии")
    local prefill = U.db.setupContact
    if (not prefill or prefill == "") and U.guild and U.OtherGuild() == 1 and U.GUILD_LEADERS then prefill = U.GUILD_LEADERS[1] end
    contact:SetMaxBytes(160); contact:SetText(prefill or "")
    local function Connect() U.Link(contact:GetText()); contact:ClearFocus(); RenderLinks() end
    contact:SetScript("OnEnterPressed", Connect)
    connectButton = Button(l, "Подключить", 380, -141, 185, Connect)
    setupProgress = Label(l, "", 0, -187, 565); setupProgress:SetHeight(90); setupProgress:SetJustifyV("TOP")
    diagnostics = Label(l, "", 0, -297, 565, "GameFontHighlightSmall"); diagnostics:SetHeight(85); diagnostics:SetJustifyV("TOP")
    Label(l, "Для общего чата аддон нужен всем участникам.\nДостаточно одного игрока с аддоном онлайн в каждой гильдии.\nГлавам и офицерам оставаться в игре не требуется.", 0, -397, 565, "GameFontHighlightSmall")
    Label(l, "Отображение", 610, 0, 335, "GameFontNormal")
    badgeCheck = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate"); badgeCheck:SetSize(24, 24); badgeCheck:SetPoint("TOPLEFT", 610, -33)
    Label(l, "Показывать гильдию рядом с именем в чате", 638, -40, 307, "GameFontHighlightSmall")
    badgeCheck:SetScript("OnClick", function(self)
        if U.SetGuildBadge then U.SetGuildBadge(self:GetChecked() == true) else U.db.showGuildBadge = self:GetChecked() == true; U.RefreshChat() end
    end)
    Label(l, "Вкладка обычного чата", 610, -77, 335, "GameFontNormalSmall")
    chatWindowButton = Button(l, "", 610, -99, 335, function()
        local names = U.ChatWindowNames and U.ChatWindowNames() or {}
        local index = 0
        for i, name in ipairs(names) do if name == U.db.chatFrameName then index = i; break end end
        local name = names[index + 1]
        if U.SetChatWindow then local ok, why = U.SetChatWindow(name); if not ok and why then U.Print(why) end end
        RenderLinks()
    end)
    noticesCheck = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate"); noticesCheck:SetSize(24, 24); noticesCheck:SetPoint("TOPLEFT", 610, -139)
    Label(l, "Сообщать о вступлениях и выходах из гильдий", 638, -146, 307, "GameFontHighlightSmall")
    noticesCheck:SetScript("OnClick", function(self) U.db.memberNotices = self:GetChecked() == true end)
    Label(l, "Сообщение дня союза", 610, -191, 335, "GameFontNormal")
    announcementEdit = Edit(l, 617, -232, 328, "Общее для обеих гильдий")
    announcementEdit:SetMaxBytes(1000)
    announcementEdit:SetScript("OnTextChanged", function(_, userInput) if userInput then announcementDirty = true end end)
    local function SaveAnnouncement(text)
        if U.SetAnnouncement and U.SetAnnouncement(text) then
            announcementDirty = false; announcementEdit:ClearFocus(); RenderLinks(); RenderAnnouncement()
        end
    end
    announcementSave = Button(l, "Сохранить", 610, -270, 160, function() SaveAnnouncement(announcementEdit:GetText()) end)
    announcementClear = Button(l, "Убрать", 785, -270, 160, function() SaveAnnouncement("") end)
    announcementHint = Label(l, "", 610, -311, 335, "GameFontHighlightSmall"); announcementHint:SetHeight(65); announcementHint:SetJustifyV("TOP")
    leaderInfo = Label(l, "", 610, -397, 335, "GameFontHighlightSmall"); leaderInfo:SetHeight(55); leaderInfo:SetJustifyV("TOP")
    window:SetScript("OnHide", U.CloseRosterContextMenu)
    window:SetScript("OnShow", function() U.Refresh(); U.RefreshChat(); MarkRead() end)
    local tick = 0
    window:SetScript("OnUpdate", function(_, dt) tick = tick + dt; if tick > 2 then tick = 0; U.Refresh(); MarkRead() end end)
    local usableContact = false
    for name, entry in pairs(U.db.contacts) do
        if U.guild and name ~= U.me and entry.guild == U.OtherGuild() then usableContact = true; break end
    end
    page = not usableContact and U.IsMaster() and "link" or "roster"; pages[page]:Show()
    U.Refresh(); U.RefreshChat()
end
function U.Toggle()
    if not U.db then return end
    if not window then Build() else window:SetShown(not window:IsShown()) end
end
function U.OpenRoster()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("roster")
end
function U.OpenChat()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("chat")
end
function U.OpenSettings()
    if not U.db then return end
    if not window then Build() end
    window:Show(); Switch("link")
end
function U.OpenClassStats()
    if not U.db then return end
    if not window then Build() end
    classOffset = 0
    window:Show(); Switch("stats")
end

local setupIntroPending = false
function U.MaybeShowSetup()
    if not setupIntroPending or not U.db or not U.me then return end
    if U.Fold(U.me) ~= U.Fold(U.UNION_LEADER) then setupIntroPending = false; return end
    if not U.guild or not U.own[U.me] then return end
    if not U.IsUnionLeader() then setupIntroPending = false; return end
    local seen = U.db.setupIntroSeen
    if type(seen) ~= "table" then seen = {}; U.db.setupIntroSeen = seen end
    local key = U.Fold(U.me)
    if seen[key] then setupIntroPending = false; return end
    local configured = U.Connected()
    for name, entry in pairs(U.db.contacts) do
        if name ~= U.me and entry.guild == U.OtherGuild() then configured = true; break end
    end
    if configured then seen[key] = true; setupIntroPending = false; return end
    if InCombatLockdown() then return end
    U.OpenSettings()
    seen[key] = true
    setupIntroPending = false
end
U.On("PLAYER_LOGIN", function() setupIntroPending = true; U.MaybeShowSetup() end)
U.On("GUILD_ROSTER_UPDATE", function() U.MaybeShowSetup() end)
U.On("PLAYER_GUILD_UPDATE", function() U.MaybeShowSetup() end)

local DEFAULT_MINIMAP_ANGLE = 225
local function PositionMinimapButton(button)
    if not button or not Minimap or not U.db then return end
    local angle = U.db.minimapAngle
    if type(angle) ~= "number" or angle ~= angle or math.abs(angle) == math.huge then angle = DEFAULT_MINIMAP_ANGLE end
    angle = angle % 360
    U.db.minimapAngle = angle
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    width = type(width) == "number" and width > 0 and width or 140
    height = type(height) == "number" and height > 0 and height or width
    local radians = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * (width / 2 + 8), math.sin(radians) * (height / 2 + 8))
end
local function DragMinimapButton(button)
    if not U.db or type(GetCursorPosition) ~= "function" then return end
    local cx, cy = Minimap:GetCenter()
    if type(cx) ~= "number" or type(cy) ~= "number" then return end
    local scale = Minimap:GetEffectiveScale()
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local x, y = GetCursorPosition()
    if type(x) ~= "number" or type(y) ~= "number" then return end
    x, y = x / scale - cx, y / scale - cy
    if x == 0 and y == 0 then return end
    local angle
    if math.atan2 then angle = math.atan2(y, x)
    elseif x == 0 then angle = y > 0 and math.pi / 2 or -math.pi / 2
    else
        angle = math.atan(y / x)
        if x < 0 then angle = angle + math.pi end
    end
    U.db.minimapAngle = math.deg(angle) % 360
    PositionMinimapButton(button)
end
function U.ResetMinimapPosition()
    if not U.db then return end
    U.db.minimapAngle = DEFAULT_MINIMAP_ANGLE
    PositionMinimapButton(U.minimapButton)
end
U.On("PLAYER_LOGIN", function()
    if not Minimap or U.minimapButton then return end
    local b = CreateFrame("Button", "ChillZoneUnionMinimapButton", Minimap)
    U.minimapButton = b
    b:SetSize(32, 32); b:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    b:EnableMouse(true); b:SetMovable(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp"); b:RegisterForDrag("LeftButton")
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetSize(28, 28); b.icon:SetPoint("CENTER")
    b.icon:SetTexture("Interface\\AddOns\\ChillZoneUnion\\Media\\minimap")
    local highlight = b:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(); highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD"); highlight:SetVertexColor(1, 0.78, 0.35, 0.7)
    b:SetScript("OnClick", function(self, button)
        if self.dragging or (self.dragStopTime and GetTime() - self.dragStopTime < 0.15) then return end
        if button == "RightButton" then
            if IsShiftKeyDown and IsShiftKeyDown() then U.ResetMinimapPosition() else U.OpenSettings() end
        elseif window and window:IsShown() and page == "roster" then window:Hide()
        else U.OpenRoster() end
    end)
    b:SetScript("OnDragStart", function(self)
        self.dragging = true; GameTooltip:Hide(); DragMinimapButton(self)
    end)
    b:SetScript("OnDragStop", function(self)
        DragMinimapButton(self); self.dragging = false; self.dragStopTime = GetTime()
    end)
    b:SetScript("OnEnter", function(self)
        if self.dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("Чиллзон — Союз гильдий")
        local text, r, g, blue = Connection()
        GameTooltip:AddLine(text, r, g, blue)
        GameTooltip:AddLine("ЛКМ — состав союза", 0.8, 0.85, 0.9)
        GameTooltip:AddLine("ПКМ — настройки", 0.8, 0.85, 0.9)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local tick = 0
    b:SetScript("OnUpdate", function(self, dt)
        if self.dragging then DragMinimapButton(self) end
        tick = tick + dt
        if tick >= 2 then tick = 0; RefreshConnection(); U.MaybeShowSetup(); if not self.dragging then PositionMinimapButton(self) end end
    end)
    PositionMinimapButton(b); RefreshConnection()
end)
