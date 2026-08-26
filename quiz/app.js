/* AIF Study Engine — Cognito PKCE in the browser, then same-origin calls to /api/quiz/*.
 *
 * Authorization Code + PKCE with a public client: there is no client secret, so nothing
 * secret ships to the browser. The code_verifier lives in sessionStorage only between the
 * redirect out and the redirect back, and is deleted the moment it is exchanged.
 *
 * Tokens are held in memory, not localStorage. That costs a re-login on refresh and buys
 * immunity to any XSS that outlives the page — a fair trade for a tool one person uses.
 */
(function () {
  "use strict";

  var COGNITO = "https://ryangrey-study.auth.us-east-1.amazoncognito.com";
  var CLIENT_ID = "2han2rpqbpv47m7vhju7nfb9mo";
  var REDIRECT = window.location.origin + "/quiz/";
  var API = "/api/quiz";

  var token = null;
  var state = null;
  var answered = {};

  var $ = function (id) { return document.getElementById(id); };

  // ---------------------------------------------------------------- PKCE

  function random(n) {
    var a = new Uint8Array(n);
    crypto.getRandomValues(a);
    return b64url(a);
  }

  function b64url(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function challenge(verifier) {
    return crypto.subtle
      .digest("SHA-256", new TextEncoder().encode(verifier))
      .then(function (buf) { return b64url(new Uint8Array(buf)); });
  }

  function signIn() {
    var verifier = random(48);
    sessionStorage.setItem("pkce", verifier);
    challenge(verifier).then(function (chal) {
      window.location.href = COGNITO + "/oauth2/authorize"
        + "?client_id=" + encodeURIComponent(CLIENT_ID)
        + "&response_type=code&scope=" + encodeURIComponent("openid email")
        + "&redirect_uri=" + encodeURIComponent(REDIRECT)
        + "&code_challenge_method=S256&code_challenge=" + chal;
    });
  }

  function exchange(code) {
    var verifier = sessionStorage.getItem("pkce");
    sessionStorage.removeItem("pkce");
    if (!verifier) { return Promise.reject(new Error("Missing PKCE verifier — start again.")); }
    var body = "grant_type=authorization_code&client_id=" + encodeURIComponent(CLIENT_ID)
      + "&code=" + encodeURIComponent(code)
      + "&redirect_uri=" + encodeURIComponent(REDIRECT)
      + "&code_verifier=" + encodeURIComponent(verifier);
    return fetch(COGNITO + "/oauth2/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body
    }).then(function (r) {
      if (!r.ok) { throw new Error("Token exchange failed (" + r.status + ")."); }
      return r.json();
    });
  }

  // ---------------------------------------------------------------- API

  function api(path, method, payload) {
    return fetch(API + path, {
      method: method || "GET",
      headers: {
        "authorization": "Bearer " + token,
        "content-type": "application/json"
      },
      body: payload ? JSON.stringify(payload) : undefined
    }).then(function (r) {
      return r.json().then(function (body) {
        if (!r.ok) { throw new Error(body.error || ("Request failed (" + r.status + ")")); }
        return body;
      });
    });
  }

  // ---------------------------------------------------------------- render

  function lessonName(order) {
    var found = null;
    state.course.modules.forEach(function (m) {
      m.lessons.forEach(function (l) { if (l.order === order) { found = m.name + " — " + l.name; } });
    });
    return found;
  }

  function renderProgress() {
    var pct = Math.round((state.throughOrder / state.maxOrder) * 100);
    $("progressbar").style.width = pct + "%";
    $("progresslabel").textContent = state.throughOrder === 0
      ? "Nothing marked complete yet — set your position to start."
      : "Complete through lesson " + state.throughOrder + " of " + state.maxOrder
        + " (" + pct + "%) · " + lessonName(state.throughOrder);

    var pick = $("lessonpick");
    pick.textContent = "";
    state.course.modules.forEach(function (m) {
      var g = document.createElement("optgroup");
      g.label = m.id + " · " + m.name;
      m.lessons.forEach(function (l) {
        var o = document.createElement("option");
        o.value = String(l.order);
        o.textContent = l.order + ". " + l.name;
        if (l.order === state.throughOrder) { o.selected = true; }
        g.appendChild(o);
      });
      pick.appendChild(g);
    });
  }

  function renderMisses() {
    var box = $("misses");
    box.textContent = "";
    var open = state.misses.filter(function (m) { return m.status === "OPEN"; });
    if (!state.misses.length) {
      box.className = "card muted";
      box.textContent = "No misses logged yet.";
      return;
    }
    box.className = "card";
    state.misses.forEach(function (m) {
      var row = document.createElement("div");
      row.className = "miss";
      var pill = document.createElement("span");
      if (m.status === "RETIRED") { pill.className = "pill ret"; pill.textContent = "retired"; }
      else if (m.due) { pill.className = "pill due"; pill.textContent = "due"; }
      else { pill.className = "pill"; pill.textContent = (m.correctStreak || 0) + "/2"; }
      var txt = document.createElement("div");
      var strong = document.createElement("div");
      strong.textContent = m.concept || m.sk;
      var why = document.createElement("div");
      why.className = "muted";
      why.textContent = m.rule || "";
      txt.appendChild(strong); txt.appendChild(why);
      row.appendChild(pill); row.appendChild(txt);
      box.appendChild(row);
    });
    var note = document.createElement("p");
    note.className = "muted";
    note.style.margin = "10px 0 0";
    note.textContent = open.length + " open · due items are prepended to the next quiz as a warm-up.";
    box.appendChild(note);
  }

  function renderSessions() {
    var box = $("sessions");
    box.textContent = "";
    if (!state.sessions.length) {
      box.className = "card muted";
      box.textContent = "No sessions recorded yet.";
      return;
    }
    box.className = "card";
    state.sessions.slice(0, 10).forEach(function (s) {
      var row = document.createElement("div");
      row.className = "miss";
      var pill = document.createElement("span");
      pill.className = "pill";
      var pct = s.total ? Math.round((s.correct / s.total) * 100) : 0;
      pill.textContent = pct + "%";
      var txt = document.createElement("div");
      txt.textContent = (s.date || "").slice(0, 10) + " · " + s.correct + "/" + s.total
        + " · through lesson " + (s.throughOrder || 0);
      row.appendChild(pill); row.appendChild(txt);
      box.appendChild(row);
    });
  }

  function questionCard(q, isWarmup, index) {
    var wrap = document.createElement("div");
    wrap.className = "q";
    var tag = document.createElement("div");
    tag.className = "tag" + (isWarmup ? " warm" : "");
    tag.textContent = (isWarmup ? "Warm-up · " : "") + q.lessonId + (q.domain ? " · " + q.domain : "");
    var stem = document.createElement("p");
    stem.className = "stem";
    stem.textContent = (index + 1) + ". " + q.question;
    wrap.appendChild(tag); wrap.appendChild(stem);

    var why = document.createElement("div");
    why.className = "why";
    why.hidden = true;

    var buttons = [];
    q.choices.forEach(function (choice, i) {
      var b = document.createElement("button");
      b.className = "choice";
      b.type = "button";
      b.textContent = choice;
      b.addEventListener("click", function () {
        if (answered[q._key]) { return; }
        var correct = i === q.answerIndex;
        answered[q._key] = correct;
        buttons.forEach(function (other, j) {
          other.disabled = true;
          if (j === q.answerIndex) { other.className = "choice right"; }
          else if (j === i) { other.className = "choice wrong"; }
        });
        why.hidden = false;
        why.textContent = (correct ? "Correct. " : "Not quite. ") + (q.explanation || "");
        api("/answer", "POST", {
          correct: correct,
          conceptId: q.conceptId || q.lessonId + ":" + q.question.slice(0, 40),
          lessonId: q.lessonId,
          domain: q.domain,
          concept: q.question,
          explanation: q.explanation,
          chosen: choice
        }).catch(function (e) {
          why.textContent += "  (not recorded: " + e.message + ")";
        });
        maybeFinish();
      });
      buttons.push(b);
      wrap.appendChild(b);
    });
    wrap.appendChild(why);
    return wrap;
  }

  var currentTotal = 0;

  function maybeFinish() {
    var keys = Object.keys(answered);
    if (keys.length < currentTotal) { return; }
    var correct = keys.filter(function (k) { return answered[k]; }).length;
    var box = $("score");
    box.hidden = false;
    box.textContent = "";
    var h = document.createElement("div");
    h.textContent = "Session complete: " + correct + "/" + currentTotal
      + " (" + Math.round((correct / currentTotal) * 100) + "%)";
    box.appendChild(h);
    api("/session", "POST", { correct: correct, total: currentTotal, byDomain: {} })
      .then(refresh)
      .catch(function () { /* score already shown; a failed write is not worth a scare */ });
  }

  function generate() {
    var btn = $("gen");
    btn.disabled = true;
    $("genstatus").className = "muted";
    $("genstatus").textContent = "Generating from lessons 1–" + state.throughOrder + "…";
    $("score").hidden = true;
    answered = {};
    api("/generate", "POST", { count: Number($("count").value) || 8 })
      .then(function (data) {
        var box = $("quiz");
        box.textContent = "";
        var all = [];
        (data.warmups || []).forEach(function (q) { q._warm = true; all.push(q); });
        (data.questions || []).forEach(function (q) { all.push(q); });
        currentTotal = all.length;
        all.forEach(function (q, i) {
          q._key = "q" + i;
          box.appendChild(questionCard(q, q._warm, i));
        });
        var bits = [all.length + " questions"];
        if (data.warmups && data.warmups.length) { bits.push(data.warmups.length + " warm-up"); }
        if (data.droppedOutOfScope) { bits.push(data.droppedOutOfScope + " dropped out of scope"); }
        $("genstatus").textContent = bits.join(" · ");
      })
      .catch(function (e) {
        $("genstatus").className = "err";
        $("genstatus").textContent = e.message;
      })
      .then(function () { btn.disabled = false; });
  }

  function refresh() {
    return api("/state").then(function (data) {
      state = data;
      renderProgress();
      renderMisses();
      renderSessions();
    });
  }

  // ---------------------------------------------------------------- boot

  function start(claimsEmail) {
    $("gate").hidden = true;
    $("app").hidden = false;
    $("who").textContent = claimsEmail ? "Signed in as " + claimsEmail : "Signed in";
    $("saveprogress").addEventListener("click", function () {
      api("/progress", "POST", { throughOrder: Number($("lessonpick").value) })
        .then(refresh)
        .catch(function (e) { $("progresslabel").textContent = e.message; });
    });
    $("gen").addEventListener("click", generate);
    $("signout").addEventListener("click", function () {
      token = null;
      window.location.href = COGNITO + "/logout?client_id=" + encodeURIComponent(CLIENT_ID)
        + "&logout_uri=" + encodeURIComponent(REDIRECT);
    });
    refresh().catch(function (e) {
      $("progresslabel").textContent = e.message;
    });
  }

  function emailFromIdToken(idToken) {
    try {
      var body = idToken.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      return JSON.parse(atob(body)).email || null;
    } catch (e) { return null; }
  }

  function boot() {
    $("signin").addEventListener("click", signIn);
    var params = new URLSearchParams(window.location.search);
    var code = params.get("code");
    if (params.get("error")) {
      $("gatemsg").className = "sub err";
      $("gatemsg").textContent = "Sign-in failed: " + params.get("error");
      $("signin").hidden = false;
      return;
    }
    if (!code) {
      $("gatemsg").textContent = "This is a private study tool. Sign in to continue.";
      $("signin").hidden = false;
      return;
    }
    exchange(code).then(function (t) {
      token = t.id_token;
      // Drop ?code= so a refresh does not retry a one-time code that is already spent.
      window.history.replaceState({}, "", REDIRECT);
      start(emailFromIdToken(t.id_token));
    }).catch(function (e) {
      $("gatemsg").className = "sub err";
      $("gatemsg").textContent = e.message;
      $("signin").hidden = false;
    });
  }

  boot();
})();
