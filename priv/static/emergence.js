// Mise à jour du timestamp en temps réel
function updateTimestamp() {
    const now = new Date();
    const timestamp = now.toLocaleString('en-US', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
        hour12: false
    }).replace(/[/:]/g, '.').replace(', ', ' ');
    
    const timestampElement = document.getElementById('timestamp');
    if (timestampElement) {
        timestampElement.textContent = timestamp;
    }
}

// Animation de frappe pour les messages
function typeWriter(element, text, speed = 50) {
    element.innerHTML = '';
    let i = 0;
    
    function type() {
        if (i < text.length) {
            element.innerHTML += text.charAt(i);
            i++;
            setTimeout(type, speed);
        }
    }
    
    type();
}

// Effet de scan pour les résultats
function scanEffect(element) {
    element.style.opacity = '0';
    element.style.transform = 'translateY(20px)';
    
    setTimeout(() => {
        element.style.transition = 'all 0.5s ease';
        element.style.opacity = '1';
        element.style.transform = 'translateY(0)';
    }, 100);
}

// Fonction principale de soumission du formulaire
function submitForm(event) {
    event.preventDefault();

    const searchQuery = document.getElementById("searchQuery").value.trim();
    
    if (!searchQuery) {
        showNotification('Veuillez entrer une requête de recherche', 'warning');
        return;
    }

    // Animation de recherche
    const searchButton = document.querySelector('.search-button');
    searchButton.style.transform = 'scale(0.95)';
    setTimeout(() => {
        searchButton.style.transform = 'scale(1)';
    }, 150);

    // Affichage du loader
    const searchResults = document.getElementById("searchResults");
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
        </div>
    `;

    // Ajouter les styles CSS pour le loader
    addLoaderStyles();

    fetch('/query', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({ query: searchQuery }),
    })
    .then(response => {
        if (!response.ok) {
            throw new Error('Network response was not ok');
        }
        return response.json();
    })
    .then(data => {
        displayResults(data);
        requestSummary(searchResults.innerHTML);
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
            </div>
        `;
    });
}

// Affichage des résultats avec animations
function displayResults(data) {
    const searchResults = document.getElementById("searchResults");
    searchResults.innerHTML = '';

    if (!data.embryo_list || data.embryo_list.length === 0) {
        searchResults.innerHTML = `
            <div class="no-results">
                <div class="no-results-icon">🔍</div>
                <div class="no-results-text">
                    <strong>NO DATA FOUND</strong><br>
                    Try adjusting your search parameters.
                </div>
            </div>
        `;
        return;
    }

    data.embryo_list.forEach((item, index) => {
        const listItem = document.createElement('li');
        listItem.className = 'result-item';
        
        const url = item.properties.url || 'URL not available';
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
            </div>
        `;

        searchResults.appendChild(listItem);
        
        // Animation d'apparition décalée
        setTimeout(() => {
            scanEffect(listItem);
        }, index * 100);
    });
}

// Parsing des liens dans le résumé
function parseLinksInSummary(summaryText) {
    const urlRegex = /(https?:\/\/[^\s\)]+)/g;
    const sourceRegex = /\(Source[s]?:\s*(https?:\/\/[^\s\)]+)\)/g;
    const multiSourceRegex = /\(Sources?:\s*([^)]+)\)/g;

    let parsedText = summaryText;

    parsedText = parsedText.replace(multiSourceRegex, (match, urls) => {
        const urlList = urls.split(',').map(url => {
            const trimmedUrl = url.trim();
            if (trimmedUrl.startsWith('http')) {
                const domain = extractDomain(trimmedUrl);
                return `<a href="${trimmedUrl}" target="_blank" class="summary-link">${domain}</a>`;
            }
            return trimmedUrl;
        });
        return `(Sources: ${urlList.join(', ')})`;
    });

    parsedText = parsedText.replace(sourceRegex, (match, url) => {
        const domain = extractDomain(url);
        return `(Source: <a href="${url}" target="_blank" class="summary-link">${domain}</a>)`;
    });

    parsedText = parsedText.replace(urlRegex, (match, url) => {
        if (!parsedText.includes(`href="${url}"`)) {
            const domain = extractDomain(url);
            return `<a href="${url}" target="_blank" class="summary-link">${domain}</a>`;
        }
        return match;
    });

    return parsedText;
}

// Extraction du domaine
function extractDomain(url) {
    try {
        const urlObj = new URL(url);
        return urlObj.hostname.replace('www.', '');
    } catch (e) {
        return url.length > 30 ? url.substring(0, 30) + '...' : url;
    }
}

// Requête de résumé avec animation
function requestSummary(htmlResult) {
    const summaryContent = document.getElementById("summaryContent");
    
    // Animation de chargement AI
    summaryContent.innerHTML = `
        <div class="ai-loading">
            <div class="ai-brain">
                <div class="brain-wave"></div>
                <div class="brain-wave"></div>
                <div class="brain-wave"></div>
            </div>
            <div class="ai-status">
                <div class="ai-text">NEURAL ANALYSIS</div>
                <div class="ai-progress">
                    <div class="progress-bar"></div>
                </div>
            </div>
        </div>
    `;

    addAILoadingStyles();

    fetch('/summarize', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({
            html: htmlResult
        }),
    })
    .then(response => {
        if (!response.ok) {
            throw new Error('Erreur lors de la génération du résumé');
        }
        return response.json();
    })
    .then(data => {
        const summaryWithLinks = parseLinksInSummary(data.summary);
        summaryContent.innerHTML = `<div class="summary-content">${summaryWithLinks}</div>`;
        
        // Animation d'apparition du texte
        const summaryDiv = summaryContent.querySelector('.summary-content');
        scanEffect(summaryDiv);
    })
    .catch(error => {
        console.error('Error:', error);
        summaryContent.innerHTML = `
            <div class="summary-error">
                <div class="error-icon">⚠️</div>
                <div class="error-text">
                    <strong>AI ANALYSIS FAILED</strong><br>
                    Neural network connection interrupted.
                </div>
            </div>
        `;
    });
}

// Notification système
function showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `notification ${type}`;
    notification.innerHTML = `
        <div class="notification-content">
            <span class="notification-icon">
                ${type === 'warning' ? '⚠️' : type === 'error' ? '❌' : 'ℹ️'}
            </span>
            <span class="notification-text">${message}</span>
        </div>
    `;
    
    document.body.appendChild(notification);
    
    // Animation d'apparition
    setTimeout(() => {
        notification.style.opacity = '1';
        notification.style.transform = 'translateY(0)';
    }, 100);
    
    // Suppression automatique
    setTimeout(() => {
        notification.style.opacity = '0';
        notification.style.transform = 'translateY(-100px)';
        setTimeout(() => {
            document.body.removeChild(notification);
        }, 300);
    }, 3000);
}

// Styles CSS pour le loader
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
        
        .loader-ring:nth-child(1) {
            width: 80px;
            height: 80px;
            animation-duration: 1s;
        }
        
        .loader-ring:nth-child(2) {
            width: 60px;
            height: 60px;
            top: 10px;
            left: 10px;
            border-top-color: #0099ff;
            animation-duration: 1.5s;
            animation-direction: reverse;
        }
        
        .loader-ring:nth-child(3) {
            width: 40px;
            height: 40px;
            top: 20px;
            left: 20px;
            border-top-color: #ff0099;
            animation-duration: 2s;
        }
        
        .loading-text {
            font-family: 'Orbitron', monospace;
            color: #00ff88;
            font-size: 1.1rem;
            letter-spacing: 2px;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        
        .loading-dots span {
            animation: dots 1.5s infinite;
        }
        
        .loading-dots span:nth-child(1) { animation-delay: 0s; }
        .loading-dots span:nth-child(2) { animation-delay: 0.3s; }
        .loading-dots span:nth-child(3) { animation-delay: 0.6s; }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        @keyframes dots {
            0%, 80%, 100% { opacity: 0; }
            40% { opacity: 1; }
        }
        
        .result-item {
            background: linear-gradient(135deg, rgba(0, 255, 136, 0.1), rgba(0, 153, 255, 0.1));
            border: 1px solid rgba(0, 255, 136, 0.3);
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
            top: 0;
            left: -100%;
            width: 100%;
            height: 100%;
            background: linear-gradient(90deg, transparent, rgba(0, 255, 136, 0.1), transparent);
            transition: left 0.5s ease;
        }
        
        .result-item:hover::before {
            left: 100%;
        }
        
        .result-item:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 25px rgba(0, 255, 136, 0.2);
            border-color: #00ff88;
        }
        
        .result-header {
            display: flex;
            align-items: center;
            gap: 1rem;
            margin-bottom: 1rem;
        }
        
        .result-index {
            background: linear-gradient(45deg, #00ff88, #0099ff);
            color: #000;
            font-weight: bold;
            padding: 0.3rem 0.8rem;
            border-radius: 6px;
            font-family: 'Orbitron', monospace;
            font-size: 0.9rem;
        }
        
        .result-url {
            flex: 1;
        }
        
        .result-link {
            color: #0099ff;
            text-decoration: none;
            font-weight: 600;
            transition: all 0.3s ease;
            font-size: 1.1rem;
        }
        
        .result-link:hover {
            color: #00ff88;
            text-shadow: 0 0 8px rgba(0, 255, 136, 0.5);
        }
        
        .result-content {
            margin: 1rem 0;
        }
        
        .result-resume {
            color: #00ff88;
            line-height: 1.6;
            font-size: 1rem;
        }
        
        .result-footer {
            display: flex;
            justify-content: flex-end;
            margin-top: 1rem;
        }
        
        .status-badge {
            background: rgba(0, 255, 136, 0.2);
            color: #00ff88;
            padding: 0.3rem 0.8rem;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
            border: 1px solid rgba(0, 255, 136, 0.3);
        }
        
        .error-message, .no-results {
            text-align: center;
            padding: 3rem;
            background: rgba(255, 68, 68, 0.1);
            border: 1px solid rgba(255, 68, 68, 0.3);
            border-radius: 10px;
            color: #ff4444;
        }
        
        .no-results {
            background: rgba(255, 170, 0, 0.1);
            border-color: rgba(255, 170, 0, 0.3);
            color: #ffaa00;
        }
        
        .error-icon, .no-results-icon {
            font-size: 3rem;
            margin-bottom: 1rem;
        }
        
        .notification {
            position: fixed;
            top: 20px;
            right: 20px;
            z-index: 1000;
            opacity: 0;
            transform: translateY(-100px);
            transition: all 0.3s ease;
        }
        
        .notification-content {
            background: rgba(0, 0, 0, 0.9);
            border: 2px solid #00ff88;
            border-radius: 10px;
            padding: 1rem 1.5rem;
            display: flex;
            align-items: center;
            gap: 1rem;
            backdrop-filter: blur(10px);
        }
        
        .notification.warning .notification-content {
            border-color: #ffaa00;
        }
        
        .notification.error .notification-content {
            border-color: #ff4444;
        }
        
        .notification-text {
            color: #00ff88;
            font-weight: 500;
        }
        
        .notification.warning .notification-text {
            color: #ffaa00;
        }
        
        .notification.error .notification-text {
            color: #ff4444;
        }
    `;
    
    document.head.appendChild(style);
}

// Styles CSS pour le chargement AI
function addAILoadingStyles() {
    if (document.getElementById('ai-loading-styles')) return;
    
    const style = document.createElement('style');
    style.id = 'ai-loading-styles';
    style.textContent = `
        .ai-loading {
            padding: 2rem;
            text-align: center;
            background: rgba(0, 153, 255, 0.05);
            border-radius: 10px;
            border: 1px solid rgba(0, 153, 255, 0.2);
        }
        
        .ai-brain {
            position: relative;
            width: 60px;
            height: 40px;
            margin: 0 auto 1.5rem;
        }
        
        .brain-wave {
            position: absolute;
            width: 100%;
            height: 4px;
            background: linear-gradient(90deg, transparent, #0099ff, transparent);
            border-radius: 2px;
            animation: brainWave 2s ease-in-out infinite;
        }
        
        .brain-wave:nth-child(1) {
            top: 0;
            animation-delay: 0s;
        }
        
        .brain-wave:nth-child(2) {
            top: 50%;
            transform: translateY(-50%);
            animation-delay: 0.3s;
        }
        
        .brain-wave:nth-child(3) {
            bottom: 0;
            animation-delay: 0.6s;
        }
        
        .ai-status {
            display: flex;
            flex-direction: column;
            gap: 1rem;
            align-items: center;
        }
        
        .ai-text {
            font-family: 'Orbitron', monospace;
            color: #0099ff;
            font-size: 1rem;
            letter-spacing: 2px;
        }
        
        .ai-progress {
            width: 200px;
            height: 4px;
            background: rgba(0, 153, 255, 0.2);
            border-radius: 2px;
            overflow: hidden;
        }
        
        .progress-bar {
            height: 100%;
            background: linear-gradient(90deg, #0099ff, #00ff88);
            width: 0%;
            animation: progress 3s ease-in-out infinite;
        }
        
        @keyframes brainWave {
            0%, 100% { opacity: 0.3; transform: scaleX(0.5); }
            50% { opacity: 1; transform: scaleX(1); }
        }
        
        @keyframes progress {
            0% { width: 0%; }
            50% { width: 70%; }
            100% { width: 100%; }
        }
    `;
    
    document.head.appendChild(style);
}

// Effets sonores (optionnel)
function playSound(type) {
    // Création d'un son synthétique simple
    const audioContext = new (window.AudioContext || window.webkitAudioContext)();
    const oscillator = audioContext.createOscillator();
    const gainNode = audioContext.createGain();
    
    oscillator.connect(gainNode);
    gainNode.connect(audioContext.destination);
    
    switch(type) {
        case 'search':
            oscillator.frequency.setValueAtTime(800, audioContext.currentTime);
            oscillator.frequency.exponentialRampToValueAtTime(400, audioContext.currentTime + 0.1);
            break;
        case 'success':
            oscillator.frequency.setValueAtTime(600, audioContext.currentTime);
            oscillator.frequency.exponentialRampToValueAtTime(800, audioContext.currentTime + 0.1);
            break;
        case 'error':
            oscillator.frequency.setValueAtTime(300, audioContext.currentTime);
            break;
    }
    
    gainNode.gain.setValueAtTime(0.1, audioContext.currentTime);
    gainNode.gain.exponentialRampToValueAtTime(0.01, audioContext.currentTime + 0.1);
    
    oscillator.start(audioContext.currentTime);
    oscillator.stop(audioContext.currentTime + 0.1);
}

// Raccourcis clavier
document.addEventListener('keydown', function(event) {
    // Ctrl + Enter pour rechercher
    if (event.ctrlKey && event.key === 'Enter') {
        event.preventDefault();
        const searchForm = document.getElementById('searchForm');
        if (searchForm) {
            submitForm(new Event('submit'));
        }
    }
    
    // Echap pour effacer la recherche
    if (event.key === 'Escape') {
        const searchInput = document.getElementById('searchQuery');
        if (searchInput && searchInput === document.activeElement) {
            searchInput.value = '';
        }
    }
});

// Gestion du focus avec effets visuels
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
    
    // Mise à jour du timestamp
    updateTimestamp();
    setInterval(updateTimestamp, 1000);
});

// Event listeners
document.getElementById("searchForm").addEventListener("submit", submitForm);
