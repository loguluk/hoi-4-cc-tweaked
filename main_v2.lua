-- pocket.lua: HOI-CC для карманного компьютера (Advanced Pocket Computer, 26x20)
-- Берёт карту из map.lua (та же, что в main.lua). Запуск: pocket
-- Управление мышью: перетаскивание = двигать карту, нажатие = выбрать провинцию,
-- колесо = масштаб. Клавиши: стрелки, = и - (масштаб), пробел (пауза), [ ] (скорость),
-- R (нанять), I (инфо), C (центр на провинции), M или Q (меню).

local dir = fs.getDir(shell.getRunningProgram())
local map = dofile(fs.combine(dir, "map.lua"))
local provinces = map.provinces

if not term.isColor() then error("Нужен Advanced Pocket Computer (цветной экран)", 0) end
local mon = term          -- общий код рисует через mon

-- своя палитра для красивой карты
for name, hex in pairs(map.palette) do
  term.setPaletteColour(colors[name], hex)
end
local function restorePalette()
  for name in pairs(map.palette) do
    local r, g, b = term.nativePaletteColour(colors[name])
    term.setPaletteColour(colors[name], r, g, b)
  end
end

local cmap = {}   -- id страны -> { name, color, fg }
local countryIds = {}
for _, c in ipairs(map.countries) do
  cmap[c.id] = { name = c.name, color = colors[c.color], fg = colors[c.fg], neutral = c.neutral }
  countryIds[#countryIds + 1] = c.id
end
local SEA_DEEP, SEA_SHALLOW = colors[map.seaDeep], colors[map.seaShallow]

local neutralId
local colorChoices = {}                -- цвета палитры, доступные для своей страны
do
  local seen = {}
  for _, c in ipairs(map.countries) do
    if c.neutral then neutralId = c.id end
    if not c.neutral and not seen[c.color] then
      seen[c.color] = true
      colorChoices[#colorChoices + 1] = { color = colors[c.color], fg = colors[c.fg], slot = c.color }
    end
  end
end

local PANEL_W = 0
local W, H, mapW, mapH

------------------------------------------------------------ мир
local WW, WH = map.w, map.h
local world = {}            -- world[y][x]: >0 провинция, 0 глубокое море, -1 мелководье
local ZOOMS = { 0.25, 0.5, 1, 2, 3, 4 }
local zi = 2
local vx, vy = 0, 0         -- левый верхний угол вида в клетках мира

local function loadWorld()
  for y = 1, WH do
    local row, x = {}, 1
    for id, n in map.rows[y]:gmatch("(-?%d+):(%d+)") do
      id, n = tonumber(id), tonumber(n)
      for i = x, x + n - 1 do row[i] = id end
      x = x + n
    end
    world[y] = row
  end
end

local function layout()
  W, H = term.getSize()
  mapW = W - PANEL_W
  mapH = H - 4        -- строки: 1 шапка, карта, 3 нижних строки
end

local function viewSize()
  local z = ZOOMS[zi]
  return mapW / z, mapH / z
end

local function clampView()
  local vw, vh = viewSize()
  if vw >= WW then vx = (WW - vw) / 2 else vx = math.max(0, math.min(WW - vw, vx)) end
  if vh >= WH then vy = (WH - vh) / 2 else vy = math.max(0, math.min(WH - vh, vy)) end
end

-- сырое значение клетки мира под клеткой экрана
local function rawAt(sx, sy)
  local z = ZOOMS[zi]
  local wx = math.floor(vx + (sx - 1) / z) + 1
  local wy = math.floor(vy + (sy - 1) / z) + 1
  if wx < 1 or wx > WW or wy < 1 or wy > WH then return 0 end
  return world[wy][wx]
end

-- провинция под клеткой экрана, 0 = море
local function pAt(sx, sy)
  local v = rawAt(sx, sy)
  return v > 0 and v or 0
end

------------------------------------------------------------ состояние
local selected = nil
local paused = true
local speed = 2
local SPEEDS = { 1.0, 0.5, 0.2, 0.05 }
local date = { y = 1936, m = 1, d = 1 }
local timerId = nil
local buttons = {}

------------------------------------------------------------ игровая логика (без отрисовки)
local playable = {}                  -- страны, за которые можно играть (без нейтральной)
for _, id in ipairs(countryIds) do
  if not cmap[id].neutral then playable[#playable + 1] = id end
end
local OPTS = {
  { key = "aggr",   label = "AI wars",             vals = { "Off", "Low", "Normal", "High" },    num = { 0, 0.05, 0.15, 0.4 } },
  { key = "expand", label = "AI colonization",     vals = { "Off", "Normal", "Fast" },           num = { 0, 1, 2 } },
  { key = "start",  label = "Divisions at start",  vals = { "1 per province", "2 per province", "3 per province" }, num = { 1, 2, 3 } },
  { key = "income", label = "Income",              vals = { "x0.5", "x1", "x2", "x4" },          num = { 0.5, 1, 2, 4 } },
  { key = "cost",   label = "Division cost (PP)",  vals = { "50", "100", "150", "200" },         num = { 50, 100, 150, 200 } },
  { key = "march",  label = "Days per land step",  vals = { "2", "3", "4", "6" },                num = { 2, 3, 4, 6 } },
  { key = "events", label = "Random events",       vals = { "Off", "Rare", "Often", "Chaos" },   num = { 0, 0.02, 0.06, 0.2 } },
  { key = "auto",   label = "Auto-recruit (you)",  vals = { "Off", "On" },                       num = { 0, 1 } },
  { key = "speed",  label = "Start speed",         vals = { "1 (slow)", "2", "3", "4 (fast)" },  num = { 1, 2, 3, 4 } },
}
local settings = { country = 1, observer = false, aggr = 3, expand = 2, start = 1, income = 2,
                   cost = 2, march = 2, events = 2, auto = 1, speed = 2 }
local function val(key)
  for _, o in ipairs(OPTS) do
    if o.key == key then return o.num[settings[key]] end
  end
end
local initialOwner = {}
for i, p in ipairs(provinces) do initialOwner[i] = p.owner end
local player = playable[1]               -- nil = режим наблюдателя
local inMenu, gameStarted, quit = true, false, false
local enterMenu                          -- определена ниже
local menuPage = "main"
local picking, pickSave = false, nil
local draft = { name = "Newland", color = 1, cap = nil, size = 2 }
local createMsg = ""
local baseCap, capOf = {}, {}            -- исходные столицы / столицы своих стран
for i, p in ipairs(provinces) do baseCap[i] = p.cap and true or false end
local provByName = {}
for i, p in ipairs(provinces) do provByName[p.name] = i end
local divisions, nextDiv = {}, 1
local wars = {}
local battles = {}          -- провинции с боем в текущий день
local dirty = false         -- нужно ли перерисовать карту
local mode = nil            -- режим приказа: { all = true/false }
local msgText = ""
local logLines = {}

math.randomseed(os.epoch("utc"))

local function daysInMonth(y, m)
  local t = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if m == 2 and (y % 4 == 0) then return 29 end
  return t[m]
end

local function warKey(a, b)
  if a > b then a, b = b, a end
  return a .. "|" .. b
end
local function atWar(a, b) return a ~= b and wars[warKey(a, b)] == true end

local function addLog(text)
  table.insert(logLines, 1, string.format("%02d.%02d %s", date.d, date.m, text))
  if #logLines > 8 then table.remove(logLines) end
end

local function addDivision(owner, prov)
  divisions[#divisions + 1] = { id = nextDiv, owner = owner, prov = prov, str = 100 }
  nextDiv = nextDiv + 1
end

local function spawnDivisions()
  local n0 = val("start")
  for i, p in ipairs(provinces) do
    if not cmap[p.owner].neutral then
      for _ = 1, (p.cap and n0 + 2 or n0) do addDivision(p.owner, i) end
    end
  end
end

local links = {}          -- links[i] = { { n = провинция, sea = true/false, days = дни по морю } }

local function linkDays(a, b)
  for _, l in ipairs(links[a] or {}) do
    if l.n == b then return l.sea and l.days or val("march") end
  end
  return nil
end

-- сухопутные связи + морские пути между материками и островами
local function buildLinks()
  links = {}
  local comp, ncomp = {}, 0
  for i = 1, #provinces do
    links[i] = {}
    for _, n in ipairs(provinces[i].nb) do links[i][#links[i] + 1] = { n = n } end
  end
  for i = 1, #provinces do
    if not comp[i] then
      ncomp = ncomp + 1
      comp[i] = ncomp
      local queue, qi = { i }, 1
      while qi <= #queue do
        local a = queue[qi]
        qi = qi + 1
        for _, n in ipairs(provinces[a].nb) do
          if not comp[n] then comp[n] = ncomp; queue[#queue + 1] = n end
        end
      end
    end
  end

  local coastal = {}
  for i, p in ipairs(provinces) do
    if p.coast then coastal[#coastal + 1] = i end
  end
  local cross = {}        -- "a|b" -> пары прибрежных провинций разных суш
  for x = 1, #coastal do
    for y = x + 1, #coastal do
      local i, j = coastal[x], coastal[y]
      if comp[i] ~= comp[j] then
        local dx = provinces[i].cx - provinces[j].cx
        local dy = (provinces[i].cy - provinces[j].cy) * 1.5
        local ca, cb = math.min(comp[i], comp[j]), math.max(comp[i], comp[j])
        local key = ca .. "|" .. cb
        cross[key] = cross[key] or {}
        table.insert(cross[key], { d = math.sqrt(dx * dx + dy * dy), i = i, j = j })
      end
    end
  end

  local partners, use = {}, {}
  for key, l in pairs(cross) do
    table.sort(l, function(u, v) return u.d < v.d end)
    local a, b = key:match("(%d+)|(%d+)")
    a, b = tonumber(a), tonumber(b)
    partners[a] = partners[a] or {}
    partners[b] = partners[b] or {}
    table.insert(partners[a], { key = key, d = l[1].d })
    table.insert(partners[b], { key = key, d = l[1].d })
    if l[1].d <= 60 then use[key] = true end          -- близкие берега всегда связаны
  end
  for _, list in pairs(partners) do                   -- каждая суша связана с двумя ближайшими
    table.sort(list, function(u, v) return u.d < v.d end)
    for k = 1, math.min(2, #list) do use[list[k].key] = true end
  end
  for key in pairs(use) do
    local l, n = cross[key], 0
    for _, e in ipairs(l) do
      if n >= 4 or e.d > l[1].d + 12 then break end
      local days = math.max(5, math.floor(e.d / 6 + 0.5))
      table.insert(links[e.i], { n = e.j, sea = true, days = days })
      table.insert(links[e.j], { n = e.i, sea = true, days = days })
      n = n + 1
    end
  end
end

-- приказ любой страны: идти из from в to. Возвращает число отправленных дивизий (или 0, причина)
local function moveDivisions(who, from, to, all)
  local days = linkDays(from, to)
  if not days then return 0, "No route there" end
  local t = provinces[to].owner
  if t ~= who and not cmap[t].neutral and not atWar(who, t) then
    return 0, "Declare war first"
  end
  local moved = 0
  for _, d in ipairs(divisions) do
    if d.owner == who and d.prov == from and not d.to and (all or moved < 1) then
      d.to, d.left = to, days
      moved = moved + 1
    end
  end
  return moved
end

-- приказ игрока. Возвращает true, если карта изменилась.
local function issueMove(from, to, all)
  if not player then msgText = "Observer mode"; return false end
  local moved, why = moveDivisions(player, from, to, all)
  if why then msgText = why; return false end
  msgText = moved > 0 and (moved .. " div -> " .. provinces[to].name) or "No ready divisions"
  return moved > 0
end

local function declareWar()
  if not player then msgText = "Observer mode"; return end
  if not selected then msgText = "Select a province"; return end
  local t = provinces[selected].owner
  if t == player then msgText = "That is your land"; return end
  if cmap[t].neutral then msgText = "Unclaimed: just walk in"; return end
  if atWar(player, t) then msgText = "Already at war"; return end
  wars[warKey(player, t)] = true
  addLog(cmap[player].name .. " vs " .. cmap[t].name)
  msgText = "War declared on " .. cmap[t].name
end

------------------------------------------------------------ экономика и ИИ
local DIV_CAP = 40                      -- лимит дивизий на страну
local pp, dead, lastWar = {}, {}, {}
for _, id in ipairs(countryIds) do pp[id] = 0; lastWar[id] = -999 end
local dayCount, aiIdx = 0, 0

local function capitalOf(id)
  local first
  for i, p in ipairs(provinces) do
    if p.owner == id then
      if p.cap then return i end
      first = first or i
    end
  end
  return first
end

local function inWar(id)
  for k in pairs(wars) do
    if k:find(id, 1, true) then return true end
  end
  return false
end

local function aiTick(id)
  local idle, foes, mine = {}, {}, 0
  for _, d in ipairs(divisions) do
    if d.owner == id then
      mine = mine + 1
      if not d.to then
        local l = idle[d.prov]
        if not l then l = {}; idle[d.prov] = l end
        l[#l + 1] = d
      end
    else
      foes[d.prov] = (foes[d.prov] or 0) + 1
    end
  end

  local orders, targeted = 0, {}
  -- 1) война: бьём слабейшую соседнюю провинцию врага
  for from, list in pairs(idle) do
    if orders >= 3 then break end
    local bestTo, bestFoe
    for _, l in ipairs(links[from]) do
      local n = l.n
      local o = provinces[n].owner
      if o ~= id and not cmap[o].neutral and atWar(id, o) and not targeted[n] then
        local f = foes[n] or 0
        if not bestFoe or f < bestFoe then bestTo, bestFoe = n, f end
      end
    end
    if bestTo and (bestFoe == 0 or #list > bestFoe) then
      if moveDivisions(id, from, bestTo, true) > 0 then
        targeted[bestTo] = true
        orders = orders + 1
        dirty = true
      end
    end
  end

  -- 2) колонизация: занимаем нейтральные земли рядом и за морем
  local colOrders = 0
  for from, list in pairs(idle) do
    if colOrders >= 3 * val("expand") then break end
    if #list >= 2 or not provinces[from].cap then
      for _, l in ipairs(links[from]) do
        local n = l.n
        if cmap[provinces[n].owner].neutral and not targeted[n] then
          if moveDivisions(id, from, n, false) > 0 then
            targeted[n] = true
            colOrders = colOrders + 1
            dirty = true
          end
          break
        end
      end
    end
  end

  -- 3) объявление войны более слабому соседу
  if not inWar(id) and dayCount - lastWar[id] > 60
      and val("aggr") > 0 and math.random() < val("aggr") then
    local cnt = {}
    for _, d in ipairs(divisions) do cnt[d.owner] = (cnt[d.owner] or 0) + 1 end
    local cand, candCnt
    for i, p in ipairs(provinces) do
      if p.owner == id then
        for _, l in ipairs(links[i]) do
          local n = l.n
          local o = provinces[n].owner
          if o ~= id and not cmap[o].neutral and not dead[o] then
            local oc = cnt[o] or 0
            if not candCnt or oc < candCnt then cand, candCnt = o, oc end
          end
        end
      end
    end
    if cand and mine >= candCnt * 1.3 + 1 then
      wars[warKey(id, cand)] = true
      lastWar[id] = dayCount
      addLog(cmap[id].name .. " vs " .. cmap[cand].name)
    end
  end
end

local function randomEvent()
  local alive = {}
  for _, id in ipairs(playable) do
    if not dead[id] then alive[#alive + 1] = id end
  end
  if #alive == 0 then return end
  local id = alive[math.random(#alive)]
  local name = cmap[id].name
  local k = math.random(6)
  if k == 1 then
    pp[id] = pp[id] + 60
    addLog(name .. ": gold rush +60 PP")
  elseif k == 2 then
    pp[id] = pp[id] + 30
    addLog(name .. ": good harvest +30 PP")
  elseif k == 3 then
    local at = capitalOf(id)
    if at then
      addDivision(id, at)
      addLog(name .. ": volunteers join")
      dirty = true
    end
  elseif k == 4 then
    local mine = {}
    for i, d in ipairs(divisions) do
      if d.owner == id then mine[#mine + 1] = i end
    end
    if #mine >= 3 then
      table.remove(divisions, mine[math.random(#mine)])
      addLog(name .. ": mutiny, a division is lost")
      dirty = true
    end
  elseif k == 5 then
    local owned = {}
    for i, p in ipairs(provinces) do
      if p.owner == id then owned[#owned + 1] = i end
    end
    if #owned > 0 then
      local at = owned[math.random(#owned)]
      for _, d in ipairs(divisions) do
        if d.owner == id and d.prov == at then d.str = d.str - 25 end
      end
      addLog("Plague in " .. provinces[at].name)
    end
  else
    local owned = {}
    for i, p in ipairs(provinces) do
      if p.owner == id and not p.cap then owned[#owned + 1] = i end
    end
    if #owned >= 3 then
      local at = owned[math.random(#owned)]
      local occupied = false
      for _, d in ipairs(divisions) do
        if d.prov == at then occupied = true; break end
      end
      if not occupied then
        provinces[at].owner = neutralId
        addLog("Revolt in " .. provinces[at].name)
        dirty = true
      end
    end
  end
end

local function economyAndAI()
  dayCount = dayCount + 1
  local income, nprov, cnt = {}, {}, {}
  for _, p in ipairs(provinces) do
    income[p.owner] = (income[p.owner] or 0) + (0.5 + 0.5 * p.ind) * val("income")
    nprov[p.owner] = (nprov[p.owner] or 0) + 1
  end
  for _, d in ipairs(divisions) do cnt[d.owner] = (cnt[d.owner] or 0) + 1 end

  for _, id in ipairs(countryIds) do
    if not cmap[id].neutral and not dead[id] then
      if (nprov[id] or 0) == 0 then
        dead[id] = true
        local keep = {}
        for _, d in ipairs(divisions) do
          if d.owner ~= id then keep[#keep + 1] = d end
        end
        divisions = keep
        for k in pairs(wars) do
          if k:find(id, 1, true) then wars[k] = nil end
        end
        addLog(cmap[id].name .. " eliminated")
        if id == player then msgText = "Your country is gone!" end
        dirty = true
      else
        pp[id] = pp[id] + (income[id] or 0)
        local auto = (id ~= player) or val("auto") == 1
        if auto and pp[id] >= val("cost") and (cnt[id] or 0) < DIV_CAP then
          local at = capitalOf(id)
          if at then
            pp[id] = pp[id] - val("cost")
            addDivision(id, at)
            dirty = true
          end
        end
      end
    end
  end

  -- случайные события
  local ec = val("events")
  if ec > 0 and math.random() < ec then randomEvent() end

  -- ИИ: две страны за день по кругу (кроме страны игрока)
  for _ = 1, 2 do
    aiIdx = aiIdx % #countryIds + 1
    local id = countryIds[aiIdx]
    if id ~= player and not cmap[id].neutral and not dead[id] then aiTick(id) end
  end
end

local function recruit()
  if not player then msgText = "Observer mode"; return end
  local at = (selected and provinces[selected].owner == player) and selected or capitalOf(player)
  if not at then msgText = "No province to recruit in"; return end
  local cost = val("cost")
  if pp[player] < cost then
    msgText = string.format("Need %d PP (have %d)", cost, math.floor(pp[player]))
    return
  end
  local n = 0
  for _, d in ipairs(divisions) do
    if d.owner == player then n = n + 1 end
  end
  if n >= DIV_CAP then msgText = "Division limit reached"; return end
  pp[player] = pp[player] - cost
  addDivision(player, at)
  dirty = true
  msgText = "Recruited in " .. provinces[at].name
end

local function newGame()
  for i, p in ipairs(provinces) do
    p.owner = initialOwner[i]
    p.cap = baseCap[i] or capOf[i] or false
  end
  divisions, nextDiv = {}, 1
  wars, battles = {}, {}
  dirty, mode, msgText, logLines = false, nil, "Tap a province to start", {}
  for _, id in ipairs(countryIds) do pp[id] = 0; lastWar[id] = -999; dead[id] = nil end
  dayCount, aiIdx = 0, 0
  date.y, date.m, date.d = 1936, 1, 1
  selected = nil
  speed = val("speed")
  paused = true
  timerId = nil
  player = (not settings.observer) and playable[settings.country] or nil
  spawnDivisions()
  zi = 2
  local vw, vh = viewSize()
  vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
end

local function advanceDay()
  date.d = date.d + 1
  if date.d > daysInMonth(date.y, date.m) then
    date.d = 1
    date.m = date.m + 1
    if date.m > 12 then date.m = 1; date.y = date.y + 1 end
  end

  local hadBattles = next(battles) ~= nil
  dirty = hadBattles
  battles = {}

  -- движение
  for _, d in ipairs(divisions) do
    if d.to then
      d.left = d.left - 1
      if d.left <= 0 then d.prov, d.to = d.to, nil; dirty = true end
    end
  end

  -- нейтральные земли достаются тому, кто пришёл
  for _, d in ipairs(divisions) do
    local p = provinces[d.prov]
    if cmap[p.owner].neutral and not cmap[d.owner].neutral then
      p.owner = d.owner
      addLog(cmap[d.owner].name .. " claimed " .. p.name)
      dirty = true
    end
  end

  -- бои и захваты
  local by = {}
  for _, d in ipairs(divisions) do
    by[d.prov] = by[d.prov] or {}
    table.insert(by[d.prov], d)
  end
  local fought = {}
  for pi, list in pairs(by) do
    local own = provinces[pi].owner
    local def, inv = {}, {}
    for _, d in ipairs(list) do
      if d.owner == own then def[#def + 1] = d
      elseif atWar(d.owner, own) then inv[#inv + 1] = d end
    end
    if #inv > 0 then
      if #def == 0 then
        local cnt, best, bn = {}, inv[1].owner, 0
        for _, d in ipairs(inv) do
          cnt[d.owner] = (cnt[d.owner] or 0) + 1
          if cnt[d.owner] > bn then best, bn = d.owner, cnt[d.owner] end
        end
        provinces[pi].owner = best
        addLog(cmap[best].name .. " took " .. provinces[pi].name)
        dirty = true
      else
        battles[pi] = true
        local a, b = 0, 0
        for _, d in ipairs(inv) do
          a = a + 10 * (d.str / 100) * (0.6 + math.random() * 0.8)
          fought[d] = true
        end
        for _, d in ipairs(def) do
          b = b + 12.5 * (d.str / 100) * (0.6 + math.random() * 0.8)
          fought[d] = true
        end
        for _, d in ipairs(def) do d.str = d.str - a / #def end
        for _, d in ipairs(inv) do d.str = d.str - b / #inv end
        dirty = true
      end
    end
  end

  -- потери и восстановление
  local alive = {}
  for _, d in ipairs(divisions) do
    if d.str > 0 then
      alive[#alive + 1] = d
      if not fought[d] then d.str = math.min(100, d.str + 0.5) end
    else
      addLog(cmap[d.owner].name .. " lost a division")
      dirty = true
    end
  end
  divisions = alive
  economyAndAI()
end

------------------------------------------------------------ отрисовка карты
local function drawMap()
  local z = ZOOMS[zi]
  local rows = {}
  for y = 1, mapH do
    local ch, fg, bg = {}, {}, {}
    for x = 1, mapW do
      local raw = rawAt(x, y)
      local col
      if raw > 0 then
        local owner = provinces[raw].owner
        col = cmap[owner].color
        local r, d = pAt(x + 1, y), pAt(x, y + 1)
        if raw ~= r or raw ~= d then
          local hl = (r ~= raw and (raw == selected or r == selected))
                  or (d ~= raw and (raw == selected or d == selected))
          if hl then
            col = colors.white
          else
            -- граница страны или берег: чёрная, внутри страны: серая
            local inner = true
            if r ~= raw and (r == 0 or provinces[r].owner ~= owner) then inner = false end
            if d ~= raw and (d == 0 or provinces[d].owner ~= owner) then inner = false end
            col = inner and colors.gray or colors.black
          end
        end
      elseif raw == -1 then
        col = SEA_SHALLOW
      else
        col = SEA_DEEP
      end
      ch[x] = " "
      bg[x] = col
      fg[x] = colors.white
    end
    rows[y] = { ch = ch, fg = fg, bg = bg }
  end

  -- морские пути выбранной провинции (пунктир)
  if selected and links[selected] then
    local function sp(p)
      return math.floor((p.cx - 0.5 - vx) * z) + 1, math.floor((p.cy - 0.5 - vy) * z) + 1
    end
    local x1, y1 = sp(provinces[selected])
    for _, l in ipairs(links[selected]) do
      if l.sea then
        local x2, y2 = sp(provinces[l.n])
        local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
        for st = 0, steps do
          if st % 3 == 0 then
            local t = steps == 0 and 0 or st / steps
            local x = math.floor(x1 + (x2 - x1) * t + 0.5)
            local y = math.floor(y1 + (y2 - y1) * t + 0.5)
            if x >= 1 and x <= mapW and y >= 1 and y <= mapH then rows[y].bg[x] = colors.white end
          end
        end
      end
    end
  end

  -- подписи: ниже x2 только столицы
  for i, p in ipairs(provinces) do
    if z >= 2 or p.cap then
      local cx = math.floor((p.cx - 0.5 - vx) * z) + 1
      local cy = math.floor((p.cy - 0.5 - vy) * z) + 1
      if cx >= 1 and cx <= mapW and cy >= 1 and cy <= mapH then
        local name = (p.cap and "*" or "") .. p.name
        name = name:sub(1, 11)
        local x0 = math.max(1, math.min(mapW - #name + 1, cx - math.floor(#name / 2)))
        local row = rows[cy]
        local c = cmap[p.owner]
        for k = 1, #name do
          row.ch[x0 + k - 1] = name:sub(k, k)
          row.bg[x0 + k - 1] = c.color
          row.fg[x0 + k - 1] = c.fg
        end
      end
    end
  end

  -- маркеры дивизий: число, ">" если идут, "!" если бой
  local byProv = {}
  for _, d in ipairs(divisions) do
    local g = byProv[d.prov]
    if not g then g = {}; byProv[d.prov] = g end
    local e = g[d.owner]
    if not e then e = { n = 0, mov = false }; g[d.owner] = e end
    e.n = e.n + 1
    if d.to then e.mov = true end
  end
  for pi, groups in pairs(byProv) do
    local p = provinces[pi]
    local cx = math.floor((p.cx - 0.5 - vx) * z) + 1
    local cy = math.floor((p.cy - 0.5 - vy) * z) + 1
    if z >= 2 or p.cap then cy = cy + 1 end
    if cx >= 1 and cx <= mapW and cy >= 1 and cy <= mapH then
      local chips, total = {}, 0
      for _, id in ipairs(countryIds) do
        local e = groups[id]
        if e then
          local txt = " " .. e.n .. (e.mov and ">" or "") .. (battles[pi] and "!" or "") .. " "
          chips[#chips + 1] = { txt = txt, id = id }
          total = total + #txt
        end
      end
      local x0 = math.max(1, math.min(mapW - total + 1, cx - math.floor(total / 2)))
      local row = rows[cy]
      for _, chip in ipairs(chips) do
        local c = cmap[chip.id]
        local hl = (chip.id == player and pi == selected)
        for k = 1, #chip.txt do
          row.ch[x0 + k - 1] = chip.txt:sub(k, k)
          row.bg[x0 + k - 1] = hl and colors.white or c.color
          row.fg[x0 + k - 1] = hl and colors.black or c.fg
        end
        x0 = x0 + #chip.txt
      end
    end
  end

  for y = 1, mapH do
    local r = rows[y]
    local t, f, b = {}, {}, {}
    for x = 1, mapW do
      t[x] = r.ch[x]
      f[x] = colors.toBlit(r.fg[x])
      b[x] = colors.toBlit(r.bg[x])
    end
    mon.setCursorPos(1, y + 1)
    mon.blit(table.concat(t), table.concat(f), table.concat(b))
  end
end

------------------------------------------------------------ свои страны
local CUSTOM_FILE = fs.combine(dir, "custom.dat")
local custom = {}   -- { { id, name, color, cap, provs = { имена провинций } } }

local function saveCustom()
  local h = fs.open(CUSTOM_FILE, "w")
  if h then
    h.write(textutils.serialize(custom))
    h.close()
  end
end

local function addCustomCountry(cc)
  local ch = colorChoices[cc.color] or colorChoices[1]
  cmap[cc.id] = { name = cc.name, color = ch.color, fg = ch.fg }
  countryIds[#countryIds + 1] = cc.id
  playable[#playable + 1] = cc.id
  pp[cc.id], lastWar[cc.id] = 0, -999
  dead[cc.id] = true          -- в идущей партии её нет, появится в новой
  for _, pname in ipairs(cc.provs) do
    local idx = provByName[pname]
    if idx and cmap[initialOwner[idx]].neutral then initialOwner[idx] = cc.id end
  end
  local cap = provByName[cc.cap]
  if cap then capOf[cap] = true end
end

local function loadCustom()
  if not fs.exists(CUSTOM_FILE) then return end
  local h = fs.open(CUSTOM_FILE, "r")
  if not h then return end
  local t = textutils.unserialize(h.readAll())
  h.close()
  if type(t) ~= "table" then return end
  for _, cc in ipairs(t) do
    if type(cc) == "table" and cc.id and cc.name and cc.cap and cc.provs then
      custom[#custom + 1] = cc
      addCustomCountry(cc)
    end
  end
end

local function removeLastCustom()
  local cc = table.remove(custom)
  if not cc then return "Nothing to delete" end
  for i = #countryIds, 1, -1 do
    if countryIds[i] == cc.id then table.remove(countryIds, i) end
  end
  for i = #playable, 1, -1 do
    if playable[i] == cc.id then table.remove(playable, i) end
  end
  for _, pname in ipairs(cc.provs) do
    local idx = provByName[pname]
    if idx and initialOwner[idx] == cc.id then initialOwner[idx] = neutralId end
    if idx then capOf[idx] = nil end
  end
  for _, p in ipairs(provinces) do
    if p.owner == cc.id then p.owner = neutralId end
  end
  local keep = {}
  for _, d in ipairs(divisions) do
    if d.owner ~= cc.id then keep[#keep + 1] = d end
  end
  divisions = keep
  if player == cc.id then player = nil end
  cmap[cc.id] = nil
  pp[cc.id], dead[cc.id] = nil, nil
  settings.country = math.max(1, math.min(settings.country, #playable))
  saveCustom()
  return "Deleted " .. cc.name
end

local function createCountry()
  if not draft.cap then return "Pick a capital on the map first" end
  if #custom >= 8 then return "Limit: 8 custom countries" end
  if not cmap[initialOwner[draft.cap]].neutral then return "That province is taken" end
  local picked, queue, seen, qi = { draft.cap }, { draft.cap }, { [draft.cap] = true }, 1
  while qi <= #queue and #picked < draft.size do
    local a = queue[qi]
    qi = qi + 1
    for _, n in ipairs(provinces[a].nb) do
      if not seen[n] and cmap[initialOwner[n]].neutral and #picked < draft.size then
        seen[n] = true
        picked[#picked + 1] = n
        queue[#queue + 1] = n
      end
    end
  end
  local k = 1
  while cmap["C" .. k] do k = k + 1 end
  local names = {}
  for _, idx in ipairs(picked) do names[#names + 1] = provinces[idx].name end
  local cc = { id = "C" .. k, name = draft.name, color = draft.color, cap = provinces[draft.cap].name, provs = names }
  custom[#custom + 1] = cc
  addCustomCountry(cc)
  saveCustom()
  draft.cap = nil
  return cc.name .. " created! Start a NEW GAME to play"
end

local SYL_A = { "al", "bel", "cor", "dra", "el", "fen", "gal", "hor", "ist", "kar", "lor", "mar",
                "nor", "ost", "pra", "ran", "sol", "tor", "ul", "val", "wen", "yor", "zan" }
local SYL_B = { "a", "o", "i", "e", "u", "an", "en", "or", "is" }
local SYL_C = { "ia", "land", "mark", "ria", "stan", "onia", "ova", "burg", "grad", "ara" }
local function randomName()
  local n = SYL_A[math.random(#SYL_A)] .. (math.random() < 0.5 and SYL_B[math.random(#SYL_B)] or "")
    .. SYL_C[math.random(#SYL_C)]
  return (n:sub(1, 1):upper() .. n:sub(2)):sub(1, 12)
end

-- ввод имени с клавиатуры компьютера (монитор ввода текста не поддерживает)
local function askName()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("New country name (letters, digits, up to 12 characters).")
  print("Empty line keeps: " .. draft.name)
  write("> ")
  local text = read() or ""
  text = text:gsub("[^%w %-%.]", "")
  text = text:match("^%s*(.-)%s*$"):sub(1, 12)
  if text ~= "" then draft.name = text end
  term.clear()
  term.setCursorPos(1, 1)
  print("HOI-CC is running on the monitor.")
end

------------------------------------------------------------ интерфейс (карманный компьютер)
local screen = "menu"     -- menu | settings | create | game | pick | info | countries | log
local listOffset = 0
local drag = nil          -- { x, y, moved } для перетаскивания карты

local function put(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or colors.white)
  term.setBackgroundColor(bg or colors.black)
  term.write(text)
end

local function fill(x, y, w, h, bg)
  for r = 0, h - 1 do put(x, y + r, string.rep(" ", w), colors.white, bg) end
end

local function clearScreen()
  term.setBackgroundColor(colors.black)
  term.clear()
  buttons = {}
end

-- кнопка w x h клеток; fn вызывается при нажатии
local function btn(label, x, y, w, h, col, fn, fg)
  buttons[#buttons + 1] = { x1 = x, x2 = x + w - 1, y1 = y, y2 = y + h - 1, fn = fn }
  fill(x, y, w, h, col)
  label = label:sub(1, w)
  put(x + math.floor((w - #label) / 2), y + math.floor(h / 2), label, fg or colors.black, col)
end

local function hit(x, y)
  for _, bt in ipairs(buttons) do
    if x >= bt.x1 and x <= bt.x2 and y >= bt.y1 and y <= bt.y2 then
      mode = nil
      bt.fn()
      return true
    end
  end
  return false
end

local function setScreen(name)
  screen = name
  if name ~= "game" then paused = true; timerId = nil end
end

local function restartTimer()
  if not paused then timerId = os.startTimer(SPEEDS[speed]) end
end

local function changeZoom(dir)
  local vw, vh = viewSize()
  local cx, cy = vx + vw / 2, vy + vh / 2
  zi = math.max(1, math.min(#ZOOMS, zi + dir))
  vw, vh = viewSize()
  vx, vy = cx - vw / 2, cy - vh / 2
  clampView()
end

local function panBy(dx, dy)      -- в клетках экрана
  local z = ZOOMS[zi]
  vx, vy = vx + dx / z, vy + dy / z
  clampView()
end

------------------------------------------------------------ экран игры
local function drawTopBar(text)
  fill(1, 1, W, 1, colors.gray)
  local s = text or string.format("%02d.%02d.%04d %s x%d%s", date.d, date.m, date.y,
    paused and "||" or ">>", speed, player and "" or " OBS")
  put(1, 1, s:sub(1, W), colors.white, colors.gray)
end

local function drawInfoRow()
  local y = H - 2
  fill(1, y, W, 1, colors.black)
  local text, fg = msgText, colors.white
  if text == "" then
    if selected then
      local p = provinces[selected]
      local mine, foe = 0, 0
      for _, d in ipairs(divisions) do
        if d.prov == selected then
          if d.owner == player then mine = mine + 1 else foe = foe + 1 end
        end
      end
      text = string.format("%s %s %d/%d", p.name, cmap[p.owner].name:sub(1, 8), mine, foe)
    else
      text, fg = "Drag=pan  tap=select", colors.lightGray
    end
  end
  put(1, y, text:sub(1, W), fg)
end

local function drawBottom()
  local x = 1
  local y = H - 1
  fill(1, y, W, 1, colors.black)
  local function b(label, col, fn)
    btn(label, x, y, #label, 1, col, fn)
    x = x + #label
  end
  if player then
    b("[MOVE]", (mode and mode.all) and colors.white or colors.lightGray, function()
      if selected then mode = { all = true }; msgText = "Tap target province"
      else msgText = "Select a province" end
    end)
    b("[M1]", (mode and not mode.all) and colors.white or colors.lightGray, function()
      if selected then mode = { all = false }; msgText = "Tap target (1 div)"
      else msgText = "Select a province" end
    end)
    b("[RCT]", colors.lightGray, function() recruit() end)
    b("[WAR]", colors.lightGray, function() declareWar() end)
    b("[INFO]", colors.lightGray, function() setScreen("info") end)
  else
    b("[INFO]", colors.lightGray, function() setScreen("info") end)
    b("[CTRY]", colors.lightGray, function() listOffset = 0; setScreen("countries") end)
    b("[LOG]", colors.lightGray, function() setScreen("log") end)
  end

  x, y = 1, H
  fill(1, y, W, 1, colors.black)
  b(paused and "[>>]" or "[||]", colors.lightGray, function()
    paused = not paused
    timerId = nil
    restartTimer()
  end)
  b("[-]", colors.lightGray, function() speed = math.max(1, speed - 1); restartTimer() end)
  b("[+]", colors.lightGray, function() speed = math.min(#SPEEDS, speed + 1); restartTimer() end)
  b("[Z-]", colors.lightGray, function() changeZoom(-1) end)
  b("[Z+]", colors.lightGray, function() changeZoom(1) end)
  b("[MENU]", colors.lightGray, function() setScreen("menu") end)
end

local function drawGame()
  buttons = {}
  clampView()
  drawMap()
  drawTopBar()
  drawInfoRow()
  drawBottom()
end

------------------------------------------------------------ выбор столицы на карте
local function startPick()
  pickSave = { owners = {}, divisions = divisions, player = player, selected = selected }
  for i, p in ipairs(provinces) do
    pickSave.owners[i] = p.owner
    p.owner = initialOwner[i]
  end
  divisions = {}
  player, selected = nil, nil
  msgText = "Tap a free (beige) province"
  setScreen("pick")
end

local function endPick(chosen)
  for i, p in ipairs(provinces) do p.owner = pickSave.owners[i] end
  divisions, player, selected = pickSave.divisions, pickSave.player, pickSave.selected
  pickSave = nil
  msgText = ""
  if chosen then draft.cap = chosen end
  setScreen("create")
end

local function drawPick()
  buttons = {}
  clampView()
  drawMap()
  drawTopBar(" PICK A CAPITAL")
  drawInfoRow()
  fill(1, H - 1, W, 2, colors.black)
  btn("[CANCEL]", 1, H, 8, 1, colors.lightGray, function() endPick(nil) end)
  btn("[Z-]", 10, H, 4, 1, colors.lightGray, function() changeZoom(-1) end)
  btn("[Z+]", 14, H, 4, 1, colors.lightGray, function() changeZoom(1) end)
end

------------------------------------------------------------ экраны информации
local function drawInfoScreen()
  clearScreen()
  drawTopBar(" INFO")
  local y = 3
  if player then
    local pc = cmap[player]
    local inc, n = 0, 0
    for _, p in ipairs(provinces) do
      if p.owner == player then inc = inc + (0.5 + 0.5 * p.ind) * val("income") end
    end
    for _, d in ipairs(divisions) do
      if d.owner == player then n = n + 1 end
    end
    put(1, y, (" " .. pc.name .. string.rep(" ", W)):sub(1, W), pc.fg, pc.color); y = y + 1
    put(1, y, string.format("PP %d/%d  +%.1f/day", math.floor(pp[player]), val("cost"), inc)); y = y + 1
    put(1, y, "Divisions: " .. n); y = y + 2
  else
    put(1, y, "Observer mode", colors.lightBlue); y = y + 2
  end
  put(1, y, "PROVINCE", colors.lightBlue); y = y + 1
  if selected then
    local p = provinces[selected]
    local c = cmap[p.owner]
    put(1, y, ((p.cap and "* " or "") .. p.name .. string.rep(" ", W)):sub(1, W), c.fg, c.color); y = y + 1
    put(1, y, "Owner:  " .. c.name); y = y + 1
    put(1, y, "Pop:    " .. p.pop .. "M   Ind: " .. p.ind); y = y + 1
    local seaN = 0
    for _, l in ipairs(links[selected] or {}) do
      if l.sea then seaN = seaN + 1 end
    end
    put(1, y, "Borders: " .. #p.nb .. (seaN > 0 and (" +" .. seaN .. " sea") or "")); y = y + 1
    local mine, foe = 0, 0
    for _, d in ipairs(divisions) do
      if d.prov == selected then
        if d.owner == player then mine = mine + 1 else foe = foe + 1 end
      end
    end
    put(1, y, "Troops:  " .. mine .. " yours / " .. foe .. " other")
  else
    put(1, y, "(nothing selected)", colors.lightGray)
  end
  btn("[CTRY]", 1, H, 6, 1, colors.lightGray, function() listOffset = 0; setScreen("countries") end)
  btn("[LOG]", 8, H, 5, 1, colors.lightGray, function() setScreen("log") end)
  btn("[BACK]", 14, H, 6, 1, colors.white, function() setScreen("game") end)
end

local function drawCountries()
  clearScreen()
  drawTopBar(" COUNTRIES (tap = play as)")
  local counts = {}
  for _, p in ipairs(provinces) do counts[p.owner] = (counts[p.owner] or 0) + 1 end
  local rows = H - 4
  local maxOff = math.max(0, #countryIds - rows)
  listOffset = math.max(0, math.min(listOffset, maxOff))
  for r = 1, rows do
    local id = countryIds[listOffset + r]
    if not id then break end
    local c = cmap[id]
    local y = 2 + r
    local tag = (id == player) and "YOU" or ((player and atWar(player, id)) and "WAR" or "")
    put(1, y, "  ", colors.white, c.color)
    put(4, y, string.format("%-9s %3dp %s", c.name:sub(1, 9), counts[id] or 0, tag),
      id == player and colors.lightBlue or colors.white)
    if not c.neutral then
      buttons[#buttons + 1] = { x1 = 1, x2 = W, y1 = y, y2 = y, fn = function()
        player = id
        msgText = "Now playing " .. c.name
      end }
    end
  end
  btn("[^]", 1, H, 3, 1, colors.lightGray, function() listOffset = listOffset - 5 end)
  btn("[v]", 5, H, 3, 1, colors.lightGray, function() listOffset = listOffset + 5 end)
  btn("[BACK]", 14, H, 6, 1, colors.white, function() setScreen("game") end)
end

local function drawLogScreen()
  clearScreen()
  drawTopBar(" LOG")
  if #logLines == 0 then put(1, 3, "(nothing happened yet)", colors.lightGray) end
  for i, line in ipairs(logLines) do
    put(1, 2 + i, line:sub(1, W), colors.lightGray)
  end
  btn("[BACK]", 14, H, 6, 1, colors.white, function() setScreen("game") end)
end

------------------------------------------------------------ меню
local function chipRow(y, text, col, fg)
  fill(5, y, W - 8, 1, col)
  put(5 + math.floor((W - 8 - #text) / 2), y, text:sub(1, W - 8), fg, col)
end

local function drawMenuScreen()
  clearScreen()
  fill(1, 1, W, 3, colors.white)
  put(1 + math.floor((W - 11) / 2), 2, "H O I - C C", colors.black, colors.white)
  put(1, 4, "Pocket edition", colors.lightGray)

  put(1, 6, "MODE", colors.lightBlue)
  local half = math.floor((W - 1) / 2)
  btn("PLAY", 1, 7, half, 1, settings.observer and colors.lightGray or colors.white,
    function() settings.observer = false end)
  btn("WATCH", half + 2, 7, half, 1, settings.observer and colors.white or colors.lightGray,
    function() settings.observer = true end)

  local id = playable[settings.country]
  local c = cmap[id]
  local n = 0
  for i = 1, #provinces do
    if initialOwner[i] == id then n = n + 1 end
  end
  put(1, 9, settings.observer and "COUNTRY (not used)" or "COUNTRY", colors.lightBlue)
  btn("<", 1, 10, 3, 1, colors.lightGray, function()
    settings.country = (settings.country - 2) % #playable + 1
  end)
  chipRow(10, string.format("%s (%dp)", c.name, n), c.color, c.fg)
  btn(">", W - 2, 10, 3, 1, colors.lightGray, function()
    settings.country = settings.country % #playable + 1
  end)

  btn(gameStarted and "NEW GAME" or "START GAME", 1, 12, W, 3, colors.white, function()
    newGame()
    gameStarted = true
    setScreen("game")
  end)
  btn("SETTINGS", 1, 16, half, 1, colors.lightGray, function() setScreen("settings") end)
  btn("CREATE", half + 2, 16, half, 1, colors.lightGray, function()
    createMsg = ""
    setScreen("create")
  end)
  if gameStarted then
    btn("RESUME", 1, 18, W, 1, colors.lightGray, function() setScreen("game") end)
  end
  btn("QUIT", 1, 19, W, 1, colors.lightGray, function() quit = true end)
  put(1, 20, "Enter=start  Q=quit", colors.lightGray)
end

local SHORT = { aggr = "AI wars", expand = "AI expand", start = "Start divs", income = "Income",
                cost = "Div cost", march = "Days/step", events = "Events", auto = "AutoRecruit",
                speed = "Start speed" }

local function drawSettings()
  clearScreen()
  fill(1, 1, W, 1, colors.white)
  put(1, 1, " SETTINGS", colors.black, colors.white)
  for i, o in ipairs(OPTS) do
    local y = 2 + i
    put(1, y, (SHORT[o.key] or o.label):sub(1, 11), colors.white)
    local text = o.vals[settings[o.key]]:sub(1, 10)
    put(12, y, "<", colors.black, colors.lightGray)
    put(13, y, string.rep(" ", 10), colors.white, colors.gray)
    put(13 + math.floor((10 - #text) / 2), y, text, colors.white, colors.gray)
    put(23, y, ">", colors.black, colors.lightGray)
    buttons[#buttons + 1] = { x1 = 11, x2 = 13, y1 = y, y2 = y, fn = function()
      settings[o.key] = (settings[o.key] - 2) % #o.vals + 1
    end }
    buttons[#buttons + 1] = { x1 = 14, x2 = W, y1 = y, y2 = y, fn = function()
      settings[o.key] = settings[o.key] % #o.vals + 1
    end }
  end
  put(1, 13, "Tap < or > to change.", colors.lightGray)
  put(1, 14, "Applies to NEW GAME.", colors.lightGray)
  btn("BACK", 1, H, W, 1, colors.white, function() setScreen("menu") end)
end

local function drawCreate()
  clearScreen()
  fill(1, 1, W, 1, colors.white)
  put(1, 1, " CREATE COUNTRY", colors.black, colors.white)
  local ch = colorChoices[draft.color]
  fill(1, 3, W, 1, ch.color)
  put(1 + math.floor((W - #draft.name) / 2), 3, draft.name, ch.fg, ch.color)
  local half = math.floor((W - 1) / 2)
  btn("RANDOM", 1, 4, half, 1, colors.lightGray, function() draft.name = randomName() end)
  btn("TYPE", half + 2, 4, half, 1, colors.lightGray, function() askName() end)

  put(1, 6, "COLOR", colors.lightBlue)
  btn("<", 1, 7, 3, 1, colors.lightGray, function()
    draft.color = (draft.color - 2) % #colorChoices + 1
  end)
  chipRow(7, string.format("color %d/%d", draft.color, #colorChoices), ch.color, ch.fg)
  btn(">", W - 2, 7, 3, 1, colors.lightGray, function()
    draft.color = draft.color % #colorChoices + 1
  end)

  put(1, 9, "SIZE (provinces)", colors.lightBlue)
  btn("<", 1, 10, 3, 1, colors.lightGray, function() draft.size = math.max(1, draft.size - 1) end)
  chipRow(10, tostring(draft.size), colors.gray, colors.white)
  btn(">", W - 2, 10, 3, 1, colors.lightGray, function() draft.size = math.min(6, draft.size + 1) end)

  put(1, 12, "CAPITAL", colors.lightBlue)
  btn(draft.cap and provinces[draft.cap].name or "PICK ON MAP", 1, 13, W, 1, colors.lightGray,
    function() startPick() end)

  btn("CREATE", 1, 15, W, 3, colors.white, function() createMsg = createCountry() end)
  put(1, 18, createMsg:sub(1, W), colors.white)
  btn("DEL LAST", 1, H, half, 1, colors.lightGray, function() createMsg = removeLastCustom() end)
  btn("BACK", half + 2, H, half, 1, colors.lightGray, function() setScreen("menu") end)
end

local function redrawScreen()
  if screen == "game" then drawGame()
  elseif screen == "pick" then drawPick()
  elseif screen == "menu" then drawMenuScreen()
  elseif screen == "settings" then drawSettings()
  elseif screen == "create" then drawCreate()
  elseif screen == "info" then drawInfoScreen()
  elseif screen == "countries" then drawCountries()
  elseif screen == "log" then drawLogScreen()
  end
end

------------------------------------------------------------ ввод
local function onMapTap(x, y)
  local p = pAt(x, y - 1)
  if screen == "pick" then
    if p ~= 0 and cmap[provinces[p].owner].neutral then
      endPick(p)
    else
      msgText = "Pick a free (beige) province"
    end
    return
  end
  if mode and selected then
    local m = mode
    mode = nil
    if p ~= 0 and p ~= selected then issueMove(selected, p, m.all) else msgText = "Cancelled" end
  else
    selected = (p ~= 0) and p or nil
    msgText = ""
  end
end

local function inMapArea(x, y) return x >= 1 and x <= mapW and y >= 2 and y <= mapH + 1 end

local function onKey(k)
  if screen == "menu" then
    if k == keys.q then quit = true
    elseif k == keys.enter then
      newGame()
      gameStarted = true
      setScreen("game")
    end
  elseif screen == "game" or screen == "pick" then
    local st = 4
    if k == keys.left then panBy(-st, 0)
    elseif k == keys.right then panBy(st, 0)
    elseif k == keys.up then panBy(0, -st)
    elseif k == keys.down then panBy(0, st)
    elseif k == keys.equals then changeZoom(1)
    elseif k == keys.minus then changeZoom(-1)
    elseif screen == "game" then
      if k == keys.space then paused = not paused; timerId = nil; restartTimer()
      elseif k == keys.leftBracket then speed = math.max(1, speed - 1); restartTimer()
      elseif k == keys.rightBracket then speed = math.min(#SPEEDS, speed + 1); restartTimer()
      elseif k == keys.r then recruit()
      elseif k == keys.i then setScreen("info")
      elseif k == keys.m or k == keys.q then setScreen("menu")
      elseif k == keys.c and selected then
        local vw, vh = viewSize()
        vx, vy = provinces[selected].cx - vw / 2, provinces[selected].cy - vh / 2
        clampView()
      end
    end
  else
    if k == keys.backspace or k == keys.q then
      if screen == "settings" or screen == "create" then setScreen("menu") else setScreen("game") end
    elseif screen == "countries" then
      if k == keys.up then listOffset = listOffset - 1 elseif k == keys.down then listOffset = listOffset + 1 end
    end
  end
end

------------------------------------------------------------ старт
local function run()
  layout()
  loadWorld()
  buildLinks()
  loadCustom()
  redrawScreen()

  while not quit do
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then
      if a == 1 then
        if (screen == "game" or screen == "pick") and inMapArea(b, c) then
          drag = { x = b, y = c, moved = false }
        elseif hit(b, c) then
          if not quit then redrawScreen() end
        end
      end
    elseif ev == "mouse_drag" then
      if drag then
        local dx, dy = b - drag.x, c - drag.y
        if dx ~= 0 or dy ~= 0 then
          drag.moved = true
          panBy(-dx, -dy)
          drag.x, drag.y = b, c
          drawMap()
        end
      end
    elseif ev == "mouse_up" then
      if drag then
        if not drag.moved then onMapTap(drag.x, drag.y) end
        drag = nil
        redrawScreen()
      end
    elseif ev == "mouse_scroll" then
      if screen == "game" or screen == "pick" then
        changeZoom(a < 0 and 1 or -1)
        redrawScreen()
      elseif screen == "countries" then
        listOffset = listOffset + a
        redrawScreen()
      end
    elseif ev == "key" then
      onKey(a)
      if not quit then redrawScreen() end
    elseif ev == "timer" and a == timerId and screen == "game" then
      advanceDay()
      if dirty then drawMap() end
      drawTopBar()
      drawInfoRow()
      restartTimer()
    elseif ev == "term_resize" then
      layout()
      redrawScreen()
    end
  end
end

local ok, err = pcall(run)
restorePalette()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
