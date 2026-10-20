-- Run the generated Hyprland Lua fragments against a recording stub of `hl`.
-- Usage: nvim -l tests/lua/run_fragments.lua FRAGMENT.lua...
-- Each file must parse; every hl call and autostart entry is printed as one
-- line (`env NAME=VALUE`, `monitor {...}`, `config {...}`, `autostart ID=CMD`)
-- so a shell test can assert exactly what the fragments ask Hyprland to do.
-- nvim -l sends print() to stderr; the recording goes to stdout.
local function emit(line)
	io.stdout:write(line, "\n")
end

local function dump(value)
	return vim.inspect(value, { newline = " ", indent = "" })
end

hl = {
	env = function(name, value) emit(("env %s=%s"):format(name, value)) end,
	monitor = function(spec) emit("monitor " .. dump(spec)) end,
	config = function(options) emit("config " .. dump(options)) end,
}
vivac = { autostart = {} }

for _, path in ipairs(_G.arg) do
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

for _, entry in ipairs(vivac.autostart) do
	emit(("autostart %s=%s"):format(entry.id, entry.cmd))
end
