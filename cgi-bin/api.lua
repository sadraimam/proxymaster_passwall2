#!/usr/bin/lua
local uci = require("luci.model.uci").cursor()
local json = require("luci.jsonc")

-- Simple router for the API
local query = os.getenv("QUERY_STRING") or ""
local params = {}
for k, v in query:gmatch("([^&]+)=([^&]*)") do
    params[k] = v
end

local action = params["action"]

print("Content-Type: application/json\n")

if action == "status" then
    local enabled = uci:get("passwall", "main", "enabled") or "0"
    local running = os.execute("pgrep -f passwall > /dev/null") == 0
    print(json.stringify({ enabled = enabled, running = running }))

elseif action == "toggle" then
    local current = uci:get("passwall", "main", "enabled")
    local new_val = (current == "1") and "0" or "1"
    uci:set("passwall", "main", "enabled", new_val)
    uci:commit("passwall")
    -- Use a non-blocking restart if possible
    os.execute("/etc/init.d/passwall restart &")
    print(json.stringify({ success = true, enabled = new_val }))

elseif action == "update_sub" then
    local link = params["link"]
    if link then
        -- In Passwall2, subscribe_list is usually an anonymous section
        uci:foreach("passwall", "subscribe_list", function(s)
            uci:set("passwall", s[".name"], "url", link)
        end)
        uci:commit("passwall")
        print(json.stringify({ success = true }))
    else
        print(json.stringify({ error = "missing link" }))
    end
else
    print(json.stringify({ error = "invalid action" }))
end
