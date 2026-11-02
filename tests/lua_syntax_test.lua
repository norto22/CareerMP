-- #10: every Lua file of the server plugin and the client mod compiles, so a syntax error
-- in any of them fails the Tests check instead of being found when a server or game loads
-- it. The other tests only compile the files they happen to load.

test("#10: every Lua file under Resources compiles", function()
	local listing = io.popen('find Resources -name "*.lua"')
	expect(listing, "could not list the Lua files")
	local checked, broken = 0, {}
	for path in listing:lines() do
		checked = checked + 1
		local chunk, err = loadfile(path)
		if not chunk then table.insert(broken, tostring(err)) end
	end
	listing:close()
	expect(checked >= 30, "only " .. checked .. " Lua files found under Resources")
	expect(#broken == 0, "files that do not compile:\n     " .. table.concat(broken, "\n     "))
end)
