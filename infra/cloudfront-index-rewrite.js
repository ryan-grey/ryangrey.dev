// CloudFront Function (viewer-request) -- directory index rewriting.
//
// The S3 origin is a REST origin behind OAC, not a website endpoint, so it has
// no concept of a directory index. CloudFront's DefaultRootObject only applies
// at the distribution root, so "/" serves index.html but "/ask/" 403s.
//
// Maps:  /ask/      -> /ask/index.html
//        /ask       -> /ask/index.html
// Leaves anything with a file extension untouched.
function handler(event) {
    var request = event.request;
    var uri = request.uri;

    if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
    } else if (!uri.includes('.')) {
        request.uri = uri + '/index.html';
    }
    return request;
}
