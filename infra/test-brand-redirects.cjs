const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const context = {};
vm.runInNewContext(fs.readFileSync(__dirname + '/cloudfront-index-rewrite.js', 'utf8'), context);

test('old project and policy links redirect permanently', () => {
  for (const suffix of ['', '-privacy', '-terms']) {
    const result = context.handler({request: {uri: `/greybot${suffix}.html`, querystring: {}}});
    assert.equal(result.statusCode, 301);
    assert.equal(result.headers.location.value, `/spoot${suffix}.html`);
  }
});

test('redirect keeps encoded values and repeated query parameters', () => {
  const result = context.handler({request: {uri: '/greybot.html', querystring: {
    source: {value: 'a%26b'}, tag: {multiValue: [{value: 'one'}, {value: 'two'}]}
  }}});
  assert.equal(result.headers.location.value, '/spoot.html?source=a%26b&tag=one&tag=two');
});

test('existing directory, asset and new-page routes stay valid', () => {
  for (const [uri, expected] of [['/', '/index.html'], ['/section', '/section/index.html'],
    ['/section/', '/section/index.html'], ['/spoot.html', '/spoot.html'], ['/favicon.ico', '/favicon.ico']]) {
    assert.equal(context.handler({request: {uri}}).uri, expected);
  }
});
