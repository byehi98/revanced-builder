(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  const ICONS = {
    obtainium:
      '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v11m0 0 4-4m-4 4-4-4"></path><path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"></path></svg>',
    download:
      '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12m0 0 4.5-4.5M12 15l-4.5-4.5"></path><path d="M5 21h14"></path></svg>',
    copy:
      '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>',
    external:
      '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"></path></svg>',
    archive:
      '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 8v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8"></path><path d="M1 3h22v5H1zM10 12h4"></path></svg>',
  };

  const state = {
    data: null,
    apps: [],
    query: "",
    source: "all",
    sort: "recent",
  };

  const els = {
    grid: $("#appGrid"),
    status: $("#catalogStatus"),
    empty: $("#emptyState"),
    resultCount: $("#resultCount"),
    search: $("#searchInput"),
    searchClear: $("#searchClear"),
    source: $("#sourceFilter"),
    sort: $("#sortSelect"),
    clearFilters: $("#clearFilters"),
    statApps: $("#statApps"),
    statBuilt: $("#statBuilt"),
    statSources: $("#statSources"),
    updatedNote: $("#updatedNote"),
    footerUpdated: $("#footerUpdated"),
    toast: $("#toast"),
    themeToggle: $("#themeToggle"),
    themeColor: $("#themeColor"),
    repoLink: $("#repoLink"),
    releasesLink: $("#releasesLink"),
    readmeLink: $("#readmeLink"),
    obtainiumImportNote: $("#obtainiumImportNote"),
    obtainiumImportDetail: $("#obtainiumImportDetail"),
    obtainiumDownload: $("#obtainiumDownload"),
  };

  /* --------------------------------------------------------------------- */
  /* helpers                                                               */
  /* --------------------------------------------------------------------- */

  const escapeMap = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => escapeMap[char]);

  function safeUrl(value) {
    try {
      const url = new URL(value, window.location.href);
      return url.protocol === "https:" || url.protocol === "http:" ? url.href : "#";
    } catch {
      return "#";
    }
  }

  function formatBytes(value) {
    if (!Number.isFinite(value) || value <= 0) return "";
    const units = ["B", "KB", "MB", "GB"];
    let size = value;
    let index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index += 1;
    }
    return `${size >= 10 || index === 0 ? Math.round(size) : size.toFixed(1)} ${units[index]}`;
  }

  function formatDate(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return new Intl.DateTimeFormat(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    }).format(date);
  }

  function formatDateTime(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return `${formatDate(value)}, ${new Intl.DateTimeFormat(undefined, {
      hour: "2-digit",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(date)}`;
  }

  function relativeDate(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    const days = Math.floor((Date.now() - date.getTime()) / 86400000);
    if (days <= 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 30) return `${days} days ago`;
    return formatDate(value);
  }

  function versionLabel(version) {
    if (!version) return "";
    return /^\d/.test(version) ? `v${version}` : version;
  }

  function assetLabel(asset) {
    const parts = [asset.kind === "module" ? "Module" : "APK"];
    if (asset.arch) parts.push(asset.arch);
    if (asset.version) parts.push(versionLabel(asset.version));
    return parts.join(" · ");
  }

  function isBuilt(app) {
    return app.status === "built" || (Array.isArray(app.assets) && app.assets.length > 0);
  }

  function primaryAsset(app) {
    if (!Array.isArray(app.assets) || app.assets.length === 0) return null;
    return app.assets.find((asset) => asset.kind === "apk") || app.assets[0];
  }

  const OBTAINIUM_APP_PREFIX = "obtainium://app/";

  function obtainiumConfig(app) {
    if (!app.obtainium) return null;
    const match = /[?&]r=([^&]+)/.exec(app.obtainium);
    if (!match) return null;
    try {
      const link = decodeURIComponent(match[1]);
      if (!link.startsWith(OBTAINIUM_APP_PREFIX)) return null;
      const config = JSON.parse(link.slice(OBTAINIUM_APP_PREFIX.length));
      return config && config.id && config.url ? config : null;
    } catch {
      return null;
    }
  }

  // Obtainium keys apps by package ID, so variants of the same package cannot
  // coexist. Keep the most recent build of each package for the bulk import.
  function bulkObtainiumConfigs() {
    const isDev = (app) => /(?:^|[-_.])dev(?:[-_.]|$)/i.test(app.name);
    const built = state.apps
      .filter(isBuilt)
      .slice()
      .sort((a, b) => {
        const recent = (b.updated_at || "").localeCompare(a.updated_at || "");
        if (recent) return recent;
        const popular = (b.downloads || 0) - (a.downloads || 0);
        if (popular) return popular;
        const dev = Number(isDev(a)) - Number(isDev(b));
        if (dev) return dev;
        return a.name.length - b.name.length || a.name.localeCompare(b.name);
      });

    const unique = new Map();
    for (const app of built) {
      const config = obtainiumConfig(app);
      if (config && !unique.has(config.id)) unique.set(config.id, config);
    }
    return [...unique.values()];
  }

  function initBulkImport() {
    const configs = bulkObtainiumConfigs();
    if (configs.length === 0) return;

    const builds = state.apps.filter(isBuilt).length;
    if (els.obtainiumImportDetail) {
      els.obtainiumImportDetail.textContent =
        builds > configs.length
          ? `${builds.toLocaleString()} builds, one config per package.`
          : `${configs.length.toLocaleString()} apps in one import file.`;
    }

    if (els.obtainiumDownload) {
      const blob = new Blob([JSON.stringify(configs, null, 2)], { type: "application/json" });
      els.obtainiumDownload.href = URL.createObjectURL(blob);
      els.obtainiumDownload.setAttribute("download", "revanced-builder-obtainium.json");
      els.obtainiumDownload.title =
        `Download ${configs.length.toLocaleString()} app configs for Obtainium`;
    }

    if (els.obtainiumImportNote) els.obtainiumImportNote.hidden = false;
  }

  function buildHaystack(app) {
    const assetText = (app.assets || [])
      .map((asset) => `${asset.name} ${asset.kind} ${asset.arch || ""} ${asset.version || ""} ${asset.release || ""}`)
      .join(" ");
    return [app.name, app.table, app.package, app.source, app.brand, app.patch_version, app.version, assetText]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
  }

  function debounce(fn, wait) {
    let timer = 0;
    return (...args) => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => fn(...args), wait);
    };
  }

  let toastTimer = 0;
  function toast(message) {
    els.toast.textContent = message;
    els.toast.classList.add("show");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => els.toast.classList.remove("show"), 2200);
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.top = "-1000px";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      let ok = false;
      try {
        ok = document.execCommand("copy");
      } catch {
        ok = false;
      }
      area.remove();
      return ok;
    }
  }

  /* --------------------------------------------------------------------- */
  /* theme                                                                 */
  /* --------------------------------------------------------------------- */

  const THEME_KEY = "rvb-theme";

  function applyTheme(theme) {
    const next = theme === "light" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    if (els.themeColor) {
      els.themeColor.setAttribute("content", next === "dark" ? "#0d0b14" : "#f7f5fc");
    }
    if (els.themeToggle) {
      els.themeToggle.setAttribute(
        "aria-label",
        next === "dark" ? "Switch to light theme" : "Switch to dark theme",
      );
      els.themeToggle.title = next === "dark" ? "Switch to light theme" : "Switch to dark theme";
    }
  }

  function initTheme() {
    let stored = null;
    try {
      stored = localStorage.getItem(THEME_KEY);
    } catch {
      stored = null;
    }
    let paramTheme = null;
    try {
      paramTheme = new URLSearchParams(window.location.search).get("theme");
    } catch {
      paramTheme = null;
    }
    const preferred = paramTheme === "dark" || paramTheme === "light" ? paramTheme : null;
    const prefersLight = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
    applyTheme(preferred || stored || (prefersLight ? "light" : "dark"));

    els.themeToggle?.addEventListener("click", () => {
      const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
      applyTheme(next);
      try {
        localStorage.setItem(THEME_KEY, next);
      } catch {
        /* storage may be unavailable */
      }
    });
  }

  /* --------------------------------------------------------------------- */
  /* rendering                                                             */
  /* --------------------------------------------------------------------- */

  function sourceBadge(app) {
    const version = app.patch_version
      ? `<span class="badge-muted">· patches ${esc(app.patch_version)}</span>`
      : "";
    return `<a class="badge source" href="${esc(safeUrl(app.source_url))}" target="_blank" rel="noopener" title="Patches source: ${esc(app.source)}"><span class="source-name">${esc(app.source)}</span> ${version}</a>`;
  }

  function archBadges(app) {
    const arches = [];
    const kinds = [];
    for (const asset of app.assets || []) {
      if (asset.arch && !arches.includes(asset.arch)) arches.push(asset.arch);
      if (asset.kind && !kinds.includes(asset.kind)) kinds.push(asset.kind);
    }
    if (kinds.length === 0) kinds.push(app.build_mode === "module" ? "module" : "apk");
    const kindBadges = kinds
      .map((kind) => `<span class="badge chip">${esc(kind === "module" ? "module" : "apk")}</span>`)
      .join("");
    const archs = arches
      .slice(0, 3)
      .map((arch) => `<span class="badge chip">${esc(arch)}</span>`)
      .join("");
    return kindBadges + archs;
  }

  function downloadsDetails(app) {
    if (!Array.isArray(app.assets) || app.assets.length < 2) return "";
    const rows = app.assets
      .map((asset) => {
        const meta = [formatBytes(asset.size), asset.release ? `#${asset.release}` : ""]
          .filter(Boolean)
          .join(" · ");
        return `<li><a href="${esc(safeUrl(asset.url))}" target="_blank" rel="noopener">${esc(assetLabel(asset))} ${ICONS.external}<span class="file-meta">${esc(meta)}</span></a></li>`;
      })
      .join("");
    return `<details class="downloads"><summary>All downloads (${app.assets.length})</summary><ul>${rows}</ul></details>`;
  }

  function cardHTML(app) {
    const primary = primaryAsset(app);
    const built = isBuilt(app);
    const statusTitle = built ? `Built${app.updated_at ? ` ${relativeDate(app.updated_at)}` : ""}` : "Not built yet";
    const statusClass = built ? "built" : app.status === "failed" ? "failed" : "";
    const version = app.version ? `<span class="version-badge" title="Patched app version">${esc(versionLabel(app.version))}</span>` : "";
    const packageLine = app.package
      ? `<code class="package" title="Android package ID">${esc(app.package)}</code>`
      : "";
    const download = primary
      ? `<a class="btn btn-ghost" href="${esc(safeUrl(primary.url))}" target="_blank" rel="noopener" title="Download ${esc(primary.name)}">${ICONS.download}<span>Download</span></a>`
      : `<a class="btn btn-ghost" aria-disabled="true" href="#" title="No release asset yet">${ICONS.download}<span>Download</span></a>`;
    const copyTitle = `Copy Obtainium link for ${app.name}`;
    const icon = app.icon || (app.package ? `icons/${app.package}.png` : "");
    const iconHTML = icon
      ? `<img class="app-icon" src="${esc(icon)}" alt="" width="40" height="40" loading="lazy" decoding="async" onerror="this.remove()">`
      : "";

    return `<article class="app-card">
      <div class="card-head">
        <div class="app-title">
          ${iconHTML}
          <span class="status-dot ${statusClass}" title="${esc(statusTitle)}" aria-label="${esc(statusTitle)}"></span>
          <h3>${esc(app.name)}</h3>
        </div>
        ${version}
      </div>
      ${packageLine}
      <div class="badges">${sourceBadge(app)}</div>
      <div class="badges">${archBadges(app)}</div>
      <div class="card-actions">
        <a class="btn btn-primary grow" href="${esc(safeUrl(app.obtainium))}" title="Add ${esc(app.name)} to Obtainium">${ICONS.obtainium}<span>Obtainium</span></a>
        ${download}
        <button class="btn copy-btn" type="button" data-copy="${esc(app.obtainium)}" title="${esc(copyTitle)}" aria-label="${esc(copyTitle)}">${ICONS.copy}</button>
      </div>
      ${downloadsDetails(app)}
    </article>`;
  }

  function filteredApps() {
    const query = state.query.trim().toLowerCase();
    const list = state.apps.filter((app) => {
      if (state.source !== "all" && app.source !== state.source) return false;
      if (!query) return true;
      return app._haystack.includes(query);
    });

    const byName = (a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" });

    list.sort((a, b) => {
      switch (state.sort) {
        case "name":
          return byName(a, b);
        case "source":
          return a.source.localeCompare(b.source, undefined, { sensitivity: "base" }) || byName(a, b);
        case "downloads":
          return (b.downloads || 0) - (a.downloads || 0) || byName(a, b);
        case "recent":
        default:
          return (b.updated_at || "").localeCompare(a.updated_at || "") || byName(a, b);
      }
    });

    return list;
  }

  function updateResultCount(shown) {
    const total = state.apps.length;
    const sources = state.data?.counts?.sources ?? 0;
    if (shown === total && state.source === "all" && !state.query.trim()) {
      els.resultCount.textContent = `${total.toLocaleString()} apps across ${sources} patch sources`;
    } else {
      els.resultCount.textContent = `Showing ${shown.toLocaleString()} of ${total.toLocaleString()} apps`;
    }
  }

  function render() {
    if (!state.data) return;
    const list = filteredApps();
    updateResultCount(list.length);

    if (list.length === 0) {
      els.grid.innerHTML = "";
      els.grid.setAttribute("aria-busy", "false");
      els.empty.hidden = false;
      return;
    }

    els.empty.hidden = true;
    els.grid.innerHTML = list.map(cardHTML).join("");
    els.grid.setAttribute("aria-busy", "false");
  }

  function renderSources() {
    const select = els.source;
    const sources = state.data?.sources || [];
    select.innerHTML = "";

    const all = document.createElement("option");
    all.value = "all";
    all.textContent = `All patch sources (${state.apps.length})`;
    select.appendChild(all);

    for (const source of sources) {
      const option = document.createElement("option");
      option.value = source.source;
      option.textContent = `${source.source} (${source.apps})`;
      select.appendChild(option);
    }
  }

  function syncUrl() {
    try {
      const params = new URLSearchParams();
      if (state.query.trim()) params.set("q", state.query.trim());
      if (state.source !== "all") params.set("source", state.source);
      if (state.sort !== "recent") params.set("sort", state.sort);
      const query = params.toString();
      const next = `${window.location.pathname}${query ? `?${query}` : ""}${window.location.hash}`;
      window.history.replaceState(null, "", next);
    } catch {
      /* history may be unavailable on file:// */
    }
  }

  function readUrlState() {
    try {
      const params = new URLSearchParams(window.location.search);
      state.query = params.get("q") || "";
      state.source = params.get("source") || "all";
      const sort = params.get("sort");
      if (["recent", "name", "source", "downloads"].includes(sort)) state.sort = sort;
    } catch {
      /* ignore malformed URLs */
    }
  }

  /* --------------------------------------------------------------------- */
  /* boot                                                                  */
  /* --------------------------------------------------------------------- */

  function showError(message) {
    els.status.hidden = true;
    els.grid.setAttribute("aria-busy", "false");
    els.grid.innerHTML = "";
    els.empty.hidden = false;
    const title = $("h3", els.empty);
    const copy = $("p", els.empty);
    if (title) title.textContent = "Could not load the catalog";
    if (copy) copy.textContent = message;
    if (els.clearFilters) els.clearFilters.hidden = true;
    els.resultCount.textContent = "Catalog unavailable";
  }

  function applyMeta(data) {
    if (data.repo_url) {
      if (els.repoLink) els.repoLink.href = data.repo_url;
      if (els.readmeLink) els.readmeLink.href = data.readme_url || `${data.repo_url}#build-status`;
    }
    if (data.releases_url && els.releasesLink) els.releasesLink.href = data.releases_url;

    els.statApps.textContent = (data.counts?.apps ?? data.apps.length).toLocaleString();
    els.statBuilt.textContent = (data.counts?.built ?? 0).toLocaleString();
    els.statSources.textContent = (data.counts?.sources ?? 0).toLocaleString();

    const generated = formatDateTime(data.generated_at);
    const release = data.latest_release ? ` · release ${data.latest_release}` : "";
    els.updatedNote.textContent = generated ? `Updated ${generated}${release}` : "Live data from GitHub releases";
    els.footerUpdated.textContent = generated ? `Catalog generated ${generated}.` : "";
  }

  async function boot() {
    initTheme();
    readUrlState();

    try {
      const response = await fetch(`data.json?v=${Date.now()}`, {
        cache: "no-store",
        headers: { Accept: "application/json" },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (!data || !Array.isArray(data.apps)) throw new Error("Invalid data.json");

      state.data = data;
      state.apps = data.apps.map((app) => ({ ...app, _haystack: buildHaystack(app) }));

      applyMeta(data);
      renderSources();
      initBulkImport();

      els.search.value = state.query;
      els.searchClear.hidden = !state.query;
      els.sort.value = state.sort;
      els.source.value = state.source;
      if (els.source.value !== state.source) {
        state.source = "all";
        els.source.value = "all";
      }

      els.status.hidden = true;
      render();
    } catch (error) {
      console.error(error);
      showError(
        "Open the site through a local server (for example: python3 -m http.server) or the deployed GitHub Pages URL. The catalogue is loaded from data.json.",
      );
    }
  }

  els.search?.addEventListener(
    "input",
    debounce(() => {
      state.query = els.search.value;
      els.searchClear.hidden = !state.query;
      syncUrl();
      render();
    }, 60),
  );

  els.search?.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && state.query) {
      els.search.value = "";
      state.query = "";
      els.searchClear.hidden = true;
      syncUrl();
      render();
    }
  });

  els.searchClear?.addEventListener("click", () => {
    els.search.value = "";
    state.query = "";
    els.searchClear.hidden = true;
    syncUrl();
    render();
    els.search.focus();
  });

  els.source?.addEventListener("change", () => {
    state.source = els.source.value;
    syncUrl();
    render();
  });

  els.sort?.addEventListener("change", () => {
    state.sort = els.sort.value;
    syncUrl();
    render();
  });

  els.clearFilters?.addEventListener("click", () => {
    state.query = "";
    state.source = "all";
    state.sort = "recent";
    els.search.value = "";
    els.searchClear.hidden = true;
    els.source.value = "all";
    els.sort.value = "recent";
    syncUrl();
    render();
    els.search.focus();
  });

  els.grid?.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-copy]");
    if (!button) return;
    const ok = await copyText(button.dataset.copy || "");
    toast(ok ? "Obtainium link copied" : "Could not copy the link");
  });

  boot();
})();
