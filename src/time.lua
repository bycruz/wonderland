-- The clock the library keeps time with, and the one an app should keep time with.
--
--   local time = require("wonderland").time
--   local started = time.now()
--
--   self:every(1 / 60, function() --[[ a frame's worth of work ]] end)
--
-- What `now` answers is seconds since some fixed point that does not move: it is a monotonic
-- clock, so the difference between two of them is how long passed between them, whatever the
-- machine's wall clock did in between. That is what a caret blinking, a key repeating, a frame
-- being paced, and a frame of video being due for the display are all measured against, and it is
-- why `os.time` and `os.date` are not what this is: an app that reads the wall clock to pace
-- itself is an app that jumps when the machine's clock is set, and one that reads `os.clock`
-- measures the work the process did rather than the time that went by -- so a window that sat
-- idle for a second says a frame just went out.
--
-- The call behind it is the platform's own: the monotonic clock on the unixes, and the
-- performance counter on Windows, which is the only one there with better than fifteen
-- milliseconds of resolution -- and a video player pacing frames to a display is the app that
-- notices. A machine where neither is there falls back to the wall clock, which is wrong twice a
-- year and right the rest of it.
local ffi = require("ffi")

ffi.cdef [[
	// Named apart from the C library's own struct so that a module that declares `timespec` for
	// something else cannot collide with this one: it is the same bytes either way.
	typedef int wl_clockid_t;
	struct wl_timespec { long tv_sec; long tv_nsec; };
	int clock_gettime(wl_clockid_t id, struct wl_timespec *time);

	struct wl_timeval { long tv_sec; long tv_usec; };
	int gettimeofday(struct wl_timeval *time, void *zone);

	unsigned long long GetTickCount64(void);
	int QueryPerformanceCounter(long long *count);
	int QueryPerformanceFrequency(long long *frequency);
]]

--- A time as the C library writes it, which the language server cannot see: spelled out so the
--- fields can be read.
---@class wonderland.time.Timespec: ffi.cdata*
---@field tv_sec number
---@field tv_nsec number

---@class wonderland.time.Timeval: ffi.cdata*
---@field tv_sec number
---@field tv_usec number

-- Which clock is the monotonic one is the platform's answer, not a name every unix agrees on:
-- Linux numbers it one and Darwin numbers it six, and a call to the wrong one is a number that
-- means something else rather than an error.
local CLOCK_IDS = {
	Linux = 1,
	OSX = 6,
	FreeBSD = 4,
	NetBSD = 3,
	OpenBSD = 3,
}

---@class wonderland.time.Time
---@field now fun(): number # Seconds since a fixed point that does not move
local time = {}

---@param id number
---@return fun(): number?
local function clockGettime(id)
	local stamp = ffi.new("struct wl_timespec")
	---@cast stamp wonderland.time.Timespec

	-- Asked once, because a C library without the symbol raises on the first call rather than
	-- answering nothing, and the answer is the same every time after it.
	local ok, answered = pcall(function() return ffi.C.clock_gettime(id, stamp) == 0 end)

	if not ok or not answered then
		return nil
	end

	return function()
		if ffi.C.clock_gettime(id, stamp) == 0 then
			return tonumber(stamp.tv_sec) + tonumber(stamp.tv_nsec) / 1e9
		end
	end
end

---@return fun(): number?
local function performanceCounter()
	local kernel32 = ffi.load("kernel32")
	local count, frequency = ffi.new("long long[1]"), ffi.new("long long[1]")

	if kernel32.QueryPerformanceFrequency(frequency) == 0 or frequency[0] == 0 then
		return nil
	end

	local perSecond = tonumber(frequency[0])

	return function()
		if kernel32.QueryPerformanceCounter(count) ~= 0 then
			return tonumber(count[0]) / perSecond
		end
	end
end

---@return fun(): number?
local function wallClock()
	if ffi.os == "Windows" then
		local kernel32 = ffi.load("kernel32")

		return function()
			return tonumber(kernel32.GetTickCount64()) / 1000
		end
	end

	local stamp = ffi.new("struct wl_timeval")
	---@cast stamp wonderland.time.Timeval

	return function()
		ffi.C.gettimeofday(stamp, nil)

		return tonumber(stamp.tv_sec) + tonumber(stamp.tv_usec) / 1e6
	end
end

local primary = ffi.os == "Windows" and performanceCounter() or clockGettime(CLOCK_IDS[ffi.os] or 0)
local fallback = wallClock()

--- Seconds on a clock that only goes forwards, for telling one moment from another.
---@return number
function time.now()
	if primary ~= nil then
		local at = primary()

		if at ~= nil then
			return at
		end
	end

	return fallback()
end

return time
