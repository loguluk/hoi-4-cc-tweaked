-- main_v2.lua: портативная версия для Pocket Computer в CC:Tweaked
-- Карта берётся из map.lua (генерируется gen_map.py). Рядом должен лежать map.lua.
-- Управление: касание экрана и клавиши компьютера.

local dir = fs.getDir(shell.getRunningProgram())
local map = dofile(fs.combine(dir, "map.lua"))
local provinces = map.provinces

------------------------------------------------------------ экран Pocket Computer
local mon = term.current()
mon.setCursorBlink(false)

local cmap = {}   -- id страны -> { name, color, fg }
local countryIds = {}
for _, c in ipairs(map.countries) do
  cmap[c.id] = { name = c.name, color = colors[c.color], fg = colors[c.fg], neutral = c.neutral }
  countryIds[#countryIds + 1] = c.id
end
local SEA_DEEP, SEA_SHALLOW = colors[map.seaDeep], colors[map.seaShallow]

local W, H, mapW, mapH

------------------------------------------------------------ мир
local WW, WH = map.w, map.h
local world = {}            -- packed byte rows: stored id is the world id plus one
local ZOOMS = { 0.25, 0.5, 1, 2, 3, 4 }
local zi = 2
local vx, vy = 0, 0         -- левый верхний угол вида в клетках мира

local function loadWorld()
  for y = 1, WH do
    local chunks = {}
    for id, n in map.rows[y]:gmatch("(-?%d+):(%d+)") do
      id, n = tonumber(id), tonumber(n)
      chunks[#chunks + 1] = string.rep(string.char(id + 1), n)
    end
    world[y] = table.concat(chunks)
  end
end

local function layout()
  W, H = mon.getSize()
  mapW = W
  mapH = math.max(1, H - 2)
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
  local value = string.byte(world[wy], wx)
  return value and value - 1 or 0
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

------------------------------------------------------------ игровая логика (без отрисовки)
local MOVE_DAYS = 3
local playable = {}                  -- страны, за которые можно играть (без нейтральной)
for _, id in ipairs(countryIds) do
  if not cmap[id].neutral then playable[#playable + 1] = id end
end
local settings = { country = 1, observer = false, speed = 2, aggr = 3 }
local WAR_CHANCE = { 0, 0.05, 0.15, 0.4 }
local AGGR_NAMES = { "Off", "Low", "Normal", "High" }
local initialOwner = {}
for i, p in ipairs(provinces) do initialOwner[i] = p.owner end
local player = playable[1]               -- nil = режим наблюдателя
local inMenu, gameStarted, quit = true, false, false
local enterMenu                          -- определена ниже
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

local function spawnDivisions()
  for i, p in ipairs(provinces) do
    for _ = 1, (cmap[p.owner].neutral and 0 or (p.cap and 3 or 1)) do
      divisions[#divisions + 1] = { id = nextDiv, owner = p.owner, prov = i, str = 100 }
      nextDiv = nextDiv + 1
    end
  end
end

local function isNeighbor(a, b)
  for _, n in ipairs(provinces[a].nb) do
    if n == b then return true end
  end
  return false
end

-- приказ любой страны: идти из from в to. Возвращает число отправленных дивизий (или 0, причина)
local function moveDivisions(who, from, to, all)
  if not isNeighbor(from, to) then return 0, "Not adjacent" end
  local t = provinces[to].owner
  if t ~= who and not cmap[t].neutral and not atWar(who, t) then
    return 0, "Declare war first"
  end
  local moved = 0
  for _, d in ipairs(divisions) do
    if d.owner == who and d.prov == from and not d.to and (all or moved < 1) then
      d.to, d.left = to, MOVE_DAYS
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
local DIV_COST, DIV_CAP = 100, 40       -- цена дивизии в очках производства, лимит дивизий
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
    for _, n in ipairs(provinces[from].nb) do
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

  -- 2) колонизация: занимаем нейтральные земли по соседству
  for from, list in pairs(idle) do
    if orders >= 3 then break end
    if #list >= 2 or not provinces[from].cap then
      for _, n in ipairs(provinces[from].nb) do
        if cmap[provinces[n].owner].neutral and not targeted[n] then
          if moveDivisions(id, from, n, false) > 0 then
            targeted[n] = true
            orders = orders + 1
            dirty = true
          end
          break
        end
      end
    end
  end

  -- 3) объявление войны более слабому соседу
  if not inWar(id) and dayCount - lastWar[id] > 60
      and WAR_CHANCE[settings.aggr] > 0 and math.random() < WAR_CHANCE[settings.aggr] then
    local cnt = {}
    for _, d in ipairs(divisions) do cnt[d.owner] = (cnt[d.owner] or 0) + 1 end
    local cand, candCnt
    for _, p in ipairs(provinces) do
      if p.owner == id then
        for _, n in ipairs(p.nb) do
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

local function economyAndAI()
  dayCount = dayCount + 1
  local income, nprov, cnt = {}, {}, {}
  for _, p in ipairs(provinces) do
    income[p.owner] = (income[p.owner] or 0) + 0.5 + 0.5 * p.ind
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
        if pp[id] >= DIV_COST and (cnt[id] or 0) < DIV_CAP then
          local at = capitalOf(id)
          if at then
            pp[id] = pp[id] - DIV_COST
            divisions[#divisions + 1] = { id = nextDiv, owner = id, prov = at, str = 100 }
            nextDiv = nextDiv + 1
            dirty = true
          end
        end
      end
    end
  end

  -- ИИ: две страны за день по кругу (кроме страны игрока)
  for _ = 1, 2 do
    aiIdx = aiIdx % #countryIds + 1
    local id = countryIds[aiIdx]
    if id ~= player and not cmap[id].neutral and not dead[id] then aiTick(id) end
  end
end

local function newGame()
  for i, p in ipairs(provinces) do p.owner = initialOwner[i] end
  divisions, nextDiv = {}, 1
  wars, battles = {}, {}
  dirty, mode, msgText, logLines = false, nil, "", {}
  for _, id in ipairs(countryIds) do pp[id] = 0; lastWar[id] = -999; dead[id] = nil end
  dayCount, aiIdx = 0, 0
  date.y, date.m, date.d = 1936, 1, 1
  selected = nil
  speed = settings.speed
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
  dirty = false
end

------------------------------------------------------------ интерфейс
local function put(x, y, text, fg, bg)
  if y < 1 or y > H or x > W then return end
  text = tostring(text)
  if x < 1 then
    text = text:sub(2 - x)
    x = 1
  end
  text = text:sub(1, W - x + 1)
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
  mon.write(text)
end

local function drawTopBar()
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, 1)
  mon.write(string.rep(" ", W))
  local tag = player or "OBS"
  local s = string.format("%s %02d.%02d.%04d %s %d/%d x%s",
    tag, date.d, date.m, date.y, paused and "PAUSE" or "RUN",
    speed, #SPEEDS, tostring(ZOOMS[zi]))
  mon.setCursorPos(1, 1)
  mon.write(s:sub(1, W))
end

local function panStep()
  local vw, vh = viewSize()
  return math.max(3, math.floor(vw / 4)), math.max(3, math.floor(vh / 4))
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
  return true
end

local function drawPanel()
  local line = msgText
  if line == "" and selected then
    local p = provinces[selected]
    line = p.name .. " " .. p.owner .. (p.cap and " *" or "")
  elseif line == "" then
    line = "Arrows pan  M/A move  Space pause"
  end
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, H)
  mon.write(string.rep(" ", W))
  mon.setCursorPos(1, H)
  mon.write(line:sub(1, W))
end

local function redrawAll()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  clampView()
  drawMap()
  drawTopBar()
  drawPanel()
end

------------------------------------------------------------ ввод
local function onTouch(x, y)
  if x >= 1 and x <= mapW and y >= 2 and y <= H - 1 then
    local p = pAt(x, y - 1)
    if mode and selected then
      local m = mode
      mode = nil
      if p ~= 0 and p ~= selected then
        issueMove(selected, p, m.all)
      else
        msgText = "Cancelled"
      end
    else
      selected = (p ~= 0) and p or nil
      msgText = ""
    end
    drawMap()
    drawTopBar()
    drawPanel()
  end
end

------------------------------------------------------------ меню
local menuRow = 1
local MENU_COUNT = 7

local function drawMenu()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  put(1, 1, "HOI-CC POCKET", colors.black, colors.lightBlue)
  put(1, 2, "Up/Down select  Left/Right change", colors.lightGray)

  local id = playable[settings.country]
  local c = cmap[id]
  local n = 0
  for i = 1, #provinces do
    if initialOwner[i] == id then n = n + 1 end
  end
  local labels = {
    settings.observer and "Mode: Observer" or "Mode: Play",
    string.format("Country: %s (%d)", c.name, n),
    string.format("Speed: %d/%d", settings.speed, #SPEEDS),
    "AI wars: " .. AGGR_NAMES[settings.aggr],
    gameStarted and "Start new game" or "Start game",
    gameStarted and "Resume game" or "Resume (not started)",
    "Quit",
  }
  for i, label in ipairs(labels) do
    local y = i + 3
    local bg = i == menuRow and colors.blue or colors.black
    put(1, y, string.rep(" ", W), colors.white, bg)
    put(1, y, (i == menuRow and "> " or "  ") .. label, colors.white, bg)
  end
  put(1, H, "Enter choose  Q quit", colors.lightGray, colors.black)
end

enterMenu = function()
  inMenu = true
  paused = true
  timerId = nil
  drawMenu()
end

local function menuAction(row, delta)
  if row == 1 then
    settings.observer = not settings.observer
  elseif row == 2 then
    settings.country = (settings.country - 1 + delta) % #playable + 1
  elseif row == 3 then
    settings.speed = math.max(1, math.min(#SPEEDS, settings.speed + delta))
  elseif row == 4 then
    settings.aggr = math.max(1, math.min(#AGGR_NAMES, settings.aggr + delta))
  elseif row == 5 and delta == 0 then
    newGame()
    gameStarted = true
    inMenu = false
    redrawAll()
  elseif row == 6 and gameStarted and delta == 0 then
    inMenu = false
    redrawAll()
  elseif row == 7 and delta == 0 then
    quit = true
  end
  if inMenu and not quit then drawMenu() end
end

local function onMenuKey(code)
  if code == keys.up then
    menuRow = (menuRow - 2) % MENU_COUNT + 1
    drawMenu()
  elseif code == keys.down then
    menuRow = menuRow % MENU_COUNT + 1
    drawMenu()
  elseif code == keys.left then
    menuAction(menuRow, -1)
  elseif code == keys.right then
    menuAction(menuRow, 1)
  elseif code == keys.enter or code == keys.space then
    if menuRow <= 4 then
      menuAction(menuRow, menuRow == 2 and 1 or 0)
    else
      menuAction(menuRow, 0)
    end
  elseif code == keys.q then
    quit = true
  end
end

local function onMenuTouch(x, y)
  local row = y - 3
  if x >= 1 and x <= W and row >= 1 and row <= MENU_COUNT then
    menuRow = row
    menuAction(row, (row == 2 or row == 3 or row == 4) and 1 or 0)
  end
end

local function pan(dx, dy)
  local sx, sy = panStep()
  vx, vy = vx + dx * sx, vy + dy * sy
  clampView()
end

local function centerView()
  local vw, vh = viewSize()
  if selected then
    vx = provinces[selected].cx - vw / 2
    vy = provinces[selected].cy - vh / 2
  else
    vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
  end
  clampView()
end

local function onGameKey(code)
  local mapChanged = false
  if code == keys.q then
    quit = true
    return
  elseif code == keys.escape then
    enterMenu()
    return
  elseif code == keys.space then
    paused = not paused
    timerId = nil
    restartTimer()
  elseif code == keys.minus then
    speed = math.max(1, speed - 1)
    timerId = nil
    restartTimer()
  elseif code == keys.equals then
    speed = math.min(#SPEEDS, speed + 1)
    timerId = nil
    restartTimer()
  elseif code == keys.left then
    pan(-1, 0); mapChanged = true
  elseif code == keys.right then
    pan(1, 0); mapChanged = true
  elseif code == keys.up then
    pan(0, -1); mapChanged = true
  elseif code == keys.down then
    pan(0, 1); mapChanged = true
  elseif code == keys.pageUp then
    mapChanged = changeZoom(1)
  elseif code == keys.pageDown then
    mapChanged = changeZoom(-1)
  elseif code == keys.r then
    centerView(); mapChanged = true
  elseif code == keys.backspace then
    mode = nil
    msgText = "Order cancelled"
  elseif code == keys.m or code == keys.a then
    if selected then
      mode = { all = code == keys.a }
      msgText = "Tap destination"
    else
      msgText = "Select a province first"
    end
  elseif code == keys.w then
    declareWar()
  elseif code == keys.c then
    local index = 0
    for i, id in ipairs(playable) do
      if id == player then index = i; break end
    end
    index = index % #playable + 1
    player = playable[index]
    msgText = "Playing " .. player
  end
  if mapChanged then drawMap() end
  drawTopBar()
  drawPanel()
end

------------------------------------------------------------ старт
local function run()
  layout()
  loadWorld()
  drawMenu()

  while not quit do
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then
      if inMenu then onMenuTouch(b, c) else onTouch(b, c) end
    elseif ev == "timer" and a == timerId and not inMenu then
      advanceDay()
      if dirty then drawMap() end
      drawTopBar()
      drawPanel()
      restartTimer()
    elseif ev == "term_resize" then
      layout()
      if inMenu then drawMenu() else redrawAll() end
    elseif ev == "key" then
      if inMenu then onMenuKey(a) else onGameKey(a) end
    end
  end
end

local ok, err = pcall(run)
mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1, 1)
if not ok then error(err, 0) end
