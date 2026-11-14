'use strict';
// Slide uses compositor snapshots. Curl bends the entire sheet as a continuous
// GPU mesh: a broad elastic front joins the roll with a continuous tangent.
// The publication is uploaded once per turn, never read back/encoded per frame.
class KMReaderCurlSurface {
  static shared;
  static disabled=false;
  static rasterScale(width,height){
    // Match native glyph resolution on phones without unbounded texture memory.
    return Math.max(1,Math.min(devicePixelRatio||1,4,Math.sqrt(32*1024*1024/(width*height*4))));
  }
  constructor() {
    this.canvas = document.createElement('canvas');
    this.canvas.id = 'page-curl-surface';
    this.canvas.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:2147483645';
    const gl=this.gl=this.canvas.getContext('webgl',{alpha:false,antialias:true,preserveDrawingBuffer:false});
    if (!gl) throw Error('WebGL unavailable');
    const parallel=gl.getExtension('KHR_parallel_shader_compile'),pending=[];
    this.parallelCompilation=!!parallel;
    // COMPILE_STATUS, LINK_STATUS and uniform lookups force the browser to
    // wait for the GPU compiler. Submit all programs first and poll the
    // nonblocking completion query when supported.
    const compile=(kind,source)=>{const shader=gl.createShader(kind);gl.shaderSource(shader,source);gl.compileShader(shader);return shader;};
    const uniforms=`uniform sampler2D oldPage,newPage;uniform vec2 size;uniform float progress,spread,sign,slope,grabY,curlReach;`;
    const samples=`vec4 oldAt(vec2 q){return texture2D(oldPage,clamp(q/size,vec2(0.),vec2(1.)));}
      vec4 newAt(vec2 q){return texture2D(newPage,clamp(q/size,vec2(0.),vec2(1.)));}`;
    const quadVertex=`attribute vec2 a;varying vec2 v;void main(){v=vec2((a.x+1.)*.5,(1.-a.y)*.5);gl_Position=vec4(a,0.,1.);}`;
    const background=`precision highp float;varying vec2 v;${uniforms}${samples}
      uniform sampler2D castShadow;
      void main(){vec2 q=v*size;float hinge=spread>.5?size.x*.5:(sign>0.?0.:size.x);
        if(progress<.0001){gl_FragColor=oldAt(q);return;}
        if(progress>.9999){gl_FragColor=newAt(q);return;}
        vec4 color=spread>.5&&(q.x-hinge)*sign<0.?oldAt(q):newAt(q);
        float shadow=texture2D(castShadow,vec2(v.x,1.-v.y)).r;
        gl_FragColor=vec4(color.rgb*(1.-shadow),1.);
      }`;
    const meshVertex=`precision highp float;attribute vec2 a;${uniforms}
      uniform float shadowPass;
      varying vec2 source;varying float normalZ;varying float sheetAngle;varying float depth;
      void main(){
        float pi=3.14159265,w=size.x/(1.+spread),h=size.y;
        vec2 n=normalize(vec2(1.,slope)),t=vec2(-n.y,n.x),origin=vec2(0.,grabY*h);
        // The mesh is aligned to the fold, with extra samples across its tight
        // radius. Varying the radius along the fold creates a corner-led roll.
        float u0=min(0.,n.y*h)-dot(origin,n),u1=n.x*w+max(0.,n.y*h)-dot(origin,n);
        float v0=min(0.,t.x*w)-dot(origin,t),v1=max(0.,t.x*w)+t.y*h-dot(origin,t);
        float v=mix(v0,v1,a.y),wave=sin(pi*progress);
        float cone=clamp((.5-grabY)*.65+slope*.35,-.45,.45);
        float factor=clamp(1.+cone*v/h,.65,1.35);
        float r=max(.001,w*.075*wave*factor),alpha=.75*wave*factor;
        float f=max(.001,w*(1.-progress)-r*(pi-alpha)*.5),end=f+r*(pi-alpha);
        float u=a.x<1.?mix(min(u0,0.),f,a.x):a.x<2.?mix(f,end,a.x-1.):mix(end,max(u1,end),a.x-2.);
        source=origin+n*u+t*v;
        float reach=min(f,w*curlReach),start=f-reach;
        float theta=alpha*clamp((u-start)/max(.001,reach),0.,1.),frontR=reach/max(.00001,alpha);
        float xf=start+frontR*sin(alpha),zf=2.*frontR*pow(sin(alpha*.5),2.);
        float x,z;
        if(u<start){x=u;z=0.;theta=0.;}
        else if(u<=f){x=start+frontR*sin(theta);z=2.*frontR*pow(sin(theta*.5),2.);}
        else if(u<=end){theta=alpha+(u-f)/r;x=xf+r*(sin(theta)-sin(alpha));z=zf+r*(cos(alpha)-cos(theta));}
        else{theta=pi;x=xf-r*sin(alpha)-(u-end);z=zf+r*(1.+cos(alpha));}
        normalZ=cos(theta);sheetAngle=theta;depth=z;
        vec2 world=origin+n*x+t*v;
        float hinge=spread>.5?size.x*.5:(sign>0.?0.:size.x),camera=w*3.,perspective=(camera-z)/camera;
        vec2 center=vec2(hinge,grabY*h),screen=vec2(hinge+world.x*sign,world.y);
        gl_Position=vec4((2.*center.x/size.x-1.)*perspective+2.*(screen.x-center.x)/size.x,
          (1.-2.*center.y/h)*perspective-2.*(screen.y-center.y)/h,-z/camera,perspective);
        if(shadowPass>.5){
          vec2 projected=center+(screen-center)/perspective+vec2(.08,.06)*z/perspective;
          gl_Position=vec4(2.*projected.x/size.x-1.,1.-2.*projected.y/h,-z/camera,1.);
        }
      }`;
    const meshFragment=`precision highp float;${uniforms}${samples}
      uniform sampler2D castShadow;uniform vec2 rasterSize;
      varying vec2 source;varying float normalZ;varying float sheetAngle;varying float depth;
      void main(){
        float w=size.x/(1.+spread),hinge=spread>.5?size.x*.5:(sign>0.?0.:size.x);
        if(source.x<0.||source.x>w||source.y<0.||source.y>size.y)discard;
        vec4 color=oldAt(vec2(hinge+source.x*sign,source.y));
        if(!gl_FrontFacing){
          if(spread>.5)color=newAt(vec2(hinge-source.x*sign,source.y));
          else{vec3 stock=oldAt(vec2(sign>0.?1.:size.x-1.,1.)).rgb;color=vec4(mix(stock,color.rgb,.36),1.);}
        }
        // A soft contact shadow on the front and a broad roll terminator.
        // Lighting belongs to the sheet normal, independent of slide tint.
        float shade=1.-.30*pow(max(0.,sin(sheetAngle)),1.4);
        // Flat paper is another receiver on the same plane as the stationary
        // page. Sample the same screen-space shadow across the spine instead
        // of repainting this half without a shadow.
        // Attenuate over the physical roll radius. A fixed 2px cutoff made
        // the projected shadow disappear just as the front started bending,
        // leaving a bright diagonal seam on otherwise shaded paper.
        float received=texture2D(castShadow,gl_FragCoord.xy/rasterSize).r*exp(-depth/max(1.,w*.075));
        gl_FragColor=vec4(color.rgb*shade*(1.-received),1.);
      }`;
    const shadowFragment=`precision highp float;${uniforms}
      varying vec2 source;varying float depth;
      void main(){
        float w=size.x/(1.+spread);
        if(source.x<0.||source.x>w||source.y<0.||source.y>size.y)discard;
        float opacity=.36*sqrt(max(0.,sin(3.14159265*progress)))*smoothstep(0.,3.,depth);
        gl_FragColor=vec4(vec3(opacity),1.);
      }`;
    const blurFragment=`precision highp float;varying vec2 v;uniform sampler2D castShadow;uniform vec2 blurStep;
      uniform float blurWeights[13];
      void main(){
        vec2 uv=vec2(v.x,1.-v.y);
        vec4 color=texture2D(castShadow,uv)*blurWeights[0];
        // Contiguous texels are essential. Scaling a five-tap bilinear kernel
        // spreads its lobes apart and produces repeated silhouettes of the leaf.
        for(int i=1;i<13;i++){
          vec2 offset=blurStep*float(i);
          color+=(texture2D(castShadow,uv+offset)+texture2D(castShadow,uv-offset))*blurWeights[i];
        }
        gl_FragColor=color;
      }`;
    const program=(vertexSource,fragmentSource)=>{
      const vertex=compile(gl.VERTEX_SHADER,vertexSource),fragment=compile(gl.FRAGMENT_SHADER,fragmentSource),p=gl.createProgram();
      gl.attachShader(p,vertex);gl.attachShader(p,fragment);gl.linkProgram(p);gl.deleteShader(vertex);gl.deleteShader(fragment);
      const result={p,u:{},a:-1};
      pending.push(()=>{
        if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(p));
        for(const name of ['oldPage','newPage','size','progress','spread','sign','slope','grabY','curlReach','shadowPass','castShadow','blurStep','rasterSize','blurWeights[0]'])result.u[name]=gl.getUniformLocation(p,name);
        result.a=gl.getAttribLocation(p,'a');
      });return result;
    };
    this.background=program(quadVertex,background);this.sheet=program(meshVertex,meshFragment);
    this.cast=program(meshVertex,shadowFragment);this.blur=program(quadVertex,blurFragment);
    const finish=()=>{for(const complete of pending)complete();this.initialized=true;};
    this.finishPrograms=finish;
    if(parallel){
      this.readiness=(async()=>{
        const programs=[this.background,this.sheet,this.cast,this.blur],deadline=performance.now()+2500;
        while(programs.some(program=>!gl.getProgramParameter(program.p,parallel.COMPLETION_STATUS_KHR))){
          if(this.disposed||gl.isContextLost())throw Error('Curl context lost while compiling');
          if(performance.now()>deadline)throw Error('Curl compilation timed out');
          // RAF may be frozen inside a browser View Transition update.
          await new Promise(resolve=>setTimeout(resolve,8));
        }
        finish();
      })();
      this.readiness.catch(()=>{if(!this.disposed)this.fail();});
    }
    this.quad=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,this.quad);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
    const vertices=[],indices=[],columns=144,rows=24;
    for(let col=0;col<=columns;col++)for(let row=0;row<=rows;row++)vertices.push(3*col/columns,row/rows);
    for(let col=0;col<columns;col++)for(let row=0;row<rows;row++){const a=col*(rows+1)+row,b=a+rows+1;indices.push(a,b,a+1,a+1,b,b+1);}
    this.mesh=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,this.mesh);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(vertices),gl.STATIC_DRAW);
    this.indices=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,this.indices);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,new Uint16Array(indices),gl.STATIC_DRAW);this.count=indices.length;
    this.textures=[0,1].map(i=>{gl.activeTexture(gl.TEXTURE0+i);const t=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,t);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);return t;});
    gl.flush();
    this.onContextLost=()=>this.fail();
    this.canvas.addEventListener('webglcontextlost',this.onContextLost);
  }
  whenReady(){return this.readiness??=Promise.resolve().then(()=>{if(this.disposed)throw Error('Curl surface retired');this.finishPrograms();});}
  fail(){
    // Do not repeatedly warm/recreate a failing driver in this WebView. The
    // publication remains live underneath and subsequent turns are direct.
    KMReaderCurlSurface.disabled=true;
    if(this.effect){this.effect.failed=true;this.effect.stop();}this.dispose();
  }
  dispose(){
    if(this.disposed)return;
    this.disposed=true;this.canvas.remove();
    if(KMReaderCurlSurface.shared===this)KMReaderCurlSurface.shared=null;
    this.canvas.removeEventListener('webglcontextlost',this.onContextLost);
    // Release the retained textures/framebuffers when the reader closes or a
    // driver fails, rather than waiting for Android's WebView GC.
    if(!this.gl.isContextLost())this.gl.getExtension('WEBGL_lose_context')?.loseContext();
    this.sources=[];this.effect=null;
  }
  upload(before,after,width,height) {
    if(this.disposed||this.gl.isContextLost())throw Error('Curl surface unavailable');
    const gl=this.gl,dpr=KMReaderCurlSurface.rasterScale(width,height);
    const pixelWidth=Math.round(width*dpr),pixelHeight=Math.round(height*dpr);
    // Rounded bitmap dimensions must not stretch CSS glyph coordinates.
    this.width=pixelWidth/dpr;this.height=pixelHeight/dpr;
    this.canvas.style.width=this.width+'px';this.canvas.style.height=this.height+'px';
    if(this.canvas.width!==pixelWidth)this.canvas.width=pixelWidth;
    if(this.canvas.height!==pixelHeight)this.canvas.height=pixelHeight;
    gl.viewport(0,0,pixelWidth,pixelHeight);
    this.sources??=[];
    // The incoming page normally becomes the next turn's front. Keep that GPU
    // allocation and swap its role instead of rasterizing/uploading it again.
    if(this.sources[1]===before&&this.sources[0]!==before){
      [this.sources[0],this.sources[1]]=[this.sources[1],this.sources[0]];
      [this.textures[0],this.textures[1]]=[this.textures[1],this.textures[0]];
    }
    after??=this.sources[1]||before;
    [before,after].forEach((image,i)=>{
      gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,this.textures[i]);
      if(this.sources[i]!==image){gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);this.sources[i]=image;}
    });
    if(gl.getError()!==gl.NO_ERROR)throw Error('Page texture unavailable');
  }
  render(progress,spread,sign,slope,y,reach=.18){
    if(this.disposed||this.gl.isContextLost())throw Error('Curl surface unavailable');
    const g=this.gl;
    const bind=(program,buffer)=>{const {p,u,a}=program;g.useProgram(p);g.bindBuffer(g.ARRAY_BUFFER,buffer);g.enableVertexAttribArray(a);g.vertexAttribPointer(a,2,g.FLOAT,false,0,0);g.uniform1i(u.oldPage,0);g.uniform1i(u.newPage,1);g.uniform2f(u.size,this.width,this.height);g.uniform1f(u.progress,progress);g.uniform1f(u.spread,spread?1:0);g.uniform1f(u.sign,sign);g.uniform1f(u.slope,slope);g.uniform1f(u.grabY,y);g.uniform1f(u.curlReach,reach);};
    const width=this.canvas.width,height=this.canvas.height;
    if(progress<.0001||progress>.9999){
      g.bindFramebuffer(g.FRAMEBUFFER,null);g.viewport(0,0,width,height);g.disable(g.DEPTH_TEST);g.disable(g.BLEND);
      g.activeTexture(g.TEXTURE2);g.bindTexture(g.TEXTURE_2D,this.shadowTargets?.[0].texture||this.textures[0]);
      bind(this.background,this.quad);g.uniform1i(this.background.u.castShadow,2);g.drawArrays(g.TRIANGLE_STRIP,0,4);return;
    }
    if(!this.shadowTargets||this.shadowWidth!==width||this.shadowHeight!==height||this.shadowSpread!==spread){
      for(const target of this.shadowTargets||[]){g.deleteFramebuffer(target.fbo);g.deleteTexture(target.texture);if(target.depth)g.deleteRenderbuffer(target.depth);}
      this.shadowWidth=width;this.shadowHeight=height;this.shadowSpread=spread;
      // The penumbra, rather than the text, determines mask resolution. Keep
      // its largest sigma at 3.5 texels so a dense finite kernel covers it.
      const texel=Math.max(1,(3+this.width/(spread?2:1)*.018)*1.6/3.5);
      this.maskWidth=Math.max(1,Math.ceil(this.width/texel));this.maskHeight=Math.max(1,Math.ceil(this.height/texel));
      this.shadowTargets=[0,1].map(i=>{
        const texture=g.createTexture();g.activeTexture(g.TEXTURE2);g.bindTexture(g.TEXTURE_2D,texture);
        g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MIN_FILTER,g.LINEAR);g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MAG_FILTER,g.LINEAR);
        g.texParameteri(g.TEXTURE_2D,g.TEXTURE_WRAP_S,g.CLAMP_TO_EDGE);g.texParameteri(g.TEXTURE_2D,g.TEXTURE_WRAP_T,g.CLAMP_TO_EDGE);
        g.texImage2D(g.TEXTURE_2D,0,g.RGBA,this.maskWidth,this.maskHeight,0,g.RGBA,g.UNSIGNED_BYTE,null);
        const fbo=g.createFramebuffer();g.bindFramebuffer(g.FRAMEBUFFER,fbo);g.framebufferTexture2D(g.FRAMEBUFFER,g.COLOR_ATTACHMENT0,g.TEXTURE_2D,texture,0);
        let depth;
        if(i===0){depth=g.createRenderbuffer();g.bindRenderbuffer(g.RENDERBUFFER,depth);g.renderbufferStorage(g.RENDERBUFFER,g.DEPTH_COMPONENT16,this.maskWidth,this.maskHeight);g.framebufferRenderbuffer(g.FRAMEBUFFER,g.DEPTH_ATTACHMENT,g.RENDERBUFFER,depth);}
        if(g.checkFramebufferStatus(g.FRAMEBUFFER)!==g.FRAMEBUFFER_COMPLETE)throw Error('Curl shadow framebuffer unavailable');
        return {texture,fbo,depth};
      });
    }
    const [mask,temporary]=this.shadowTargets;
    // Project the actual curved sheet onto the page. A depth-tested mask and
    // separable blur follow every free edge, without straight segment seams or
    // disconnected endpoint blobs on dark/sepia stock.
    g.bindFramebuffer(g.FRAMEBUFFER,mask.fbo);g.viewport(0,0,this.maskWidth,this.maskHeight);
    g.clearColor(0,0,0,1);g.clear(g.COLOR_BUFFER_BIT|g.DEPTH_BUFFER_BIT);g.disable(g.BLEND);
    if(progress>.0001&&progress<.9999){
      g.enable(g.DEPTH_TEST);g.depthFunc(g.LEQUAL);bind(this.cast,this.mesh);g.uniform1f(this.cast.u.shadowPass,1);
      g.bindBuffer(g.ELEMENT_ARRAY_BUFFER,this.indices);g.drawElements(g.TRIANGLES,this.count,g.UNSIGNED_SHORT,0);
    }
    g.disable(g.DEPTH_TEST);
    const sigma=(3+Math.sin(Math.PI*progress)*this.width/(spread?2:1)*.018)*1.6;
    this.blurShadow(sigma);
    g.bindFramebuffer(g.FRAMEBUFFER,null);g.viewport(0,0,width,height);
    g.activeTexture(g.TEXTURE2);g.bindTexture(g.TEXTURE_2D,mask.texture);
    bind(this.background,this.quad);g.uniform1i(this.background.u.castShadow,2);
    g.drawArrays(g.TRIANGLE_STRIP,0,4);
    if(progress<.0001||progress>.9999)return;
    g.clear(g.DEPTH_BUFFER_BIT);g.enable(g.DEPTH_TEST);g.depthFunc(g.LEQUAL);g.frontFace(sign>0?g.CW:g.CCW);
    bind(this.sheet,this.mesh);g.uniform1f(this.sheet.u.shadowPass,0);g.uniform1i(this.sheet.u.castShadow,2);g.uniform2f(this.sheet.u.rasterSize,width,height);g.bindBuffer(g.ELEMENT_ARRAY_BUFFER,this.indices);g.drawElements(g.TRIANGLES,this.count,g.UNSIGNED_SHORT,0);g.disable(g.DEPTH_TEST);
  }
  blurShadow(sigma) {
    const g=this.gl,program=this.blur,[mask,temporary]=this.shadowTargets;
    g.disable(g.DEPTH_TEST);g.disable(g.BLEND);g.viewport(0,0,this.maskWidth,this.maskHeight);
    g.useProgram(program.p);g.bindBuffer(g.ARRAY_BUFFER,this.quad);g.enableVertexAttribArray(program.a);g.vertexAttribPointer(program.a,2,g.FLOAT,false,0,0);
    g.uniform1i(program.u.castShadow,2);
    for(const [target,source,dx,dy,scale] of [
      [temporary,mask,1/this.maskWidth,0,this.maskWidth/this.width],
      [mask,temporary,0,1/this.maskHeight,this.maskHeight/this.height]]){
      const weights=new Float32Array(13),pixels=Math.max(.25,sigma*scale);
      let total=0;
      for(let i=0;i<weights.length;i++){weights[i]=Math.exp(-.5*(i/pixels)**2);total+=weights[i]*(i?2:1);}
      for(let i=0;i<weights.length;i++)weights[i]/=total;
      g.bindFramebuffer(g.FRAMEBUFFER,target.fbo);g.activeTexture(g.TEXTURE2);g.bindTexture(g.TEXTURE_2D,source.texture);
      g.uniform1fv(program.u['blurWeights[0]'],weights);g.uniform2f(program.u.blurStep,dx,dy);g.drawArrays(g.TRIANGLE_STRIP,0,4);
    }
  }

}
class KMReaderSheetEffect {
  static serial=0;
  static retirementSerial=0;
  // capturedLayout temporarily replaces window RAF with task callbacks while
  // View Transitions freeze painting. Retirement must observe real delivery.
  static deliveryFrame=window.requestAnimationFrame.bind(window);
  static retireCapture(compositor=false){
    this.needsRetirement=true;
    if(compositor)this.needsCompositorRetirement=true;
    const serial=++this.retirementSerial;
    this.deliveryFrame(()=>this.deliveryFrame(()=>{
      if(serial===this.retirementSerial){this.needsRetirement=false;this.needsCompositorRetirement=false;}
    }));
  }
  static supported(style='slide'){return style==='curl'?!KMReaderCurlSurface.disabled&&typeof WebGLRenderingContext!=='undefined':typeof document.startViewTransition==='function';}
  constructor(style,sign,preferences,y=.5,reverse=false,spread=false,capture=null){
    Object.assign(this,{style,sign,preferences,y,reverse,spread,capture});
    this.width=innerWidth;this.height=innerHeight;this.progress=0;this.slope=0;this.ready=false;this.id=`km-sheet-${++KMReaderSheetEffect.serial}`;
    this.dragWidth=this.width/(spread?2:1);
    this.cancelled=new Promise(resolve=>this.cancelWait=resolve);
  }
  async wait(work){
    let timer;
    try{return await Promise.race([work,
      this.cancelled.then(()=>{throw Error('Page effect cancelled');}),
      new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('Page effect preparation timed out')),2500))]);}
    finally{clearTimeout(timer);}
  }
  fail(){
    this.failed=true;
    if(this.style==='curl')KMReaderCurlSurface.disabled=true;
    this.surface?.fail();this.stop();
  }
  async start(move,preview){
    // Compositor capture needs a delivered frame after the previous surface
    // retires. Keep that barrier here so direct/interactive callers share it.
    if(KMReaderSheetEffect.needsRetirement&&(this.style!=='curl'||KMReaderSheetEffect.needsCompositorRetirement)){
      KMReaderSheetEffect.needsRetirement=false;KMReaderSheetEffect.needsCompositorRetirement=false;
      try{await this.wait(new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));}
      catch(_){const cancelled=this.stopped;this.stop();if(!cancelled)await move();return false;}
    }
    if(this.stopped)return false;
    if(this.style==='slide'&&preview){
      try{
        const [before,after]=await this.wait(Promise.all([preview.before,preview.after]));
        if(this.stopped||!after)return false;
        this.previewLayer=document.createElement('div');this.previewLayer.dataset.pageMotionPreview=this.id;
        this.previewLayer.style.cssText='position:fixed;inset:0;overflow:hidden;pointer-events:none;z-index:2147483645';
        this.styles=[before,after].map(image=>{
          const clone=image.cloneNode();
          const scale=KMReaderCurlSurface.rasterScale(this.width,this.height);
          clone.style.cssText=`position:absolute;left:0;top:0;width:${Math.round(this.width*scale)/scale}px;height:${Math.round(this.height*scale)/scale}px;will-change:transform`;
          this.previewLayer.append(clone);return clone.style;
        });
        document.body.append(this.previewLayer);this.update(0);this.ready=true;return true;
      }catch(_){this.stop();return false;}
    }
    if(this.style==='curl'){
      let moved=false;
      try{
        this.surface=KMReaderCurlSurface.shared??=new KMReaderCurlSurface();
        this.surface.effect=this;
        const [before,afterPreview]=await this.wait(Promise.all([preview?.before||this.capture(),preview?.after,this.surface.whenReady()]));
        if(this.stopped)return false;
        if(afterPreview){
          this.surface.upload(before,afterPreview,this.width,this.height);this.update(0);document.body.append(this.surface.canvas);this.ready=true;return true;
        }
        this.surface.upload(before,null,this.width,this.height);this.update(0);document.body.append(this.surface.canvas);
        moved=true;await move();
        const after=await this.wait(this.capture());if(this.stopped)return false;
        this.surface.upload(before,after,this.width,this.height);this.update(0);this.ready=true;return true;
      }catch(_){const cancelled=this.stopped&&!this.failed;if(cancelled)this.stop();else this.fail();if(!moved&&!cancelled)await move();return false;}
    }
    this.sheet=document.createElement('style');this.sheet.dataset.pageMotion=this.id;
    this.sheet.textContent=`::view-transition{pointer-events:none}:root{view-transition-name:none}#viewer{view-transition-name:km-reader-page}
      ::view-transition-group(km-reader-page){animation:none}
      ::view-transition-old(km-reader-page),::view-transition-new(km-reader-page){animation:km-sheet-hold 30s linear both paused;mix-blend-mode:normal;transform-origin:center;object-fit:fill;overflow:visible;will-change:transform,filter}
      @keyframes km-sheet-hold{from{opacity:1}to{opacity:1}}`;
    this.frames=document.createElement('style');this.frames.dataset.pageMotionFrame=this.id;document.head.append(this.sheet,this.frames);
    let moved=false;
    try{this.transition=document.startViewTransition(async()=>{moved=true;await move();});this.transition.finished.then(()=>this.stop(),()=>this.stop());this.transition.updateCallbackDone.catch(()=>{});await this.wait(this.transition.ready);this.update(0);this.ready=true;return true;}
    catch(_){this.stop();if(this.transition)await this.transition.updateCallbackDone.catch(()=>{});if(!moved)await move();return false;}
  }
  update(value,point){
    if(this.stopped)return;
    const p=this.progress=Math.max(0,Math.min(1,value));
    if(point){const dx=Math.max(this.width*.15,p*this.width);this.slope=Math.max(-.65,Math.min(.65,-(point.y-this.y*this.height)/dx));}
    if(this.style==='curl'){
      if(this.surface)this.surface.render(p,this.spread,this.sign,this.slope*Math.sin(Math.PI*p),this.y, .18);return;
    }
    const frames=this.sheetFrames(p);
    if(!this.styles){
      this.frames.textContent='::view-transition-old(km-reader-page){}::view-transition-new(km-reader-page){}';
      this.styles=[...this.frames.sheet.cssRules].map(rule=>rule.style);
    }
    for(let i=0;i<2;i++)Object.assign(this.styles[i],this.previewLayer?{...frames[i],filter:'none'}:frames[i]);
  }
  sheetFrames(p){
    const upperOld=this.style==='slide'?!this.reverse:false;
    const travel=this.style==='cover'?this.sign*(1-p)*100:upperOld?-this.sign*p*100:this.sign*(1-p)*100;
    const parallax=this.style==='cover'?0:upperOld?this.sign*(1-p)*10:-this.sign*p*10;
    const wave=Math.sin(Math.PI*p),edge=this.style==='cover'?-this.sign:upperOld?this.sign:-this.sign;
    return [0,1].map(i=>{
      const upper=(i===0)===upperOld;
      return {transform:`translate3d(${(i===0?upperOld:!upperOld)?travel:parallax}%,0,0)`,zIndex:upper?'2':'1',
        filter:upper?`drop-shadow(${edge*10}px 0 24px rgba(0,0,0,${.20*wave}))`:`brightness(${1-.10*wave})`};
    });
  }
  get progress(){
    const animation=this.compositor?.animations[0];
    const fraction=animation?.effect.getComputedTiming().progress;
    return fraction==null?this._progress:this.compositor.from+(this.compositor.target-this.compositor.from)*fraction;
  }
  set progress(value){this._progress=value;}

  track(value,point){
    if(this.stopped)return;
    this.pendingPoint=[value,point];
    // Input may arrive during texture/compositor preparation. It must not draw
    // an uninitialized surface, nor jump straight to a distant finger on ready.
    if(!this.ready||this.tracking)return;
    const frame=now=>{
      this.tracking=0;
      if(this.stopped||!this.pendingPoint)return;
      const [target,point]=this.pendingPoint;
      if(this.entryFrom==null){
        this.entryFrom=this.progress;this.entryStart=now;
        const distance=Math.abs(target-this.entryFrom);
        this.entryDuration=distance*this.dragWidth>24?Math.min(90,40+distance*125):0;
      }
      const t=this.entryDuration?Math.min(1,(now-this.entryStart)/this.entryDuration):1;
      const eased=t*t*(3-2*t);
      const progress=this.entryComplete?target:this.entryFrom+(target-this.entryFrom)*eased;
      const contact=point&&!this.entryComplete?{...point,y:this.y*this.height+(point.y-this.y*this.height)*eased}:point;
      try{this.update(progress,contact);}catch(_){this.fail();return;}
      if(t<1)this.tracking=requestAnimationFrame(frame);
      else{this.entryComplete=true;this.pendingPoint=null;}
    };
    this.tracking=requestAnimationFrame(frame);
  }
  animateTo(target,duration,{automatic=false,velocity=0}={}){
    // A release during entry must continue from the displayed sheet, rather
    // than flushing a distant, still unpresented pointer target in one frame.
    const pending=this.pendingPoint;cancelAnimationFrame(this.tracking);this.tracking=0;this.pendingPoint=null;
    try{if(pending&&(this.entryComplete||Math.abs(pending[0]-this.progress)*this.dragWidth<=24))this.update(...pending);}catch(_){this.fail();}
    if(this.stopped)return Promise.resolve();
    this.finishAnimation?.();cancelAnimationFrame(this.frame);
    clearTimeout(this.watchdog);
    // A suspended RAF or a rejected compositor promise must never retain an
    // opaque snapshot indefinitely. This task timer also runs without frames.
    this.watchdog=setTimeout(()=>this.stop(),Math.max(1500,duration+1000));
    const from=this.progress,delta=target-from;
    const tangent=delta===0?0:Math.max(0,Math.min(3,velocity*duration/delta));
    if(this.style!=='curl'&&(this.transition||this.previewLayer)&&typeof document.documentElement.animate==='function'){
      const animations=[];
      try{
        for(const i of [0,1]){
          const pseudoElement=i===0?'::view-transition-old(km-reader-page)':'::view-transition-new(km-reader-page)';
          const element=this.previewLayer?this.previewLayer.children[i]:document.documentElement;
          const animation=element.animate(
          Array.from({length:17},(_,j)=>{const f=j/16,frame=this.sheetFrames(from+delta*f)[i];return this.previewLayer?{offset:f,transform:frame.transform}:{offset:f,transform:frame.transform,filter:frame.filter};}),
          {duration,easing:automatic?'cubic-bezier(.45,0,.25,1)':`cubic-bezier(.333333,${tangent/3},.666667,1)`,
            fill:'both',...(this.previewLayer?{}:{pseudoElement})});
          animations.push(animation);
          if(!this.previewLayer&&animation.effect.pseudoElement!==pseudoElement)throw Error('Snapshot compositor animation unavailable');
        }
        this.compositor={animations,from,target};
        return new Promise(resolve=>{
          this.finishAnimation=resolve;
          Promise.all(animations.map(a=>a.finished)).then(()=>{
            if(this.stopped)return;
            try{this.compositor=null;this.update(target);for(const animation of animations)animation.cancel();}
            catch(_){this.fail();}
            clearTimeout(this.watchdog);this.finishAnimation=null;resolve();
          },()=>this.stop());
        });
      }catch(_){for(const animation of animations)animation.cancel();this.compositor=null;}
    }
    return new Promise(resolve=>{
      this.finishAnimation=resolve;let started;
      const frame=now=>{
        if(this.stopped){resolve();return;}
        started??=now;
        // Preserve the requested wall duration under load. Capping each delta
        // at 32ms turned slow presentation into multi-second slow motion. RAF
        // timestamps follow the delivered document frame: anchor to its first
        // delivery so a delayed/frozen capture cannot consume the whole flight
        // before its initial frame has even appeared.
        const t=Math.min(1,Math.max(0,now-started)/Math.max(1,duration));
        const eased=automatic?t*t*t*(10+t*(-15+6*t)):(-2*t*t*t+3*t*t)+tangent*(t*t*t-2*t*t+t);
        try{this.update(from+delta*eased);}catch(_){this.fail();return;}
        if(t<1)this.frame=requestAnimationFrame(frame);else{clearTimeout(this.watchdog);this.finishAnimation=null;resolve();}
      };
      this.frame=requestAnimationFrame(frame);
    });
  }

  stop(){
    if(this.stopped)return;
    this.stopped=true;this.ready=false;this.pendingPoint=null;
    try{this._progress=this.progress;}catch(_){}
    for(const animation of this.compositor?.animations||[])try{animation.cancel();}catch(_){}
    this.compositor=null;clearTimeout(this.watchdog);
    cancelAnimationFrame(this.tracking);cancelAnimationFrame(this.frame);
    this.cancelWait();this.finishAnimation?.();this.finishAnimation=null;
    try{this.transition?.skipTransition();}catch(_){}
    if(this.transition||this.previewLayer?.isConnected||this.surface?.canvas.isConnected)KMReaderSheetEffect.retireCapture(!!this.transition);
    this.previewLayer?.remove();this.sheet?.remove();this.frames?.remove();this.surface?.canvas.remove();
    if(this.surface?.effect===this)this.surface.effect=null;
  }
}

// Curl textures need the visible page's glyphs, not the text of every other
// page in the chapter. Retain offscreen prose's measured flow boxes while
// omitting its glyph layout in the temporary SVG document. The live publication
// is never edited. Complex authored blocks keep the full snapshot path.
class KMReaderPageSnapshot {
  static compact(root, document, clip, cache) {
    if (!cache.blocks) {
      // Relational selectors can make a visible block depend on the children
      // of an offscreen one. Preserve those authored documents verbatim.
      if ([...document.styleSheets].some(sheet => {
        try { return [...sheet.cssRules].some(rule => rule.cssText.includes(':has(')||/::?(before|after|first-letter|first-line)\b/.test(rule.cssText)); }
        catch (_) { return true; }
      })) { cache.blocks=[]; return; }
      const ancestorStyles=new WeakMap();
      const simpleAncestor=element=>{
        if(element===document.body)return true;
        if(ancestorStyles.has(element))return ancestorStyles.get(element);
        const style=document.defaultView.getComputedStyle(element);
        const simple=style.display==='block'&&style.position==='static'&&style.float==='none'&&
          style.columnCount==='auto'&&style.columnWidth==='auto'&&simpleAncestor(element.parentElement);
        ancestorStyles.set(element,simple);return simple;
      };
      cache.blocks = [...document.body.querySelectorAll('p,h1,h2,h3,h4,h5,h6')].map((element, index) => {
        // Anchor-only chapter markers have no line box. Inserting even a
        // zero-width glyph stops margins collapsing through them and shifts
        // every subsequent column (including otherwise visible words).
        if (!element.textContent.trim() || !/^(P|H[1-6])$/.test(element.tagName) ||
            !simpleAncestor(element.parentElement)||
            element.querySelector('img,svg,math,table,video,audio,canvas,iframe,object')) return null;
        const style = document.defaultView.getComputedStyle(element);
        if (style.display !== 'block' || style.position !== 'static' || style.float !== 'none' ||
            style.transform !== 'none' || style.columnCount !== 'auto' || style.columnWidth !== 'auto'||
            style.boxShadow!=='none'||style.textShadow!=='none'||style.filter!=='none') return null;
        // Authored nowrap/height constraints can put visible ink beyond the
        // block's box. Such content must not be culled using box visibility.
        if(element.scrollWidth>element.clientWidth+1||element.scrollHeight>element.clientHeight+1)return null;
        for(const child of element.querySelectorAll('*')){
          const childStyle=document.defaultView.getComputedStyle(child);
          if(childStyle.float!=='none'||childStyle.position!=='static'||!['inline','contents','none'].includes(childStyle.display))return null;
        }
        const rects = [...element.getClientRects()].map(r => ({left:r.left,right:r.right,top:r.top,bottom:r.bottom}));
        // Fragmented paragraphs carry widow/orphan line-break constraints.
        // Their line boxes must stay intact even when the glyphs are offscreen.
        if(rects.length!==1)return null;
        return {index, height:style.height, rects};
      }).filter(Boolean);
    }
    const blocks = root.querySelector('body').querySelectorAll('p,h1,h2,h3,h4,h5,h6');
    for (const block of cache.blocks) {
      // Retain adjacent line boxes too, including italic glyph overhangs at a
      // page edge that are outside the block's nominal rectangle.
      if (block.rects.some(r => r.right > clip.left-128 && r.left < clip.right+128 && r.bottom > clip.top-128 && r.top < clip.bottom+128)) continue;
      const element = blocks[block.index];
      element.textContent = '\u200b';
      element.style.setProperty('height', block.height, 'important');
      element.style.setProperty('break-inside', 'avoid', 'important');
      element.style.setProperty('visibility', 'hidden', 'important');
    }
  }
}

(() => {
  let book, rendition, config, preferences, location, auxiliary, anchor;
  let renditionSpineHooks = [], operationQueue = Promise.resolve(), turnAnimation, sheetEffect, gesture;
  let interactiveNavigation = false, suppressClickUntil = 0, inputSuspended = false;
  const settledDocuments = new WeakSet();
  function enqueue(operation) {
    const pending = operationQueue.then(() => disposed ? undefined : operation());
    operationQueue = pending.catch(() => {});
    return pending;
  }
  let lastTurnDelta = 1;
  let userMoveUntil = 0;
  let restoring = true, disposed = false, userMove = false, relocationTimer, resizeTimer = null, layoutJobs = 0;
  const tick = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const inputEvents = ['wheel', 'touchstart', 'touchmove'];
  const interruptMouse = event => {if(event.pointerType==='mouse'&&!gesture)cancelTurnAnimation();};
  const noteUserMove = () => {
    if (!restoring && !disposed) {
      if (!gesture) cancelTurnAnimation();
      userMove = true; userMoveUntil = Date.now() + 2000;
      // A no-op programmatic scroll can leave Epub.js ignoring its next event.
      // Real input owns that next scroll and must update the reading locator.
      if (rendition?.manager) rendition.manager.ignore = false;
    }
  };
  const send = (type, value = {}) => {
    if (disposed || !config) return;
    const message = {type, ...value, nonce: config.nonce};
    if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('readerEvent', message);
    else window.dispatchEvent(new CustomEvent('readerEvent', {detail: message}));
  };
  const timeout = (promise, ms = 6000) => {
    let timer;
    return Promise.race([promise, new Promise(resolve => {timer = setTimeout(resolve, ms);})])
      .finally(() => clearTimeout(timer));
  };
  const colors = () => /^#[a-f0-9]{6}$/i.test(preferences.backgroundColor || '') && /^#[a-f0-9]{6}$/i.test(preferences.textColor || '') ? [preferences.backgroundColor, preferences.textColor] : preferences.theme === 'black' ? ['#1c1c1e', '#e8e4dc'] : preferences.theme === 'white' ? ['#ffffff', '#262321'] : ['#efe5d0', '#262321'];
  const isFixedLayout = () => Boolean(book && (book.package?.metadata.layout === 'pre-paginated' || book.displayOptions?.fixedLayout === 'true'));
  const verticalWriting = () => Boolean(rendition?.manager?.writingMode?.startsWith('vertical'));
  const spreadPreference = value => verticalWriting() ? 'none' : value.columns === 1 ? 'none' : value.columns === 2 ? 'always'
    : isFixedLayout() && book.package?.metadata.spread === 'none' ? 'none'
    : isFixedLayout() && book.package?.metadata.spread === 'both' ? 'always' : 'auto';
  // Epub.js formats through setters that immediately read computed geometry.
  // A chapter was being laid out at its publisher size, again at each width /
  // height setter, and once more when our late content hook applied typography.
  // These formatting methods do not consume setter return values. Apply the
  // reader stylesheet first and batch their writes; ordinary getters retain
  // upstream semantics and the following expand() measures the final layout.
  const formattingContents = new WeakSet();
  const IframeView = ePub.Rendition.prototype.requireView('iframe');
  const createIframe = IframeView.prototype.create;
  IframeView.prototype.create = function(...args) {
    const frame = createIframe.apply(this, args);
    // Loading long prose into a zero-width iframe first wraps every word on
    // its own line. Give the still-hidden frame its real initial viewport;
    // expand() remains responsible for the final chapter extent.
    if (!this.contents) {
      frame.style.width = Math.max(1, this.settings.width || this.layout.width) + 'px';
      frame.style.height = Math.max(1, this.settings.height || this.layout.height) + 'px';
    }
    return frame;
  };
  const destroyIframe = IframeView.prototype.destroy;
  IframeView.prototype.destroy = function(...args) {
    const result=destroyIframe.apply(this,args);
    // Upstream drops the native iframe but retains both the parsed source DOM
    // and its serialized XHTML on the spine (and on reusable continuous views).
    // Keep source documents only while a live view is actually using them.
    this.sectionRender=undefined;
    const shared=rendition?.manager?.views?.all().some(view=>
      view!==this&&view.section===this.section&&(view.contents||view.rendering));
    if(!shared)this.section?.unload();
    return result;
  };
  const showIframe = IframeView.prototype.show;
  IframeView.prototype.show = function(...args) {
    // ContinuousManager.update() calls show() on every scroll check, even for
    // an already visible chapter. Upstream's Safari redraw workaround toggles
    // translateZ and reads offsetWidth each time, invalidating Chromium's layer
    // and forcing synchronous layout throughout normal Windows/Android scroll.
    if(this.element.style.visibility==='visible'&&this.iframe?.style.visibility==='visible')return;
    return showIframe.apply(this,args);
  };
  for (const name of ['columns', 'size', 'fit']) {
    const format = ePub.Contents.prototype[name];
    ePub.Contents.prototype[name] = function(...args) {
      if (preferences) style(this.document);
      formattingContents.add(this);
      try { return format.apply(this, args); }
      finally { formattingContents.delete(this); }
    };
  }
  for (const name of ['width', 'height', 'css']) {
    const original = ePub.Contents.prototype[name];
    ePub.Contents.prototype[name] = function(value, ...args) {
      if (formattingContents.has(this)) {
        const target = this.content || this.document.body;
        if (name === 'css' && args[0]) {
          target.style.setProperty(value, args[0], args[1] ? 'important' : '');
          return;
        }
        if (name !== 'css' && value) {
          target.style[name] = typeof value === 'number' ? value + 'px' : value;
          return;
        }
      }
      return original.call(this, value, ...args);
    };
  }
  function atReadingEnd() {
    if (!location?.atEnd) return false;
    if (preferences.flow !== 'scrolled' || !rendition?.manager?.container) return true;
    const manager = rendition.manager, container = manager.container;
    return manager.settings.axis === 'horizontal'
      ? container.scrollWidth - container.clientWidth - Math.abs(container.scrollLeft) <= 2
      : container.scrollHeight - container.clientHeight - container.scrollTop <= 2;
  }
  // Axis selection happens before rendition content hooks. Adapt the public
  // Contents getter so body-declared CJK writing modes are visible in time.
  const nativeWritingMode = ePub.Contents.prototype.writingMode;
  ePub.Contents.prototype.writingMode = function(value) {
    if (!value && !isFixedLayout() && this.document.body) {
      const root = nativeWritingMode.call(this);
      const body = this.window.getComputedStyle(this.document.body).writingMode;
      if (body.startsWith('vertical') && !root.startsWith('vertical')) nativeWritingMode.call(this, body);
    }
    return nativeWritingMode.call(this, value);
  };
  function style(document) {
    if(!document.documentElement.lang&&config?.language)document.documentElement.lang=config.language;
    if (document.documentElement.style) document.documentElement.style.touchAction = preferences.flow === 'paged' ? 'pan-y pinch-zoom' : 'auto';
    const [background, foreground] = colors();
    let head = document.head || document.querySelector('head');
    if (!head) { head = document.createElementNS('http://www.w3.org/1999/xhtml', 'head'); document.documentElement.prepend(head); }
    let sheet = document.getElementById('kmreader-preferences');
    if (!sheet) { sheet = document.createElementNS('http://www.w3.org/1999/xhtml', 'style'); sheet.id = 'kmreader-preferences'; head.appendChild(sheet); }
    // Fixed pages position artwork and text in an authored coordinate system.
    // Reflow typography or color overrides would change that composition.
    if (isFixedLayout()) { if (sheet.textContent) sheet.textContent = ''; return; }
    const custom = preferences.fontUrl && new URL(preferences.fontUrl).origin === window.location.origin;
    const family = custom ? 'font-family:kmreader-custom !important;' : ['serif','sans-serif'].includes(preferences.font) ? `font-family:${preferences.font} !important;` : '';
    const face = custom ? `@font-face{font-family:kmreader-custom;src:url("${preferences.fontUrl}");font-display:block;}` : '';
    const align = preferences.advancedLayout !== false && ['left', 'right', 'justify', 'center'].includes(preferences.alignment) ? `text-align:${preferences.alignment} !important;` : '';
    const css = `${face}html,body{background:${background} !important;color:${foreground} !important;}
      body{${preferences.advancedLayout === false ? '' : `font-size:${preferences.fontSize}px !important;line-height:${preferences.lineHeight} !important;`}${family}${align}${preferences.fontWeight > 0 ? `font-weight:${preferences.fontWeight} !important;` : ''}}
      ${preferences.advancedLayout === false ? '' : `p{margin-block-end:${preferences.paragraphSpacing}em !important;text-indent:${preferences.indent}em !important;} body{letter-spacing:${preferences.letterSpacing}em !important;word-spacing:${preferences.wordSpacing}em !important;}`}
      pre{white-space:pre-wrap !important;overflow-wrap:anywhere !important;max-inline-size:100%;box-sizing:border-box;}
      ::selection{background:rgba(75,135,230,.38);color:inherit;}img,svg,video{max-width:100% !important;object-fit:contain;}a{color:${preferences.theme === 'black' ? '#9fc6ff' : '#235a9c'};}`;
    const resolvedCss=css+'\nhtml{-webkit-text-size-adjust:none!important;text-size-adjust:none!important}';
    if (sheet.textContent !== resolvedCss) sheet.textContent = resolvedCss;
  }
  async function stable(contents) {
    await tick();
    await timeout(Promise.all(contents.map(async content => {
      const doc = content.document || content;
      if (doc.fonts) await doc.fonts.ready;
      await Promise.all([...doc.images].map(image => image.complete ? Promise.resolve() : new Promise(resolve => {
        image.addEventListener('load', resolve, {once: true}); image.addEventListener('error', resolve, {once: true});
      })));
    })));
    await tick();
    for (const content of contents) settledDocuments.add(content.document || content);
  }
  const textIndexes = new WeakMap();
  // Epub.js restarts its text walk at the beginning of the chapter for both
  // ends of every location query. Keep its mapping rules and word ranges, but
  // reuse text-node geometry until the publication actually changes.
  const mappingGeometry = new WeakMap(), adaptedMapping = new WeakSet();
  const contentDisposers = new WeakMap();
  function geometryFor(root) {
    const doc = root.ownerDocument;
    let cache = mappingGeometry.get(root);
    if (!cache) {
      cache = {nodes:null, bounds:new WeakMap(), pages:new Map(), range:doc.createRange()};
      const invalidate = records => {
        cache.bounds = new WeakMap();
        cache.pages.clear();
        if (!records || records.some(r => r.type !== 'attributes')) cache.nodes = null;
      };
      cache.observer = new MutationObserver(records => invalidate(records));
      cache.observer.observe(doc, {subtree:true, childList:true, characterData:true, attributes:true});
      // Intrinsic image/font changes need not mutate the DOM. Scrolling an
      // authored nested scrollport also changes text's viewport geometry.
      const changed = () => invalidate();
      doc.addEventListener('load', changed, true);
      doc.addEventListener('scroll', changed, true);
      doc.fonts?.addEventListener('loadingdone', changed);
      doc.defaultView.addEventListener('resize', changed);
      const resize = new ResizeObserver(changed);
      resize.observe(root); cache.resize = resize;
      cache.dispose=()=>{
        cache.observer.disconnect();resize.disconnect();
        doc.removeEventListener('load',changed,true);doc.removeEventListener('scroll',changed,true);
        doc.fonts?.removeEventListener('loadingdone',changed);doc.defaultView?.removeEventListener('resize',changed);
        cache.nodes=null;cache.pages.clear();mappingGeometry.delete(root);
      };
      mappingGeometry.set(root, cache);
    }
    const records = cache.observer.takeRecords();
    if (records.length) {
      cache.bounds = new WeakMap();
      cache.pages.clear();
      if (records.some(r => r.type !== 'attributes')) cache.nodes = null;
    }
    // Publisher CSS can animate layout without DOM mutations. Measure fresh
    // bounds while those animations run.
    if (doc.getAnimations?.().some(animation => animation.playState === 'running' || animation.pending)) {
      cache.bounds = new WeakMap(); cache.pages.clear();
    }
    if (!cache.nodes) {
      cache.nodes = [];
      const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) if (node.data.trim()) cache.nodes.push(node);
    }
    return cache;
  }
  const destroyMappedContents=ePub.Contents.prototype.destroy;
  ePub.Contents.prototype.destroy=function(...args){
    // A ResizeObserver created in the host window can retain an observed
    // iframe body after navigation. Weak map keys alone do not release it.
    mappingGeometry.get(this.document?.body)?.dispose();
    contentDisposers.get(this.document)?.();contentDisposers.delete(this.document);
    return destroyMappedContents.apply(this,args);
  };
  function textBounds(cache, node) {
    let bounds = cache.bounds.get(node);
    if (!bounds) {
      cache.range.selectNodeContents(node);
      bounds = cache.range.getBoundingClientRect(); cache.bounds.set(node, bounds);
    }
    return bounds;
  }
  function adaptLocationMapping(manager) {
    if (!manager?.mapping || adaptedMapping.has(Object.getPrototypeOf(manager.mapping))) return;
    const prototype = Object.getPrototypeOf(manager.mapping);
    adaptedMapping.add(prototype);
    const page = prototype.page;
    prototype.page = function(contents, base, start, end) {
      const root = contents?.document?.body;
      if (!root || this._dev || typeof ResizeObserver === 'undefined') return page.call(this, contents, base, start, end);
      const cache = geometryFor(root), key = JSON.stringify([this.horizontal, this.direction, base, start, end]);
      if (cache.pages.has(key)) return cache.pages.get(key);
      const result = page.call(this, contents, base, start, end);
      cache.pages.set(key, result);
      if (cache.pages.size > 8) cache.pages.delete(cache.pages.keys().next().value);
      return result;
    };
    for (const end of [false, true]) {
      const name = end ? 'findEnd' : 'findStart', original = prototype[name];
      prototype[name] = function(root, start, finish) {
        if (!root || root.nodeType === Node.TEXT_NODE || typeof ResizeObserver === 'undefined') return original.call(this, root, start, finish);
        const cache = geometryFor(root);
        let previous = root;
        for (const node of cache.nodes) {
          const bounds = textBounds(cache, node);
          const low = this.horizontal ? bounds.left : bounds.top;
          const high = this.horizontal ? bounds.right : bounds.bottom;
          let found;
          if (end) {
            if (this.horizontal && this.direction === 'rtl') {
              if (Math.round(high) < start && previous) found = previous;
              else if (Math.round(low) < start) found = node;
            } else {
              if (Math.round(low) > finish && previous) found = previous;
              else if (Math.round(high) > finish) found = node;
            }
          } else if (this.horizontal && this.direction === 'rtl') {
            if (high <= finish && high >= start || low < finish) found = node;
          } else if (low >= start && low <= finish || high > start) found = node;
          if (found) return end ? this.findTextEndRange(found, start, finish) : this.findTextStartRange(found, start, finish);
          previous = node;
        }
        return end ? this.findTextEndRange(previous, start, finish) : this.findTextStartRange(previous, start, finish);
      };
    }
  }
  function retainLocationLayout(manager) {
    const original = manager.currentLocation;
    manager.currentLocation = function() {
      // A position read must not reformat every iframe. Actual resize, flow,
      // font and spread changes already update layout through their own paths.
      // Keep the upstream barrier when native viewport bounds have changed.
      const padding=this.stage?.containerPadding||{};
      const width=(this.container?.clientWidth||0)-(padding.left||0)-(padding.right||0);
      const height=(this.container?.clientHeight||0)-(padding.top||0)-(padding.bottom||0);
      // Stage.size() measures the content box, excluding classic scrollbars
      // and padding. Comparing it to innerWidth invalidated every Windows
      // continuous-scroll query and defeated the geometry cache.
      if (!this._stageSize || !width || !height || this._stageSize.width !== width || this._stageSize.height !== height) return original.call(this);
      return this.location = this.isPaginated && this.settings.axis === 'horizontal'
        ? this.paginatedLocation() : this.scrolledLocation();
    };
  }
  function textIndex(contents) {
    const doc = contents.document;
    if (textIndexes.has(doc)) return textIndexes.get(doc);
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    const nodes = [], offsets = new WeakMap(); let length = 0, node;
    while ((node = walker.nextNode())) {
      if (['STYLE', 'SCRIPT'].includes(node.parentElement.tagName)) continue;
      offsets.set(node, length); nodes.push(node); length += node.length;
    }
    const index = {nodes, offsets, length}; textIndexes.set(doc, index); return index;
  }
  function progression(start, displayed) {
    for (const contents of rendition.getContents()) {
      if (contents.sectionIndex !== start.index) continue;
      try {
        const index = textIndex(contents), range = contents.range(start.cfi);
        const offset = index.offsets.get(range.startContainer);
        if (index.length && offset !== undefined) return Math.min(1, (offset + range.startOffset) / index.length);
      } catch (_) { /* Image-only sections use their page position. */ }
    }
    return Math.max(0, (displayed.page - 1) / Math.max(1, displayed.total));
  }
  function visibleTextCfi(contents, viewport) {
    const nodes = textIndex(contents).nodes, doc = contents.document;
    let mapped;
    try { mapped = contents.range(location.start.cfi); } catch (_) { return; }
    let first = nodes.indexOf(mapped.startContainer);
    if (first < 0) first = nodes.findIndex(node => mapped.startContainer.contains(node));
    if (first < 0) first = 0;
    const range = doc.createRange();
    const visible = () => [...range.getClientRects()].some(rect =>
      rect.width > 0 && rect.height > 0 && rect.right > viewport.left + 1 &&
      rect.left < viewport.right - 1 && rect.bottom > viewport.top + 1 &&
      rect.top < viewport.bottom - 1);
    // The mapper identifies the paragraph. Prefix visibility is monotonic, so
    // binary search finds its first visible UTF-16 offset without scanning the
    // chapter character by character or relying on platform caret hit testing.
    for (let i = first; i < Math.min(nodes.length, first + 64); i++) {
      const node = nodes[i];
      if (!node.length || !node.textContent.trim()) continue;
      range.selectNodeContents(node);
      if (!visible()) continue;
      let low = 0, high = node.length - 1;
      while (low < high) {
        const middle = Math.floor((low + high) / 2);
        range.setStart(node, 0); range.setEnd(node, middle + 1);
        if (visible()) high = middle; else low = middle + 1;
      }
      range.setStart(node, low); range.collapse(true);
      return contents.cfiFromRange(range);
    }
  }
  function refineVerticalLocator() {
    if (!verticalWriting() || isFixedLayout() || !location) return;
    const contents = rendition.getContents().find(content => content.sectionIndex === location.start.index);
    const doc = contents?.document, frame = doc?.defaultView?.frameElement;
    if (!frame) return;
    const viewport = rendition.manager.container.getBoundingClientRect(), bounds = frame.getBoundingClientRect();
    const style = doc.defaultView.getComputedStyle(doc.body);
    const leftToRight = contents.writingMode().endsWith('-lr');
    const edge = leftToRight ? viewport.left - bounds.left : viewport.right - bounds.left;
    const padding = parseFloat(leftToRight ? style.paddingLeft : style.paddingRight) || 0;
    const top = viewport.top - bounds.top, right = viewport.right - bounds.left, left = viewport.left - bounds.left;
    // The stock mapper can return the same paragraph start for successive
    // pages of large vertical text. Ask the browser for the visible character.
    const fontSize = parseFloat(style.fontSize) || 16, lineHeight = parseFloat(style.lineHeight) || fontSize * 1.5;
    for (const inset of [padding + lineHeight / 2, padding + fontSize / 2, padding + 1]) {
      for (const dy of [fontSize / 2, fontSize, lineHeight / 2]) {
        const x = edge + (leftToRight ? inset : -inset);
        const y = top + (parseFloat(style.paddingTop) || 0) + dy;
        const range = doc.caretRangeFromPoint?.(x, y);
        if (!range || range.startContainer.nodeType !== Node.TEXT_NODE || !range.startContainer.textContent.trim()) continue;
        const rect = range.getBoundingClientRect();
        if ((rect.width || rect.height) && rect.right >= left && rect.left <= right && rect.top >= top - 1 && rect.top < top + viewport.height) {
          const cfi = contents.cfiFromRange(range);
          if (cfi === anchor) continue;
          location.start.cfi = cfi;
          return;
        }
      }
    }
    const cfi = visibleTextCfi(contents, {left, right, top, bottom: top + viewport.height});
    if (cfi) location.start.cfi = cfi;
  }
  function kindleOriginalPosition(start) {
    if (!config.kindlePositions || !start?.cfi) return null;
    try {
      const cfi = new ePub.CFI(start.cfi);
      for (const contents of rendition.getContents()) {
        if (contents.sectionIndex !== cfi.spinePos) continue;
        const range = cfi.toRange(contents.document);
        const node = range?.startContainer;
        const element = (node?.nodeType === 1 ? node : node?.parentElement)
          ?.closest('[data-kmreader-kindle-position]');
        if (!element) continue;
        const original = Number(element.getAttribute('data-kmreader-kindle-position'));
        const length = Number(element.getAttribute('data-kmreader-kindle-length'));
        if (!Number.isSafeInteger(original) || !Number.isSafeInteger(length) ||
            original < 0 || length !== [...element.textContent].length) continue;
        const prefix = contents.document.createRange();
        prefix.selectNodeContents(element);
        prefix.setEnd(range.startContainer, range.startOffset);
        const offset = [...prefix.toString()].length;
        if (offset >= 0 && offset < length) return original + offset;
      }
    } catch (_) {}
    return null;
  }
  async function restoreKindlePosition(value) {
    for (const contents of rendition.getContents()) {
      const element = contents.document.getElementById(String(value.id));
      if (!element || Number(element.getAttribute('data-kmreader-kindle-position')) !== value.position) continue;
      let remaining = value.offset;
      if (!Number.isSafeInteger(remaining) || remaining < 0 ||
          remaining >= Number(element.getAttribute('data-kmreader-kindle-length'))) return null;
      const walker = contents.document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const characters = [...node.data];
        if (remaining >= characters.length) { remaining -= characters.length; continue; }
        const range = contents.document.createRange();
        range.setStart(node, characters.slice(0, remaining).join('').length);
        range.collapse(true);
        const cfi = contents.cfiFromRange(range);
        await displayStable(cfi);
        return cfi;
      }
    }
    return null;
  }
  const renderedAnnotations = new Map();
  function kindlePoint(contents, value) {
    if (!value || !Number.isSafeInteger(value.offset) || value.offset < 0) return null;
    const element = contents.document.getElementById(String(value.id));
    if (!element || Number(element.dataset.kmreaderKindlePosition) !== value.position || value.offset > Number(element.dataset.kmreaderKindleLength) || Number(element.dataset.kmreaderKindleLength) !== [...element.textContent].length) return null;
    let remaining = value.offset, last;
    const walker = contents.document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const characters = [...node.data]; last = node;
      if (remaining <= characters.length) return [node, characters.slice(0, remaining).join('').length];
      remaining -= characters.length;
    }
    return last && remaining === 0 ? [last, last.length] : null;
  }
  function drawKindleAnnotations() {
    if (!config.kindlePositions || !rendition) return;
    for (const mark of config.annotations || []) {
      if (!mark.endLocator || mark.locator?.href !== mark.endLocator.href || renderedAnnotations.has(mark.id)) continue;
      for (const contents of rendition.getContents()) {
        try {
          const cfi = kindleRange(contents, mark);
          if (!cfi) continue;
          // Epub.js uses a separate SVG overlay. Publication text nodes and
          // their original position markers are never replaced or wrapped.
          rendition.annotations.highlight(cfi, {}, null, 'kmreader-kindle-highlight', {fill:'#e6b72d','fill-opacity':'.24','mix-blend-mode':'multiply'});
          renderedAnnotations.set(mark.id,cfi);
          captureRevision++;capturePages.clear();
        } catch (_) { /* Unsupported annotation ranges remain navigable in the list. */ }
      }
    }
  }
  function kindleRange(contents, mark) {
    const start=kindlePoint(contents,mark.locator),end=kindlePoint(contents,mark.endLocator);
    if(!start||!end)return null;
    const range=contents.document.createRange();range.setStart(...start);range.setEnd(...end);
    return range.collapsed?null:contents.cfiFromRange(range);
  }
  function updateKindleAnnotations(value) {
    for(const cfi of renderedAnnotations.values())rendition?.annotations.remove(cfi,'highlight');
    renderedAnnotations.clear();config.annotations=value;captureRevision++;capturePages.clear();
    drawKindleAnnotations();return true;
  }
  function annotationMarkup(frame,shift){
    return [...frame.parentElement.querySelectorAll('svg')].filter(svg=>svg.querySelector('.kmreader-kindle-highlight')).map(svg=>{
      const box=svg.getBoundingClientRect(),clone=svg.cloneNode(true);
      clone.removeAttribute('style');clone.setAttribute('x','0');clone.setAttribute('y','0');
      clone.setAttribute('width',box.width);clone.setAttribute('height',box.height);
      return `<g transform="translate(${box.x+shift} ${box.y})">${new XMLSerializer().serializeToString(clone)}</g>`;
    }).join('');
  }
  function position(changed = false) {
    if (!location || restoring || auxiliary || interactiveNavigation) return;
    // Delayed Epub.js reports contain a coarse paragraph CFI, which can lie on
    // the preceding page in large vertical text. Only real navigation chooses
    // a new anchor; reflow/reporting must retain the committed character CFI.
    if (changed || !anchor) refineVerticalLocator();
    else location.start.cfi = anchor;
    const start = location.start, displayed = start.displayed || {page: 1, total: 1};
    changed = changed && start.cfi !== anchor;
    if (changed) {
      anchor = start.cfi;
      if (preferences.flow === 'scrolled') userMoveUntil = Date.now() + 2000;
    }
    send('position', {cfi: start.cfi, href: start.href, page: displayed.page, pages: displayed.total,
      progression: progression(start, displayed),
      totalProgression: Number.isFinite(start.percentage) ? start.percentage : null,
      atStart: !!location.atStart, atEnd: atReadingEnd(), changed,
      ...(config.kindlePositions ? {kindlePosition: kindleOriginalPosition(start)} : {})});
  }
  function hook(contents) {
    adaptLocationMapping(rendition.manager);
    const section = book.spine.get(contents.sectionIndex);
    const doc = contents.document;
    const active = () => doc.defaultView && doc.defaultView.frameElement && doc.defaultView.frameElement.isConnected;
    const mutations=new MutationObserver(records=>{
      captureRevision++;capturePages.clear();
      if(records.some(record=>record.type!=='attributes'))textIndexes.delete(doc);
    });
    mutations.observe(doc.body,{subtree:true,childList:true,characterData:true,attributes:true});
    contentDisposers.set(doc,()=>{mutations.disconnect();clearTimeout(doc._selectionReport);textIndexes.delete(doc);});
    if (!doc.documentElement.lang && config.language) doc.documentElement.lang = config.language;
    if (!doc.documentElement.dir && config.direction === 'rtl' && !contents.writingMode().startsWith('vertical')) doc.documentElement.dir = 'rtl';
    style(doc);
    const clearSelection = () => doc.getSelection()?.removeAllRanges();
    if (preferences.flow === 'scrolled' && rendition.manager?.stage) {
      // The first CJK view can change the manager axis after its stage chose
      // overflow-x/y. Reapply that policy so the new axis accepts input.
      const manager = rendition.manager;
      manager.stage.overflow(manager.overflow || 'scroll');
    }
    doc.addEventListener('click', event => {
      if (inputSuspended || Date.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); return; }
      const link = event.target.closest && event.target.closest('a[href]');
      if (link) {
        event.preventDefault(); event.stopImmediatePropagation();
        send('link', {href: link.href, base: section.href});
      } else if (doc.getSelection().isCollapsed) {
        const bounds = doc.defaultView.frameElement.getBoundingClientRect();
        send('tap', {pointerType: event.pointerType || 'mouse', x: (bounds.left + event.clientX) / window.innerWidth, y: (bounds.top + event.clientY) / window.innerHeight});
      }
    }, true);
    doc.addEventListener('keydown', event => {
      if (inputSuspended || event.ctrlKey || event.metaKey || event.altKey) return;
      if (event.key === 'Escape' && !doc.getSelection().isCollapsed) { clearSelection(); event.preventDefault(); return; }
      if (!doc.getSelection().isCollapsed && !['ArrowLeft','ArrowRight','PageDown','PageUp','F11'].includes(event.key)) return;
      const rtl = config.direction === 'rtl';
      if (event.key === 'F11') { event.preventDefault(); send('fullscreen'); }
      else if (event.key === ' ' && preferences.spaceKeyAction === 'toggleControls') { event.preventDefault(); send('controls'); }
      else if ([rtl ? 'ArrowLeft' : 'ArrowRight', 'PageDown', ' '].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: 1});
      } else if ([rtl ? 'ArrowRight' : 'ArrowLeft', 'PageUp'].includes(event.key)) {
        event.preventDefault(); send('turn', {delta: -1});
      } else if (event.key === 'Escape') send('close');
    });
    let contact;
    const point = event => {
      const frame = doc.defaultView.frameElement.getBoundingClientRect();
      return {x: frame.left + event.clientX, y: frame.top + event.clientY};
    };
    doc.addEventListener('pointerdown', event => {
      if (!event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) {
        cancelGesture(); contact = null; return;
      }
      if (inputSuspended) { event.preventDefault(); return; }
      const p = point(event);
      let textHit = false;
      if (event.pointerType === 'mouse') {
        interruptMouse(event);
        // caretRangeFromPoint snaps to the nearest paragraph even in margins.
        // Only a hit on a real glyph may start a native text selection.
        const caret = doc.caretRangeFromPoint?.(event.clientX,event.clientY);
        if (caret?.startContainer.nodeType === Node.TEXT_NODE && caret.startContainer.length) {
          const range=caret.cloneRange(),node=caret.startContainer;
          // A caret snaps to either side of a character. Test both neighbors,
          // otherwise the right half of a glyph is mistaken for blank margin.
          for(const offset of new Set([Math.min(caret.startOffset,node.length-1),Math.max(0,caret.startOffset-1)])) {
            range.setStart(node,offset);range.setEnd(node,offset+1);
            if([...range.getClientRects()].some(r=>event.clientX>=r.left-2&&event.clientX<=r.right+2&&event.clientY>=r.top&&event.clientY<=r.bottom)){textHit=true;break;}
          }
        }
        if (!textHit && !event.target.closest?.('a[href]')) { event.preventDefault(); clearSelection(); }
      }
      const edge = p.x < innerWidth * .18 || p.x > innerWidth * .82;
      contact = event.target.closest?.('a[href]') || (event.pointerType === 'mouse' && (!edge || textHit))
        ? null : {id:event.pointerId,x:p.x,y:p.y,time:Date.now()};
      if (contact && event.pointerType === 'mouse' && edge && preferences.flow === 'paged') {
        event.preventDefault();
        try { doc.documentElement.setPointerCapture(event.pointerId); } catch (_) {}
      }
    }, {passive:false});
    doc.addEventListener('dragstart', event => { if (preferences.flow === 'paged') event.preventDefault(); });
    doc.addEventListener('pointermove', event => {
      if (gesture?.pointer === event.pointerId) { event.preventDefault(); gesture.update(point(event)); return; }
      if (!contact || event.pointerId !== contact.id || preferences.flow !== 'paged' || auxiliary ||
          !doc.getSelection().isCollapsed) return;
      const p = point(event), dx = p.x - contact.x, dy = p.y - contact.y;
      if (Math.abs(dx) < 14 || Math.abs(dx) < Math.abs(dy) * 1.3 || Date.now() - contact.time > 550) return;
      if (preferences.followGesture !== false && motionAllowed(preferences.transition) && KMReaderSheetEffect.supported(preferences.transition)) {
        event.preventDefault();
        beginGesture(contact, p, event.pointerId);
        contact = null;
      }
    }, {passive:false});
    doc.addEventListener('pointerup', event => {
      if (gesture?.pointer === event.pointerId) { event.preventDefault(); gesture.update(point(event)); gesture.release(); contact = null; return; }
      if (!contact || event.pointerId !== contact.id) return;
      const p = point(event), dx = p.x - contact.x, dy = p.y - contact.y;
      if (preferences.flow === 'paged' && doc.getSelection().isCollapsed && Math.abs(dx) > 45 &&
          Math.abs(dx) > Math.abs(dy) * 1.3 && Date.now() - contact.time < 1000) {
        event.preventDefault(); suppressClickUntil = Date.now() + 500;
        send('turn', {delta: dx < 0 !== (config.direction === 'rtl') ? 1 : -1});
      }
      contact = null;
    }, {passive:false});
    doc.addEventListener('pointercancel', () => { contact = null; cancelGesture(); });
    doc.addEventListener('wheel', noteUserMove, {passive: true});
    let reflowQueued = false;
    const resourceChanged = () => {
      settledDocuments.delete(doc);
      if (!active() || restoring || !location || reflowQueued) return;
      reflowQueued = true;
      enqueue(async () => {
        reflowQueued = false;
        if (active()) await preserve(() => Promise.resolve());
      }).catch(error => send('error', {message: String(error)}));
    };
    for (const image of doc.images) image.addEventListener('load', resourceChanged);
    if (doc.fonts) doc.fonts.addEventListener('loadingdone', resourceChanged);
    doc.addEventListener('selectionchange', () => {
      const selection = doc.getSelection();
      if (inputSuspended) return;
      const selected = selection.isCollapsed ? '' : selection.toString().trim().slice(0,16000);
      clearTimeout(doc._selectionReport);
      doc._selectionReport=setTimeout(()=>send('selection',{text:selected}),80);
    });
  }
  function resizePublication(width, height) {
    const manager = rendition.manager;
    if (isFixedLayout() || preferences.flow !== 'paged' || !manager?.views?.length) {
      rendition.resize(width, height); return;
    }
    // DefaultManager.resize clears every iframe and asks Rendition to display
    // again. Keep the live reflowable document while updating its column box.
    rendition.settings.width = width; rendition.settings.height = height;
    manager.stage.size(width, height);
    manager._stageSize = manager.stage.size(); manager._bounds = manager.bounds();
    manager.updateLayout();
    manager.views.forEach(view => {
      const collapsed=view.displayed&&view.iframe?.isConnected&&view.iframe.clientHeight===0;
      const previousReframe=view._needsReframe;
      if(collapsed)view._needsReframe=true;
      view.size(manager.layout.width, manager.layout.height);
      view.setLayout(manager.layout);
      if(collapsed)view._needsReframe=previousReframe;
    });
  }
  function collapsedPageView(){
    const manager=rendition?.manager;
    if(preferences?.flow!=='paged'||manager?.settings.axis!=='horizontal'||isFixedLayout())return false;
    let collapsed=false;
    manager.views?.forEach(view=>{if(view.displayed&&view.iframe?.isConnected&&view.iframe.clientHeight===0)collapsed=true;});
    return collapsed;
  }
  function layoutReady() {
    return !restoring && resizeTimer === null && layoutJobs === 0 &&
      Boolean(rendition?.getContents().length) && !collapsedPageView();
  }
  async function waitForLayout() {
    if (resizeTimer !== null) {
      clearTimeout(resizeTimer); resizeTimer = null;
      await preserve(() => resizePublication(window.innerWidth, window.innerHeight));
    }
    const deadline = Date.now() + 10000;
    while (restoring || resizeTimer !== null || layoutJobs > 0) {
      if (disposed) return;
      if (Date.now() > deadline) throw new Error('The EPUB layout did not settle.');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    // Native view recreation can leave an iframe at zero height even when the
    // host viewport and saved CFI are valid. Repair only that invalid state;
    // stable position reads keep the retained-layout optimization.
    if(collapsedPageView())await preserve(()=>resizePublication(innerWidth,innerHeight));
  }
  async function preserve(change) {
    if (!rendition) return;
    cancelCurlWarm();captureRevision++;capturePages.clear();
    cancelTurnAnimation();
    const cfi = anchor || (location && location.start.cfi);
    if (layoutJobs === 0) send('layout', {active:true});
    layoutJobs++; restoring = true; userMove = false; userMoveUntil = 0; clearTimeout(relocationTimer);
    try {
      await change();
      await stable(rendition.getContents());
      if (cfi) await displayStable(cfi);
      await tick();
    } finally { layoutJobs--; restoring = layoutJobs > 0; position(false); if (!restoring) { send('layout', {active:false}); warmCurl(); } }
  }
  function setPreferences(value) {
    cancelGesture();
    // Flow changes replace the manager. Keep rapid preference updates ordered
    // so an older reflow cannot destroy a newer rendition or restore its CFI.
    return enqueue(() => applyPreferences(value));
  }
  async function applyPreferences(value) {
    await waitForLayout();
    cancelCurlWarm();
    const motionKeys = new Set(['animationDuration','followGesture','pageTint','pageCornerRadius','curlReach','animate','transition']);
    if ([...new Set([...Object.keys(preferences), ...Object.keys(value)])].every(key =>
        motionKeys.has(key) || JSON.stringify(preferences[key]) === JSON.stringify(value[key]))) {
      cancelTurnAnimation(); preferences = value;
      if (!curlConfigured()) releaseCurl();
      warmCurl(); return;
    }
    captureRevision++;capturePages.clear();
    const flowChanged = preferences.flow !== value.flow;
    preferences = value;
    if (!curlConfigured()) releaseCurl();
    const [background] = colors();
    document.body.style.background = background;
    document.getElementById('viewer').style.background = background;
    await preserve(async () => {
      if (flowChanged) {
        const cfi = anchor || (location && location.start.cfi);
        destroyRendition();
        createRendition();
        await rendition.display(cfi || undefined);
      }
      rendition.spread(spreadPreference(value), 800);
      rendition.settings.gap = isFixedLayout() ? 0 : value.margin * 2;
      for (const contents of rendition.getContents()) style(contents.document);
      if (auxiliary) style(auxiliary.contentDocument);
      resizePublication(window.innerWidth, window.innerHeight);
    });
    warmCurl();
  }
  function fixedViewportLocation() {
    // One authored fixed page is one spine item. A native view can deliver its
    // contents before Epub.js exposes a viewport mapping; use that real page's
    // canonical CFI instead of announcing readiness with no reading position.
    if(!isFixedLayout()||preferences.flow!=='paged'||rendition.manager?.layout?.divisor!==1)return;
    const contents=rendition.getContents();if(contents.length!==1)return;
    const content=contents[0],section=book.spine.get(content.sectionIndex);
    if(!section||!content.document?.body)return;
    try{
      const range=content.document.createRange();range.selectNodeContents(content.document.body);range.collapse(true);
      const entry={index:section.index,href:section.href,cfi:content.cfiFromRange(range),displayed:{page:1,total:1}};
      const linear=book.spine.spineItems.filter(item=>item.linear!==false&&item.linear!=='no');
      return {start:entry,end:{...entry},atStart:section.index===linear[0]?.index,atEnd:section.index===linear.at(-1)?.index};
    }catch(_){return;}
  }
  function refreshViewportLocation() {
    // Reading the current location also synchronizes Epub.js layout with the
    // actual native viewport. A turn must not use cached geometry from before
    // the reader was shown or a settings sheet finished closing.
    const current = rendition.currentLocation();
    if (current?.start?.cfi) location = current;
    else {const fixed=fixedViewportLocation();if(fixed)location=fixed;}
  }
  async function advance(delta) {
    refreshViewportLocation();
    const beforeCfi=location?.start?.cfi;
    const sectionIndex=location?.start?.index??rendition.getContents()[0]?.sectionIndex??0;
    const fixedTarget=delta>0?(location?.end?.index??sectionIndex)+1:sectionIndex-1;
    const manager = rendition.manager;
    if (!isFixedLayout() && !manager.isPaginated && manager.settings.axis === 'horizontal') {
      const fraction = preferences.flow === 'scrolled' ? (Number(preferences.tapScroll) || 80) / 100 : 1;
      manager.scrollBy(delta * manager.container.clientWidth * fraction, 0, true);
      await manager.q.enqueue(() => manager.check());
      rendition.reportLocation();
    } else if (!isFixedLayout() && preferences.flow === 'scrolled' && !manager.isPaginated && manager.container) {
      manager.scrollBy(0, delta * manager.container.clientHeight * (Number(preferences.tapScroll) || 80) / 100, true);
      await manager.q.enqueue(() => manager.check());
      rendition.reportLocation();
    } else if (delta > 0) await rendition.next();
    else await rendition.prev();
    // The manager already completes the move on its rendering queue. Existing
    // chapter documents have settled fonts/images; four extra RAFs on every
    // page only delay input. New chapters still wait for complete layout.
    const contents = rendition.getContents();
    if (contents.some(content => !settledDocuments.has(content.document))) {
      await stable(contents);
    }
    // Epub.js resolves reportLocation's queue job before its RAF callback emits
    // relocated. Read the settled viewport before committing this user turn;
    // otherwise the old locator can be treated as an unchanged position.
    refreshViewportLocation();
    if(isFixedLayout() && beforeCfi===location?.start?.cfi) {
      // A native fixed-layout view can finish its resize/display queue without
      // accepting the first manager.next(). Wait for delivery, then explicitly
      // display the adjacent spine item only if the viewport really stayed put.
      await tick();refreshViewportLocation();
      if(beforeCfi===location?.start?.cfi && fixedTarget>=0) {
        const section=book.spine.get(fixedTarget);
        if(section){
          await rendition.display(section.href);
          await stable(rendition.getContents());
          refreshViewportLocation();
        }
      }
    }
    if(preferences.flow==='paged')KMReaderSheetEffect.retireCapture();
  }
  async function next() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    if (atReadingEnd()) { send('end'); return; }
    lastTurnDelta=1;
    restoring = true;
    try { await advance(1); }
    finally { restoring = false; userMove = false; position(true); if(!interactiveNavigation)warmCurl(); }
  }
  async function previous() {
    if (!rendition || auxiliary) return;
    await waitForLayout();
    lastTurnDelta=-1;
    restoring = true;
    try { await advance(-1); }
    finally { restoring = false; userMove = false; position(true); if(!interactiveNavigation)warmCurl(); }
  }
  async function display(target, changed = true) {
    if (auxiliary) closeAuxiliary();
    restoring = true;
    try { await displayStable(target); }
    finally { restoring = false; userMove = false; position(changed); warmCurl(); }
  }
  async function seek(value) {
    if (auxiliary) closeAuxiliary();
    await waitForLayout();
    restoring = true;
    try {
      await displayStable(value.href);
      let target;
      if (value.locator) target = await restoreKindlePosition(value.locator);
      else if (value.progression > 0) await legacyProgress(value.progression);
      await tick();
      refreshViewportLocation();
      if (target && location?.start) location.start.cfi = target;
    } finally { restoring = false; userMove = false; position(true); warmCurl(); }
  }
  async function displayStable(target) {
    await rendition.display(target);
    await stable(rendition.getContents());
    if(collapsedPageView()){
      resizePublication(innerWidth,innerHeight);
      await rendition.display(target);
      await stable(rendition.getContents());
      if(collapsedPageView())throw Error('The EPUB page has no visible height.');
    }
    // Continuous moveTo only applies target.top. Vertical pagination also
    // reuses a width-based delta after reflow. Align locators on the real axis.
    const manager = rendition.manager;
    const horizontalFlow = !manager?.isPaginated && manager?.settings.axis === 'horizontal';
    const verticalPages = manager?.isPaginated && manager?.settings.axis === 'vertical' && !isFixedLayout();
    if ((!horizontalFlow && !verticalPages) || typeof target !== 'string') return;
    let range;
    if (target.startsWith('epubcfi(')) {
      const cfi = new ePub.CFI(target);
      const contents = rendition.getContents().find(content => content.sectionIndex === cfi.spinePos);
      if (contents) range = contents.range(target);
    }
    else if (target.includes('#')) {
      let id;
      try { id = decodeURIComponent(target.slice(target.indexOf('#') + 1)); } catch (_) { return; }
      const section = book.spine.get(target);
      const contents = rendition.getContents().find(content => (!section || content.sectionIndex === section.index) && content.document.getElementById(id));
      const element = contents?.document.getElementById(id);
      if (element) { range = contents.document.createRange(); range.selectNodeContents(element); }
    }
    if (!range) return;
    const frame = range.startContainer.ownerDocument.defaultView.frameElement;
    const bounds = frame.getBoundingClientRect(), rect = range.getBoundingClientRect();
    const viewport = manager.container.getBoundingClientRect();
    if (verticalPages) {
      const height = manager.layout.height;
      const top = Math.max(0, Math.floor((manager.container.scrollTop + bounds.top + rect.top - viewport.top) / height) * height);
      if (Math.abs(top - manager.container.scrollTop) > 1) manager.scrollTo(manager.container.scrollLeft, top, true);
    } else {
      const delta = config.direction === 'rtl'
        ? bounds.left + rect.right - viewport.right
        : bounds.left + rect.left - viewport.left;
      if (Math.abs(delta) > 1) manager.scrollTo(manager.container.scrollLeft + delta, manager.container.scrollTop, true);
    }
    rendition.reportLocation();
    await tick();
  }
  let captureMarkup=new WeakMap();
  const capturePages=new Map(),captureResources=new Map();
  let captureSerial=0,captureRevision=0,captureIdle,captureIdleJob,captureResourceBytes=0,captureWarmRevision=0;
  let curlPreview;
  let boundaryWork=Promise.resolve();
  const boundaryPreviews=new Map();
  const captureResourceSizes=new Map();
  function cancelCurlWarm(){
    captureWarmRevision++;clearTimeout(captureIdle);
    if(captureIdleJob)window.cancelIdleCallback?.(captureIdleJob);
    captureIdleJob=null;
  }
  function releaseCurl(){
    cancelCurlWarm();curlPreview=null;boundaryPreviews.clear();captureRevision++;capturePages.clear();captureMarkup=new WeakMap();
    captureResources.clear();captureResourceSizes.clear();captureResourceBytes=0;
    KMReaderCurlSurface.shared?.dispose();
  }
  const curlConfigured=()=>!disposed&&KMReaderSheetEffect.supported('curl')&&
    preferences?.flow==='paged'&&preferences.transition==='curl'&&motionAllowed('curl');
  const curlEligible=()=>curlConfigured()&&!document.hidden&&!inputSuspended&&
    rendition?.manager?.settings.axis==='horizontal';
  async function embeddedResource(value,base){
    if(!value||value.startsWith('data:')||value.startsWith('#'))return value;
    const url=new URL(value,base);if(url.origin!==locationOrigin())throw Error('External page artwork');
    if(!captureResources.has(url.href)){
      const task=fetch(url.href).then(r=>{if(!r.ok)throw Error('Artwork unavailable');return r.blob();}).then(blob=>{
        if(blob.size>32*1024*1024)throw Error('Artwork exceeds snapshot budget');
        if(captureResources.has(url.href)){captureResourceSizes.set(url.href,blob.size);captureResourceBytes+=blob.size;}
        while(captureResourceBytes>48*1024*1024&&captureResources.size>1){
          const old=captureResources.keys().next().value;
          captureResources.delete(old);captureResourceBytes-=captureResourceSizes.get(old)||0;captureResourceSizes.delete(old);
        }
        return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(blob);});
      });
      if(captureResources.size>=24){const old=captureResources.keys().next().value;captureResources.delete(old);captureResourceBytes-=captureResourceSizes.get(old)||0;captureResourceSizes.delete(old);}
      captureResources.set(url.href,task);
    }
    return captureResources.get(url.href);
  }
  const locationOrigin=()=>window.location.origin;
  async function embedCss(text,base){
    const matches=[...text.matchAll(/url\(\s*(['"]?)(.*?)\1\s*\)/g)];
    for(const match of matches)text=text.replace(match[0],`url("${await embeddedResource(match[2],base)}")`);
    return text;
  }
  async function cssSheet(sheet,base){
    const rules=[...sheet.cssRules];
    return (await Promise.all(rules.map(rule=>rule.styleSheet?cssSheet(rule.styleSheet,rule.styleSheet.href||base):embedCss(rule.cssText,sheet.href||base)))).join('\n');
  }
  async function sheetMarkup(frame,shift=0){
    const doc=frame.contentDocument,box=frame.getBoundingClientRect();
    const signature=[captureRevision,box.width,box.height,doc.body.getAttribute('style'),doc.documentElement.getAttribute('style')].join('|');
    let cached=captureMarkup.get(doc);
    if(cached?.signature!==signature){cached={signature,id:++captureSerial,pages:new Map()};captureMarkup.set(doc,cached);}
    const clip={left:-box.x-shift,right:innerWidth-box.x-shift,top:-box.y,bottom:innerHeight-box.y};
    const pageKey=JSON.stringify(clip);
    if(cached.pages.has(pageKey))return cached.pages.get(pageKey);
    const value={signature,id:cached.id+':'+pageKey};
    value.work=(async()=>{
      const root=doc.documentElement.cloneNode(true);
      if(!isFixedLayout())KMReaderPageSnapshot.compact(root,doc,clip,cached);
      root.querySelectorAll('script,link,base,meta,style').forEach(n=>n.remove());
      const css=(await Promise.all([...doc.styleSheets].map(sheet=>cssSheet(sheet,doc.baseURI)))).join('\n');
      const style=doc.createElement('style');style.textContent=css+'\nhtml{-webkit-text-size-adjust:none!important;text-size-adjust:none!important}*{caret-color:transparent!important}::selection{background:transparent!important}';root.querySelector('head').append(style);
      const original=doc.querySelectorAll('img'),clones=root.querySelectorAll('img');
      await Promise.all([...clones].map(async(img,i)=>{const url=original[i].currentSrc||original[i].src;if(url)img.setAttribute('src',await embeddedResource(url,doc.baseURI));img.removeAttribute('srcset');img.removeAttribute('loading');}));
      await Promise.all([...root.querySelectorAll('image')].map(async(img)=>{const url=img.getAttribute('href')||img.getAttributeNS('http://www.w3.org/1999/xlink','href');if(url){const data=await embeddedResource(url,doc.baseURI);img.setAttribute('href',data);img.removeAttributeNS('http://www.w3.org/1999/xlink','href');}}));
      root.querySelector('body').style.setProperty('overflow','visible','important');root.style.setProperty('overflow','visible','important');
      root.setAttribute('xmlns','http://www.w3.org/1999/xhtml');root.style.width=box.width+'px';root.style.height=box.height+'px';
      return new XMLSerializer().serializeToString(root);
    })();cached.pages.set(pageKey,value);
    while(cached.pages.size>4)cached.pages.delete(cached.pages.keys().next().value);
    return value;
  }
  async function captureSheet(shift=0,sourceFrames){
    const width=innerWidth,height=innerHeight,dpr=KMReaderCurlSurface.rasterScale(width,height),revision=captureRevision;
    const frames=sourceFrames||[...document.querySelectorAll('#viewer iframe')].filter(f=>{const b=f.getBoundingClientRect();return b.right>0&&b.left<width&&b.bottom>0&&b.top<height;});
    const parts=await Promise.all(frames.map(async frame=>{const r=frame.getBoundingClientRect();return {box:{x:r.x+shift,y:r.y,width:r.width,height:r.height},markup:await sheetMarkup(frame,shift),annotations:annotationMarkup(frame,shift)};}));
    if(!parts.length)throw Error('No visible publication');
    const key=JSON.stringify([width,height,dpr,...parts.map(p=>[p.markup.id,p.box.x,p.box.y])]);
    if(capturePages.has(key)){const value=capturePages.get(key);capturePages.delete(key);capturePages.set(key,value);return value;}
    const task=(async()=>{
      const layers=await Promise.all(parts.map(async({box,markup,annotations})=>`<foreignObject x="${box.x}" y="${box.y}" width="${box.width}" height="${box.height}">${await markup.work}</foreignObject>${annotations}`));
      const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${Math.round(width*dpr)}" height="${Math.round(height*dpr)}" viewBox="0 0 ${Math.round(width*dpr)/dpr} ${Math.round(height*dpr)/dpr}"><rect width="100%" height="100%" fill="${colors()[0]}"/>${layers.join('')}</svg>`;
      if(svg.length>8*1024*1024)throw Error('Page texture exceeds markup budget');
      const image=new Image();image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);await image.decode();
      if(disposed||revision!==captureRevision)throw Error('Stale page texture');return image;
    })();capturePages.set(key,task);task.catch(()=>capturePages.delete(key));
    // Four screen-sized textures at most; document markup is shared per chapter.
    const limit=Math.max(2,Math.min(4,Math.floor(64*1024*1024/(width*height*dpr*dpr*4))));
    while(capturePages.size>limit)capturePages.delete(capturePages.keys().next().value);
    return task;
  }
  function prepareCurlPrograms(){
    if(disposed||!KMReaderSheetEffect.supported('curl')||preferences.flow!=='paged'||rendition?.manager?.settings.axis!=='horizontal'||preferences.transition!=='curl'||!motionAllowed('curl'))return;
    try{KMReaderCurlSurface.shared??=new KMReaderCurlSurface();}catch(_){KMReaderCurlSurface.disabled=true;}
  }
  function previewOrigin(){
    const manager=rendition?.manager;
    return [captureRevision,innerWidth,innerHeight,manager?.container.scrollLeft,manager?.container.scrollTop,
      ...[...document.querySelectorAll('#viewer iframe')].map(f=>{const b=f.getBoundingClientRect();return [b.x,b.y,b.width,b.height].join(',');})].join('|');
  }
  function previewShift(delta){
    if(preferences.flow!=='paged'||rendition?.manager?.settings.axis!=='horizontal'||isFixedLayout())return null;
    const frames=[...document.querySelectorAll('#viewer iframe')];
    if(frames.length!==1)return null;
    const physical=(delta>0)!==(config.direction==='rtl')?1:-1;
    const shift=-physical*innerWidth,bounds=frames[0].getBoundingClientRect();
    return bounds.left+shift<=1&&bounds.right+shift>=innerWidth-1?shift:null;
  }
  async function preparePreview(delta){
    const origin=previewOrigin();
    if(curlPreview?.origin===origin&&curlPreview.pages.has(delta))return {before:curlPreview.before,after:curlPreview.pages.get(delta)};
    const [before,after]=await Promise.all([captureSheet(),previewImage(delta)]);
    if(origin!==previewOrigin())return null;
    return after?{before,after}:null;
  }
  function previewImage(delta){
    const shift=previewShift(delta);
    if(shift!==null)return captureSheet(shift);
    const manager=rendition?.manager,views=manager?.views?.all();
    if(preferences.flow!=='paged'||isFixedLayout()||verticalWriting()||views?.length!==1)return Promise.resolve(null);
    const section=delta>0?views[0].section.next():views[0].section.prev();
    if(!section)return Promise.resolve(null);
    const revision=captureRevision,key=[revision,section.index,delta,innerWidth,innerHeight].join('|');
    if(boundaryPreviews.has(key))return boundaryPreviews.get(key);
    // Render only the adjacent boundary page in an isolated, temporary view.
    // The input's live iframe, location and manager stay untouched. Retain the
    // resulting image, then release the chapter DOM and its observers.
    const task=boundaryWork.then(async()=>{
      if(disposed||revision!==captureRevision||rendition?.manager!==manager)return null;
      const layout=Object.assign(Object.create(Object.getPrototypeOf(manager.layout)),manager.layout,
        {settings:{...manager.layout.settings},props:{...manager.layout.props}});
      // Preview loading must not repopulate the spine's discarded DOM while
      // a new live chapter is opening. Share hooks, not parsed chapter state.
      const previewSection=new section.constructor({...section,linear:section.linear?'yes':'no'},section.hooks);
      const view=new IframeView(previewSection,{...manager.viewSettings,layout});
      const holder=document.createElement('div');
      holder.style.cssText=`position:fixed;left:0;top:0;width:${innerWidth}px;height:${innerHeight}px;overflow:hidden;opacity:0;pointer-events:none;contain:strict;direction:${config.direction==='rtl'?'rtl':'ltr'}`;
      holder.setAttribute('aria-hidden','true');holder.append(view.element);document.body.append(holder);
      try{
        await view.display(manager.request);
        if(view.settings.axis!=='horizontal'||view.writingMode?.startsWith('vertical'))return null;
        const doc=view.contents.document;
        if(!doc.documentElement.dir&&config.direction==='rtl'&&!view.contents.writingMode().startsWith('vertical')){
          doc.documentElement.dir='rtl';layout.format(view.contents,section,view.axis);view.expand();
        }
        await stable([view.contents]);
        if(config.kindlePositions)for(const mark of config.annotations||[]){
          if(!mark.endLocator||mark.locator?.href!==mark.endLocator.href)continue;
          const cfi=kindleRange(view.contents,mark);
          if(cfi)view.highlight(cfi,{},null,'kmreader-kindle-highlight',{fill:'#e6b72d','fill-opacity':'.24','mix-blend-mode':'multiply'});
        }
        if(disposed||revision!==captureRevision||rendition?.manager!==manager)return null;
        const bounds=view.iframe.getBoundingClientRect(),rtl=config.direction==='rtl';
        const shift=(delta>0)!==rtl?-bounds.left:innerWidth-bounds.right;
        return await captureSheet(shift,[view.iframe]);
      }finally{
        // A format/load failure can leave Contents alive before display()
        // sets displayed. Destroy its observers on that partial path too.
        try{if(view.contents)view.displayed=true;view.destroy();}
        finally{view.iframe?.remove();holder.remove();}
      }
    });
    boundaryWork=task.then(()=>{},()=>{});
    boundaryPreviews.set(key,task);
    task.catch(()=>{if(boundaryPreviews.get(key)===task)boundaryPreviews.delete(key);});
    while(boundaryPreviews.size>2)boundaryPreviews.delete(boundaryPreviews.keys().next().value);
    return task;
  }
  function warmCurl(){
    cancelCurlWarm();
    // Direct navigation is also used inside an effect's capture callback.
    // Never dispose or replace its textures while that effect owns them.
    if(gesture||sheetEffect||KMReaderCurlSurface.shared?.effect)return;
    const gpu=curlConfigured();
    const slideConfigured=()=>preferences?.flow==='paged'&&preferences.transition==='slide'&&motionAllowed('slide')&&KMReaderSheetEffect.supported('slide');
    if(!gpu&&!slideConfigured()){releaseCurl();return;}
    const eligible=()=>!disposed&&!document.hidden&&!inputSuspended&&rendition?.manager?.settings.axis==='horizontal'&&(gpu?curlConfigured():slideConfigured());
    if(!eligible())return;
    const revision=captureWarmRevision,publication=captureRevision;
    const valid=()=>revision===captureWarmRevision&&publication===captureRevision&&eligible()&&!gesture&&!sheetEffect;
    const prepare=async()=>{
      if(!valid())return;
      try {
        if(gpu){prepareCurlPrograms();if(!KMReaderSheetEffect.supported('curl'))return;}
        const idleImage=await captureSheet();
        if(!valid())return;
        // Compile the retained GPU programs while idle, rather than on the
        // first finger movement, including driver pipeline and framebuffer setup.
        const surface=gpu?(KMReaderCurlSurface.shared??=new KMReaderCurlSurface()):null;
        await surface?.whenReady();
        if(!valid())return;
        // Prepare the actual front texture on every idle page, not just the
        // first viewport. A null back preserves the other retained allocation.
        const origin=previewOrigin(),pages=new Map();
        curlPreview={origin,before:idleImage,pages};
        surface?.upload(idleImage,null,innerWidth,innerHeight);
        // Cache both directions without moving the publication. Navigating
        // during a drag used to invalidate input routing and require rollback.
        const budget=innerWidth*innerHeight*KMReaderCurlSurface.rasterScale(innerWidth,innerHeight)**2*4;
        const preferred=lastTurnDelta;
        for(const delta of budget*3<=64*1024*1024?[preferred,-preferred]:[preferred]){
          const image=await previewImage(delta);
          if(!valid()||origin!==previewOrigin())return;
          if(!image)continue;
          pages.set(delta,image);
          if(surface){surface.upload(idleImage,image,innerWidth,innerHeight);
          surface.render(.5,rendition.manager?.layout?.divisor===2,(delta>0)!==(config.direction==='rtl')?1:-1,0,.5);surface.gl.flush();}
        }
        if(surface){surface.upload(idleImage,pages.get(preferred)||idleImage,innerWidth,innerHeight);
        // Submit a real draw for each newly prepared pair. Decoding SVG alone
        // does not force its glyph rasterization/texture work onto the GPU.
        surface.render(.5,rendition.manager?.layout?.divisor===2,1,0,.5);
        surface.render(0,false,1,0,.5);surface.gl.flush();}
      }catch(_){/* Unsupported artwork retains direct reading. */}
    };
    // Prefer idle time, with a deadline against indefinite starvation. Input,
    // settings, reflow and visibility changes retire the remainder of this job.
    captureIdle=setTimeout(()=>{if(window.requestIdleCallback)captureIdleJob=requestIdleCallback(prepare,{timeout:120});else prepare();},16);
  }
  function cancelTurnAnimation() {
    sheetEffect?.stop(); sheetEffect = undefined;
    const previous = turnAnimation; turnAnimation = undefined;
    if (previous) previous.cancel();
  }
  function cancelGesture() { if (gesture) { gesture.invalidated = true; gesture.finish(false); } }
  function beginGesture(contact, point, pointer) {
    if (gesture || disposed) return;
    cancelCurlWarm();
    const physical = point.x < contact.x ? 1 : -1;
    const delta = (physical > 0) !== (config.direction === 'rtl') ? 1 : -1;
    if (delta > 0 && atReadingEnd() || delta < 0 && location?.atStart) return;
    cancelTurnAnimation();
    const shield = document.createElement('div');
    shield.id = 'page-gesture';
    shield.style.cssText = 'position:fixed;inset:0;z-index:2147483646;touch-action:none;cursor:grabbing';
    document.body.appendChild(shield);
    let resolve;
    const finished = new Promise(done => resolve = done);
    const state = gesture = {progress:0,effect:null,ended:false,invalidated:false,width:innerWidth,height:innerHeight,
      finish: commit => { if (!state.ended) { state.ended = true; resolve(commit && innerWidth === state.width && innerHeight === state.height); } }};
    let lastX = point.x, lastTime = performance.now(), velocity = 0;
    const update = p => {
      const now = performance.now(), elapsed = Math.max(1, now - lastTime);
      if (Math.abs(p.x - lastX) > .1) velocity = -(p.x - lastX) * physical / elapsed;
      else if (elapsed > 90) velocity = 0;
      lastX = p.x; lastTime = now;
      const leaf=innerWidth/(rendition.manager?.layout?.divisor===2?2:1);
      state.progress = Math.max(0, Math.min(1, (contact.x - p.x) * physical / leaf));
      state.point=p;state.effect?.track(state.progress,p);
    };
    state.update = update;
    state.pointer = pointer;
    state.release = () => state.finish(state.progress > .28 || state.progress > .06 && velocity > .45);
    update(point);
    shield.addEventListener('pointermove', event => {
      if (!event.isPrimary || event.pointerId !== pointer) { state.finish(false); return; }
      event.preventDefault(); update({x:event.clientX,y:event.clientY});
    }, {passive:false});
    shield.addEventListener('pointerup', event => {
      if (event.pointerId !== pointer) return;
      event.preventDefault(); update({x:event.clientX,y:event.clientY});
      state.finish(state.progress > .28 || state.progress > .06 && velocity > .45);
    });
    shield.addEventListener('pointercancel', () => state.finish(false));

    shield.addEventListener('pointerdown', event => { if (event.pointerId !== pointer) state.finish(false); });
    const abort=()=>{state.invalidated=true;state.finish(false);};
    window.addEventListener('blur',abort);
    // Keep input in its original document. Moving capture between a book iframe
    // and the top document can deadlock Chromium's input router during capture.
    enqueue(async () => {
      const saved = anchor || location?.start?.cfi;
      const originalManager=rendition.manager,originalDocuments=rendition.getContents().map(c=>c.document);
      const originalScroll={x:originalManager.container.scrollLeft,y:originalManager.container.scrollTop};
      interactiveNavigation = true;
      let moved=false;
      try {
        const preview=['curl','slide'].includes(preferences.transition)?await timeout(Promise.race([
          preparePreview(delta).catch(()=>null),finished.then(()=>null)
        ]),2500):null;
        // Curl and slide gestures preview without replacing the input iframe.
        // The live document and CFI
        // remain on the original page until the user commits, including chapter
        // boundaries prepared in a temporary view without replacing input.
        if(preview&&!state.invalidated){
          state.effect=sheetEffect=new KMReaderSheetEffect(preferences.transition,physical,preferences,contact.y/innerHeight,delta<0,
            rendition.manager?.layout?.divisor===2,captureSheet);
          if(!await state.effect.start(()=>Promise.resolve(),preview)){
            if(sheetEffect===state.effect)sheetEffect=undefined;
            state.effect=null;
          }
          state.effect?.track(state.progress,state.point);
        }else if(!['curl','slide'].includes(preferences.transition)&&!state.invalidated){
          state.effect=await transitionMove(delta,preferences.transition,contact.y/innerHeight);
          moved=true;state.effect?.track(state.progress,state.point);
        }
        let commit = await finished;
        commit=commit&&!state.invalidated;
        if(commit&&!state.effect){
          state.effect=await transitionMove(delta,preferences.transition,contact.y/innerHeight);
          moved=true;
          state.progress=0;
        }
        const duration = Math.min(300, Math.max(80, (Number(preferences.animationDuration) || 380) *
          (commit ? 1 - (state.effect?.progress||0) : (state.effect?.progress||0))));
        if (!disposed) {
          await state.effect?.animateTo(commit ? 1 : 0, duration, {velocity:velocity/(innerWidth/(rendition.manager?.layout?.divisor===2?2:1))});
        }
        commit = commit && !state.invalidated;
        if(!disposed&&commit&&!moved){await (delta>0?next():previous());moved=true;}
        if (!disposed && !commit && moved && saved) {
          const current=rendition.getContents().map(c=>c.document);
          if(rendition.manager===originalManager && current.length===originalDocuments.length && current.every((d,i)=>d===originalDocuments[i])) {
            originalManager.scrollTo(originalScroll.x,originalScroll.y,true);
            rendition.reportLocation();
            await tick();
          } else await displayStable(saved);
          refreshViewportLocation(); anchor = saved;
          await tick();
        }
        state.effect?.stop();
        interactiveNavigation = false;
        if (!disposed) { refreshViewportLocation(); userMove = false; position(commit); }
      } finally {
        state.effect?.stop();
        if (sheetEffect === state.effect) sheetEffect = undefined;
        interactiveNavigation = false;
        shield.remove();
        if (gesture === state) gesture = undefined;
        window.removeEventListener('blur',abort);
        suppressClickUntil = Date.now() + 500;
        // Both committed and canceled drags need preparation for the next
        // input. Previously only automatic turns restarted idle warming.
        if(!disposed)warmCurl();
      }
    }).catch(error => send('error', {message:String(error)}));
  }
  function motionAllowed(style) {
    return !config.disableMotion && preferences.animate !== false && preferences.flow === 'paged' && style !== 'none' &&
      !matchMedia('(prefers-reduced-motion: reduce)').matches;
  }
  async function capturedLayout(move) {
    // View Transitions freeze painting until their update resolves. Epub.js
    // queues layout on RAF, so use task turns during this brief frozen update;
    // geometry is still synchronously available. Restore schedulers afterward.
    const raf = window.requestAnimationFrame;
    const schedule = callback => setTimeout(() => callback(performance.now()), 0);
    const queues = [rendition.q, rendition.manager?.q].filter(Boolean).map(q => [q, q.tick]);
    window.requestAnimationFrame = schedule;
    for (const [q] of queues) q.tick = schedule;
    try { return await move(); }
    finally {
      window.requestAnimationFrame = raf;
      for (const [q, tick] of queues) q.tick = tick;
    }
  }
  async function transitionMove(delta, style, y) {
    if(delta>0 && atReadingEnd() || delta<0 && location?.atStart)return null;
    const move = () => delta > 0 ? next() : previous();
    if (!motionAllowed(style) || !KMReaderSheetEffect.supported(style) || (delta > 0 && atReadingEnd())) {
      await move(); return null;
    }
    // SheetEffect owns the compositor delivery barrier. GPU curl has no
    // compositor snapshot to prepare or retire on its own.
    const effect = sheetEffect = new KMReaderSheetEffect(style,
      (delta > 0) !== (config.direction === 'rtl') ? 1 : -1, preferences, y, delta < 0, rendition.manager?.layout?.divisor === 2, captureSheet);
    const preview=style==='slide'?await timeout(preparePreview(delta).catch(()=>null),2500):null;
    if(preview){
      if(await effect.start(()=>Promise.resolve(),preview)){
        try{await move();return effect;}catch(error){effect.stop();throw error;}
      }
      await move();if(sheetEffect===effect)sheetEffect=undefined;return null;
    }
    if (!await effect.start(() => capturedLayout(move))) { if (sheetEffect === effect) sheetEffect = undefined; return null; }
    return effect;
  }
  async function turn(value) {
    if (!rendition || auxiliary) return;
    cancelCurlWarm();
    for (const contents of rendition.getContents()) contents.document.getSelection()?.removeAllRanges();
    cancelTurnAnimation();
    const effect = await transitionMove(value.delta, value.style || preferences.transition, .5);
    if (!effect || disposed) { if(!disposed)warmCurl(); return; }
    // Navigation is already committed. Cosmetic motion never owns the input
    // queue, and the next input can replace this compositor transition.
    const duration = Math.max(150, Math.min(900, Number(preferences.animationDuration) || 380));
    Promise.resolve().then(()=>effect.animateTo(1, duration, {automatic:true})).catch(()=>effect.fail()).finally(() => {
      effect.stop(); if (sheetEffect === effect) sheetEffect = undefined; warmCurl();
    });
  }
  async function legacyProgress(progression) {
    const all = rendition.getContents();
    const contents = all.find(content => location && content.sectionIndex === location.start.index) || all[0];
    if (!contents || progression <= 0) return;
    const walker = contents.document.createTreeWalker(contents.document.body, NodeFilter.SHOW_TEXT);
    const nodes = []; let total = 0, node;
    while ((node = walker.nextNode())) { nodes.push(node); total += node.length; }
    let remaining = Math.floor(total * Math.min(.999999, progression));
    for (const text of nodes) {
      if (remaining <= text.length) {
        const range = contents.document.createRange(); range.setStart(text, remaining); range.collapse(true);
        await rendition.display(contents.cfiFromRange(range)); return;
      }
      remaining -= text.length;
    }
  }
  async function open(value) {
    config = value; renderedAnnotations.clear(); preferences = value.preferences; restoring = true; captureRevision++;capturePages.clear();captureResources.clear();captureResourceSizes.clear();captureResourceBytes=0;
    document.body.style.background = colors()[0];
    document.getElementById('viewer').style.background = colors()[0];
    book = ePub(value.url, {openAs: 'opf', replacements: 'none'});
    await book.ready;
    if (disposed) return;
    // Include typography in the serialized publication before the iframe's
    // first layout, rather than paginating the entire chapter with publisher
    // defaults and throwing that work away in the rendered-content hook.
    book.spine.hooks.content.register(style);
    createRendition();
    let restoredCfi = Boolean(value.cfi);
    try { await displayStable(value.cfi || value.href || undefined); }
    catch (error) {
      if (!value.cfi) throw error;
      restoredCfi = false;
      await displayStable(value.href || undefined);
    }
    // A native WebView can attach its remaining spread view after display's
    // first completion. Keep the verified initial layout barrier; archive
    // preparation is optimized independently of native first-paint readiness.
    await stable(rendition.getContents());
    if(collapsedPageView())await displayStable(restoredCfi?value.cfi:value.href||undefined);
    if (!restoredCfi && value.progression > 0) await legacyProgress(value.progression);
    if (value.kindleResume) {
      const cfi = await restoreKindlePosition(value.kindleResume);
      if (cfi) { value.cfi = cfi; restoredCfi = true; }
    }
    await tick();
    // Ready must describe a real viewport, even if the initial relocated
    // callback is still queued by the renderer.
    refreshViewportLocation();
    restoring = false; userMove = false; anchor = restoredCfi ? value.cfi : (location && location.start.cfi);
    position(false); warmCurl(); send('ready', {layout: isFixedLayout() ? 'pre-paginated' : 'reflowable', writingMode: rendition.manager?.writingMode || 'horizontal-tb'});
    window.addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('pagehide', onVisibility);
    document.addEventListener('pointerdown',interruptMouse,true);
    for (const event of inputEvents) document.addEventListener(event, noteUserMove, {passive: true});
  }
  function onVisibility(event){
    if(document.hidden||event.type==='pagehide'){cancelCurlWarm();cancelGesture();cancelTurnAnimation();}
    else warmCurl();
  }
  function onResize() {
    cancelCurlWarm();
    cancelGesture();
    captureRevision++;capturePages.clear();
    if (disposed || !rendition) return;
    cancelTurnAnimation();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resizeTimer = null;
      enqueue(() => preserve(() => resizePublication(window.innerWidth, window.innerHeight)))
        .catch(error => send('error', {message: String(error)}));
    }, 80);
  }
  function createRendition() {
    const before = new Set(book.spine.hooks.content.list());
    const current = rendition = book.renderTo('viewer', {width: window.innerWidth, height: window.innerHeight, resizeOnOrientationChange: false,
      manager: preferences.flow === 'scrolled' ? 'continuous' : 'default',
      flow: preferences.flow === 'scrolled' ? 'scrolled' : 'paginated',
      offset: Math.max(800, Math.min(1600, window.innerHeight * 2)),
      spread: spreadPreference(preferences),
      minSpreadWidth: 800, gap: isFixedLayout() ? 0 : preferences.margin * 2, direction: config.direction,
      allowScriptedContent: false, allowPopups: false});
    renditionSpineHooks = book.spine.hooks.content.list().filter(callback => !before.has(callback));
    current.started.then(() => { if (rendition === current) retainLocationLayout(current.manager); });
    rendition.hooks.content.register(hook);
    renderedAnnotations.clear();
    rendition.on('rendered', drawKindleAnnotations);
    rendition.on('relocated', value => {
      if (rendition !== current || disposed) return;
      location = value;
      if (!restoring && !interactiveNavigation && anchor && !userMove &&
          !(preferences.flow === 'scrolled' && Date.now() < userMoveUntil)) {
        location.start.cfi = anchor;
      }
      clearTimeout(relocationTimer);
      relocationTimer = setTimeout(() => {
        const changed = userMove || (preferences.flow === 'scrolled' && Date.now() < userMoveUntil);
        userMove = false; position(changed);
      }, 120);
    });
    rendition.on('displayError', error => { if (rendition === current && !restoring) send('error', {message: String(error)}); });
  }
  function destroyRendition() {
    const current = rendition;
    rendition = null;
    clearTimeout(relocationTimer);
    // Epub.js 0.3.93 leaves its bound identifier hook on the book at destroy.
    // Remove only hooks this rendition added; publication hooks stay intact.
    for (const callback of renditionSpineHooks) book.spine.hooks.content.deregister(callback);
    renditionSpineHooks = [];
    if (current) {
      const manager = current.manager;
      if (manager) {
        clearTimeout(manager.trimTimeout); clearTimeout(manager.scrollTimeout);
        if (manager._scrolled && manager._scrolled.cancel) manager._scrolled.cancel();
        if (manager.q) manager.q.stop();
      }
      if (current.q) current.q.stop();
      current.destroy();
      if (book.rendition === current) book.rendition = undefined;
    }
  }
  async function search(term) {
    const matches = [];
    for (const section of book.spine.spineItems) {
      if (section.linear === 'no') continue;
      await section.load(book.load.bind(book));
      for (const result of section.find(term)) {
        matches.push({cfi: result.cfi, excerpt: result.excerpt, href: section.href});
        if (matches.length >= 500) break;
      }
      section.unload();
      if (matches.length >= 500) break;
    }
    return matches;
  }
  function closeAuxiliary() {
    if (!auxiliary) return;
    auxiliary.remove(); auxiliary = null;
    send('auxiliary', {active: false});
  }
  async function openAuxiliary(url) {
    closeAuxiliary();
    auxiliary = document.createElement('iframe'); auxiliary.id = 'auxiliary';
    auxiliary.sandbox = 'allow-same-origin'; auxiliary.style.display = 'block';
    auxiliary.src = url; document.body.appendChild(auxiliary);
    await new Promise(resolve => { auxiliary.onload = resolve; });
    style(auxiliary.contentDocument);
    auxiliary.contentDocument.addEventListener('click', event => {
      const link = event.target.closest && event.target.closest('a[href]');
      if (link) { event.preventDefault(); send('link', {href: link.href}); }
    }, true);
    send('auxiliary', {active: true});
  }
  window.reader = {open: value => enqueue(() => open(value)), next: () => enqueue(next), previous: () => enqueue(previous),
    seek: value => enqueue(() => seek(value)),
    annotations: updateKindleAnnotations,
    turn: value => enqueue(() => turn(value)), display: (target, changed) => enqueue(() => display(target, changed)),
    preferences: setPreferences, search: value => enqueue(() => search(value)),
    openAuxiliary: value => enqueue(() => openAuxiliary(value)), closeAuxiliary: () => enqueue(closeAuxiliary),
    suspendInput: value => {
      inputSuspended=!!value;cancelCurlWarm();cancelGesture();cancelTurnAnimation();
      for(const c of rendition?.getContents()||[]) c.document.getSelection()?.removeAllRanges();
      if(inputSuspended)return true;
      // Android delivers native surface bounds/focus after the sheet closes.
      // Settle that delivery once here, ahead of queued turns, not per page.
      return enqueue(async()=>{await tick();await waitForLayout();warmCurl();return true;});
    },
    selectedText: () => (rendition?.getContents()||[]).map(c=>c.document.getSelection()?.toString()||'').find(text=>text.trim())||'',
    clearSelection: () => {for(const c of rendition?.getContents()||[]) c.document.getSelection()?.removeAllRanges();return true;},
    position: () => location, layoutReady,
    whenIdle: () => enqueue(waitForLayout), destroy: () => {
      disposed = true; cancelGesture(); clearTimeout(relocationTimer); clearTimeout(resizeTimer); clearTimeout(captureIdle);if(captureIdleJob)window.cancelIdleCallback?.(captureIdleJob);captureRevision++;capturePages.clear();captureResources.clear();captureResourceSizes.clear();captureResourceBytes=0;boundaryPreviews.clear();curlPreview=null;captureMarkup=new WeakMap();
      cancelTurnAnimation();
      KMReaderCurlSurface.shared?.dispose();
      window.removeEventListener('resize', onResize);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('pagehide', onVisibility);
      document.removeEventListener('pointerdown',interruptMouse,true);
      for (const event of inputEvents) document.removeEventListener(event, noteUserMove);
      destroyRendition(); if (book) book.destroy();
    }};
})();
