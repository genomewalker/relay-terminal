const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../Sources/Relay/Resources/Editor/index.html'), 'utf8');
const source = html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const messages = [], models = [];
class Model {
  constructor(text) { this.text = text; this.version = 1; this.history = []; this.listeners = new Set(); this.disposed = false; }
  getValue() { return this.text; }
  getAlternativeVersionId() { return this.version; }
  onDidChangeContent(fn) { this.listeners.add(fn); return { dispose: () => this.listeners.delete(fn) }; }
  edit(text) { this.history.push([this.text, this.version]); this.text = text; this.version++; this.listeners.forEach(fn => fn()); }
  undo() { [this.text, this.version] = this.history.pop(); this.listeners.forEach(fn => fn()); }
  dispose() { this.disposed = true; }
}
class Editor {
  constructor(model) { this.model = model; this.state = { line: 9 }; this.actions = new Map(); }
  getValue() { return this.model.getValue(); }
  addCommand() {}
  addAction(action) {
    assert.ok(action.id && typeof action.run === 'function');
    this.actions.set(action.id, action);
    return { dispose: () => this.actions.delete(action.id) };
  }
  trigger(_, action) { if (action === 'undo') this.model.undo(); }
  focus() {}
  onDidFocusEditorText() {}
  hasTextFocus() { return true; }
  layout() {}
  render() {}
  dispose() {}
  updateOptions() {}
  saveViewState() { return this.state; }
  restoreViewState(state) { this.state = state; }
}
const monaco = {
  KeyMod: { CtrlCmd: 1 }, KeyCode: { KeyS: 2 }, Uri: { file: value => value },
  editor: {
    defineTheme() {},
    createModel(text) { const model = new Model(text); models.push(model); return model; },
    create(_, options) { return new Editor(options.model); },
    createDiffEditor() {
      return { addCommand() {}, dispose() {}, updateOptions() {}, layout() {},
        setModel({original, modified}) { this.original = new Editor(original); this.modified = new Editor(modified); },
        getModifiedEditor() { return this.modified; }, getOriginalEditor() { return this.original; }
      };
    }
  }
};
const requireMock = (_, ready) => ready(); requireMock.config = () => {};
const window = { webkit: { messageHandlers: { relay: { postMessage: msg => messages.push(msg) } } } };
const context = vm.createContext({ window, monaco, require: requireMock,
  RelayRLanguage: { install() {} },
  document: { getElementById() { return {}; }, body: { classList: { add() {} } } } });
vm.runInContext(source, context);
const value = expr => vm.runInContext(expr, context);
const open = id => window.relayOpenDocument({ documentID: id, path: '/tmp/a # unicode λ.txt', content: 'initial', language: 'plaintext' });
const dirty = () => messages.filter(m => m.type === 'dirty').at(-1).dirty;
open('A');
let model = value('currentModel');
model.edit('first edit');
window.relayToggleLocalDiff();
window.relayToggleLocalDiff();
assert.equal(value('currentModel'), model, 'diff toggle must retain the document model');
assert.equal(model.disposed, false);
window.relayUndo(false);
assert.equal(model.getValue(), 'initial');
assert.equal(dirty(), false, 'undo to saved version must clear dirty state');
model.edit('diff undo');
window.relayToggleLocalDiff();
window.relayUndo(false);
assert.equal(model.getValue(), 'initial', 'native undo must target the modified diff editor');
window.relayToggleLocalDiff();
assert.ok(messages.some(m => m.type === 'edited' && m.documentID === 'A'), 'edits must invalidate pending file opens');
model.edit('submitted');
window.relayRequestSave();
model.edit('typed during SSH save');
window.relayMarkSaved('A');
assert.equal(dirty(), true, 'save completion must not mark newer edits saved');
assert.equal(value('savedText'), 'submitted');
model.undo();
assert.equal(dirty(), false, 'undo back to submitted revision must be clean');
model.edit('save one'); window.relayRequestSave();
model.edit('save two'); window.relayRequestSave();
assert.equal(value('pendingSave.content'), 'save one');
window.relayMarkSaved('A');
assert.equal(value('pendingSave.content'), 'save two', 'repeated save queues current revision');
window.relayMarkSaved('A'); assert.equal(dirty(), false);
model.edit('failure'); window.relayRequestSave(); window.relaySaveFailed('A');
assert.equal(value('pendingSave'), null); assert.equal(dirty(), true);
window.relayRequestSave(); open('B');
window.relayMarkSaved('A');
assert.equal(value('savedText'), 'initial', 'stale acknowledgement cannot affect another document');
assert.equal(model.disposed, true, 'replaced documents must release their models');
assert.equal(value('currentModel.listeners.size'), 1, 'diff toggles must not accumulate listeners');
console.log('Editor lifecycle checks passed: undo, diff, in-flight edits, queued saves, failure, stale acknowledgements, disposal.');
