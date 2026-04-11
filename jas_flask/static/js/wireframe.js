/**
 * Wireframe mode: click-to-inspect popovers via /api/spec/<id>.
 */

(function () {
  "use strict";

  document.addEventListener("click", function (e) {
    const el = e.target.closest(".wf-element");
    if (!el) {
      // Click outside: close any open popover
      closePopovers();
      return;
    }
    e.stopPropagation();
    const elementId = el.getAttribute("data-element-id");
    if (!elementId) return;

    fetch("/api/spec/" + encodeURIComponent(elementId))
      .then(function (r) { return r.json(); })
      .then(function (spec) { showPopover(el, spec); })
      .catch(function (err) { console.error("Failed to load spec:", err); });
  });

  function closePopovers() {
    document.querySelectorAll(".wf-popover").forEach(function (p) { p.remove(); });
  }

  function showPopover(target, spec) {
    closePopovers();

    var div = document.createElement("div");
    div.className = "wf-popover card shadow";

    var title = spec.summary || spec.id || "Element";
    var html = '<div class="card-header d-flex align-items-center">' +
      '<strong>' + escapeHtml(title) + '</strong>' +
      '<button class="btn-close btn-sm ms-auto" onclick="this.closest(\'.wf-popover\').remove()"></button>' +
      '</div>';

    html += '<div class="card-body">';

    if (spec.description) {
      html += '<p>' + escapeHtml(spec.description) + '</p>';
    }

    html += '<table class="table table-sm table-borderless mb-0" style="font-size:11px">';

    if (spec.type) {
      html += row("Type", '<code>' + escapeHtml(spec.type) + '</code>');
    }
    if (spec.id) {
      html += row("ID", '<code>' + escapeHtml(spec.id) + '</code>');
    }
    if (spec.tier) {
      html += row("Tier", '<span class="badge bg-secondary">T' + spec.tier + '</span>');
    }
    if (spec.behavior && spec.behavior.length) {
      html += row("Behavior", '<pre>' + escapeHtml(JSON.stringify(spec.behavior, null, 2)) + '</pre>');
    }
    if (spec.style && Object.keys(spec.style).length) {
      html += row("Style", '<pre>' + escapeHtml(JSON.stringify(spec.style, null, 2)) + '</pre>');
    }
    if (spec.bind && Object.keys(spec.bind).length) {
      html += row("Bind", '<pre>' + escapeHtml(JSON.stringify(spec.bind, null, 2)) + '</pre>');
    }
    if (spec.alternates) {
      html += row("Alternates", '<pre>' + escapeHtml(JSON.stringify(spec.alternates, null, 2)) + '</pre>');
    }
    if (spec.menu) {
      html += row("Menu", '<pre>' + escapeHtml(JSON.stringify(spec.menu, null, 2)) + '</pre>');
    }

    html += '</table></div>';
    div.innerHTML = html;

    document.body.appendChild(div);

    // Position near target
    var rect = target.getBoundingClientRect();
    var popW = 380;
    var left = rect.right + 10;
    if (left + popW > window.innerWidth) {
      left = rect.left - popW - 10;
    }
    if (left < 0) left = 10;
    var top = rect.top + window.scrollY;
    if (top + 300 > window.innerHeight + window.scrollY) {
      top = Math.max(10, window.innerHeight + window.scrollY - 350);
    }
    div.style.left = left + "px";
    div.style.top = top + "px";
  }

  function row(label, value) {
    return '<tr><td class="fw-bold text-nowrap align-top pe-2">' + label + '</td><td>' + value + '</td></tr>';
  }

  function escapeHtml(str) {
    if (!str) return "";
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

})();
