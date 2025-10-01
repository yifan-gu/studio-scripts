local scrollTimer = nil
local scrollSpeed = 1
local scrollInterval = 0.1  -- tighter interval = smoother

-- Scroll Up
hs.hotkey.bind({"ctrl", "alt"}, "W", function()
  if scrollTimer then scrollTimer:stop() end
  scrollTimer = hs.timer.doUntil(
    function() return false end,
    function()
      hs.eventtap.scrollWheel({0, scrollSpeed}, {}, "pixel")
    end,
    scrollInterval
  )
end)

-- Scroll Down
hs.hotkey.bind({"ctrl", "alt"}, "S", function()
  if scrollTimer then scrollTimer:stop() end
  scrollTimer = hs.timer.doUntil(
    function() return false end,
    function()
      hs.eventtap.scrollWheel({0, -scrollSpeed}, {}, "pixel")
    end,
    scrollInterval
  )
end)

-- Stop
hs.hotkey.bind({"ctrl", "alt"}, "D", function()
  if scrollTimer then scrollTimer:stop() end
end)
