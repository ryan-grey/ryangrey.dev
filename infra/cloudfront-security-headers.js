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
//   Homepage only: script-src 'self' and connect-src 'self' allow the local
//   contribution script and JSON feed. Inline handlers, inline scripts, eval,
//   and third-party scripts/connections remain blocked. Other pages keep
//   script-src 'none' and connect-src 'none'.
//   img-src  ... data:  -- REQUIRED. The favicon is an inline data:image/svg+xml
//                          URI; without `data:` the tab icon silently vanishes.
//   style-src 'unsafe-inline'
//                       -- the CSS is one inline <style> block. The strict
//                          alternative is a sha256- hash of its exact contents,
//                          which goes stale on every CSS edit and fails silently
//                          to an unstyled page.
//   X-XSS-Protection is deliberately NOT set: it is deprecated and can
//   introduce vulnerabilities when a real CSP is present.

var CSP_STRICT = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests";
var CSP_HOME = CSP_STRICT.replace("script-src 'none'", "script-src 'self'; script-src-attr 'none'").replace("connect-src 'none'", "connect-src 'self'");

function handler(event) {
    var h = event.response.headers;
    h['strict-transport-security'] = { value: 'max-age=63072000; includeSubDomains; preload' };
    h['x-content-type-options']    = { value: 'nosniff' };
    h['x-frame-options']           = { value: 'DENY' };
    h['referrer-policy']           = { value: 'strict-origin-when-cross-origin' };
    var uri = event.request.uri;
    h['content-security-policy'] = { value: uri === '/' || uri === '/index.html' ? CSP_HOME : CSP_STRICT };
    h['permissions-policy']        = { value: 'accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()' };
    return event.response;
}
