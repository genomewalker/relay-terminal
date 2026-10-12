const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, '../Sources/Relay/Resources/Editor/r-language.js'), 'utf8'), context);
const providers = [];
let snapshot = {objects:[{name:'my_data',active_binding:false},{name:'danger',active_binding:true}],
  previews:[{name:'my_data',columns:['sample','value']}], installed_packages:['dplyr','MASS'],
  completion_packages:[{name:'dplyr',symbols:['filter','mutate']}]};
const mono = {languages:{CompletionItemKind:{Snippet:1,Variable:2,Function:3,Module:4,Field:5},
  CompletionItemInsertTextRule:{InsertAsSnippet:4}, registerCompletionItemProvider(_,p){providers.push(p);return {dispose(){}}}},
  editor:{tokenize(){return [[{offset:0,type:''}]]}}};
context.RelayRLanguage.install(mono, async type => type === 'rCompletion' ? snapshot : {text:'mutate(.data, ...)'});
async function complete(line, cancelled=false){
  return (await providers[1].provideCompletionItems({getValueLength:()=>line.length,
    getLineContent:()=>line,getLinesContent:()=>[line],getVersionId:()=>1,isDisposed:()=>false,
    getWordUntilPosition:()=>({word:line.match(/[\w.]*$/)[0]})},
    {lineNumber:1,column:line.length+1},{},{isCancellationRequested:cancelled})).suggestions;
}
(async()=>{
  assert.equal((await complete('mut'))[0].label,'mutate');
  assert.equal((await complete('dplyr::fil'))[0].label,'filter');
  assert.equal((await complete('my_data$sa'))[0].label,'sample');
  assert.equal((await complete('library(dp'))[0].label,'dplyr');
  assert.equal((await complete('dan')).length,0);
  assert.equal((await complete('mut',true)).length,0);
  const item = (await complete('mut'))[0];
  await providers[1].resolveCompletionItem(item,{isCancellationRequested:false});
  assert.match(item.documentation.value,/mutate\(\.data/);
  assert.equal(item.documentation.isTrusted,false);
  snapshot.completion_packages=[];
  assert.equal((await complete('mut')).length,0);
  console.log('Live R completion: packages, namespace, columns, cancellation, help and detach passed');
})().catch(e=>{console.error(e);process.exitCode=1});
