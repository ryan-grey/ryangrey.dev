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

function handler(event) {
    var h = event.response.headers;
    var uri = event.request.uri;
    h['strict-transport-security'] = { value: 'max-age=63072000; includeSubDomains; preload' };
    h['x-content-type-options']    = { value: 'nosniff' };
    h['x-frame-options']           = { value: 'DENY' };
    h['referrer-policy']           = { value: 'strict-origin-when-cross-origin' };
    h['content-security-policy']   = { value: uri.indexOf('/ask') === 0 ? CSP_ASK : CSP_STRICT };
    h['permissions-policy']        = { value: 'accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()' };
    return event.response;
}
