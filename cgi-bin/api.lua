#!/usr/bin/lua
local uci = require("luci.model.uci").cursor()
local json = require("luci.jsonc")

-- Helper to decode URL parameters
local function url_decode(str)
    str = str:gsub("+", " ")
    str = str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return str
end

-- Simple router for the API
local query = os.getenv("QUERY_STRING") or ""
local params = {}
for k, v in query:gmatch("([^&]+)=([^&]*)") do
    params[k] = url_decode(v)
end

local action = params["action"]
local DASHBOARD_URL = "https://pmaster.pro"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local COOKIE_FILE = "/tmp/pm_cookies.txt"

-- Helper to escape shell arguments
local function shell_escape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Helper to read POST body
local function get_post_data()
    local content_length = tonumber(os.getenv("CONTENT_LENGTH")) or 0
    if content_length > 0 then
        return io.read(content_length)
    end
    return ""
end

-- Function to handle the main logic, wrapped in pcall
local function main_logic()
    -- Log the action to the OpenWrt system log (viewable via logread)
    os.execute(string.format("logger -t ProxyMaster 'API request: action=%s'", tostring(action)))

    print("Content-Type: application/json\n")

    if action == "status" then
        local enabled = uci:get("passwall2", "@global[0]", "enabled") or "0"
        local token = uci:get("passwall2", "ProxyMaster", "token")
        local config_exists = (token ~= nil and token ~= "")
        
        -- Check for common cores used by Passwall2 to determine if it is actually running
        local running = os.execute("pgrep -f 'sing-box|xray|v2ray|base_tcp' > /dev/null") == 0
        print(json.stringify({ enabled = enabled, running = running, config_exists = config_exists, token = token }))

    elseif action == "toggle" then
        local current = uci:get("passwall2", "@global[0]", "enabled")
        local new_val = (current == "1") and "0" or "1"
        uci:set("passwall2", "@global[0]", "enabled", new_val)
        uci:commit("passwall2")
        -- Use a non-blocking restart if possible
        os.execute("/etc/init.d/passwall2 restart &")
        print(json.stringify({ success = true, enabled = new_val }))

    elseif action == "proxy_login" then
        local post_data = get_post_data()
        -- Log the received POST data for debugging
        os.execute(string.format("logger -t ProxyMaster 'proxy_login received POST data: %s'", shell_escape(post_data)))

        -- Added -c to save cookies and -H Accept to force JSON
        local curl_cmd_template = "curl -s -L -k -c %s -X POST '%s/api/v1/passport/auth/login' -H 'Content-Type: application/json' -H 'Accept: application/json' -A %s --data-binary @-"
        local full_curl_cmd = string.format(curl_cmd_template, COOKIE_FILE, DASHBOARD_URL, shell_escape(USER_AGENT))
        local cmd_to_execute = "echo " .. shell_escape(post_data) .. " | " .. full_curl_cmd

        os.execute(string.format("logger -t ProxyMaster 'Executing proxy_login curl command: %s'", shell_escape(cmd_to_execute)))

        local pipe, err, code = io.popen(cmd_to_execute, "r")

        if not pipe then
            os.execute(string.format("logger -t ProxyMaster 'ERROR: Failed to open pipe for proxy_login. Error: %s, Code: %s'", tostring(err), tostring(code)))
            print(json.stringify({ error = "Failed to execute proxy login command on router.", details = tostring(err) }))
        else
            local result = pipe:read("*a")
            pipe:close()
            os.execute(string.format("logger -t ProxyMaster 'proxy_login curl response: %s'", shell_escape(result)))
            
            -- Attempt to parse result as JSON, if it fails, return a generic error
            local success, parsed_result = pcall(json.parse, result)
            if success and type(parsed_result) == "table" then
                print(result) -- Print the original result if it's valid JSON
            else
                os.execute(string.format("logger -t ProxyMaster 'WARNING: proxy_login curl returned non-JSON or empty response: %s'", shell_escape(result)))
                print(json.stringify({ error = "Dashboard login response was not valid JSON or empty.", raw_response = result }))
            end
        end

    elseif action == "proxy_info" then
        local token = params["token"]
        -- Log the received token for debugging
        os.execute(string.format("logger -t ProxyMaster 'proxy_info using token: %s'", shell_escape(token)))

        -- Dashboard info call. Using Authorization header is usually enough for V2board/Xboard
        local curl_cmd_template = "curl -s -L -k -H 'Authorization: %s' -H 'Accept: application/json' -A %s '%s/api/v1/user/info'"
        local full_curl_cmd = string.format(curl_cmd_template, token, shell_escape(USER_AGENT), DASHBOARD_URL)

        os.execute(string.format("logger -t ProxyMaster 'Executing proxy_info curl command: %s'", shell_escape(full_curl_cmd)))

        local pipe, err, code = io.popen(full_curl_cmd, "r")

        if not pipe then
            os.execute(string.format("logger -t ProxyMaster 'ERROR: Failed to open pipe for proxy_info. Error: %s, Code: %s'", tostring(err), tostring(code)))
            print(json.stringify({ error = "Failed to execute proxy info command on router.", details = tostring(err) }))
        else
            local result = pipe:read("*a")
            pipe:close()
            os.execute(string.format("logger -t ProxyMaster 'proxy_info curl response: %s'", shell_escape(result)))
            
            -- Attempt to parse result as JSON, if it fails, return a generic error
            local success, parsed_result = pcall(json.parse, result)
            if success and type(parsed_result) == "table" then
                print(result) -- Print the original result if it's valid JSON
            else
                os.execute(string.format("logger -t ProxyMaster 'WARNING: proxy_info curl returned non-JSON or empty response: %s'", shell_escape(result)))
                print(json.stringify({ error = "Dashboard user info response was not valid JSON or empty.", raw_response = result }))
            end
        end

    elseif action == "update_sub" then
        local link = params["link"]
        local token = params["token"]
        if link then
            -- Create or update the specific 'ProxyMaster' section
            uci:set("passwall2", "ProxyMaster", "subscribe_list")
            uci:set("passwall2", "ProxyMaster", "remark", "ProxyMaster")
            uci:set("passwall2", "ProxyMaster", "url", link)
            if token then
                uci:set("passwall2", "ProxyMaster", "token", token)
            end
            
            os.execute("logger -t ProxyMaster 'Updating ProxyMaster subscription URL'")

            -- Check if commit was successful
            local commit_status = uci:commit("passwall2")
            if commit_status then
                os.execute("logger -t ProxyMaster 'Passwall UCI commit successful.'")
                print(json.stringify({ success = true }))
            else
                os.execute("logger -t ProxyMaster 'ERROR: Passwall UCI commit failed.'")
                print(json.stringify({ success = false, error = "UCI commit failed." }))
            end
        else
            os.execute("logger -t ProxyMaster 'ERROR: update_sub missing link parameter.'")
            print(json.stringify({ error = "missing link" }))
        end

    elseif action == "update_nodes" then
        os.execute("logger -t ProxyMaster 'Triggering Passwall2 subscription update...'")
        -- Execute subscription update. Some versions use subscribe.lua, others require app.lua -u
        -- We will try the most common trigger for version 2
        os.execute("lua /usr/share/passwall2/subscribe.lua ProxyMaster > /dev/null 2>&1 &")
        print(json.stringify({ success = true }))

    elseif action == "logout" then
        uci:delete("passwall2", "ProxyMaster")
        uci:commit("passwall2")
        print(json.stringify({ success = true }))

    else
        os.execute(string.format("logger -t ProxyMaster 'ERROR: Invalid action requested: %s'", tostring(action)))
        print(json.stringify({ error = "invalid action" }))
    end
end

-- Wrap the main logic in a pcall to catch any unhandled Lua errors
local ok, err = pcall(main_logic)
if not ok then
    -- If an error occurred, print a JSON error response
    print("Content-Type: application/json\n")
    os.execute(string.format("logger -t ProxyMaster 'CRITICAL LUA ERROR: %s'", tostring(err)))
    print(json.stringify({ error = "Internal Lua script error", details = tostring(err) }))
end
