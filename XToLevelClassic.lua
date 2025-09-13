-- XToLevel (Classic) — v1.1.2
-- Minimal, 1.12.1-compatible leveling panel: kills/quests to level, XP/h, ETA.
-- Exploration XP contributes to session totals only (not kills/quests).

local ADDON_NAME = "XToLevelClassic"
local f = CreateFrame("Frame", "XTLClassic_Frame", UIParent)

XToLevelClassicDB = XToLevelClassicDB or nil

local MAX_LEVEL = 60 -- Classic cap

local defaults = {
  version = "1.1.2",
  frame = { point = "CENTER", x = 0, y = 0, locked = false, shown = true },
  lengths = { kills = 50, quests = 50 },
  debug = false,
  mode = "last",         -- "last" (default) or "avg"
  questDebounce = 5.0,   -- seconds to ignore duplicate echoes
  pendingWindow = 2.0,   -- seconds to wait for SYSTEM after COMBAT w/o "dies"
  data = {
    kills = {},
    quests = {},
    xpSession = 0,
    sessionStart = nil,
    lastQuestXP = 0,
    lastQuestTime = 0,
    lastExploreXP = 0,
    lastExploreTime = 0,
    pending = {},        -- queued COMBAT w/o "dies": {xp=, t=}
  },
}

local disabled = false

-- ========== Utilities ==========
local function ensureDefaults(dst, src)
  if dst == nil then
    local t = {}
    for k, v in pairs(src) do t[k] = (type(v) == "table") and ensureDefaults(nil, v) or v end
    return t
  end
  for k, v in pairs(src) do
    if type(v) == "table" then dst[k] = ensureDefaults(dst[k], v)
    elseif dst[k] == nil then dst[k] = v end
  end
  return dst
end

local function dprint(msg)
  if XToLevelClassicDB and XToLevelClassicDB.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff6aa84f[XTL]|r "..tostring(msg))
  end
end

local function pushSample(list, value, maxLen)
  if not value then return end
  table.insert(list, value)
  if maxLen and maxLen > 0 then
    while table.getn(list) > maxLen do table.remove(list, 1) end
  end
end

local function last(list)
  local n = table.getn(list)
  if n == 0 then return nil end
  return list[n]
end

local function average(list)
  local n = table.getn(list)
  if n == 0 then return nil end
  local s = 0
  for i = 1, n do s = s + (list[i] or 0) end
  return s / n
end

local function parseFirstNumber(msg)
  local s = string.gsub(msg or "", ",", "")
  local _, _, num = string.find(s, "(%d+)")
  if num then return tonumber(num) end
  return nil
end

local function formatNumber(n)
  if not n then return "-" end
  local s = tostring(math.floor(n + 0.5))
  local sign = ""
  if string.sub(s, 1, 1) == "-" then sign = "-" s = string.sub(s, 2) end
  local out, count = "", 0
  for i = string.len(s), 1, -1 do
    out = string.sub(s, i, i) .. out
    count = count + 1
    if count == 3 and i > 1 then out = "," .. out; count = 0 end
  end
  return sign .. out
end

-- quest / exploration markers
local function markQuestXP(xp)
  XToLevelClassicDB.data.lastQuestXP = xp
  XToLevelClassicDB.data.lastQuestTime = GetTime()
end
local function markExploreXP(xp)
  XToLevelClassicDB.data.lastExploreXP = xp
  XToLevelClassicDB.data.lastExploreTime = GetTime()
end

-- pending COMBAT (no "dies") helpers
local function addPending(xp)
  table.insert(XToLevelClassicDB.data.pending, { xp = xp, t = GetTime() })
  dprint("Pending COMBAT (no 'dies') +"..xp)
end
local function consumePending(xp)
  local p = XToLevelClassicDB.data.pending
  for i = table.getn(p), 1, -1 do
    if p[i].xp == xp then table.remove(p, i); return true end
  end
  return false
end
local function promoteExpiredPending()
  local now = GetTime()
  local p = XToLevelClassicDB.data.pending
  local window = XToLevelClassicDB.pendingWindow or defaults.pendingWindow
  local i = 1
  while i <= table.getn(p) do
    if (now - (p[i].t or 0)) >= window then
      local xp = p[i].xp
      table.remove(p, i)
      -- promote to Quest fallback
      pushSample(XToLevelClassicDB.data.quests, xp, XToLevelClassicDB.lengths.quests)
      XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
      markQuestXP(xp)
      dprint("Quest XP (promoted COMBAT pending) +"..xp)
      -- do not increment i (removed current)
    else
      i = i + 1
    end
  end
end

-- ========== Session sanity ==========
local function resetSession()
  XToLevelClassicDB.data.xpSession = 0
  XToLevelClassicDB.data.sessionStart = GetTime()
  -- also clear any dangling pending items
  XToLevelClassicDB.data.pending = {}
  dprint("Session reset")
end

local function sanitizeSessionOnLoad()
  local tnow = GetTime()
  local ts = XToLevelClassicDB.data.sessionStart
  if type(ts) ~= "number" or tnow < ts then
    -- GetTime wrapped (new login/reload) or invalid; start a fresh session
    resetSession()
  end
end

-- ========== UI ==========
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
  if not XToLevelClassicDB then
    XToLevelClassicDB = ensureDefaults(nil, defaults)
  else
    XToLevelClassicDB = ensureDefaults(XToLevelClassicDB, defaults)
  end
  if not built then BuildFrame() end
  if not XToLevelClassicDB.data.sessionStart then
    XToLevelClassicDB.data.sessionStart = GetTime()
  end
  sanitizeSessionOnLoad()
end

-- ========== Computation & Text ==========
local function compute()
  ensureInit()
  if disabled then return { vKill=nil, vQuest=nil, killsTo=nil, questsTo=nil, xph=0, etaTxt="" } end

  local xp = UnitXP("player") or 0
  local xpMax = UnitXPMax("player") or 1
  local remain = xpMax - xp

  local vKill, vQuest
  if XToLevelClassicDB.mode == "last" then
    vKill  = last(XToLevelClassicDB.data.kills)
    vQuest = last(XToLevelClassicDB.data.quests)
  else
    vKill  = average(XToLevelClassicDB.data.kills)
    vQuest = average(XToLevelClassicDB.data.quests)
  end

  -- robust elapsed (avoid negatives/zeros)
  local elapsed = GetTime() - (XToLevelClassicDB.data.sessionStart or GetTime())
  if (not elapsed) or (elapsed < 1) then elapsed = 1 end

  local xph = (XToLevelClassicDB.data.xpSession or 0) * 3600 / elapsed

  local killsTo  = (vKill  and vKill  > 0) and math.ceil(remain / vKill)  or nil
  local questsTo = (vQuest and vQuest > 0) and math.ceil(remain / vQuest) or nil

  local etaTxt = ""
  if xph > 0 then
    local sec = math.floor(remain / (xph / 3600))
    if sec < 1 then sec = 1 end
    local h = math.floor(sec / 3600)
    local m = math.floor(math.mod(sec, 3600) / 60)
    local s = math.mod(sec, 60)
    if h > 0 then etaTxt = string.format("ETA %dh %dm", h, m)
    elseif m > 0 then etaTxt = string.format("ETA %dm %ds", m, s)
    else etaTxt = "ETA <1s" end
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

-- ========== Disable at 60 ==========
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

-- ========== Ticker ==========
local acc = 0
local function OnUpd(self, elapsed)
  if disabled then return end
  acc = acc + (elapsed or 0)
  if acc >= 1.0 then
    acc = 0
    promoteExpiredPending()
    if XToLevelClassicDB and XToLevelClassicDB.frame and XToLevelClassicDB.frame.shown then updateText() end
  end
end

-- ========== Events ==========
f:SetScript("OnEvent", function(self, ev, a1)
  ev = ev or event; a1 = a1 or arg1; if not ev then return end

  if ev == "PLAYER_LOGIN" then
    ensureInit()
    -- Fresh session each login/reload if clock wrapped
    sanitizeSessionOnLoad()
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
    -- keep session timer running across dings; users prefer continuous XP/h
    updateText()

  elseif ev == "PLAYER_XP_UPDATE" then
    if disabled then return end
    ensureInit(); updateText()

  elseif ev == "CHAT_MSG_SYSTEM" then
    if disabled then return end
    ensureInit()
    local raw = a1 or ""
    local lower = string.lower(raw)

    -- Exploration: "Discovered <Place>: N experience gained"
    if string.find(lower, "experience gained") and string.find(lower, "^discovered") then
      local xp = parseFirstNumber(raw)
      if xp then
        XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
        markExploreXP(xp)
        if consumePending(xp) then dprint("Consumed pending due to exploration +"..xp) end
        updateText()
        dprint("Exploration XP +"..xp.."  | "..tostring(raw))
      else
        dprint("SYSTEM exploration seen, no XP parsed  | "..tostring(raw))
      end
      return
    end

    -- Quests: "Experience gained: N."
    if string.find(lower, "experience gained") then
      local xp = parseFirstNumber(raw)
      if xp then
        consumePending(xp) -- consume any pending non-dies COMBAT for this XP
        pushSample(XToLevelClassicDB.data.quests, xp, XToLevelClassicDB.lengths.quests)
        XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
        markQuestXP(xp)
        updateText()
        dprint("Quest XP +"..xp.."  | "..tostring(raw))
      else
        dprint("SYSTEM seen, no XP parsed  | "..tostring(raw))
      end
      return
    end

    dprint("SYSTEM ignored (no XP)  | "..tostring(raw))

  elseif ev == "CHAT_MSG_COMBAT_XP_GAIN" then
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

    if string.find(lower, "dies") then
      -- Kill
      pushSample(XToLevelClassicDB.data.kills, xp, XToLevelClassicDB.lengths.kills)
      XToLevelClassicDB.data.xpSession = (XToLevelClassicDB.data.xpSession or 0) + xp
      updateText()
      dprint("Kill XP +"..xp.."  | "..tostring(raw))
    else
      -- Non-kill COMBAT: buffer for SYSTEM clarification
      addPending(xp)
      -- promotion happens in OnUpdate if no SYSTEM arrives
    end
  end
end)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")

f:SetScript("OnUpdate", OnUpd)

-- ========== Slash Commands ==========
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
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl qdebounce <sec>    - set quest/explore echo window (default 5.0)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl pending <sec>      - set pending COMBAT wait window (default 2.0)")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl lock|unlock        - lock/unlock frame")
    DEFAULT_CHAT_FRAME:AddMessage("  /xtl show|hide          - show/hide panel")
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
    XToLevelClassicDB.data.kills = {}; XToLevelClassicDB.data.quests = {}
    resetSession()
    DEFAULT_CHAT_FRAME:AddMessage("XToLevel: data reset"); updateText()
  elseif msg == "show" then
    XToLevelClassicDB.frame.shown = true; f:Show(); updateText()
  elseif msg == "hide" then
    XToLevelClassicDB.frame.shown = false; f:Hide()
  elseif msg == "debug" then
    XToLevelClassicDB.debug = not XToLevelClassicDB.debug; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: debug "..(XToLevelClassicDB.debug and "ON" or "OFF"))
  else
    local _, _, m = string.find(msg, "^mode%s+(%a+)")
    if m == "avg" or m == "last" then
      XToLevelClassicDB.mode = m; DEFAULT_CHAT_FRAME:AddMessage("XToLevel: mode set to "..m); updateText(); return
    end
    local _, _, nK = string.find(msg, "len%s+k%s+(%d+)")
    if nK then
      XToLevelClassicDB.lengths.kills = tonumber(nK) or XToLevelClassicDB.lengths.kills
      DEFAULT_CHAT_FRAME:AddMessage("XToLevel: kill window set to "..XToLevelClassicDB.lengths.kills)
      while table.getn(XToLevelClassicDB.data.kills) > XToLevelClassicDB.lengths.kills do table.remove(XToLevelClassicDB.data.kills, 1) end
      updateText(); return
    end
    local _, _, nQ = string.find(msg, "len%s+q%s+(%d+)")
    if nQ then
      XToLevelClassicDB.lengths.quests = tonumber(nQ) or XToLevelClassicDB.lengths.quests
      DEFAULT_CHAT_FRAME:AddMessage("XToLevel: quest window set to "..XToLevelClassicDB.lengths.quests)
      while table.getn(XToLevelClassicDB.data.quests) > XToLevelClassicDB.lengths.quests do table.remove(XToLevelClassicDB.data.quests, 1) end
      updateText(); return
    end
    local _, _, sec = string.find(msg, "^qdebounce%s+(%d+%.?%d*)")
    if sec then
      XToLevelClassicDB.questDebounce = tonumber(sec) or defaults.questDebounce
      DEFAULT_CHAT_FRAME:AddMessage(string.format("XToLevel: quest/explore echo window set to %.1fs", XToLevelClassicDB.questDebounce))
      return
    end
    local _, _, pwin = string.find(msg, "^pending%s+(%d+%.?%d*)")
    if pwin then
      XToLevelClassicDB.pendingWindow = tonumber(pwin) or defaults.pendingWindow
      DEFAULT_CHAT_FRAME:AddMessage(string.format("XToLevel: pending COMBAT wait set to %.1fs", XToLevelClassicDB.pendingWindow))
      return
    end

    DEFAULT_CHAT_FRAME:AddMessage("XToLevel: unknown command. Use /xtl for help")
  end
end
