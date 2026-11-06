// Points the Download buttons at the latest release's .dmg (or .zip) asset and shows
// its version. If the GitHub API can't be reached, the links keep their
// static href (the releases/latest page) and their static label.
(function () {
  var FALLBACK = "https://github.com/onurozcan/omux/releases/latest";
  var links = document.querySelectorAll("[data-download]");
  var labels = document.querySelectorAll("[data-download-label]");
  var versions = document.querySelectorAll("[data-release-version]");
  var sizes = document.querySelectorAll("[data-release-size]");

  if (typeof fetch !== "function") return;

  fetch("https://api.github.com/repos/onurozcan/omux/releases/latest", {
    headers: { Accept: "application/vnd.github+json" }
  })
    .then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    })
    .then(function (release) {
      var assets = Array.isArray(release.assets) ? release.assets : [];
      // Prefer the disk image; older releases only have a zip.
      var zip = assets.find(function (a) {
        return typeof a.name === "string" && /\.dmg$/i.test(a.name);
      }) || assets.find(function (a) {
        return typeof a.name === "string" && /\.zip$/i.test(a.name);
      });
      var version = String(release.tag_name || "").replace(/^v/, "");
      var href = zip && /^https:\/\/github\.com\//.test(zip.browser_download_url)
        ? zip.browser_download_url
        : FALLBACK;

      links.forEach(function (a) { a.href = href; });
      if (version) {
        labels.forEach(function (a) { a.textContent = "Download omux " + version + " for macOS"; });
        versions.forEach(function (el) { el.textContent = version; });
      }
      if (zip && typeof zip.size === "number" && zip.size > 0) {
        var mb = (zip.size / (1024 * 1024)).toFixed(1);
        var kind = /\.dmg$/i.test(zip.name) ? "dmg" : "zip";
        sizes.forEach(function (el) { el.textContent = mb + " MB " + kind; });
      }
    })
    .catch(function () {
      // Keep the static fallback.
    });
})();

// Reports Download and GitHub taps to Google Analytics as `download_click` and
// `github_click`, with where on the page the link sits. No-op if the tag is
// blocked or hasn't loaded.
(function () {
  function place(a) {
    var el = a;
    while (el && el !== document.body) {
      if (el.tagName === "HEADER") return "header";
      if (el.tagName === "FOOTER") return "footer";
      if (el.id) return el.id;
      if (el.classList && el.classList.contains("hero")) return "hero";
      el = el.parentElement;
    }
    return "body";
  }
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a || typeof window.gtag !== "function") return;
    var href = a.getAttribute("href") || "";
    var name = null;
    if (a.hasAttribute("data-download") || /github\.com\/onurozcan\/omux\/releases/.test(href) || /\.(dmg|zip)$/i.test(href)) {
      name = "download_click";
    } else if (/^https:\/\/github\.com\/onurozcan\/omux/.test(href)) {
      name = "github_click";
    }
    if (!name) return;
    window.gtag("event", name, {
      link_url: a.href,
      link_text: (a.textContent || "").trim().slice(0, 80),
      placement: place(a),
      page_path: location.pathname
    });
  });
})();
