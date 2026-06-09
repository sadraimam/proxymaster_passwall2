const API_BASE_URL = "https://your-dashboard.com"; // CHANGE THIS
const SYSTEM_MODE = "XBOARD"; // Options: "XBOARD", "V2BOARD"

async function login() {
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;

    try {
        // 1. Authenticate
        const res = await axios.post(`${API_BASE_URL}/api/v1/passport/auth/login`, { email, password });
        
        // Xboard uses auth_data, older V2board might use token or auth_data
        const token = SYSTEM_MODE === "XBOARD" 
            ? res.data.data.auth_data 
            : (res.data.data.token || res.data.data.auth_data);

        // 2. Fetch User Info
        const info = await axios.get(`${API_BASE_URL}/api/v1/user/info`, {
            headers: { 'Authorization': token }
        });

        const subLink = info.data.data.subscribe_url;
        
        // 3. Push to OpenWrt Backend
        await axios.get(`/cgi-bin/proxymaster-api?action=update_sub&link=${encodeURIComponent(subLink)}`);
        
        // 4. Update UI
        document.getElementById('login-section').style.display = 'none';
        document.getElementById('stats').style.display = 'block';
        document.getElementById('usage').innerText = ((info.data.data.u + info.data.data.d) / (1024**3)).toFixed(2);
        
        updateStatus();
    } catch (e) {
        console.error("Failed to sync with Xboard", e);
        alert("Login failed. Check console.");
    }
}

async function updateStatus() {
    try {
        const res = await axios.get('/cgi-bin/proxymaster-api?action=status');
        const { enabled, running } = res.data;
        const statusText = document.getElementById('status-text');
        const toggleBtn = document.getElementById('toggle-btn');

        if (enabled === "1") {
            statusText.innerText = running ? "Active" : "Enabled (Starting...)";
            statusText.className = "status-on";
            toggleBtn.innerText = "Deactivate Passwall";
        } else {
            statusText.innerText = "Disabled";
            statusText.className = "status-off";
            toggleBtn.innerText = "Activate Passwall";
        }
    } catch (e) {
        console.error("Failed to fetch status", e);
        document.getElementById('status-text').innerText = "Error fetching status";
    }
}

async function togglePasswall() {
    await axios.get('/cgi-bin/proxymaster-api?action=toggle');
    updateStatus();
}
