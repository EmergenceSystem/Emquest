/* ------------------------------------------------------------------ */
/* Timestamp — updates every second in the header                      */
/* ------------------------------------------------------------------ */
function updateTimestamp() {
    const now = new Date();
    const timestamp = now.toLocaleString('en-US', {
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
        hour12: false
    }).replace(/[/:]/g, '.').replace(', ', ' ');

    const el = document.getElementById('timestamp');
    if (el) el.textContent = timestamp;
}

/* ------------------------------------------------------------------ */
/* Scan animation — fades a result item in from below                 */
/* ------------------------------------------------------------------ */
function scanEffect(element) {
    element.style.opacity   = '0';
    element.style.transform = 'translateY(20px)';
    setTimeout(() => {
        element.style.transition = 'all 0.5s ease';
        element.style.opacity    = '1';
        element.style.transform  = 'translateY(0)';
    }, 100);
}

/* ------------------------------------------------------------------ */
/* Notification banner — auto-dismisses after 3 seconds               */
/* ------------------------------------------------------------------ */
function showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `notification ${type}`;
    notification.innerHTML = `
        <div class="notification-content">
            <span class="notification-icon">
                ${type === 'warning' ? '⚠️' : type === 'error' ? '❌' : 'ℹ️'}
            </span>
            <span class="notification-text">${message}</span>
        </div>`;
    document.body.appendChild(notification);

    setTimeout(() => {
        notification.style.opacity   = '1';
        notification.style.transform = 'translateY(0)';
    }, 100);

    setTimeout(() => {
        notification.style.opacity   = '0';
        notification.style.transform = 'translateY(-100px)';
        setTimeout(() => document.body.removeChild(notification), 300);
    }, 3000);
}

/* ------------------------------------------------------------------ */
/* Form submission — POSTs the query and displays results              */
/* ------------------------------------------------------------------ */
function submitForm(event) {
    event.preventDefault();

    const searchQuery = document.getElementById('searchQuery').value.trim();
    if (!searchQuery) {
        showNotification('Please enter a search query', 'warning');
        return;
    }

    /* Brief button press animation */
    const searchButton = document.querySelector('.search-button');
    searchButton.style.transform = 'scale(0.95)';
    setTimeout(() => { searchButton.style.transform = 'scale(1)'; }, 150);

    /* Show loader while waiting for results */
    const searchResults = document.getElementById('searchResults');
    searchResults.innerHTML = `
        <div class="search-loading">
            <div class="loader-container">
                <div class="tech-loader">
                    <div class="loader-ring"></div>
                    <div class="loader-ring"></div>
                    <div class="loader-ring"></div>
                </div>
                <div class="loading-text">
                    <span>SCANNING DATABASE...</span>
                    <div class="loading-dots">
                        <span>.</span><span>.</span><span>.</span>
                    </div>
                </div>
            </div>
        </div>`;

    addLoaderStyles();

    fetch('/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: searchQuery }),
    })
    .then(response => {
        if (!response.ok) throw new Error('Network response was not ok');
        return response.json();
    })
    .then(data => {
        displayResults(data);
    })
    .catch(error => {
        console.error('Error:', error);
        searchResults.innerHTML = `
            <div class="error-message">
                <div class="error-icon">⚠️</div>
                <div class="error-text">
                    <strong>SYSTEM ERROR</strong><br>
                    Connection failed. Please try again.
                </div>
            </div>`;
    });
}

/* ------------------------------------------------------------------ */
/* Result rendering — builds one list item per embryo                 */
/* ------------------------------------------------------------------ */
function displayResults(data) {
    const searchResults = document.getElementById('searchResults');
    searchResults.innerHTML = '';

    if (!data.embryo_list || data.embryo_list.length === 0) {
        searchResults.innerHTML = `
            <div class="no-results">
                <div class="no-results-icon">🔍</div>
                <div class="no-results-text">
                    <strong>NO DATA FOUND</strong><br>
                    Try adjusting your search parameters.
                </div>
            </div>`;
        return;
    }

    data.embryo_list.forEach((item, index) => {
        const listItem = document.createElement('li');
        listItem.className = 'result-item';

        const url    = item.properties.url    || 'URL not available';
        const resume = item.properties.resume || 'Resume not available';

        listItem.innerHTML = `
            <div class="result-header">
                <div class="result-index">${String(index + 1).padStart(2, '0')}</div>
                <div class="result-url">
                    <a href="${url}" target="_blank" class="result-link">${url}</a>
                </div>
            </div>
            <div class="result-content">
                <p class="result-resume">${resume}</p>
            </div>
            <div class="result-footer">
                <div class="result-status">
                    <span class="status-badge">ACTIVE</span>
                </div>
            </div>`;

        searchResults.appendChild(listItem);

        /* Stagger the scan-in animation per item */
        setTimeout(() => scanEffect(listItem), index * 100);
    });
}

/* ------------------------------------------------------------------ */
/* Loader styles — injected once into <head>                          */
/* ------------------------------------------------------------------ */
function addLoaderStyles() {
    if (document.getElementById('loader-styles')) return;

    const style = document.createElement('style');
    style.id = 'loader-styles';
    style.textContent = `
        .search-loading {
            padding: 3rem;
            text-align: center;
            background: rgba(0, 255, 136, 0.05);
            border-radius: 10px;
            border: 1px solid rgba(0, 255, 136, 0.2);
        }
        .loader-container {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 1.5rem;
        }
        .tech-loader {
            position: relative;
            width: 80px;
            height: 80px;
        }
        .loader-ring {
            position: absolute;
            border: 3px solid transparent;
            border-top: 3px solid #00ff88;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        .loader-ring:nth-child(1) { width:80px; height:80px; animation-duration:1s; }
        .loader-ring:nth-child(2) { width:60px; height:60px; top:10px; left:10px; border-top-color:#0099ff; animation-duration:1.5s; animation-direction:reverse; }
        .loader-ring:nth-child(3) { width:40px; height:40px; top:20px; left:20px; border-top-color:#ff0099; animation-duration:2s; }
        .loading-text {
            font-family: 'Orbitron', monospace;
            color: #00ff88;
            font-size: 1.1rem;
            letter-spacing: 2px;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .loading-dots span { animation: dots 1.5s infinite; }
        .loading-dots span:nth-child(1) { animation-delay: 0s; }
        .loading-dots span:nth-child(2) { animation-delay: 0.3s; }
        .loading-dots span:nth-child(3) { animation-delay: 0.6s; }
        @keyframes spin  { 0% { transform: rotate(0deg); }   100% { transform: rotate(360deg); } }
        @keyframes dots  { 0%, 80%, 100% { opacity: 0; }     40%  { opacity: 1; } }

        /* Result item card */
        .result-item {
            background: linear-gradient(135deg, rgba(0,255,136,0.1), rgba(0,153,255,0.1));
            border: 1px solid rgba(0,255,136,0.3);
            border-radius: 12px;
            margin: 1rem 0;
            padding: 1.5rem;
            transition: all 0.3s ease;
            position: relative;
            overflow: hidden;
        }
        .result-item::before {
            content: '';
            position: absolute;
            top: 0; left: -100%;
            width: 100%; height: 100%;
            background: linear-gradient(90deg, transparent, rgba(0,255,136,0.1), transparent);
            transition: left 0.5s ease;
        }
        .result-item:hover::before { left: 100%; }
        .result-item:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 25px rgba(0,255,136,0.2);
            border-color: #00ff88;
        }
        .result-header { display:flex; align-items:center; gap:1rem; margin-bottom:1rem; }
        .result-index {
            background: linear-gradient(45deg, #00ff88, #0099ff);
            color: #000;
            font-weight: bold;
            padding: 0.3rem 0.8rem;
            border-radius: 6px;
            font-family: 'Orbitron', monospace;
            font-size: 0.9rem;
        }
        .result-url  { flex: 1; }
        .result-link { color:#0099ff; text-decoration:none; font-weight:600; transition:all 0.3s ease; font-size:1.1rem; }
        .result-link:hover { color:#00ff88; text-shadow:0 0 8px rgba(0,255,136,0.5); }
        .result-content { margin: 1rem 0; }
        .result-resume  { color: #00ff88; line-height: 1.6; font-size: 1rem; }
        .result-footer  { display:flex; justify-content:flex-end; margin-top:1rem; }
        .status-badge {
            background: rgba(0,255,136,0.2);
            color: #00ff88;
            padding: 0.3rem 0.8rem;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
            border: 1px solid rgba(0,255,136,0.3);
        }
        .error-message, .no-results {
            text-align: center;
            padding: 3rem;
            background: rgba(255,68,68,0.1);
            border: 1px solid rgba(255,68,68,0.3);
            border-radius: 10px;
            color: #ff4444;
        }
        .no-results {
            background: rgba(255,170,0,0.1);
            border-color: rgba(255,170,0,0.3);
            color: #ffaa00;
        }
        .error-icon, .no-results-icon { font-size:3rem; margin-bottom:1rem; }

        /* Notification banner */
        .notification {
            position: fixed;
            top: 20px; right: 20px;
            z-index: 1000;
            opacity: 0;
            transform: translateY(-100px);
            transition: all 0.3s ease;
        }
        .notification-content {
            background: rgba(0,0,0,0.9);
            border: 2px solid #00ff88;
            border-radius: 10px;
            padding: 1rem 1.5rem;
            display: flex;
            align-items: center;
            gap: 1rem;
            backdrop-filter: blur(10px);
        }
        .notification.warning .notification-content { border-color: #ffaa00; }
        .notification.error   .notification-content { border-color: #ff4444; }
        .notification-text               { color: #00ff88; font-weight: 500; }
        .notification.warning .notification-text { color: #ffaa00; }
        .notification.error   .notification-text { color: #ff4444; }
    `;
    document.head.appendChild(style);
}

/* ------------------------------------------------------------------ */
/* Keyboard shortcuts                                                  */
/*   Ctrl+Enter — submit the form                                     */
/*   Escape     — clear the search input                              */
/* ------------------------------------------------------------------ */
document.addEventListener('keydown', function(event) {
    if (event.ctrlKey && event.key === 'Enter') {
        event.preventDefault();
        const form = document.getElementById('searchForm');
        if (form) submitForm(new Event('submit'));
    }
    if (event.key === 'Escape') {
        const input = document.getElementById('searchQuery');
        if (input && input === document.activeElement) input.value = '';
    }
});

/* ------------------------------------------------------------------ */
/* DOMContentLoaded — input focus effects + timestamp                 */
/* ------------------------------------------------------------------ */
document.addEventListener('DOMContentLoaded', function() {
    const searchInput = document.getElementById('searchQuery');
    if (searchInput) {
        searchInput.addEventListener('focus', function() {
            this.parentElement.style.boxShadow = '0 0 20px rgba(0, 255, 136, 0.3)';
        });
        searchInput.addEventListener('blur', function() {
            this.parentElement.style.boxShadow = 'none';
        });
    }

    updateTimestamp();
    setInterval(updateTimestamp, 1000);
});

/* Form submit listener */
document.getElementById('searchForm').addEventListener('submit', submitForm);
