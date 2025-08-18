local ADDON_NAME = "XToLevelClassic"

local f = CreateFrame("Frame", "XTLClassic_Frame", UIParent)



XToLevelClassicDB = XToLevelClassicDB or nil



local defaults = {

  version = "1.0.6",

  frame = { point = "CENTER", x = 0, y = 0, locked = false, shown = true },

  lengths = { kills = 50, quests = 50 },

  showETA = true,

  showXPH = true,

  debug = false,

  data = { kills = {}, quests = {}, xpSession = 0, sessionStart = nil },

}



local function ensureDefaults(dst, src)

  if dst == nil then

    local t = {}

    for k,v in pairs(src) do

      if type(v) == "table" then t[k] = ensureDefaults(nil, v) else t[k] = v end

    end

    return t

  end

  for k,v in pairs(src) do

    if type(v) == "table" then dst[k] = ensureDefaults(dst[k], v) elseif dst[k] == nil then dst[k] = v end

  end

  return dst

end



local function pushSample(list, value, maxLen)

  if not value then return end

  table.insert(list, value)

  if maxLen and maxLen > 0 then

    while table.getn(list) > maxLen do table.remove(list, 1) end

  end

end



local function average(list)

  local n = table.getn(list)

  if n == 0 then return nil end

  local s = 0

  for i = 1, n do s = s + (list[i] or 0) end

  return s / n

end



local function formatNumber(n)

  if not n then return "-" end

  local s = tostring(math.floor(n + 0.5))

  local sign = ""

  if string.sub(s,1,1) == "-" then sign = "-" s = string.sub(s,2) end

  local out, count = "", 0

  for i = string.len(s), 1, -1 do

    out = string.sub(s, i, i) .. out

    count = count + 1

    if count == 3 and i > 1 then out = "," .. out; count = 0 end

  end

  return sign .. out

end



local function dprint(msg)

  if XToLevelClassicDB and XToLevelClassicDB.debug then

    DEFAULT_CHAT_FRAME:AddMessage("|cff6aa84f[XTL]|r "..tostring(msg))

  end

end



local titleText, line1, line2, line3

local built = false



local function BuildFrame()

  if built then return end

  built = true

  f:SetWidth(240); f:SetHeight(72)

  f:SetFrameStrata("MEDIUM")

  if not f.bg then

    f.bg = f:CreateTexture(nil, "BACKGROUND")

    f.bg:SetAllPoints(true)

    f.bg:SetTexture(0, 0, 0, 0.35)

  end

  f:EnableMouse(true)

  f:SetMovable(true)

  f:RegisterForDrag("LeftButton")

  f:SetScript("OnDragStart", function() if not XToLevelClassicDB.frame.locked then f:StartMoving() end end)

  f:SetScript("OnDragStop", function()

    f:StopMovingOrSizing()

    local point, _, _, x, y = f:GetPoint()

    XToLevelClassicDB.frame.point, XToLevelClassicDB.frame.x, XToLevelClassicDB.frame.y = point, x, y

  end)

  titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); titleText:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6); titleText:SetText("XToLevel (Classic)")

  line1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); line1:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -22)

  line2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); line2:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -38)

  line3 = f:CreateFontString(nil, "OVERLAY", "GameFontDisable");  line3:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -54)

  f:ClearAllPoints()

  f:SetPoint(XToLevelClassicDB.frame.point, UIParent, XToLevelClassicDB.frame.point, XToLevelClassicDB.frame.x, XToLevelClassicDB.frame.y)

  if XToLevelClassicDB.frame.shown then f:Show() else f:Hide() end

end



local function ensureInit()

  if not XToLevelClassicDB then XToLevelClassicDB = ensureDefaults(nil, defaults) else XToLevelClassicDB = ensureDefaults(XToLevelClassicDB, defaults) end

  if not built then BuildFrame() end

  if not XToLevelClassicDB.data.sessionStart then XToLevelClassicDB.data.sessionStart = GetTime() end

end



local function compute()

  ensureInit()

  local xp = UnitXP("player") or 0

  local xpMax = UnitXPMax("player") or 1

  local remain = xpMax - xp

  local avgKill = average(XToLevelClassicDB.data.kills)

  local avgQuest = average(XToLevelClassicDB.data.quests)

  local killsTo = nil

  if avgKill and avgKill > 0 then killsTo = math.ceil(remain / avgKill) end

  local questsTo = nil

  if avgQuest and avgQuest > 0 then questsTo = math.ceil(remain / avgQuest) end

  local sessionStart = XToLevelClassicDB.data.sessionStart or GetTime()

  local elapsed = math.max(1, GetTime() - sessionStart)

  local xph = 0

  if XToLevelClassicDB.data.xpSession and XToLevelClassicDB.data.xpSession > 0 then xph = (XToLevelClassicDB.data.xpSession) * 3600 / elapsed end

  local etaTxt = ""

  if xph > 0 then

    local sec = math.floor(remain / (xph / 3600))

    local h = math.floor(sec / 3600)

    local m = math.floor(math.mod(sec, 3600) / 60)

    local s = math.mod(sec, 60)

    if h > 0 then etaTxt = string.format("ETA %dh %dm", h, m) elseif m > 0 then etaTxt = string.format("ETA %dm %ds", m, s) else etaTxt = string.format("ETA %ds", s) end

  end

  return { remain=remain, avgKill=avgKill, avgQuest=avgQuest, killsTo=killsTo, questsTo=questsTo, xph=xph, xp=xp, xpMax=xpMax, etaTxt=etaTxt }

end



local function updateText()

  ensureInit()

  local s = compute()

  line1:SetText(string.format("Kills: avg %s  |  to level: %s", s.avgKill and string.format("%.0f", s.avgKill) or "-", s.killsTo and formatNumber(s.killsTo) or "-"))

  line2:SetText(string.format("Quests: avg %s  |  to level: %s", s.avgQuest and string.format("%.0f", s.avgQuest) or "-", s.questsTo and formatNumber(s.questsTo) or "-"))

  local t = "XP/h: " .. formatNumber(math.floor((s.xph or 0) + 0.5))

  if s.etaTxt ~= "" then t = t .. "  |  " .. s.etaTxt end

  line3:SetText(t)

end



local function parseFirstNumber(msg)

  local _,_,num = string.find(msg or "", "(%d+)")

  if num then return tonumber(num) end

  return nil

end



local update_acc = 0

local function XTL_OnUpdate(self, elapsed)

  update_acc = update_acc + (elapsed or 0)

  if update_acc >= 1.0 then

    update_acc = 0

    if XToLevelClassicDB and XToLevelClassicDB.frame and XToLevelClassicDB.frame.shown then updateText() end

  end

end



-- 1.12 compatibility: Some clients don't pass event/args; use globals when nil

f:SetScript("OnEvent", function(self, ev, a1)

  ev = ev or event

  a1 = a1 or arg1

  if not ev then return end

  if ev == "PLAYER_LOGIN" then

    ensureInit(); DEFAULT_CHAT_FRAME:AddMessage("XToLevelClassic loaded. Use /xtl"); updateText()

  elseif ev == "PLAYER_LEVEL_UP" then

    ensureInit(); XToLevelClassicDB.data.kills = {}; XToLevelClassicDB.data.quests = {}; updateText()

  elseif ev == "PLAYER_XP_UPDATE" then

    ensureInit(); updateText()

  elseif ev == "CHAT_MSG_SYSTEM" then

    ensureInit(); local xp = parseFirstNumber(a1 or ""); if xp then pushSample(XToLevelClassicDB.data.quests, xp, XToLevelClassicDB.lengths.quests); XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp; updateText(); dprint("Quest XP +"..xp) end

  elseif ev == "CHAT_MSG_COMBAT_XP_GAIN" then

    ensureInit(); local xp = parseFirstNumber(a1 or ""); if xp then pushSample(XToLevelClassicDB.data.kills, xp, XToLevelClassicDB.lengths.kills); XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp; updateText(); dprint("Kill XP +"..xp) end

  elseif ev == "PLAYER_ENTERING_WORLD" then

    ensureInit(); updateText()

  end

end)



f:RegisterEvent("PLAYER_LOGIN")

f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:RegisterEvent("PLAYER_LEVEL_UP")

f:RegisterEvent("PLAYER_XP_UPDATE")

f:RegisterEvent("CHAT_MSG_SYSTEM")

f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")



f:SetScript("OnUpdate", XTL_OnUpdate)



SLASH_XTOLEVEL1 = "/xtl"

SlashCmdList["XTOLEVEL"] = function(msg)

  ensureInit()

  msg = string.lower(msg or "")

  if msg == "" or msg == "help" then

    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100XToLevel Classic commands:|r")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl lock   - lock the frame")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl unlock - unlock the frame (drag with left mouse)")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl reset  - reset averages and session XP")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl len k <n> - set kill window (default 50)")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl len q <n> - set quest window (default 50)")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl show   - show the frame")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl hide   - hide the frame")

    DEFAULT_CHAT_FRAME:AddMessage("  /xtl debug  - toggle debug prints")

    return

  end

  if msg == "lock" then XToLevelClassicDB.frame.locked = true; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: frame locked")

  elseif msg == "unlock" then XToLevelClassicDB.frame.locked = false; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: frame unlocked")

  elseif msg == "reset" then XToLevelClassicDB.data.kills = {}; XToLevelClassicDB.data.quests = {}; XToLevelClassicDB.data.xpSession = 0; XToLevelClassicDB.data.sessionStart = GetTime(); DEFAULT_CHAT_FRAME:AddMessage("XToLevel: data reset"); updateText()

  elseif msg == "show" then XToLevelClassicDB.frame.shown = true; f:Show(); updateText()

  elseif msg == "hide" then XToLevelClassicDB.frame.shown = false; f:Hide()

  elseif msg == "debug" then XToLevelClassicDB.debug = not XToLevelClassicDB.debug; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: debug "..(XToLevelClassicDB.debug and "ON" or "OFF"))

  else

    local _,_,w,nstr = string.find(msg, "len%s+([kq])%s+(%d+)")

    if w and nstr then

      local n = tonumber(nstr)

      if w == "k" then XToLevelClassicDB.lengths.kills = n; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: kill window set to "..n); while table.getn(XToLevelClassicDB.data.kills) > n do table.remove(XToLevelClassicDB.data.kills, 1) end

      else XToLevelClassicDB.lengths.quests = n; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: quest window set to "..n); while table.getn(XToLevelClassicDB.data.quests) > n do table.remove(XToLevelClassicDB.data.quests, 1) end end

      updateText()

    else

      DEFAULT_CHAT_FRAME:AddMessage("XToLevel: unknown command. Use /xtl help")

    end

  end

end