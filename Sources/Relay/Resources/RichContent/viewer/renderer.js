'use strict';
let revision = 0;
window.renderRelaySurface = async function (input) {
  const current = ++revision;
  const output = document.getElementById('output');
  output.replaceChildren();
  document.body.classList.toggle('inline-mode', input.inline === true);
  output.style.transform = '';
  output.style.width = '';
  const fit = () => {
    if (!input.inline || current !== revision) return;
    output.style.transform = '';
    const node = output.firstElementChild;
    if (!node) return;
    const box = node.getBoundingClientRect();
    const scale = Math.min(1, innerWidth / Math.max(1, box.width), innerHeight / Math.max(1, box.height));
    output.style.transformOrigin = 'top center';
    output.style.transform = 'scale(' + scale + ')';
  };
  if (window.relayResizeObserver) window.relayResizeObserver.disconnect();
  window.relayResizeObserver = new ResizeObserver(fit);
  window.relayResizeObserver.observe(document.body);
  try {
    if (input.kind === 'equation') {
      katex.render(input.source, output, {displayMode:true, throwOnError:true,
        trust:false, strict:'error', maxExpand:1000, maxSize:20});
    } else if (input.kind === 'diagram') {
      mermaid.initialize({startOnLoad:false, securityLevel:'strict',
        maxTextSize:262144, maxEdges:500, suppressErrorRendering:true,
        flowchart:{htmlLabels:false}, theme:input.inline ? 'dark' : 'neutral'});
      const result = await mermaid.render('relayDiagram' + current, input.source);
      if (current !== revision) return;
      output.innerHTML = result.svg;
    }
    requestAnimationFrame(fit);
  } catch (_) {
    if (current !== revision) return;
    const fallback = document.createElement('pre');
    fallback.textContent = 'Preview unavailable.\n\n' + input.source;
    output.replaceChildren(fallback);
  }
};

let agentRevision = 0;
window.renderRelayAgentMessage = async function(input) {
  const current = ++agentRevision;
  if (typeof input.source !== 'string' || input.source.length > 131072) return;
  document.body.classList.add('agent-message');
  document.documentElement.classList.add('agent-message-page');
  const output = document.getElementById('output'); output.replaceChildren();
  const measure = () => {
    if (current !== agentRevision) return;
    window.webkit?.messageHandlers?.agentHeight?.postMessage(Math.ceil(output.getBoundingClientRect().height + 4));
  };
  if (window.agentObserver) window.agentObserver.disconnect();
  window.agentObserver = new ResizeObserver(measure); window.agentObserver.observe(output);
  function math(parent, source, display) {
    const node = document.createElement(display ? 'div' : 'span'); parent.append(node);
    try { katex.render(source, node, {displayMode:display, throwOnError:true, trust:false, strict:'error', maxExpand:1000, maxSize:20}); }
    catch (_) { node.textContent = (display ? '$$' : '$') + source + (display ? '$$' : '$'); }
  }
  function inline(parent, source) {
    // Parse source delimiters; code is consumed before math, and raw HTML is always text.
    const token = /(`[^`\n]+`|\\\([\s\S]*?\\\)|\$[^$\n]+\$|\*\*[^*]+\*\*|\[[^\]\n]+\]\(https?:\/\/[^\s)]+\))/g;
    let previous = 0, match;
    while ((match = token.exec(source))) {
      parent.append(document.createTextNode(source.slice(previous, match.index)));
      const value = match[0];
      if (value.startsWith('`')) { const code=document.createElement('code'); code.textContent=value.slice(1,-1); parent.append(code); }
      else if (value.startsWith('\\(')) math(parent,value.slice(2,-2),false);
      else if (value.startsWith('$')) math(parent,value.slice(1,-1),false);
      else if (value.startsWith('**')) { const strong=document.createElement('strong'); strong.textContent=value.slice(2,-2); parent.append(strong); }
      else { const split=value.indexOf(']('), link=document.createElement('a'); link.textContent=value.slice(1,split); link.href=value.slice(split+2,-1); parent.append(link); }
      previous = token.lastIndex;
    }
    parent.append(document.createTextNode(source.slice(previous)));
  }
  function tableCells(source) {
    const text=source.trim(), cells=[]; let cell='', codeRun=0, separators=0, last=false;
    for(let i=0;i<text.length;) {
      const char=text[i];
      if(char==='\\' && i+1<text.length) { cell+=text.slice(i,i+2); i+=2; last=false; continue; }
      if(char==='`') {
        let end=i+1; while(text[end]==='`') end++;
        const run=end-i;
        if(!codeRun) {
          let cursor=end, matched=false;
          while(cursor<text.length) {
            if(text[cursor]!=='`') { cursor++; continue; }
            let stop=cursor+1; while(text[stop]==='`') stop++;
            if(stop-cursor===run) { matched=true; break; } cursor=stop;
          }
          if(matched) codeRun=run;
        } else if(codeRun===run) codeRun=0;
        cell+=text.slice(i,end); i=end; last=false; continue;
      }
      if(char==='|' && !codeRun) { cells.push(cell.trim()); cell=''; separators++; last=true; }
      else { cell+=char; last=false; }
      i++;
    }
    cells.push(cell.trim());
    if(text.startsWith('|')) cells.shift(); if(last) cells.pop();
    return separators && cells.length && cells.length<=32 ? cells : null;
  }
  function tableAt(lines, index) {
    if(index+1>=lines.length) return null;
    const header=tableCells(lines[index]), delimiters=tableCells(lines[index+1]);
    if(!header || !delimiters || header.length!==delimiters.length || !delimiters.every(cell=>/^:?-{3,}:?$/.test(cell))) return null;
    const rows=[]; let next=index+2;
    for(;next<lines.length;next++) {
      const row=tableCells(lines[next]); if(!row) break;
      if(rows.length>=512) return null;
      rows.push(header.map((_,column)=>row[column] || ''));
    }
    return {header,delimiters,rows,next};
  }
  const lines=input.source.split('\n');
  for (let i=0;i<lines.length;i++) {
    const line=lines[i], fence=line.match(/^\s*```([A-Za-z0-9_-]*)\s*$/);
    if (fence) {
      let end=i+1; while(end<lines.length && !/^\s*```\s*$/.test(lines[end])) end++;
      if(end===lines.length) { const pre=document.createElement('pre'); pre.textContent=lines.slice(i).join('\n'); output.append(pre); break; }
      const source=lines.slice(i+1,end).join('\n'), language=fence[1].toLowerCase(); i=end;
      if (['math','latex','tex'].includes(language)) math(output,source,true);
      else if(language==='mermaid') {
        const node=document.createElement('div'); output.append(node);
        try {
          if(/%%\{|^\s*---|click\s|<[a-z!\/]|https?:|data:|@\{/i.test(source)) throw Error();
          mermaid.initialize({startOnLoad:false,securityLevel:'strict',maxTextSize:131072,maxEdges:500,suppressErrorRendering:true,flowchart:{htmlLabels:false},theme:'dark'});
          const result=await mermaid.render('agentDiagram'+current+'_'+i,source);
          if(current!==agentRevision) return; node.innerHTML=result.svg;
        } catch(_) { const pre=document.createElement('pre'); pre.textContent=source; node.append(pre); }
      } else { const pre=document.createElement('pre'), code=document.createElement('code'); code.textContent=source; pre.append(code); output.append(pre); }
      continue;
    }
    const parsed=tableAt(lines,i);
    if(parsed) {
      const wrapper=document.createElement('div'); wrapper.className='agent-table-scroll';
      const table=document.createElement('table'), head=document.createElement('thead'), body=document.createElement('tbody');
      function row(parent,cells,header) {
        const tr=document.createElement('tr');
        cells.forEach((source,column)=> {
          const cell=document.createElement(header ? 'th' : 'td');
          if(header) cell.scope='col';
          const delimiter=parsed.delimiters[column];
          cell.style.textAlign=delimiter.endsWith(':') ? (delimiter.startsWith(':') ? 'center' : 'right') : 'left';
          inline(cell,source.replace(/\\\|/g,'|')); tr.append(cell);
        }); parent.append(tr);
      }
      row(head,parsed.header,true); parsed.rows.forEach(cells=>row(body,cells,false));
      table.append(head,body); wrapper.append(table); output.append(wrapper); i=parsed.next-1; continue;
    }
    const display=line.match(/^\s*(\$\$|\\\[)([\s\S]*)$/);
    if(display) {
      const close=display[1]==='$$' ? '$$' : '\\]'; let body=display[2], end=i;
      while(!body.includes(close) && end+1<lines.length) body+='\n'+lines[++end];
      const stop=body.indexOf(close);
      if(stop>=0) { math(output,body.slice(0,stop),true); if(body.slice(stop+close.length).trim()) { const p=document.createElement('p'); inline(p,body.slice(stop+close.length)); output.append(p); } i=end; continue; }
    }
    if(!line.trim()) continue;
    const heading=line.match(/^(#{1,6})\s+(.+)$/), bullet=line.match(/^\s*(?:[-*+]\s+|\d+\.\s+)(.+)$/);
    const node=document.createElement(heading ? 'h'+heading[1].length : 'p');
    if(bullet) { node.className='agent-list-item'; inline(node,'• '+bullet[1]); }
    else inline(node,heading ? heading[2] : line);
    output.append(node);
  }
  requestAnimationFrame(measure);
};
