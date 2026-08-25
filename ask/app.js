/* Ask about Ryan — talks to /api/ask, same origin (CloudFront fronts the Lambda). */
(function () {
  "use strict";
  var form = document.getElementById("f");
  var input = document.getElementById("q");
  var button = document.getElementById("go");
  var out = document.getElementById("answer");

  function render(text, sources, isError) {
    out.className = "show" + (isError ? " err" : "");
    var p = document.createElement("p");
    p.textContent = text;
    out.replaceChildren(p);
    if (sources && sources.length) {
      var d = document.createElement("div");
      d.className = "srcs";
      d.appendChild(document.createTextNode("Drawn from: "));
      sources.forEach(function (s) {
        var el = document.createElement("span");
        el.textContent = s;
        d.appendChild(el);
      });
      out.appendChild(d);
    }
  }

  function ask(question) {
    if (!question) return;
    button.disabled = true;
    render("Thinking…", null, false);
    fetch("/api/ask", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: question })
    })
      .then(function (r) {
        return r.json().then(function (body) { return { ok: r.ok, body: body }; });
      })
      .then(function (res) {
        if (res.ok && res.body.answer) {
          render(res.body.answer, res.body.sources, false);
        } else {
          render(res.body.error || "Something went wrong. Try again.", null, true);
        }
      })
      .catch(function () {
        render("Couldn't reach the assistant. Check your connection and try again.", null, true);
      })
      .then(function () { button.disabled = false; });
  }

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    ask(input.value.trim());
  });

  document.getElementById("ex").addEventListener("click", function (e) {
    var q = e.target.getAttribute("data-q");
    if (q) { input.value = q; ask(q); }
  });
})();
