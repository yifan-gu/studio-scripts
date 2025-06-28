local scrollTimer = nil
local scrollSpeed = 1  -- change this to control speed

-- Scroll Up
hs.hotkey.bind({"ctrl", "alt"}, "W", function()
  if scrollTimer then scrollTimer:stop() end
  scrollTimer = hs.timer.doUntil(
    function() return false end,
    function()
      hs.eventtap.scrollWheel({0, scrollSpeed}, {}, "pixel")
    end,
    0.01
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
    0.01
  )
end)

-- Stop
hs.hotkey.bind({"ctrl", "alt"}, "D", function()
  if scrollTimer then scrollTimer:stop() end
end)
