#!/usr/bin/env python3
"""Compare retained geometry with the original Epub.js CFI mapper."""
import json
import sys

from playwright.sync_api import sync_playwright

url, config = sys.argv[1], json.loads(sys.argv[2])
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport=config['viewport'])
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.goto(url)
    page.evaluate('''() => {
      const render=ePub.Book.prototype.renderTo;
      ePub.Book.prototype.renderTo=function(...args){
        const r=window.testRendition=render.apply(this,args);
        r.started.then(()=>{
          const manager=r.manager,set=manager.setLayout;
          manager.setLayout=function(...args){
            const value=set.apply(this,args),p=Object.getPrototypeOf(this.mapping);
            window.stockMapper??={findStart:p.findStart,findEnd:p.findEnd,page:p.page};
            return value;
          };
        });return r;
      };
    }''')
    page.evaluate('(config)=>reader.open(config)', config)
    result = page.evaluate('''async config => {
      let comparisons=0,retainedReads=0,originalReads=0;
      function compare() {
        const manager=testRendition.manager, mapper=manager.mapping;
        const contents=testRendition.getContents()[0],doc=contents.document;
        const p=Object.getPrototypeOf(mapper),fast={findStart:p.findStart,findEnd:p.findEnd,page:p.page};
        if(fast.findStart===stockMapper.findStart)throw Error('Retained mapper was not installed');
        const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT),range=doc.createRange();
        let node,min=Infinity,max=-Infinity;
        while(node=walker.nextNode()){
          if(!node.data.trim())continue;
          range.selectNodeContents(node);const b=range.getBoundingClientRect();
          min=Math.min(min,mapper.horizontal?b.left:b.top);max=Math.max(max,mapper.horizontal?b.right:b.bottom);
        }
        const span=mapper.horizontal?manager.layout.width:manager.layout.height;
        const prototype=doc.defaultView.Range.prototype,read=prototype.getBoundingClientRect;
        let reads=0;prototype.getBoundingClientRect=function(...args){reads++;return read.apply(this,args);};
        try{
          for(let i=0;i<17;i++){
            const start=min+Math.max(0,max-min-span)*i/16,end=start+span;
            const actual=mapper.page(contents,contents.cfiBase,start,end);
            reads=0;
            const repeated=mapper.page(contents,contents.cfiBase,start,end);
            retainedReads+=reads;reads=0;
            Object.assign(p,stockMapper);
            let expected;
            try{expected=mapper.page(contents,contents.cfiBase,start,end);}
            finally{Object.assign(p,fast);}
            originalReads+=reads;
            if(JSON.stringify(actual)!==JSON.stringify(expected)||JSON.stringify(repeated)!==JSON.stringify(expected)){
              throw Error('CFI differs from the original mapper '+JSON.stringify({start,end,actual,repeated,expected}));
            }
            comparisons++;
          }
        }finally{prototype.getBoundingClientRect=read;}
      }
      compare();
      for(const change of [{fontSize:27,margin:31,columns:1},{flow:'scrolled'},{fontSize:16,flow:'paged',columns:2}]){
        await reader.preferences({...config.preferences,...change});await reader.whenIdle();compare();
      }
      // Mutations are drained synchronously, including edits before observers
      // receive their callback. The mapper must not reuse removed text nodes.
      const doc=testRendition.getContents()[0].document;
      const p=doc.createElement('p');p.textContent='Inserted publication text. '.repeat(40);doc.body.prepend(p);compare();
      p.firstChild.data='Replaced text with a different length. '.repeat(60);compare();
      p.remove();compare();
      // Classic Windows scrollbars and stage padding reduce available layout
      // width. Stable position queries must not reformat the chapter each time
      // simply because that content box differs from the outer viewport.
      const manager=testRendition.manager,container=manager.container;
      container.style.paddingRight='17px';container.style.boxSizing='border-box';
      manager.updateLayout();
      const update=manager.updateLayout;let updates=0;
      manager.updateLayout=function(...args){updates++;return update.apply(this,args);};
      try{for(let i=0;i<8;i++)testRendition.currentLocation();}
      finally{manager.updateLayout=update;}
      if(updates)throw Error('Stable content-box reads reformatted the publication '+updates);
      compare();
      if(originalReads<=retainedReads*3)throw Error('Repeated mapping still scans chapter geometry '+JSON.stringify({retainedReads,originalReads}));
      return {comparisons,retainedReads,originalReads,stableContentBoxReformats:updates};
    }''', config)
    assert not errors, errors
    print(json.dumps(result))
    page.evaluate('reader.destroy()')
    browser.close()
