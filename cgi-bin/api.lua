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

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function trigger_subscription_update(section_id)
    section_id = section_id or "ProxyMaster"

    local commands = {}
    if file_exists("/usr/share/passwall2/api.lua") then
        commands[#commands + 1] = {
            name = "api.lua subscribe_manual",
            cmd = string.format("lua /usr/share/passwall2/api.lua subscribe_manual %s", shell_escape(section_id))
        }
    end
    if file_exists("/usr/share/passwall2/node_subscribe.lua") then
        commands[#commands + 1] = {
            name = "node_subscribe.lua",
            cmd = string.format("lua /usr/share/passwall2/node_subscribe.lua %s", shell_escape(section_id))
        }
    end
    if file_exists("/usr/share/passwall2/subscribe.lua") then
        commands[#commands + 1] = {
            name = "subscribe.lua start",
            cmd = string.format("lua /usr/share/passwall2/subscribe.lua start %s", shell_escape(section_id))
        }
    end

    if #commands == 0 then
        return false, "Passwall2 subscription script not found."
    end

    local parts = {}
    for _, command in ipairs(commands) do
        parts[#parts + 1] = string.format(
            "( logger -t ProxyMaster 'Trying %s'; %s )",
            command.name,
            command.cmd
        )
    end

    local shell_cmd = "cd /usr/share/passwall2 && export HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin; " ..
        table.concat(parts, " || ")
    local background_cmd = string.format("sh -c %s >/tmp/proxymaster-subscribe.log 2>&1 &", shell_escape(shell_cmd))

    os.execute("logger -t ProxyMaster 'Triggering Passwall2 subscription update'")
    os.execute(background_cmd)

    return true, nil, "/tmp/proxymaster-subscribe.log"
end

local function get_or_create_section(section_type)
    local section_name = nil
    uci:foreach("passwall2", section_type, function(section)
        if not section_name then
            section_name = section[".name"]
        end
    end)

    if not section_name then
        section_name = uci:section("passwall2", section_type)
    end

    return section_name
end

local function enable_subscription_defaults(section_id)
    -- Keep both global and section-level knobs for compatibility across Passwall2 builds.
    local global_subscribe = get_or_create_section("global_subscribe")
    if global_subscribe then
        uci:set("passwall2", global_subscribe, "auto_update", "1")
        -- Passwall2 uses week_update=8 for loop mode and interval_update for hours.
        uci:set("passwall2", global_subscribe, "week_update", "8")
        uci:set("passwall2", global_subscribe, "interval_update", "24")
        uci:set("passwall2", global_subscribe, "auto_update_time", "24")
        uci:set("passwall2", global_subscribe, "auto_update_interval", "24")
        uci:set("passwall2", global_subscribe, "interval", "24")
        uci:set("passwall2", global_subscribe, "allowInsecure", "1")
        uci:set("passwall2", global_subscribe, "allow_insecure", "1")
    end

    uci:set("passwall2", section_id, "allowInsecure", "1")
    uci:set("passwall2", section_id, "allow_insecure", "1")
    uci:set("passwall2", section_id, "tls_allowInsecure", "1")
    uci:set("passwall2", section_id, "auto_update", "1")
    uci:set("passwall2", section_id, "boot_update", "0")
    uci:set("passwall2", section_id, "week_update", "8")
    uci:set("passwall2", section_id, "interval_update", "24")
    uci:set("passwall2", section_id, "auto_update_time", "24")
    uci:set("passwall2", section_id, "auto_update_interval", "24")
    uci:set("passwall2", section_id, "interval", "24")
end

local function delete_subscription_nodes(add_from)
    local nodes_to_delete = {}

    uci:foreach("passwall2", "nodes", function(node)
        if node.add_from == add_from or node.group == add_from then
            nodes_to_delete[#nodes_to_delete + 1] = node[".name"]
        end
    end)

    for _, node_id in ipairs(nodes_to_delete) do
        uci:delete("passwall2", node_id)
    end

    return #nodes_to_delete
end

local function get_proxy_nodes(group_name)
    local nodes = {}

    uci:foreach("passwall2", "nodes", function(node)
        if node.group == group_name or node.add_from == group_name then
            nodes[#nodes + 1] = {
                id = node[".name"],
                remarks = node.remarks or node[".name"],
                protocol = node.protocol or "",
                type = node.type or ""
            }
        end
    end)

    return nodes
end

local function get_shunt_node_id()
    local global_node = uci:get("passwall2", "@global[0]", "node")
    if global_node and uci:get("passwall2", global_node, "protocol") == "_shunt" then
        return global_node
    end

    local shunt_node = nil
    uci:foreach("passwall2", "nodes", function(node)
        if not shunt_node and node.protocol == "_shunt" then
            shunt_node = node[".name"]
        end
    end)

    return shunt_node
end

local function proxy_node_exists(node_id, group_name)
    local exists = false
    uci:foreach("passwall2", "nodes", function(node)
        if node[".name"] == node_id and (node.group == group_name or node.add_from == group_name) then
            exists = true
        end
    end)
    return exists
end

local function truncate_subscription_nodes(add_from)
    if file_exists("/usr/share/passwall2/subscribe.lua") then
        local cmd = string.format(
            "cd /usr/share/passwall2 && export HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin; lua /usr/share/passwall2/subscribe.lua truncate %s",
            shell_escape(add_from)
        )
        os.execute(string.format("sh -c %s >/tmp/proxymaster-logout.log 2>&1", shell_escape(cmd)))
        uci = require("luci.model.uci").cursor()
        return true, "/tmp/proxymaster-logout.log"
    end

    return false, nil
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

    elseif action == "connect_check" then
        local target_url = params["url"]
        if not target_url or target_url == "" then
            print(json.stringify({ error = "no url provided" }))
            return
        end

        -- Use curl to measure time_total. -o /dev/null ignores body, -s is silent, -k allows insecure
        local curl_format = '{"use_time": %{time_total}, "http_code": %{http_code}}'
        local cmd = string.format("curl -L -k -s -o /dev/null -w %s --max-time 5 %s", 
            shell_escape(curl_format), 
            shell_escape(target_url)
        )

        local pipe = io.popen(cmd)
        if pipe then
            local result = pipe:read("*a")
            pipe:close()
            local success, parsed = pcall(json.parse, result)
            if success and parsed then
                -- time_total is in seconds, convert to ms
                parsed.use_time = math.floor(parsed.use_time * 1000)
                print(json.stringify(parsed))
            else
                print(json.stringify({ error = "check failed" }))
            end
        end

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
        os.execute("logger -t ProxyMaster 'Attempting proxy login'")

        -- Added -c to save cookies and -H Accept to force JSON
        local curl_cmd_template = "curl -s -L -k -c %s -X POST '%s/api/v1/passport/auth/login' -H 'Content-Type: application/json' -H 'Accept: application/json' -A %s --data-binary @-"
        local full_curl_cmd = string.format(curl_cmd_template, COOKIE_FILE, DASHBOARD_URL, shell_escape(USER_AGENT))
        local cmd_to_execute = "echo " .. shell_escape(post_data) .. " | " .. full_curl_cmd


        local pipe, err, code = io.popen(cmd_to_execute, "r")

        if not pipe then
            os.execute(string.format("logger -t ProxyMaster 'ERROR: Failed to open pipe for proxy_login. Error: %s, Code: %s'", tostring(err), tostring(code)))
            print(json.stringify({ error = "Failed to execute proxy login command on router.", details = tostring(err) }))
        else
            local result = pipe:read("*a")
            pipe:close()
            
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
        os.execute("logger -t ProxyMaster 'Fetching proxy user info'")

        -- Dashboard info call. Using Authorization header is usually enough for V2board/Xboard
        local curl_cmd_template = "curl -s -L -k -H 'Authorization: %s' -H 'Accept: application/json' -A %s '%s/api/v1/user/info'"
        local full_curl_cmd = string.format(curl_cmd_template, shell_escape(token or ""), shell_escape(USER_AGENT), DASHBOARD_URL)

        local pipe, err, code = io.popen(full_curl_cmd, "r")

        if not pipe then
            os.execute(string.format("logger -t ProxyMaster 'ERROR: Failed to open pipe for proxy_info. Error: %s, Code: %s'", tostring(err), tostring(code)))
            print(json.stringify({ error = "Failed to execute proxy info command on router.", details = tostring(err) }))
        else
            local result = pipe:read("*a")
            pipe:close()
            
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
            -- Delete existing to ensure we start with a clean 'subscribe_list' type section
            uci:delete("passwall2", "ProxyMaster")
            
            -- Create named section of type 'subscribe_list'
            uci:section("passwall2", "subscribe_list", "ProxyMaster")
            
            uci:set("passwall2", "ProxyMaster", "remark", "ProxyMaster")
            uci:set("passwall2", "ProxyMaster", "url", link)
            -- Passwall2 26.x compatibility: set user_agent and template to ensure parsing
            uci:set("passwall2", "ProxyMaster", "user_agent", "v2ray")
            uci:set("passwall2", "ProxyMaster", "template", "v2ray")
            -- Passwall2 requires the section to be enabled to process it during updates
            uci:set("passwall2", "ProxyMaster", "enabled", "1")
            enable_subscription_defaults("ProxyMaster")
            if token then
                uci:set("passwall2", "ProxyMaster", "token", token)
            end
            
            os.execute("logger -t ProxyMaster 'Updating ProxyMaster subscription URL'")

            -- Check if commit was successful
            local commit_status = uci:commit("passwall2")
            if commit_status then
                os.execute("logger -t ProxyMaster 'Passwall UCI commit successful.'")
                local triggered, trigger_error, log_file = trigger_subscription_update("ProxyMaster")
                print(json.stringify({
                    success = true,
                    update_triggered = triggered,
                    update_error = trigger_error,
                    log_file = log_file
                }))
            else
                os.execute("logger -t ProxyMaster 'ERROR: Passwall UCI commit failed.'")
                print(json.stringify({ success = false, error = "UCI commit failed." }))
            end
        else
            os.execute("logger -t ProxyMaster 'ERROR: update_sub missing link parameter.'")
            print(json.stringify({ error = "missing link" }))
        end

    elseif action == "update_nodes" then
        local link = uci:get("passwall2", "ProxyMaster", "url")
        if not link or link == "" then
            os.execute("logger -t ProxyMaster 'ERROR: Subscription URL missing in UCI.'")
            print(json.stringify({ success = false, error = "Subscription URL not found in config." }))
            return
        end

        local triggered, trigger_error, log_file = trigger_subscription_update("ProxyMaster")
        if triggered then
            print(json.stringify({ success = true, log_file = log_file }))
        else
            os.execute("logger -t ProxyMaster 'ERROR: No valid Passwall2 subscription script found.'")
            print(json.stringify({ success = false, error = trigger_error }))
        end

    elseif action == "list_nodes" then
        local shunt_node = get_shunt_node_id()
        local current_node = nil
        if shunt_node then
            current_node = uci:get("passwall2", shunt_node, "default_node")
        end

        print(json.stringify({
            success = true,
            nodes = get_proxy_nodes("ProxyMaster"),
            shunt_node = shunt_node,
            current_node = current_node
        }))

    elseif action == "set_shunt_node" then
        local node_id = params["node"]
        if not node_id or node_id == "" then
            print(json.stringify({ success = false, error = "missing node" }))
            return
        end

        if not proxy_node_exists(node_id, "ProxyMaster") then
            print(json.stringify({ success = false, error = "selected node is not a ProxyMaster node" }))
            return
        end

        local shunt_node = get_shunt_node_id()
        if not shunt_node then
            print(json.stringify({ success = false, error = "shunt node not found" }))
            return
        end

        uci:set("passwall2", shunt_node, "default_node", node_id)
        local commit_status = uci:commit("passwall2")
        if commit_status then
            os.execute("/etc/init.d/passwall2 restart &")
        end
        print(json.stringify({
            success = commit_status and true or false,
            shunt_node = shunt_node,
            selected_node = node_id
        }))

    elseif action == "logout" then
        local truncated, log_file = truncate_subscription_nodes("ProxyMaster")
        local deleted_nodes = delete_subscription_nodes("ProxyMaster")
        uci:delete("passwall2", "ProxyMaster")
        uci:set("passwall2", "@global[0]", "enabled", "0")
        local commit_status = uci:commit("passwall2")
        if commit_status then
            os.execute("/etc/init.d/passwall2 stop &")
        end
        print(json.stringify({
            success = commit_status and true or false,
            deleted_nodes = deleted_nodes,
            truncated = truncated,
            log_file = log_file
        }))

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
