const SYSTEM_MODE = "V2BOARD"; // Options: "XBOARD", "V2BOARD"
const DASHBOARD_DOMAIN = "https://pmaster.pro";

// Initialize: Check if user is already "logged in" on the router
window.onload = async function() {
    console.log("Checking for existing ProxyMaster configuration...");
    await updateStatus();
};

async function login() {
    console.log("Login button clicked. Attempting proxy authentication...");
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;

    try {
        // 1. Authenticate
        const res = await axios.post(`/cgi-bin/proxymaster-api?action=proxy_login`, { email, password });
        console.log("Authentication response received:", res.status);
        console.log("Login response data:", res.data);
        
        // Check if login response has expected structure
        if (!res.data || !res.data.data) {
            throw new Error("Login response missing 'data' or 'data.data' field, or invalid JSON from proxy.");
        }

        // Xboard uses auth_data, older V2board might use token or auth_data
        const token = SYSTEM_MODE === "XBOARD" 
            ? res.data.data.auth_data 
            : (res.data.data.token || res.data.data.auth_data);

        if (!token) {
            throw new Error("Authentication token not found in login response.");
        }

        // Construct Sub Link (Bot Logic is reliable)
        const subLink = `${DASHBOARD_DOMAIN}/api/v1/client/subscribe?token=${token}`;

        // 3. Push to OpenWrt Backend
        console.log("Sending subscription link to router...");
        const updateRes = await axios.get(`/cgi-bin/proxymaster-api?action=update_sub&token=${encodeURIComponent(token)}&link=${encodeURIComponent(subLink)}`);
        if (updateRes.data && updateRes.data.update_triggered === false) {
            throw new Error(updateRes.data.update_error || "Subscription saved, but Passwall2 update script was not found.");
        }
        
        // 4. Reload status and show dashboard
        await updateStatus();
        setTimeout(loadNodeOptions, 5000);
    } catch (e) {
        // Improved error logging
        const errorDetail = e.response?.data?.message || e.message || "Unknown error";
        console.error("Login Error:", {
            status: e.response?.status,
            data: e.response?.data,
            config: e.config
        });
        alert(`Login failed: ${errorDetail}`);
    }
}

async function updateStatus() {
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=status');
        const { enabled, running, config_exists, token } = res.data;
        
        if (config_exists) {
            showDashboard();
            fetchUsage(token);
            loadNodeOptions();
        }

        const statusText = document.getElementById('status-text');
        const toggleBtn = document.getElementById('toggle-btn');

        statusText.innerText = enabled === "1" ? (running ? "Running" : "Starting...") : "Stopped";
        statusText.className = enabled === "1" ? "status-on" : "status-off";
        toggleBtn.innerText = enabled === "1" ? "Deactivate Passwall" : "Activate Passwall";
        toggleBtn.className = enabled === "1" ? "secondary" : "primary-btn";

    } catch (e) {
        console.error("Failed to fetch status", e);
        document.getElementById('status-text').innerText = "Error fetching status";
    }
}

async function checkConnect(id, url) {
    const label = document.getElementById(`${id}-status`);
    if (!label) return;

    label.innerText = "Checking...";
    label.className = "status-neutral";

    try {
        const res = await axios.get(`/cgi-bin/proxymaster-api?action=connect_check&url=${encodeURIComponent(url)}`);
        const { use_time, http_code } = res.data;

        if (use_time) {
            label.innerText = `${use_time} ms`;
            if (use_time < 500) label.className = "green";
            else if (use_time < 1500) label.className = "yellow";
            else label.className = "red";
        } else {
            label.innerText = "Error";
            label.className = "red";
        }
    } catch (e) {
        console.error(`Check failed for ${id}`, e);
        label.innerText = "Failed";
        label.className = "red";
    }
}

function showDashboard() {
    document.getElementById('login-section').style.display = 'none';
    document.getElementById('stats').style.display = 'block';
}

async function fetchUsage(token) {
    try {
        const info = await axios.get(`/cgi-bin/proxymaster-api?action=proxy_info&token=${encodeURIComponent(token)}`);
        if (info.data && info.data.data) {
            const usage = ((info.data.data.u + info.data.data.d) / (1024**3)).toFixed(2);
            document.getElementById('usage').innerText = usage;
        }
    } catch (e) {
        console.warn("Could not refresh traffic stats.");
    }
}

async function togglePasswall() {
    await axios.get('/cgi-bin/proxymaster-api?action=toggle');
    updateStatus();
}

async function loadNodeOptions() {
    const select = document.getElementById('node-select');
    if (!select) return;

    select.disabled = true;
    select.innerHTML = '<option value="">Loading nodes...</option>';

    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=list_nodes');
        const nodes = res.data?.nodes || [];
        const currentNode = res.data?.current_node || "";

        if (!nodes.length) {
            select.innerHTML = '<option value="">No subscription nodes found</option>';
            return;
        }

        select.innerHTML = nodes.map((node) => {
            const selected = node.id === currentNode ? "selected" : "";
            const label = node.remarks || node.id;
            return `<option value="${escapeHtml(node.id)}" ${selected}>${escapeHtml(label)}</option>`;
        }).join("");
    } catch (e) {
        console.error("Failed to load nodes", e);
        select.innerHTML = '<option value="">Failed to load nodes</option>';
    } finally {
        select.disabled = false;
    }
}

async function selectNode(nodeId) {
    if (!nodeId) return;

    const select = document.getElementById('node-select');
    if (select) select.disabled = true;

    try {
        const res = await axios.get(`/cgi-bin/proxymaster-api?action=set_shunt_node&node=${encodeURIComponent(nodeId)}`);
        if (res.data && res.data.success === false) {
            throw new Error(res.data.error || "Failed to set node.");
        }
    } catch (e) {
        console.error("Failed to set shunt node", e);
        alert(`Failed to set node: ${e.message || "Unknown error"}`);
        loadNodeOptions();
        return;
    } finally {
        if (select) select.disabled = false;
    }
}

function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (char) => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
    }[char]));
}

async function logout() {
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=logout');
        if (res.data && res.data.success === false) {
            throw new Error(res.data.error || "Logout cleanup failed.");
        }
    } catch (e) {
        console.error("Logout failed on server", e);
        alert(`Logout failed: ${e.message || "Unknown error"}`);
        return;
    }
    location.reload();
}

async function updateNodes() {
    const btn = document.getElementById('update-btn');
    const originalText = btn.innerText;
    btn.innerText = "Updating...";
    btn.disabled = true;
    
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=update_nodes');
        if (res.data && res.data.success === false) {
            throw new Error(res.data.error || "Passwall2 update failed.");
        }
        setTimeout(loadNodeOptions, 5000);
        alert("Node update triggered. Nodes will appear in Passwall2 shortly.");
    } catch (e) {
        console.error("Failed to update nodes", e);
        alert(`Failed to trigger update: ${e.message || "Unknown error"}`);
    } finally {
        btn.innerText = originalText;
        btn.disabled = false;
    }
}
