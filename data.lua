-- data.lua: страны и провинции
-- ВАЖНО: шрифт ComputerCraft не умеет кириллицу, поэтому все названия латиницей.
-- fx, fy: положение центра провинции на карте в долях (0..1).

local C = {
  GER = { name = "Germany", color = colors.gray },
  FRA = { name = "France",  color = colors.blue },
  GBR = { name = "Britain", color = colors.red },
  SOV = { name = "USSR",    color = colors.brown },
  ITA = { name = "Italy",   color = colors.green },
  POL = { name = "Poland",  color = colors.orange },
}

local P = {
  { name = "Scotland",     fx = 0.22, fy = 0.12, owner = "GBR" },
  { name = "London",       fx = 0.25, fy = 0.30, owner = "GBR" },

  { name = "Paris",        fx = 0.32, fy = 0.48, owner = "FRA" },
  { name = "Bordeaux",     fx = 0.27, fy = 0.67, owner = "FRA" },
  { name = "Marseille",    fx = 0.40, fy = 0.70, owner = "FRA" },

  { name = "Rhineland",    fx = 0.42, fy = 0.38, owner = "GER" },
  { name = "Berlin",       fx = 0.53, fy = 0.32, owner = "GER" },
  { name = "Bavaria",      fx = 0.52, fy = 0.50, owner = "GER" },
  { name = "Koenigsberg",  fx = 0.64, fy = 0.22, owner = "GER" },

  { name = "Milan",        fx = 0.47, fy = 0.64, owner = "ITA" },
  { name = "Rome",         fx = 0.53, fy = 0.80, owner = "ITA" },

  { name = "Warsaw",       fx = 0.65, fy = 0.40, owner = "POL" },

  { name = "Minsk",        fx = 0.74, fy = 0.30, owner = "SOV" },
  { name = "Moscow",       fx = 0.88, fy = 0.22, owner = "SOV" },
  { name = "Kiev",         fx = 0.76, fy = 0.55, owner = "SOV" },
  { name = "Stalingrad",   fx = 0.90, fy = 0.50, owner = "SOV" },
}

return { countries = C, provinces = P }
