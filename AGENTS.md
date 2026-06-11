# Repository Notes for Agents

## Project Purpose

This repo is a small OpenWrt companion UI for ProxyMaster and Passwall2. It deploys a static web interface plus a Lua CGI backend to an OpenWrt router so a user can:

- Log in to the ProxyMaster dashboard at `https://pmaster.pro`.
- Save the returned subscription token/link into Passwall2 UCI config.
- Check Passwall2 status.
- Toggle Passwall2 on/off.
- Trigger a node/subscription update.
- Log out by deleting the stored ProxyMaster UCI section.

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

- `toggle`
  - Flips `passwall2.@global[0].enabled`.
  - Commits UCI changes.
  - Runs `/etc/init.d/passwall2 restart &`.

- `proxy_login`
  - Reads the JSON POST body from the browser.
  - Forwards it to `https://pmaster.pro/api/v1/passport/auth/login`.
  - Returns the dashboard response if it parses as JSON.

- `proxy_info`
  - Accepts `token` as a query parameter.
  - Calls `https://pmaster.pro/api/v1/user/info` with an `Authorization` header.
  - Returns the dashboard response if it parses as JSON.

- `update_sub`
  - Accepts `link` and optional `token` query parameters.
  - Creates/updates the `passwall2.ProxyMaster` UCI section as `subscribe_list`.
  - Stores `remark`, `url`, and `token`.

- `update_nodes`
  - Runs `lua /usr/share/passwall2/subscribe.lua ProxyMaster > /dev/null 2>&1 &`.

- `logout`
  - Deletes the `passwall2.ProxyMaster` UCI section and commits.

## Frontend Flow

1. On page load, `updateStatus()` checks whether a ProxyMaster config/token already exists.
2. Login posts `{ email, password }` to `proxy_login`.
3. The frontend extracts a token from `res.data.data.token` or `res.data.data.auth_data`.
4. It builds a subscription link:

   ```text
   https://pmaster.pro/api/v1/client/subscribe?token=<token>
   ```

5. It sends that link and token to `update_sub`.
6. If config exists, the UI shows the dashboard and fetches usage via `proxy_info`.

## Deployment Assumptions

The target is OpenWrt with:

- `/www/proxymaster` for static assets.
- `/www/cgi-bin/proxymaster-api` for the CGI API.
- Passwall2 installed and configured through UCI package `passwall2`.
- Lua available at `/usr/bin/lua`.
- `curl`, `luci-lib-jsonc`, and LuCI UCI Lua bindings available.

`install.sh` currently:

- Creates `/www/proxymaster` and `/www/cgi-bin`.
- Copies `www/*` to `/www/proxymaster/`.
- Copies `cgi-bin/api.lua` to `/www/cgi-bin/proxymaster-api`.
- Converts CRLF to LF for the CGI script.
- Makes the CGI script executable.
- Installs `lua`, `curl`, and `luci-lib-jsonc`.

## Known Risks and Cleanup Targets

- The backend currently logs sensitive values, including login POST data, tokens, curl commands, and dashboard responses. Remove or redact this before production use.
- `install.sh` sets `/etc/config/passwall2` to mode `666`, making it world-writable. Prefer a safer permission/ownership model.
- Shell commands are assembled as strings and executed with `os.execute`/`io.popen`. Keep inputs escaped and avoid adding untrusted parameters to shell commands.
- Tokens are passed in query strings, which can appear in browser history, server logs, router logs, and referrers.
- `curl -k` disables TLS certificate verification for dashboard calls.
- `proxy_info` uses `Authorization: <token>` directly. Confirm whether the target dashboard expects a prefix such as `Bearer` for all supported systems.
- `update_nodes` assumes `/usr/share/passwall2/subscribe.lua ProxyMaster` is valid for the installed Passwall2 version. Some versions may need another trigger.

## Working Guidance

- Keep the project small unless the user asks for a broader rewrite.
- Preserve OpenWrt/BusyBox compatibility when changing shell or Lua behavior.
- Be careful with UCI section names and Passwall2 expectations; `ProxyMaster` is a named section used by both config storage and subscription updates.
- If changing backend behavior, consider how the frontend expects response shapes from Axios.
- Avoid logging secrets. If logs are needed, log action names and high-level success/failure only.
