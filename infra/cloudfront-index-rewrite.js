// CloudFront Function (viewer-request) -- directory index rewriting.
//
// The S3 origin is a REST origin behind OAC, not a website endpoint, so it has
// no concept of a directory index. CloudFront's DefaultRootObject only applies
// at the distribution root, so "/" serves index.html but "/section/" 403s.
//
// Maps:  /section/      -> /section/index.html
//        /section       -> /section/index.html
// Leaves anything with a file extension untouched.
function handler(event) {
    var request = event.request;
    var uri = request.uri;

    // Keep bookmarks and legal-policy links working after the spoot rename.
    var moved = {
        '/greybot.html': '/spoot.html',
        '/greybot-privacy.html': '/spoot-privacy.html',
        '/greybot-terms.html': '/spoot-terms.html'
    };
    if (Object.prototype.hasOwnProperty.call(moved, uri)) {
        var pairs = [];
        var query = request.querystring || {};
        Object.keys(query).forEach(function (key) {
            var values = query[key].multiValue || [query[key]];
            values.forEach(function (entry) { pairs.push(key + '=' + entry.value); });
        });
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                location: { value: moved[uri] + (pairs.length ? '?' + pairs.join('&') : '') },
                'cache-control': { value: 'public, max-age=3600' }
            }
        };
    }

    if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
    } else if (!uri.includes('.')) {
        request.uri = uri + '/index.html';
    }
    return request;
}
