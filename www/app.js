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

        const loginData = res.data.data;
        
        // pmaster.pro (V2Board) provides two different tokens:
        // 1. 'token': A short hash used for subscription URLs.
        // 2. 'auth_data': A long JWT used for API authentication (user info).
        const subToken = loginData.token || loginData.auth_data;
        const apiToken = (loginData.auth_data && loginData.auth_data.startsWith("ey")) ? loginData.auth_data : subToken;

        if (!subToken) {
            throw new Error("Authentication token not found in login response.");
        }

        // Use the short token for the subscription link so Passwall2 can fetch nodes.
        const subLink = `${DASHBOARD_DOMAIN}/api/v1/client/subscribe?token=${subToken}`;

        // 3. Push to OpenWrt Backend
        // We store the apiToken (JWT) in UCI so fetchUsage() can continue to use it for headers.
        console.log("Sending subscription link to router...");
        const updateRes = await axios.get(`/cgi-bin/proxymaster-api?action=update_sub&token=${encodeURIComponent(apiToken)}&link=${encodeURIComponent(subLink)}`);
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

async function updateStatus(isPolling = false) {
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=status');
        const { enabled, running, config_exists, token } = res.data;
        
        if (config_exists) {
            showDashboard();
            if (!isPolling) fetchUsage(token);
            if (!isPolling) loadNodeOptions();
        }

        const statusText = document.getElementById('status-text');
        const toggleBtn = document.getElementById('toggle-btn');

        statusText.innerText = enabled === "1" ? (running ? "Running" : "Starting...") : "Stopped";
        statusText.className = enabled === "1" ? "status-on" : "status-off";
        toggleBtn.innerText = enabled === "1" ? "Deactivate Passwall" : "Activate Passwall";
        toggleBtn.className = enabled === "1" ? "secondary" : "primary-btn";
        return res.data;
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
        // Ensure token is available before making the API call
        if (!token) {
            console.warn("No token available for fetching usage.");
            document.getElementById('user-email').innerText = "N/A";
            document.getElementById('used-traffic').innerText = "N/A";
            document.getElementById('total-traffic').innerText = "N/A";
            document.getElementById('remaining-traffic').innerText = "N/A";
            return;
        }

        const info = await axios.get(`/cgi-bin/proxymaster-api?action=proxy_info&token=${encodeURIComponent(token)}`);
        if (info.data && info.data.data) {
            const userData = info.data.data;
            
            // V2board /user/getSubscribe uses 'u' and 'd'. /user/info might not.
            const u = Number(userData.u || 0); 
            const d = Number(userData.d || 0);
            const transferEnable = userData.transfer_enable || 0; // Total allowed traffic in bytes
            const email = userData.email || "N/A";

            const usedTrafficBytes = u + d;
            const remainingTrafficBytes = transferEnable > 0 ? (transferEnable - usedTrafficBytes) : 0;
            
            document.getElementById('user-email').innerText = email;
            document.getElementById('used-traffic').innerText = convertBytesToGB(usedTrafficBytes);
            document.getElementById('total-traffic').innerText = convertBytesToGB(transferEnable);
            document.getElementById('remaining-traffic').innerText = convertBytesToGB(remainingTrafficBytes);
        } else {
            // If request succeeded but data structure is wrong (e.g. dashboard returns {message: "..."})
            document.getElementById('user-email').innerText = info.data?.message || "Fetch Error";
            console.error("Unexpected proxy_info response structure:", info.data);
        }
    } catch (e) {
        console.error("Could not refresh traffic stats.", e);
        document.getElementById('user-email').innerText = "Error";
        document.getElementById('used-traffic').innerText = "Error";
        document.getElementById('total-traffic').innerText = "Error";
        document.getElementById('remaining-traffic').innerText = "Error";
    }
}

function convertBytesToGB(bytes) {
    if (bytes < 0) return "0.00 GB"; // Handle negative remaining traffic
    return (bytes / (1024 ** 3)).toFixed(2) + ' GB';
}

async function togglePasswall() {
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=toggle');
        const targetEnabled = res.data.enabled;
        // Update immediately to show transition state
        await updateStatus();
        
        if (targetEnabled === "1") {
            // Poll until enabled AND running
            pollStatus(d => d.enabled === "1" && d.running === true);
        } else {
            // Poll until disabled
            pollStatus(d => d.enabled === "0");
        }
    } catch (e) {
        console.error("Toggle failed", e);
        updateStatus();
    }
}

async function pollStatus(predicate, maxAttempts = 15) {
    if (maxAttempts <= 0) return;
    setTimeout(async () => {
        const data = await updateStatus(true);
        if (data && predicate(data)) {
            console.log("Target status reached. Polling stopped.");
            return;
        }
        pollStatus(predicate, maxAttempts - 1);
    }, 2000);
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

async function selectNode() {
    const select = document.getElementById('node-select');
    const nodeId = select ? select.value : null;
    if (!nodeId) return;

    const btn = document.getElementById('set-node-btn');
    try {
        if (select) select.disabled = true;
        if (btn) btn.disabled = true;
        const res = await axios.get(`/cgi-bin/proxymaster-api?action=set_shunt_node&node=${encodeURIComponent(nodeId)}`);
        if (res.data && res.data.success === false) {
            throw new Error(res.data.error || "Failed to set node.");
        }
        // Restarting via set_shunt_node also takes time to re-init core
        pollStatus(d => d.enabled === "1" && d.running === true);
    } catch (e) {
        console.error("Failed to set shunt node", e);
        alert(`Failed to set node: ${e.message || "Unknown error"}`);
        loadNodeOptions();
        return;
    } finally {
        if (select) select.disabled = false;
        if (btn) btn.disabled = false;
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

async function refreshUsage() {
    const statusData = await updateStatus(); // Get current token
    if (statusData && statusData.config_exists && statusData.token) {
        fetchUsage(statusData.token);
    } else {
        console.warn("Cannot refresh usage: no active configuration or token.");
        alert("Please log in to refresh usage data.");
    }
}
async function updateNodes() {
    const btn = document.getElementById('update-btn');
    const originalText = btn.innerText;
    btn.innerText = '...';
    btn.disabled = true;
    
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=update_nodes');
        if (res.data && res.data.success === false) {
            throw new Error(res.data.error || "Passwall2 update failed.");
        }
        setTimeout(loadNodeOptions, 5000);
        console.log("Node update triggered successfully.");
    } catch (e) {
        console.error("Failed to update nodes", e);
        alert(`Failed to trigger update: ${e.message || "Unknown error"}`);
    } finally {
        btn.innerText = originalText;
        btn.disabled = false;
    }
}

function togglePassword() {
    const passwordInput = document.getElementById('password');
    if (!passwordInput) return;
    passwordInput.type = passwordInput.type === 'password' ? 'text' : 'password';
}
