-- Load a rendered hyprland.lua against a recording stub of `hl`, the way
-- Hyprland would, and print what the config asked for.
-- Usage: nvim -l tests/lua/hl_stub.lua HYPRLAND.lua
--
-- The module search path and the local.lua lookup come from the environment
-- (XDG_CONFIG_HOME, HOME), exactly as in a session. Every line on stdout is one
-- fact a shell test can grep:
--   bind KEYS => DISPATCHER      unbind KEYS      config {...}      env N=V
--   monitor {...}  rule NAME     on EVENT         log TEXT          notify TEXT
--   start exec CMD               (a command run by the hyprland.start event)
--   final N                      (binds still standing after the whole load)
-- HL_STUB_RELOADS=N loads the file N times in one Lua state, which is what a
-- reload does if the Lua state persists.
local function emit(line)
	io.stdout:write(line, "\n")
end

local function dump(value)
	return vim.inspect(value, { newline = " ", indent = "" })
end

local binds = {}
local handlers = {}

-- A dispatcher is the call that built it, as text: hl.dsp.window.close() reads
-- back as `window.close()`, with its argument table dumped.
local function dispatcher(path)
	return setmetatable({}, {
		__index = function(_, name)
			return dispatcher(path == "" and name or path .. "." .. name)
		end,
		__call = function(_, ...)
			local rendered = {}
			for _, argument in ipairs({ ... }) do
				rendered[#rendered + 1] = type(argument) == "table" and dump(argument) or tostring(argument)
			end
			return { text = path .. "(" .. table.concat(rendered, ", ") .. ")" }
		end,
	})
end

local function recorder(name)
	return function(spec)
		emit(name .. " " .. dump(spec))
	end
end

hl = {
	dsp = dispatcher(""),
	env = function(name, value) emit(("env %s=%s"):format(name, value)) end,
	monitor = recorder("monitor"),
	config = recorder("config"),
	curve = recorder("curve"),
	animation = recorder("animation"),
	gesture = recorder("gesture"),
	device = recorder("device"),
	window_rule = function(spec)
		emit("rule " .. tostring(spec.name))
		return {}
	end,
	bind = function(keys, action)
		binds[#binds + 1] = { keys = keys, action = action }
		emit(("bind %s => %s"):format(keys, action.text))
		return {}
	end,
	unbind = function(keys)
		emit("unbind " .. keys)
		for index = #binds, 1, -1 do
			if binds[index].keys == keys then table.remove(binds, index) end
		end
	end,
	on = function(event, callback)
		emit("on " .. event)
		handlers[event] = handlers[event] or {}
		table.insert(handlers[event], callback)
		return {}
	end,
	exec_cmd = function(command)
		emit("start exec " .. command)
	end,
	notification = {
		create = function(options)
			emit("notify " .. tostring(options and options.text))
			return {}
		end,
	},
}

print = function(...)
	local parts = {}
	for _, part in ipairs({ ... }) do parts[#parts + 1] = tostring(part) end
	emit("log " .. table.concat(parts, " "))
end

local path = _G.arg[1]
for _ = 1, tonumber(os.getenv("HL_STUB_RELOADS") or "1") do
	binds = {}
	local chunk, err = loadfile(path)
	if not chunk then
		io.stderr:write("parse error: " .. err .. "\n")
		os.exit(1)
	end
	local ok, run_err = pcall(chunk)
	if not ok then
		io.stderr:write("run error: " .. tostring(run_err) .. "\n")
		os.exit(1)
	end
end

emit("final " .. #binds)
for _, callback in ipairs(handlers["hyprland.start"] or {}) do
	callback()
end
