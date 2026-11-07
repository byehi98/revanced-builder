(() => {
  "use strict";

  const PREFIX = "obtainium://apps/";
  const status = document.getElementById("redirectStatus");
  const fallback = document.getElementById("redirectFallback");
  const retry = document.getElementById("redirectRetry");
  const download = document.getElementById("redirectDownload");
  const hint = document.getElementById("redirectHint");

  let deepLink = "";
  try {
    const hash = window.location.hash.slice(1);
    if (hash) deepLink = decodeURIComponent(hash);
  } catch {
    deepLink = "";
  }

  if (!deepLink.startsWith(PREFIX)) {
    if (status) status.textContent = "This import link is incomplete. Go back to the catalog and try again.";
    if (fallback) fallback.hidden = false;
    if (retry) retry.hidden = true;
    if (download) download.hidden = true;
    return;
  }

  if (retry) retry.href = deepLink;

  try {
    const payload = decodeURIComponent(deepLink.slice(PREFIX.length));
    const configs = JSON.parse(payload);
    const blob = new Blob([JSON.stringify(configs, null, 2)], { type: "application/json" });
    if (download) download.href = URL.createObjectURL(blob);
  } catch {
    if (download) download.hidden = true;
  }

  let leftPage = false;
  const markLeft = () => {
    leftPage = true;
  };
  window.addEventListener("blur", markLeft);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) markLeft();
  });

  // The fragment keeps the large payload out of the HTTP request, so it is not
  // subject to the URL length limits of a query-string redirect service.
  window.location.href = deepLink;

  window.setTimeout(() => {
    if (leftPage) {
      if (status) status.textContent = "Obtainium should be open now.";
      if (hint) hint.textContent = "Confirm the bulk import in Obtainium to finish. Your browser may ask for permission to open the app.";
      return;
    }
    if (status) status.textContent = "Obtainium did not open automatically.";
    if (hint) hint.textContent = "Install Obtainium, or download the import file and open it from Settings → Import/export → Obtainium import.";
    if (fallback) fallback.hidden = false;
  }, 2200);
})();
