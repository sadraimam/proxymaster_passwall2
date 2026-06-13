# Repository Notes for Agents

## Project Purpose

This repo is a small OpenWrt companion UI for ProxyMaster and Passwall2. It deploys a static web interface plus a Lua CGI backend to an OpenWrt router so a user can:

- Log in to the ProxyMaster dashboard at `https://pmaster.pro`.
- Save the returned subscription token/link into Passwall2 UCI config.
- Check Passwall2 status.
- Toggle Passwall2 on/off.
- Trigger a node/subscription update.
- Log out by deleting the stored ProxyMaster UCI section, removing ProxyMaster-imported nodes, and disabling Passwall2.

## File Map

- `cgi-bin/api.lua`
  - Main backend CGI script.
  - Deployed as `/www/cgi-bin/proxymaster-api`.
  - Uses `luci.model.uci` and `luci.jsonc`.
  - Talks to ProxyMaster with shell-executed `curl`.

- `www/index.html`
  - Single-page UI shell.
  - Loads Axios from `https://unpkg.com/axios/dist/axios.min.js`.
  - Loads local `style.css` and `app.js`.

- `www/app.js`
  - Browser-side logic.
  - Calls `/cgi-bin/proxymaster-api?action=...`.
  - Handles login, status, usage fetch, toggle, update nodes, and logout.
  - `SYSTEM_MODE` is currently `"V2BOARD"`.
  - Dashboard domain is currently `https://pmaster.pro`.

- `www/style.css`
  - Simple centered card styling for the current UI.

- `install.sh`
  - Deploy helper for copying files to an OpenWrt router over SSH/SCP.
  - Default router IP is `192.168.11.1`.

## API Actions

The Lua backend routes based on the `action` query parameter:

- `status`
  - Reads `passwall2.@global[0].enabled`.
  - Reads `passwall2.ProxyMaster.token`.
  - Checks if proxy-related processes are running with `pgrep -f 'sing-box|xray|v2ray|base_tcp'`.
  - Returns `enabled`, `running`, `config_exists`, and `token`.

- `connect_check`
  - Accepts `url` as a query parameter.
  - Measures connection latency to the target using `curl` and returns `use_time` in milliseconds.

- `toggle`
  - Flips `passwall2.@global[0].enabled`.
  - Commits UCI changes.
  - Runs `/etc/init.d/passwall2 restart &`.

- `proxy_login`
  - Reads the JSON POST body from the browser.
  - Forwards it to `https://pmaster.pro/api/v1/passport/auth/login`.
  - Saves session cookies to `/tmp/pm_cookies.txt`.
  - Returns the dashboard response if it parses as JSON.

- `proxy_info`
  - Accepts `token` as a query parameter.
  - Calls `https://pmaster.pro/api/v1/user/getSubscribe` with an `Authorization` header.
  - Loads session cookies from `/tmp/pm_cookies.txt`.
  - Returns the dashboard response if it parses as JSON.

- `update_sub`
  - Accepts `link` and optional `token` query parameters.
  - Creates/updates the `passwall2.ProxyMaster` UCI section as `subscribe_list`.
  - Stores `remark`, `url`, and `token`.
  - Enables subscription processing and TLS-insecure compatibility fields.
  - Sets Passwall2 auto-update loop mode for every 24 hours with:
    - `week_update='8'`
    - `interval_update='24'`
  - Also writes compatibility interval fields (`auto_update_time`, `auto_update_interval`, `interval`) as `24`.
  - Triggers a subscription import after saving.

- `update_nodes`
  - Reuses backend subscription trigger detection.
  - Known trigger forms:
    - `/usr/share/passwall2/api.lua subscribe_manual ProxyMaster`
    - `/usr/share/passwall2/node_subscribe.lua ProxyMaster`
    - `/usr/share/passwall2/subscribe.lua start ProxyMaster`
  - `subscribe.lua` requires `start` as the first argument; `lua subscribe.lua ProxyMaster` does not enter the update path on observed builds.

- `list_nodes`
  - Returns proxy nodes parsed from the `ProxyMaster` group.
  - Returns the currently selected `default_node` from the active shunt node.

- `set_shunt_node`
  - Accepts `node` as a query parameter.
  - Updates the `default_node` of the shunt node in Passwall2's UCI config to the selected node.
  - Commits the config and restarts Passwall2.

- `logout`
  - Runs `lua /usr/share/passwall2/subscribe.lua truncate ProxyMaster` when available.
  - Deletes remaining `nodes` sections where `group='ProxyMaster'` or `add_from='ProxyMaster'`.
  - Deletes the `passwall2.ProxyMaster` subscription section.
  - Sets `passwall2.@global[0].enabled='0'`, commits, and stops Passwall2.

## Frontend Flow

1. On page load, `updateStatus()` checks whether a ProxyMaster config/token already exists.
2. Login posts `{ email, password }` to `proxy_login`.
3. The frontend extracts a token from `res.data.data.token` or `res.data.data.auth_data`.
4. It builds a subscription link:

   ```text
   https://pmaster.pro/api/v1/client/subscribe?token=<token>
   ```

5. It sends that link and token to `update_sub`.
6. The backend saves the subscription and starts the Passwall2 subscription import.
7. If config exists, the UI shows the dashboard and fetches usage via `proxy_info`.
8. The UI retrieves the node list (`list_nodes`) and allows the user to perform connectivity checks (`connect_check`) or select an active node (`set_shunt_node`).

## Observed Passwall2 UCI Details

From the target router's `uci show passwall2`:

- `passwall2.ProxyMaster=subscribe_list`
- Subscription scheduler loop mode is represented by `week_update='8'`.
- Subscription loop interval is represented by `interval_update='24'`.
- ProxyMaster-imported nodes may have:
  - `add_mode='2'`
  - `group='ProxyMaster'`
  - no `add_from` field
- Because `add_from` may be absent, cleanup must match both `group='ProxyMaster'` and `add_from='ProxyMaster'`.
- Passwall2 can handle default node becoming `(not set)` by itself; avoid special handling unless a concrete bug appears.
- The user can SSH into the router and provide exact `uci show passwall2` or script output when Passwall2 behavior is unclear.

## Deployment Assumptions

The target is OpenWrt with:

- `/www/proxymaster` for static assets.
- `/www/cgi-bin/proxymaster-api` for the CGI API.
- Passwall2 installed and configured through UCI package `passwall2`.
- Lua available at `/usr/bin/lua`.
- `curl`, `luci-lib-jsonc`, and LuCI UCI Lua bindings available.

`install.sh` currently:

- Updates OpenWrt package lists (`opkg update`) and installs `lua`, `curl`, and `luci-lib-jsonc`.
- Creates `/www/proxymaster` and `/www/cgi-bin`.
- Downloads `index.html`, `app.js`, `style.css`, and `api.lua` directly from the main branch on GitHub using `curl`.
- Converts CRLF to LF for the CGI script.
- Makes the CGI script executable.

## Known Risks and Cleanup Targets

- The backend currently logs sensitive values, including login POST data, tokens, curl commands, and dashboard responses. Remove or redact this before production use.
- Shell commands are assembled as strings and executed with `os.execute`/`io.popen`. Keep inputs escaped and avoid adding untrusted parameters to shell commands.
- Tokens are passed in query strings, which can appear in browser history, server logs, router logs, and referrers.
- Session cookies are written to `/tmp/pm_cookies.txt`, which persists between requests.
- `curl -k` disables TLS certificate verification for dashboard calls.
- `proxy_info` uses `Authorization: <token>` directly. Confirm whether the target dashboard expects a prefix such as `Bearer` for all supported systems.

## Working Guidance

- Keep the project small unless the user asks for a broader rewrite.
- Preserve OpenWrt/BusyBox compatibility when changing shell or Lua behavior.
- Be careful with UCI section names and Passwall2 expectations; `ProxyMaster` is a named section used by both config storage and subscription updates.
- If changing backend behavior, consider how the frontend expects response shapes from Axios.
- Avoid logging secrets. If logs are needed, log action names and high-level success/failure only.
