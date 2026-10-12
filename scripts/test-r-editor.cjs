const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Sources/Relay/Resources/Editor/r-language.js'), 'utf8'), context);
let provider;
let tokenType = '';
context.RelayRLanguage.install({ languages: {
  CompletionItemKind: { Snippet: 1 }, CompletionItemInsertTextRule: { InsertAsSnippet: 4 },
  registerCompletionItemProvider(language, p) { assert.equal(language, 'r'); provider = p; }
}, editor: { tokenize() { return [[{offset: 0, type: tokenType}]]; } } });
function complete(text, wordStart = 1) {
  return provider.provideCompletionItems({ getLinesContent: () => [text],
    getValueLength: () => text.length, getLineContent: () => text,
    getWordUntilPosition: () => ({ startColumn: wordStart, endColumn: text.length + 1 })
  }, { lineNumber: 1, column: text.length + 1 }).suggestions;
}
assert.equal(complete('plo').find(x => x.label === 'plot').range.endColumn, 4);
assert.match(complete('plo').find(x => x.label === 'plot').documentation.value, /plot\(x, y/);
assert.equal(complete('plo').find(x => x.label === 'plot').documentation.isTrusted, false);
assert.ok(complete('fun').some(x => x.label === 'function' && x.insertText.includes('${0}')));
for (const type of ['string.r', 'comment.r']) { tokenType = type; assert.equal(complete('plot').length, 0); }
tokenType = '';
for (const prefix of ['stats::', 'pkg:::', 'x$', 'x@']) assert.equal(complete(prefix + 'pl', prefix.length + 1).length, 0);
assert.equal(complete('x'.repeat(1000001)).length, 0);
console.log('R editor snippets: insertion, token guards, namespace/member guards and size limit passed.');
