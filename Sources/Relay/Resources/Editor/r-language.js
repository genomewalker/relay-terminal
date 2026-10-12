/* Offline editing aids. Runtime/package intelligence belongs to the host-bound
 * language server; these snippets never inspect or evaluate an R session. */
(function (root) {
  const snippets = [
    ['function', 'function(${1:arguments}) {\n\t${0}\n}', 'Function definition'],
    ['if', 'if (${1:condition}) {\n\t${0}\n}', 'Conditional block'],
    ['for', 'for (${1:item} in ${2:items}) {\n\t${0}\n}', 'For loop'],
    ['library', 'library(${1:package})', 'Load a package'],
    ['plot', 'plot(${1:x}, ${2:y})', 'Plot x and y'],
    ['data.frame', 'data.frame(${1:column} = ${2:values})', 'Create a data frame'],
    ['tryCatch', 'tryCatch({\n\t${1}\n}, error = function(e) {\n\t${0}\n})', 'Handle an error']
  ];
  const documentation = {
    function: ['function(arguments) body', 'Define a function. Arguments can have defaults; the last evaluated expression is returned.'],
    if: ['if (condition) expr else expr', 'Run a branch when condition is a single TRUE or FALSE value.'],
    for: ['for (item in sequence) expr', 'Evaluate the body once for each element of a sequence.'],
    library: ['library(package, help, character.only = FALSE, …)', 'Attach an installed package. Use character.only = TRUE when package is held in a variable.'],
    plot: ['plot(x, y, …)', 'Generic plotting function. The selected method determines the arguments. For numeric vectors, x and y supply point coordinates.\n\nExample: `plot(1:10, (1:10)^2)`'],
    'data.frame': ['data.frame(…, row.names = NULL, check.names = TRUE)', 'Build a data frame from named columns. Compatible column lengths are required.\n\nExample: `data.frame(x = 1:3, y = c(2, 4, 6))`'],
    tryCatch: ['tryCatch(expr, …, finally)', 'Evaluate an expression with condition handlers. An error handler receives the condition as its argument.']
  };
  function install(monaco, request) {
    const offline = monaco.languages.registerCompletionItemProvider('r', {
      provideCompletionItems(model, position) {
        // Do not offer code inside strings/comments (including multiline ones).
        const lines = model.getLinesContent();
        if (lines.length > 20000 || model.getValueLength() > 1000000) return { suggestions: [] };
        const tokens = monaco.editor.tokenize(lines.join('\n'), 'r')[position.lineNumber - 1] || [];
        const offset = position.column - 2;
        const token = tokens.filter(t => t.offset <= offset).at(-1);
        if (token && /comment|string/.test(token.type)) return { suggestions: [] };
        const word = model.getWordUntilPosition(position);
        const before = model.getLineContent(position.lineNumber).slice(0, word.startColumn - 1);
        if (/(:::{0,1}|\$|@)\s*$/.test(before)) return { suggestions: [] };
        return { suggestions: snippets.map(([label, insertText, detail]) => ({
          label, insertText, detail: 'R snippet · ' + detail,
          documentation: { value: '`' + documentation[label][0] + '`\n\n' + documentation[label][1] + '\n\nOffline R reference; not live session completion.', isTrusted: false },
          kind: monaco.languages.CompletionItemKind.Snippet,
          insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
          range: { startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
            startColumn: word.startColumn, endColumn: word.endColumn }
        })) };
      }
    });
    if (!request) return offline;
    const live = monaco.languages.registerCompletionItemProvider('r', {
      triggerCharacters: ['$', ':', '('],
      async provideCompletionItems(model, position, context, cancellation) {
        if (model.getValueLength() > 1000000) return {suggestions: []};
        const line = model.getLineContent(position.lineNumber).slice(0, position.column - 1);
        const library = /\b(?:library|require)\(\s*["']?([\w.]*)$/.exec(line);
        const tokens = monaco.editor.tokenize(model.getLinesContent().join('\n'), 'r')[position.lineNumber - 1] || [];
        const token = tokens.filter(t => t.offset <= position.column - 2).at(-1);
        if (!library && token && /comment|string/.test(token.type)) return {suggestions: []};
        if (token && /comment/.test(token.type)) return {suggestions: []};
        const version = model.getVersionId();
        const snapshot = await request('rCompletion');
        if (!snapshot || cancellation.isCancellationRequested || model.isDisposed() || version !== model.getVersionId()) return {suggestions: []};
        const member = /([\w.]+)\$([\w.]*)$/.exec(line);
        const namespace = /([\w.]+)::([\w.]*)$/.exec(line);
        if (/:::|@$/.test(line)) return {suggestions: []};
        const prefix = (library?.[1] ?? member?.[2] ?? namespace?.[2] ?? model.getWordUntilPosition(position).word ?? '');
        const range = {startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
          startColumn: position.column - prefix.length, endColumn: position.column};
        const items = [];
        const add = (name, source, kind, pkg) => {
          if (typeof name !== 'string' || name.length > 256 || !name.startsWith(prefix) || items.length >= 300) return;
          items.push({label:name, insertText:/^[A-Za-z.][\w.]*$/.test(name) ? name : '`' + name.replace(/`/g,'\\`') + '`',
            detail:source, kind, range, relayPackage:pkg,
            documentation:{value:'From the linked R session snapshot.',isTrusted:false}});
        };
        if (library) for (const name of snapshot.installed_packages || []) add(name, 'Installed R package', monaco.languages.CompletionItemKind.Module);
        else if (member) {
          const preview = (snapshot.previews || []).find(p => p.name === member[1]);
          for (const name of preview?.columns || []) add(name, member[1] + ' column', monaco.languages.CompletionItemKind.Field);
        } else {
          if (!namespace) for (const object of snapshot.objects || []) if (!object.active_binding) add(object.name, 'R workspace', monaco.languages.CompletionItemKind.Variable);
          for (const pkg of snapshot.completion_packages || []) {
            if (namespace && namespace[1] !== pkg.name) continue;
            for (const name of pkg.symbols || []) add(name, pkg.name + ' · attached package', monaco.languages.CompletionItemKind.Function, pkg.name);
          }
        }
        return {suggestions:items};
      },
      async resolveCompletionItem(item, cancellation) {
        if (!item.relayPackage) return item;
        const result = await request('rCompletionHelp', item.relayPackage + '::' + item.label);
        if (result?.text && !cancellation.isCancellationRequested)
          item.documentation = {value:'```text\n' + result.text.slice(0,12000).replace(/```/g,'') + '\n```',isTrusted:false};
        return item;
      }
    });
    return {dispose() { offline.dispose(); live.dispose(); }};
  }
  root.RelayRLanguage = { install };
})(globalThis);
