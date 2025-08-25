local ADDON_NAME = "XToLevelClassic"
local f = CreateFrame("Frame", "XTLClassic_Frame", UIParent)

XToLevelClassicDB = XToLevelClassicDB or nil

local MAX_LEVEL = 60 -- Classic cap

local defaults = {
  version = "1.0.14",
  frame = { point = "CENTER", x = 0, y = 0, locked = false, shown = true },
  lengths = { kills = 50, quests = 50 },
  showETA = true,
  showXPH = true,
  debug = false,
  mode = "last",       -- "avg" or "last"
  questDebounce = 5.0, -- seconds to ignore duplicate quest echoes
  combatGate = false,  -- optional: require recent combat for kill XP
  data = {
    kills = {},
    quests = {},
    xpSession = 0,
    sessionStart = nil,
    lastQuestXP = 0,
    lastQuestTime = 0,
    lastCombatStart = 0,
    lastCombatEnd   = 0,
  },
}

local disabled = false

-- ===== utils =====
local function ensureDefaults(dst, src)
  if dst == nil then
    local t = {}
    for k,v in pairs(src) do t[k] = (type(v) == "table") and ensureDefaults(nil, v) or v end
    return t
  end
  for k,v in pairs(src) do
    if type(v) == "table" then dst[k] = ensureDefaults(dst[k], v)
    elseif dst[k] == nil then dst[k] = v end
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

local function last(list)
  local n = table.getn(list)
  if n == 0 then return nil end
  return list[n]
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

-- ===== UI =====
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
  if disabled then return end
  if not XToLevelClassicDB then XToLevelClassicDB = ensureDefaults(nil, defaults) else XToLevelClassicDB = ensureDefaults(XToLevelClassicDB, defaults) end
  if not built then BuildFrame() end
  if not XToLevelClassicDB.data.sessionStart then XToLevelClassicDB.data.sessionStart = GetTime() end
end

-- ===== disable at 60 =====
local function DisableAddon(msg)
  disabled = true
  if f then
    f:Hide()
    f:UnregisterAllEvents()
    f:SetScript("OnUpdate", nil)
  end
  SLASH_XTOLEVEL1 = "/xtl"
  SlashCmdList["XTOLEVEL"] = function()
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7e5eXToLevelClassic|r: disabled at level "..MAX_LEVEL..".")
  end
  if msg then DEFAULT_CHAT_FRAME:AddMessage(msg) end
end

-- ===== helpers =====
local function parseFirstNumber(msg)
  local s = string.gsub(msg or "", ",", "")
  local _,_,num = string.find(s, "(%d+)")
  if num then return tonumber(num) end
  return nil
end

local function markQuestXP(xp)
  XToLevelClassicDB.data.lastQuestXP = xp
  XToLevelClassicDB.data.lastQuestTime = GetTime()
end

-- ===== compute + text =====
local function compute()
  ensureInit()
  if disabled then return { vKill=nil, vQuest=nil, killsTo=nil, questsTo=nil, xph=0, etaTxt="" } end

  local xp = UnitXP("player") or 0
  local xpMax = UnitXPMax("player") or 1
  local remain = xpMax - xp

  local vKill, vQuest
  if XToLevelClassicDB.mode == "last" then
    vKill = last(XToLevelClassicDB.data.kills)
    vQuest = last(XToLevelClassicDB.data.quests)
  else
    vKill = average(XToLevelClassicDB.data.kills)
    vQuest = average(XToLevelClassicDB.data.quests)
  end

  local killsTo  = (vKill  and vKill  > 0) and math.ceil(remain / vKill)  or nil
  local questsTo = (vQuest and vQuest > 0) and math.ceil(remain / vQuest) or nil

  local elapsed = math.max(1, GetTime() - (XToLevelClassicDB.data.sessionStart or GetTime()))
  local xph = (XToLevelClassicDB.data.xpSession or 0) * 3600 / elapsed

  local etaTxt = ""
  if xph > 0 then
    local sec = math.floor(remain / (xph / 3600))
    local h = math.floor(sec / 3600)
    local m = math.floor(math.mod(sec, 3600) / 60)
    local s = math.mod(sec, 60)
    if h > 0 then etaTxt = string.format("ETA %dh %dm", h, m)
    elseif m > 0 then etaTxt = string.format("ETA %dm %ds", m, s)
    else etaTxt = string.format("ETA %ds", s) end
  end

  return { vKill=vKill, vQuest=vQuest, killsTo=killsTo, questsTo=questsTo, xph=xph, etaTxt=etaTxt }
end

local function updateText()
  if disabled then return end
  ensureInit()
  local s = compute()
  local label = (XToLevelClassicDB.mode == "last") and "last" or "avg"
  line1:SetText(string.format("Kills: %s %s  |  to level: %s", label, s.vKill and string.format("%.0f", s.vKill) or "-", s.killsTo and formatNumber(s.killsTo) or "-"))
  line2:SetText(string.format("Quests: %s %s  |  to level: %s", label, s.vQuest and string.format("%.0f", s.vQuest) or "-", s.questsTo and formatNumber(s.questsTo) or "-"))
  local t = "XP/h: " .. formatNumber(math.floor((s.xph or 0) + 0.5))
  if s.etaTxt ~= "" then t = t .. "  |  " .. s.etaTxt end
  line3:SetText(t)
end

-- ===== ticker =====
local acc = 0
local function OnUpd(self, elapsed)
  if disabled then return end
  acc = acc + (elapsed or 0)
  if acc >= 1.0 then
    acc = 0
    if XToLevelClassicDB and XToLevelClassicDB.frame and XToLevelClassicDB.frame.shown then updateText() end
  end
end

-- ===== events =====
f:SetScript("OnEvent", function(self, ev, a1)
  ev = ev or event; a1 = a1 or arg1; if not ev then return end

  if ev == "PLAYER_LOGIN" then
    ensureInit()
    DEFAULT_CHAT_FRAME:AddMessage("XToLevelClassic loaded. Use /xtl")

  elseif ev == "PLAYER_ENTERING_WORLD" then
    if UnitLevel("player") >= MAX_LEVEL then
      DisableAddon("|cffff7e5eXToLevelClassic|r: max level detected; addon disabled.")
      return
    end
    ensureInit(); updateText()

  elseif ev == "PLAYER_LEVEL_UP" then
    local newLevel = tonumber(a1) or UnitLevel("player") or 1
    if newLevel >= MAX_LEVEL then
      DisableAddon("|cffff7e5eXToLevelClassic|r: reached level "..newLevel.."; disabled.")
      return
    end
    ensureInit()
    XToLevelClassicDB.data.kills = {}
    XToLevelClassicDB.data.quests = {}
    updateText()

  elseif ev == "PLAYER_REGEN_DISABLED" then
    ensureInit()
    XToLevelClassicDB.data.lastCombatStart = GetTime()

  elseif ev == "PLAYER_REGEN_ENABLED" then
    ensureInit()
    XToLevelClassicDB.data.lastCombatEnd = GetTime()

  elseif ev == "PLAYER_XP_UPDATE" then
    if disabled then return end
    ensureInit(); updateText()

elseif ev == "CHAT_MSG_SYSTEM" then
  if disabled then return end
  ensureInit()
  local raw = a1 or ""

  -- Only treat lines that actually say "Experience gained"
  if not string.find(string.lower(raw), "experience gained") then
    dprint("SYSTEM ignored (no XP)  | "..tostring(raw))
    return
  end

  local xp = parseFirstNumber(raw)
  if xp then
    pushSample(XToLevelClassicDB.data.quests, xp, XToLevelClassicDB.lengths.quests)
    XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
    markQuestXP(xp)
    updateText()
    dprint("Quest XP +"..xp.."  | "..tostring(raw))
  else
    dprint("SYSTEM seen, no XP parsed  | "..tostring(raw))
  end

  elseif ev == "CHAT_MSG_COMBAT_XP_GAIN" then
    -- Kills and sometimes quest fallback
    if disabled then return end
    ensureInit()
    local raw = a1 or ""
    local line = string.gsub(raw, ",", "")
    local lower = string.lower(line)
    if not string.find(lower, "experience") then
      dprint("COMBAT seen, but no 'experience' word  | "..tostring(raw))
      return
    end

    local xp = parseFirstNumber(line)
    if not xp then
      dprint("COMBAT seen, couldn't parse XP  | "..tostring(raw))
      return
    end

    local now = GetTime()
    local hasDies = string.find(lower, "dies")

    if hasDies then
      -- Treat as kill
      local okByCombat = true
      if XToLevelClassicDB.combatGate then
        okByCombat = ((now - (XToLevelClassicDB.data.lastCombatStart or 0)) < 10.0) or
                     ((now - (XToLevelClassicDB.data.lastCombatEnd   or 0)) < 5.0)
      end
      if okByCombat then
        pushSample(XToLevelClassicDB.data.kills, xp, XToLevelClassicDB.lengths.kills)
        XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
        updateText()
        dprint("Kill XP +"..xp.."  | "..tostring(raw))
      else
        dprint("Ignored kill due to combatGate  | "..tostring(raw))
      end
    else
      -- Quest fallback (COMBAT without 'dies')
      local recentSystemQuest = ((now - (XToLevelClassicDB.data.lastQuestTime or 0)) < (XToLevelClassicDB.questDebounce or 5.0))
      if recentSystemQuest and XToLevelClassicDB.data.lastQuestXP == xp then
        dprint("Ignored COMBAT quest echo +"..xp.."  | "..tostring(raw))
      else
        pushSample(XToLevelClassicDB.data.quests, xp, XToLevelClassicDB.lengths.quests)
        XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
        markQuestXP(xp)
        updateText()
        dprint("Quest XP (COMBAT fallback) +"..xp.."  | "..tostring(raw))
      end
    end
  end
end)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnUpdate", OnUpd)

-- ===== slash =====
SLASH_XTOLEVEL1 = "/xtl"
SlashCmdList["XTOLEVEL"] = function(msg)
  if disabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7e5eXToLevelClassic|r: disabled at level "..MAX_LEVEL..".")
    return
  end
  ensureInit()
  msg = string.lower(msg or "")
  if msg == "" or msg == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100XToLevel Classic commands:|r")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl mode avg           - use rolling average")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl mode last          - use last sample (default)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl len k <n>          - set kill window (avg mode)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl len q <n>          - set quest window (avg mode)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl clear              - clear kill/quest samples")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl reset              - reset kills, quests, session XP, timer")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl qdebounce <sec>    - set quest debounce window (default 5.0)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl combatgate on|off  - require recent combat for kill XP (default off)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl lock|unlock        - lock/unlock frame")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl show|hide          - show/hide frame")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl debug              - toggle debug prints")
    return
  end

  if msg == "lock" then
    XToLevelClassicDB.frame.locked = true; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: frame locked")
  elseif msg == "unlock" then
    XToLevelClassicDB.frame.locked = false; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: frame unlocked")
  elseif msg == "clear" then
    XToLevelClassicDB.data.kills = {}; XToLevelClassicDB.data.quests = {}
    DEFAULT_CHAT_FRAME:AddMessage("XToLevel: kill/quest data cleared"); updateText()
  elseif msg == "reset" then
    XToLevelClassicDB.data.kills = {}; XToLevelClassicDB.data.quests = {}; XToLevelClassicDB.data.xpSession = 0; XToLevelClassicDB.data.sessionStart = GetTime()
    DEFAULT_CHAT_FRAME:AddMessage("XToLevel: data reset"); updateText()
  elseif msg == "show" then
    XToLevelClassicDB.frame.shown = true; f:Show(); updateText()
  elseif msg == "hide" then
    XToLevelClassicDB.frame.shown = false; f:Hide()
  elseif msg == "debug" then
    XToLevelClassicDB.debug = not XToLevelClassicDB.debug; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: debug "..(XToLevelClassicDB.debug and "ON" or "OFF"))
  else
    local _,_,m = string.find(msg, "^mode%s+(%a+)")
    if m == "avg" or m == "last" then
      XToLevelClassicDB.mode = m; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: mode set to "..m); updateText(); return
    end
    local _,_,sec = string.find(msg, "^qdebounce%s+(%d+%.?%d*)")
    if sec then
      XToLevelClassicDB.questDebounce = tonumber(sec) or 5.0
      DEFAULT_CHAT_FRAME:AddMessage(string.format("XToLevel: quest debounce set to %.1fs", XToLevelClassicDB.questDebounce))
      return
    end
    local _,_,cg = string.find(msg, "^combatgate%s+(%a+)")
    if cg == "on" or cg == "off" then
      XToLevelClassicDB.combatGate = (cg == "on")
      DEFAULT_CHAT_FRAME:AddMessage("XToLevel: combat gate "..(XToLevelClassicDB.combatGate and "ON" or "OFF"))
      return
    end
    local _,_,w,nstr = string.find(msg, "len%s+([kq])%s+(%d+)")
    if w and nstr then
      local n = tonumber(nstr)
      if w == "k" then
        XToLevelClassicDB.lengths.kills = n; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: kill window set to "..n)
        while table.getn(XToLevelClassicDB.data.kills) > n do table.remove(XToLevelClassicDB.data.kills, 1) end
      else
        XToLevelClassicDB.lengths.quests = n; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: quest window set to "..n)
        while table.getn(XToLevelClassicDB.data.quests) > n do table.remove(XToLevelClassicDB.data.quests, 1) end
      end
      updateText()
    else
      DEFAULT_CHAT_FRAME:AddMessage("XToLevel: unknown command. Use /xtl for help")
    end
  end
end
