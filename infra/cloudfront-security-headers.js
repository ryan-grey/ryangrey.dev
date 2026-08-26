// CloudFront Function (viewer-response) -- adds security headers to every
// response from the ryangrey.dev distribution.
//
// Why a function and not a response headers policy: this distribution is on
// CloudFront's Free pricing plan, which rejects custom response headers
// policies outright ("InvalidArgument: Distributions with the Free pricing
// plan can't have the following features: Custom response headers policy").
// A viewer-response function is permitted on that plan and sets the same
// headers, so no plan upgrade is needed.
//
// Runtime: cloudfront-js-2.0
// Deploy:  ./infra/deploy-security-headers.sh
//
// CSP notes:
//   script-src 'none'   -- the site has zero <script> tags, so the entire XSS
//                          class is removed rather than mitigated.
//   img-src  ... data:  -- REQUIRED. The favicon is an inline data:image/svg+xml
//                          URI; without `data:` the tab icon silently vanishes.
//   style-src 'unsafe-inline'
//                       -- the CSS is one inline <style> block. The strict
//                          alternative is a sha256- hash of its exact contents,
//                          which goes stale on every CSS edit and fails silently
//                          to an unstyled page. With no JavaScript on the page
//                          there is nothing to weaponise CSS injection against.
//   X-XSS-Protection is deliberately NOT set: it is deprecated and can
//   introduce vulnerabilities when a real CSP is present.

var CSP_STRICT = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";

// The chat page needs its own script and a fetch back to /api/ask on the same
// origin. Scoped to /ask/* so the main page keeps script-src 'none' byte for
// byte -- a second narrow policy, not a weakened first one.
var CSP_ASK = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'none'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";

// The study engine at /quiz signs in with Cognito. The browser does the PKCE token
// exchange itself, which is one fetch to the Cognito hosted domain -- so connect-src
// names that EXACT host and nothing else. No wildcard, no *.amazoncognito.com: only the
// pool's own domain can be reached, so a different pool or a lookalike subdomain is
// still blocked.
//
// This is the /ask precedent applied consistently, not a new concession. The public
// pages keep CSP_STRICT byte for byte, so "zero external requests" remains true of
// everything a visitor can reach without signing in.
//
// The alternative -- proxying the token exchange through Lambda -- was considered and
// rejected: it is a BFF pattern that adds redirect handling, session cookies and new
// failure modes to a single-user private tool.
var COGNITO = "https://ryangrey-study.auth.us-east-1.amazoncognito.com";
var CSP_QUIZ = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'none'; connect-src 'self' " + COGNITO + "; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";

function under(uri, base) {
    return uri === base || uri.indexOf(base + '/') === 0;
}

function handler(event) {
    var h = event.response.headers;
    var uri = event.request.uri;
    h['strict-transport-security'] = { value: 'max-age=63072000; includeSubDomains; preload' };
    h['x-content-type-options']    = { value: 'nosniff' };
    h['x-frame-options']           = { value: 'DENY' };
    h['referrer-policy']           = { value: 'strict-origin-when-cross-origin' };
    var csp = CSP_STRICT;
    // Segment match, not prefix match. `uri.indexOf('/quiz') === 0` also matches
    // /quizzical, which would hand a widened policy to an unrelated path; likewise
    // /askew for the chat policy. Only the exact path or something beneath it counts.
    if (under(uri, '/ask'))       { csp = CSP_ASK; }
    else if (under(uri, '/quiz')) { csp = CSP_QUIZ; }
    h['content-security-policy']   = { value: csp };
    h['permissions-policy']        = { value: 'accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()' };
    return event.response;
}
