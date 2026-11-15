-- main.lua v4: HOI-подобная стратегия для CC:Tweaked (дивизии, приказы, война)
-- Карта берётся из map.lua (генерируется gen_map.py). Рядом должен лежать map.lua.
-- Управление только нажатиями на монитор. Выход: клавиша Q на компьютере.

local dir = fs.getDir(shell.getRunningProgram())
local map = dofile(fs.combine(dir, "map.lua"))
local provinces = map.provinces

------------------------------------------------------------ монитор
local mon = peripheral.find("monitor")
if not mon then error("Монитор не найден", 0) end
if not mon.isColor() then error("Нужен Advanced Monitor", 0) end
local monName = peripheral.getName(mon)
mon.setTextScale(0.5)

-- своя палитра для красивой карты
for name, hex in pairs(map.palette) do
  mon.setPaletteColour(colors[name], hex)
end
local function restorePalette()
  for name in pairs(map.palette) do
    local r, g, b = term.nativePaletteColour(colors[name])
    mon.setPaletteColour(colors[name], r, g, b)
  end
end

local cmap = {}   -- id страны -> { name, color, fg }
local countryIds = {}
for _, c in ipairs(map.countries) do
  cmap[c.id] = { name = c.name, color = colors[c.color], fg = colors[c.fg] }
  countryIds[#countryIds + 1] = c.id
end
local SEA_DEEP, SEA_SHALLOW = colors[map.seaDeep], colors[map.seaShallow]

local PANEL_W = 30
local W, H, mapW, mapH

------------------------------------------------------------ мир
local WW, WH = map.w, map.h
local world = {}            -- world[y][x]: >0 провинция, 0 глубокое море, -1 мелководье
local ZOOMS = { 0.5, 1, 2, 3 }
local zi = 1
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
  W, H = mon.getSize()
  mapW = W - PANEL_W
  mapH = H - 1
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
local MOVE_DAYS = 3
local player = countryIds[1]
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
    for _ = 1, (p.cap and 3 or 1) do
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

-- приказ игрока: идти из from в to. Возвращает true, если карта изменилась.
local function issueMove(from, to, all)
  if not isNeighbor(from, to) then msgText = "Not adjacent"; return false end
  local t = provinces[to].owner
  if t ~= player and not atWar(player, t) then
    msgText = "Declare war first"
    return false
  end
  local moved = 0
  for _, d in ipairs(divisions) do
    if d.owner == player and d.prov == from and not d.to and (all or moved < 1) then
      d.to, d.left = to, MOVE_DAYS
      moved = moved + 1
    end
  end
  msgText = moved > 0 and (moved .. " div -> " .. provinces[to].name) or "No ready divisions"
  return moved > 0
end

local function declareWar()
  if not selected then msgText = "Select a province"; return end
  local t = provinces[selected].owner
  if t == player then msgText = "That is your land"; return end
  if atWar(player, t) then msgText = "Already at war"; return end
  wars[warKey(player, t)] = true
  addLog(cmap[player].name .. " vs " .. cmap[t].name)
  msgText = "War declared on " .. cmap[t].name
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

  -- подписи: при мелком масштабе только столицы
  for i, p in ipairs(provinces) do
    if z >= 1 or p.cap then
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
    if z >= 1 or p.cap then cy = cy + 1 end
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

------------------------------------------------------------ интерфейс
local function put(x, y, text, fg, bg)
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
  local s = string.format(" HOI-CC  |  %02d.%02d.%04d  |  %s  |  speed %d/%d  |  zoom x%s",
    date.d, date.m, date.y, paused and "PAUSED" or "RUNNING", speed, #SPEEDS,
    tostring(ZOOMS[zi]))
  mon.setCursorPos(1, 1)
  mon.write(s:sub(1, W))
end

-- кнопка w x h клеток; fn возвращает true, если надо перерисовать карту
local function btn(label, x, y, w, h, col, fn)
  buttons[#buttons + 1] = { x1 = x, x2 = x + w - 1, y1 = y, y2 = y + h - 1, fn = fn }
  for r = 0, h - 1 do put(x, y + r, string.rep(" ", w), colors.black, col) end
  put(x + math.floor((w - #label) / 2), y + math.floor(h / 2), label, colors.black, col)
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
  local x0 = mapW + 1
  buttons = {}
  local bx = x0 + 1
  for y = 2, H do put(x0, y, string.rep(" ", PANEL_W)) end

  local pc = cmap[player]
  put(x0 + 1, 2, (" You: " .. pc.name .. string.rep(" ", 22)):sub(1, 24), pc.fg, pc.color)

  -- выбранная провинция
  local y = 3
  put(x0 + 1, y, "PROVINCE", colors.yellow); y = y + 1
  if selected then
    local p = provinces[selected]
    local c = cmap[p.owner]
    put(x0 + 1, y, (p.cap and "* " or "") .. p.name .. " ", c.fg, c.color); y = y + 1
    put(x0 + 1, y, "Owner:    " .. c.name, colors.white); y = y + 1
    put(x0 + 1, y, "Pop:      " .. p.pop .. "M", colors.white); y = y + 1
    put(x0 + 1, y, "Industry: " .. p.ind, colors.white); y = y + 1
    put(x0 + 1, y, "Borders:  " .. #p.nb .. (p.coast and "  coast" or ""), colors.white); y = y + 1
    local mine, foe = 0, 0
    for _, d in ipairs(divisions) do
      if d.prov == selected then
        if d.owner == player then mine = mine + 1 else foe = foe + 1 end
      end
    end
    put(x0 + 1, y, "Troops:   " .. mine .. " yours / " .. foe .. " other", colors.white)
  else
    put(x0 + 1, y, "(tap a province)", colors.lightGray)
  end

  -- страны (нажми на строку, чтобы играть за неё)
  y = 11
  put(x0 + 1, y, "COUNTRIES (tap = play)", colors.yellow); y = y + 1
  local counts = {}
  for _, p in ipairs(provinces) do counts[p.owner] = (counts[p.owner] or 0) + 1 end
  for _, id in ipairs(countryIds) do
    local c = cmap[id]
    local tag = (id == player) and "YOU" or (atWar(player, id) and "WAR" or "")
    put(x0 + 1, y, "  ", colors.white, c.color)
    put(x0 + 4, y, string.format("%-9s %2d prov %s", c.name, counts[id] or 0, tag),
      id == player and colors.yellow or colors.white)
    buttons[#buttons + 1] = { x1 = x0 + 1, x2 = x0 + PANEL_W - 1, y1 = y, y2 = y, fn = function()
      player = id
      msgText = "Now playing " .. c.name
      return true
    end }
    y = y + 1
  end

  -- приказы
  local oy = 21
  local function moveBtn(label, x, w, all)
    btn(label, x, oy, w, 3, (mode and mode.all == all) and colors.yellow or colors.lime, function()
      if selected then
        mode = { all = all }
        msgText = "Tap a neighbor province"
      else
        msgText = "Select a province first"
      end
      return false
    end)
  end
  moveBtn("MOVE ALL", bx, 10, true)
  moveBtn("MOVE 1", bx + 11, 9, false)
  btn("WAR", bx + 21, oy, 6, 3, colors.red, function() declareWar(); return true end)

  put(x0 + 1, 25, msgText:sub(1, PANEL_W - 2), colors.yellow)

  put(x0 + 1, 27, "LOG", colors.lightGray)
  for i, line in ipairs(logLines) do
    if 27 + i < H - 19 then put(x0 + 1, 27 + i, line:sub(1, PANEL_W - 2), colors.lightGray) end
  end

  -- время
  local ty = H - 18
  btn(paused and "PLAY" or "PAUSE", bx, ty, 9, 3, paused and colors.lime or colors.orange, function()
    paused = not paused
    timerId = nil
    restartTimer()
    return false
  end)
  btn("-", bx + 10, ty, 5, 3, colors.lightGray, function()
    speed = math.max(1, speed - 1); restartTimer(); return false
  end)
  btn("+", bx + 16, ty, 5, 3, colors.lightGray, function()
    speed = math.min(#SPEEDS, speed + 1); restartTimer(); return false
  end)

  -- крестовина прокрутки
  local function pan(dx, dy)
    return function()
      local sx, sy = panStep()
      vx, vy = vx + dx * sx, vy + dy * sy
      clampView()
      return true
    end
  end
  local py = H - 14
  btn("^", bx + 8,  py,     7, 3, colors.cyan, pan(0, -1))
  btn("<", bx,      py + 4, 7, 3, colors.cyan, pan(-1, 0))
  btn("o", bx + 8,  py + 4, 7, 3, colors.yellow, function()
    local vw, vh = viewSize()
    if selected then
      vx = provinces[selected].cx - vw / 2
      vy = provinces[selected].cy - vh / 2
    else
      vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
    end
    clampView()
    return true
  end)
  btn(">", bx + 16, py + 4, 7, 3, colors.cyan, pan(1, 0))
  btn("v", bx + 8,  py + 8, 7, 3, colors.cyan, pan(0, 1))

  -- масштаб
  local zy = H - 2
  btn("-", bx, zy, 7, 3, colors.lightGray, function() return changeZoom(-1) end)
  put(bx + 8, zy + 1, string.format("x%-5s", tostring(ZOOMS[zi])), colors.white)
  btn("+", bx + 16, zy, 7, 3, colors.lightGray, function() return changeZoom(1) end)
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
  if x <= mapW and y >= 2 then
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
    drawPanel()
    return
  end
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      mode = nil
      if b.fn() then drawMap() end
      drawTopBar()
      drawPanel()
      return
    end
  end
end

------------------------------------------------------------ старт
local function run()
  layout()
  loadWorld()
  spawnDivisions()
  local vw, vh = viewSize()
  vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
  redrawAll()

  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "monitor_touch" and a == monName then
      onTouch(b, c)
    elseif ev == "timer" and a == timerId then
      advanceDay()
      if dirty then drawMap() end
      drawTopBar()
      drawPanel()
      restartTimer()
    elseif ev == "monitor_resize" and a == monName then
      layout()
      redrawAll()
    elseif ev == "key" and a == keys.q then
      return
    end
  end
end

local ok, err = pcall(run)
restorePalette()
mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1, 1)
if not ok then error(err, 0) end
