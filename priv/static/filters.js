/* Emergence — public filters directory. CSP-clean (script-src 'self',
   textContent only, no inline handlers). Fetches the topology-safe
   /filters.json and renders a live grid. */
(function () {
    "use strict";

    async function load() {
        const grid = document.getElementById("filter-grid");
        const count = document.getElementById("count");
        if (!grid) return;
        let filters = [];
        try {
            const r = await fetch("/filters.json", { cache: "no-store" });
            if (!r.ok) throw new Error("HTTP " + r.status);
            filters = await r.json();
        } catch (e) {
            if (count) count.textContent = "unavailable";
            grid.innerHTML = "";
            const p = document.createElement("div");
            p.className = "filters-empty";
            p.textContent = "Directory temporarily unavailable.";
            grid.appendChild(p);
            return;
        }

        filters.sort(function (a, b) {
            return (a.name || "").localeCompare(b.name || "");
        });
        if (count) count.textContent = filters.length + (filters.length === 1 ? " filter" : " filters");

        grid.innerHTML = "";
        if (!filters.length) {
            const p = document.createElement("div");
            p.className = "filters-empty";
            p.textContent = "No filters online right now.";
            grid.appendChild(p);
            return;
        }

        filters.forEach(function (f) {
            const card = document.createElement("div");
            card.className = "filter-card tier-" + (f.tier || "");

            const name = document.createElement("div");
            name.className = "f-name";
            name.textContent = f.name || "(unnamed)";

            const meta = document.createElement("div");
            meta.className = "f-meta";
            const parts = [];
            if (f.role) parts.push(f.role);
            if (f.tier) parts.push(f.tier);
            meta.textContent = parts.join(" · ");
            if (f.verified) {
                const v = document.createElement("span");
                v.className = "f-verified";
                v.textContent = (parts.length ? " · " : "") + "✓ signed";
                meta.appendChild(v);
            }

            card.appendChild(name);
            card.appendChild(meta);
            grid.appendChild(card);
        });
    }

    load();
    setInterval(load, 30000);
})();
