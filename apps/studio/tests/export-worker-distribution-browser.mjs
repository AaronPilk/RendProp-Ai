import assert from "node:assert/strict";
import {createHash,X509Certificate} from "node:crypto";
import {createServer,request as httpsRequest,Agent as HTTPSAgent} from "node:https";
import {readFile,readdir,lstat,mkdtemp,mkdir,writeFile,realpath,chmod,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {resolve,join,extname,sep} from "node:path";
import {fileURLToPath} from "node:url";
import {execFileSync} from "node:child_process";
import {chromium,webkit} from "@playwright/test";

// No build, install, login, AudioContext, PCM, VideoFrame input, or export.
// This checks the real compiled worker under the build's response policy.
const root=fileURLToPath(new URL("../",import.meta.url));
const args=process.argv.slice(2),options={dist:join(root,"dist")};
for(let i=0;i<args.length;i+=2){
  assert(["--dist","--artifacts"].includes(args[i]) && args[i+1] && !args[i+1].startsWith("--"),"Use --dist PATH and/or --artifacts NEW_PATH.");
  const key=args[i].slice(2);assert(!Object.hasOwn(options,`seen-${key}`),"Duplicate option.");
  options[`seen-${key}`]=true;options[key]=resolve(args[i+1]);
}
const dist=resolve(options.dist);
const artifacts=options.artifacts?(await mkdir(options.artifacts),options.artifacts):
  await mkdtemp(join(tmpdir(),"rendprop-worker-distribution-"));
const sha=bytes=>createHash("sha256").update(bytes).digest("hex");
const receipt={gate:"studio-built-worker-browser-distribution",status:"running",
  scope:"Local built-asset/CSP/MIME/worker capability smoke only; not a media-quality, full-suite, deployed-site, Safari application or iPhone verification.",
  dist,artifacts,browsers:[],checks:[],externalRequests:[],errors:[],cleanup:[],
  observationVersion:3,http:{maximumRequests:256,requests:[],dropped:0},
  noCustomerData:true,noAudioContext:true,noUserPCM:true,noVideoFrameInput:true,noMediaExport:true};
let server,activeServer,certificateDirectory,privateKeyBuffer,httpsAgent,activeBrowserLabel="transport-preflight";
const limited=(rows,value,limit)=>{if(rows.length<limit){rows.push(value);return true;}return false;};
const networkURL=raw=>{try{return new URL(raw).origin;}catch{return null;}};
const requestHeaders=headers=>Object.fromEntries(Object.entries(headers).filter(([key])=>
  ["host","origin","referer","sec-fetch-site","sec-fetch-mode","sec-fetch-dest","user-agent","accept"].includes(key.toLowerCase())));
// All URLs/headers originate from this empty synthetic document and its frozen
// local assets. Bodies, cookies, credentials and encoded media are never read.
function observeBrowserNetwork(context,row){
  const network={maximumRequests:256,requests:[],droppedEvents:0,
    observationErrors:[],observationErrorsDropped:0}, ids=new Map();
  const protect=(kind,observe)=>(...args)=>{try{return observe(...args);}catch(error){
    if(!limited(network.observationErrors,{kind,message:String(error).slice(0,8192)},16))network.observationErrorsDropped++;
  }};
  row.network=network;
  const identify=request=>{
    let record=ids.get(request);
    if(record)return record;
    if(network.requests.length>=network.maximumRequests){network.droppedEvents++;return null;}
    const rawURL=request.url();
    record={requestId:network.requests.length+1,epochMilliseconds:Date.now(),rawURL,
      origin:networkURL(rawURL),method:request.method(),resourceType:request.resourceType(),
      navigation:request.isNavigationRequest(),headers:requestHeaders(request.headers()),
      redirectedFrom:request.redirectedFrom()?.url()??null,response:null,failed:null,finished:false};
    network.requests.push(record);ids.set(request,record);return record;
  };
  context.on("request",protect("request",identify));
  context.on("response",protect("response",response=>{
    const record=identify(response.request());if(!record)return;
    record.response={epochMilliseconds:Date.now(),rawURL:response.url(),origin:networkURL(response.url()),
      status:response.status(),statusText:response.statusText(),headers:response.headers(),
      headersMethod:"Playwright Response.headers(): synthetic local server sends no cookies"};
  }));
  context.on("requestfailed",protect("requestfailed",request=>{const record=identify(request);if(record)
    record.failed={epochMilliseconds:Date.now(),errorText:request.failure()?.errorText??null,
      redirectedTo:request.redirectedTo()?.url()??null};}));
  context.on("requestfinished",protect("requestfinished",request=>{const record=identify(request);if(record){record.finished=true;
    record.finishedEpochMilliseconds=Date.now();record.redirectedTo=request.redirectedTo()?.url()??null;}}));
}
async function getTestHTTPS(url,agent,expectedCertificateSHA256){
  return new Promise((resolve,reject)=>{
    const request=httpsRequest(url,{method:"GET",agent,signal:AbortSignal.timeout(5000)},response=>{
      let tls;
      try{
        // Capture the authenticated peer while the response still owns its live
        // socket; a non-keepalive socket may be detached after body completion.
        const socket=response.socket;
        assert.equal(socket.authorized,true,"Node must validate the exact generated test CA and127.0.0.1 SAN.");
        const peer=socket.getPeerCertificate();
        assert(peer.raw,"The test TLS handshake must expose its actual peer certificate.");
        const certificateSHA256=sha(peer.raw);
        assert.equal(certificateSHA256,expectedCertificateSHA256,"Node must trust only this run's exact certificate.");
        tls={authorized:socket.authorized,protocol:socket.getProtocol(),cipher:socket.getCipher(),certificateSHA256};
      }catch(error){request.destroy(error);reject(error);return;}
      const chunks=[];let length=0;
      // Only frozen local asset bytes are read by the preflight. The existing
      // total asset inventory is finite; cap each transport read as well.
      response.on("data",chunk=>{length+=chunk.length;if(length>8*1024*1024){
        const error=new Error("Synthetic HTTPS preflight response exceeded8MiB.");
        reject(error);request.destroy(error);
      }else chunks.push(chunk);});
      response.once("aborted",()=>reject(new Error("Synthetic HTTPS response aborted.")));
      response.once("error",reject);
      response.once("end",()=>{try{
        const headers=new Headers();
        for(const [name,value] of Object.entries(response.headers))
          for(const item of Array.isArray(value)?value:[value])if(item!==undefined)headers.append(name,item);
        resolve({status:response.statusCode,statusText:response.statusMessage,headers,
          arrayBuffer:async()=>Buffer.concat(chunks),
          tls});
      }catch(error){reject(error);}});
    });
    request.once("error",reject);request.end();
  });
}
async function listenLoopback(server,onError){
  // A real late server failure must remain visible after startup settles.
  server.on("error",onError);
  await new Promise((done,fail)=>{
    const failed=error=>{server.removeListener("error",failed);fail(error);};
    server.once("error",failed);
    server.listen(0,"127.0.0.1",()=>{server.removeListener("error",failed);done();});
  });
}
async function bounded(operation,milliseconds,label){
  let timer;
  try{return await Promise.race([operation,new Promise((_,reject)=>{
    timer=setTimeout(()=>reject(new Error(`${label} exceeded ${milliseconds} ms.`)),milliseconds);
  })]);}finally{clearTimeout(timer);}
}
async function closeBrowserServer(owner,label){
  if(!owner)return;
  const process=owner.process(),row={label,pid:process.pid,graceful:false,killed:false,processExited:false,errors:[]};
  try{await bounded(owner.close(),7000,`${label} close`);row.graceful=true;}
  catch(error){row.errors.push(String(error));
    try{await bounded(owner.kill(),5000,`${label} kill`);row.killed=true;}
    catch(killError){row.errors.push(String(killError));}
  }
  row.exitCode=process.exitCode;row.signalCode=process.signalCode;
  row.processExited=process.exitCode!==null || process.signalCode!==null;
  receipt.cleanup.push(row);
  assert(row.processExited,`${label} owned browser process did not exit.`);
}
try{
  const assets=(await readdir(join(dist,"assets"),{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name));
  assert(assets.length>0,"The frozen build has no assets.");
  const inventory=[];
  for(const entry of assets){
    assert(entry.isFile(),"Built assets must be regular files, without links/directories.");
    assert(!/\.(?:ts|tsx|map|env)$/i.test(entry.name),"Raw TypeScript/maps/env must not ship.");
    const bytes=await readFile(join(dist,"assets",entry.name));
    inventory.push({path:`assets/${entry.name}`,bytes:bytes.length,sha256:sha(bytes)});
  }
  const worker=inventory.filter(row=>/^assets\/encoder-worker-[A-Za-z0-9_-]+\.js$/.test(row.path));
  const worklet=inventory.filter(row=>/^assets\/export-pcm-worklet-[A-Za-z0-9_-]+\.js$/.test(row.path));
  assert.equal(worker.length,1,"Exactly one compiled encoder worker .js must exist.");
  assert.equal(worklet.length,1,"Exactly one compiled PCM worklet .js must exist.");
  const manifestBytes=await readFile(join(dist,".vite/manifest.json"));
  const manifest=JSON.parse(manifestBytes);
  const emitted=new Set(Object.values(manifest).flatMap(row=>[row.file,...(row.assets??[]),...(row.css??[])]));
  for(const row of [worker[0],worklet[0]])assert(emitted.has(row.path),`${row.path} is not bound to the Vite manifest.`);
  const headersBytes=await readFile(join(dist,"_headers")),redirectBytes=await readFile(join(dist,"_redirects"));
  const policy={};let block;
  for(const raw of headersBytes.toString("utf8").split(/\r?\n/)){
    if(!raw.trim() || raw.trimStart().startsWith("#"))continue;
    if(!/^\s/.test(raw)){assert.equal(raw.trim(),"/*","Unsupported header match: update this smoke's policy parser explicitly.");block=raw.trim();continue;}
    assert.equal(block,"/*");const at=raw.indexOf(":");assert(at>0,"Invalid _headers row.");
    const key=raw.slice(0,at).trim().toLowerCase(),value=raw.slice(at+1).trim();
    assert(!Object.hasOwn(policy,key),"Repeated response header needs explicit handling.");policy[key]=value;
  }
  assert(policy["content-security-policy"]?.includes("script-src 'self'"));
  assert.equal(policy["x-content-type-options"],"nosniff");
  const redirects=redirectBytes.toString("utf8").split(/\r?\n/).map(row=>row.trim()).filter(row=>row&&!row.startsWith("#")).map(row=>row.split(/\s+/));
  assert.deepEqual(redirects,[["/auth/callback","/index.html","200"]],"Unexpected _redirects: do not silently substitute SPA fallbacks or redirect rules.");
  const index=await readFile(join(dist,"index.html"));
  receipt.build={assets:inventory,manifestSHA256:sha(manifestBytes),headersSHA256:sha(headersBytes),
    redirectsSHA256:sha(redirectBytes),indexSHA256:sha(index),worker:worker[0],worklet:worklet[0]};
  receipt.policy={headers:policy,redirects,externalCanonical307NotTested:true,
    harness:"An otherwise empty test-only document receives the exact dist wildcard headers; production app scripts/customer data are not loaded."};
  const harnessPath="/__rendprop_worker_distribution_smoke__.html";
  const mime={".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",
    ".css":"text/css; charset=utf-8",".svg":"image/svg+xml",".json":"application/json",
    ".txt":"text/plain; charset=utf-8",".webp":"image/webp",".gz":"application/gzip"};
  // Generate only a new owned test key. No existing certificates, keychains,
  // global Node trust or browser certificate stores are read or modified.
  receipt.tls={transport:"https-only-loopback",selfSignedEphemeral:true,
    productionTLSVerified:false,privateKeyArchived:false,privateFilesRemoved:false};
  certificateDirectory=await mkdtemp(join(tmpdir(),"rendprop-distribution-tls-"));
  await chmod(certificateDirectory,0o700);
  const keyPath=join(certificateDirectory,"test-key.pem"),certificatePath=join(certificateDirectory,"test-cert.pem");
  const configPath=join(certificateDirectory,"openssl-test.cnf");
  await writeFile(configPath,"[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=extensions\n[subject]\nCN=127.0.0.1\n[extensions]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n",{mode:0o600});
  execFileSync("openssl",["req","-x509","-newkey","rsa:2048","-sha256","-nodes","-days","1",
    "-config",configPath,"-keyout",keyPath,"-out",certificatePath],
  {timeout:15000,stdio:["ignore","ignore","pipe"]});
  await chmod(keyPath,0o600);
  privateKeyBuffer=await readFile(keyPath);
  const certificate=await readFile(certificatePath),parsedCertificate=new X509Certificate(certificate);
  assert.equal(parsedCertificate.checkIP("127.0.0.1"),"127.0.0.1");
  const certificateSHA256=sha(parsedCertificate.raw);
  receipt.tls={transport:"https-only-loopback",selfSignedEphemeral:true,
    certificateSHA256,fingerprint256:parsedCertificate.fingerprint256,
    subjectAltName:parsedCertificate.subjectAltName,validFrom:parsedCertificate.validFrom,validTo:parsedCertificate.validTo,
    opensslVersion:execFileSync("openssl",["version"],{encoding:"utf8",timeout:5000}).trim(),
    nodePreflight:"Owned HTTPSAgent CA=only this certificate, rejectUnauthorized=true, default hostname verification, maxCachedSessions=0; no redirects followed",
    browserTrust:"ignoreHTTPSErrors=true only in the fresh synthetic context; exact-origin GET route and unchanged CSP block other network origins",
    productionTLSVerified:false,privateKeyArchived:false,privateFilesRemoved:false};
  httpsAgent=new HTTPSAgent({ca:certificate,rejectUnauthorized:true,keepAlive:false,maxCachedSessions:0});
  server=createServer({key:privateKeyBuffer,cert:certificate},async(request,response)=>{
    const rawURL=request.url,host=request.headers.host??null;
    const requestRecord={requestId:receipt.http.requests.length+1,browser:activeBrowserLabel,
      epochMilliseconds:Date.now(),rawURL,host,
      fullURL:host?`https://${host}${rawURL}`:null,
      origin:host?networkURL(`https://${host}${rawURL}`):null,encrypted:Boolean(request.socket.encrypted),
      method:request.method,headers:requestHeaders(request.headers),response:null,
      aborted:false,closed:false,finished:false};
    const retained=limited(receipt.http.requests,requestRecord,receipt.http.maximumRequests);
    if(!retained)receipt.http.dropped++;
    // Observe completion without intercepting writes or replacing native error
    // handling. Browser response events retain the actual wire header values;
    // getHeaders here records the server's explicit response policy.
    if(retained){
      response.once("finish",()=>{try{requestRecord.finished=true;requestRecord.response={
        epochMilliseconds:Date.now(),status:response.statusCode,statusText:response.statusMessage??null,
        explicitHeaders:response.getHeaders()};}catch(error){requestRecord.observationError=String(error).slice(0,8192);}});
      response.once("close",()=>{requestRecord.closed=true;});
      request.once("aborted",()=>{requestRecord.aborted=true;});
    }
    for(const [key,value] of Object.entries(policy))response.setHeader(key,value);
    if(request.method!=="GET"){response.writeHead(405);response.end();return;}
    try{
      let pathname=decodeURIComponent(new URL(request.url,"https://127.0.0.1").pathname);
      if(pathname===harnessPath){response.setHeader("Content-Type",mime[".html"]);response.end("<!doctype html><html><head><meta charset=\"utf-8\"><title>Worker distribution smoke</title></head><body></body></html>");return;}
      const rewrite=redirects.find(([from])=>from===pathname);
      if(rewrite)pathname=rewrite[1];
      if(pathname==="/")pathname="/index.html";
      const file=resolve(dist,`.${pathname}`);
      if(!file.startsWith(dist+sep) || pathname.includes("\0") || pathname.startsWith("/.")){response.writeHead(404);response.end();return;}
      const info=await lstat(file);if(!info.isFile()){response.writeHead(404);response.end();return;}
      response.setHeader("Content-Type",mime[extname(file)]??"application/octet-stream");
      response.end(await readFile(file));
    }catch(error){if(!response.headersSent)response.writeHead(error.code==="ENOENT"?404:500);response.end();}
  });
  // createServer synchronously constructs the native TLS context. Release our
  // key buffer and remove all private files before opening the listening socket.
  privateKeyBuffer.fill(0);privateKeyBuffer=undefined;
  await rm(certificateDirectory,{recursive:true,force:true});certificateDirectory=undefined;
  receipt.tls.privateFilesRemoved=true;
  await listenLoopback(server,error=>{
    receipt.status="failed";limited(receipt.errors,"Local HTTPS server error: "+String(error),32);process.exitCode=1;
  });
  const origin=`https://127.0.0.1:${server.address().port}`;
  receipt.tls.origin=origin;receipt.tls.preflights=[];
  const request=async path=>{const response=await getTestHTTPS(origin+path,httpsAgent,certificateSHA256);
    receipt.tls.preflights.push({path,status:response.status,...response.tls});return response;};
  for(const [path,expected] of [["/",index],["/auth/callback?probe=1",index],
    [`/${worker[0].path}`,await readFile(join(dist,worker[0].path))],
    [`/${worklet[0].path}`,await readFile(join(dist,worklet[0].path))]]){
    const response=await request(path);assert.equal(response.status,200);assert.equal(response.headers.get("location"),null);
    for(const [name,value] of Object.entries(policy))assert.equal(response.headers.get(name),value);
    assert.equal(sha(Buffer.from(await response.arrayBuffer())),sha(expected));
    assert.match(response.headers.get("content-type")??"",path.includes("assets/")?/^(?:text|application)\/javascript/:/^text\/html/);
  }
  for(const path of ["/workspace","/assets/__missing__.js","/assets/__missing__.ts"]){
    const response=await request(path);assert.equal(response.status,404,"Unknown routes/assets must not become HTML.");
  }
  receipt.checks.push("Real root, configured OAuth rewrite, worker and worklet bytes served exactly with original headers; JavaScript MIME/nosniff; unknown assets/routes stay404; no raw TS asset.");
  const browserDefinitions=JSON.parse(await readFile(join(root,"node_modules/playwright-core/browsers.json"),"utf8"));
  assert.equal(browserDefinitions.browsers.find(row=>row.name==="chromium")?.browserVersion,"153.0.8010.12");
  assert.equal(browserDefinitions.browsers.find(row=>row.name==="webkit")?.revision,"2359");
  const chromiumPath=await realpath(process.env.STUDIO_BROWSER_EXECUTABLE||chromium.executablePath());
  const chromeVersion=execFileSync(chromiumPath,["--version"],{encoding:"utf8",timeout:10000});
  assert.match(chromeVersion.trim(),/\b153\.0\.8010\.12$/,"Use the installed pinned Chromium153.");
  const webkitPath=await realpath(webkit.executablePath());assert.match(webkitPath,/[\/]webkit-2359[\/]/,"Use installed Playwright WebKit2359; do not download/relabel Safari.");
  receipt.runtime={chromiumVersionRaw:chromeVersion,playwrightBrowserDefinitionsSHA256:sha(await readFile(join(root,"node_modules/playwright-core/browsers.json")))};
  const configs=[];
  for(const [width,height] of [[1280,720],[720,1280],[960,960]])for(const withAudio of [false,true])
    configs.push({width,height,frames:1,durationMicroseconds:33333,withAudio,audioFrames:withAudio?1600:0,
      windowFrameCounts:withAudio?[1600]:[],frameRate:30,sampleRate:48000,channels:2});
  for(const [name,type,executablePath] of [["chromium153",chromium,chromiumPath],["playwright-webkit2359",webkit,webkitPath]]){
    activeBrowserLabel=name;
    const row={name,executablePath,configs:[],errors:[],downloads:0,cleanup:false,
      consoleEvents:[],consoleDropped:0,pageErrorEvents:[],pageErrorDropped:0,
      observationErrors:[],observationErrorsDropped:0};receipt.browsers.push(row);
    try{
      activeServer=await type.launchServer({headless:true,executablePath,timeout:20000});
      const browser=await type.connect(activeServer.wsEndpoint(),{timeout:10000});row.version=browser.version();
      if(name==="chromium153")assert.match(row.version,/153\.0\.8010\.12$/);
      const context=await browser.newContext({serviceWorkers:"block",ignoreHTTPSErrors:true,viewport:{width:1000,height:800}});
      row.tls={ignoreHTTPSErrors:true,scope:"Fresh empty synthetic context; exact HTTPS loopback origin only; no production certificate claim"};
      observeBrowserNetwork(context,row);
      context.on("console",message=>{try{const text=message.text();
        if(!limited(row.consoleEvents,{epochMilliseconds:Date.now(),
          type:message.type(),text:text.slice(0,8192),textTruncated:text.length>8192,
          location:message.location()},80))row.consoleDropped++;
      }catch(error){if(!limited(row.observationErrors,{kind:"console",message:String(error).slice(0,8192)},16))row.observationErrorsDropped++;}});
      await context.route("**/*",route=>{
        const req=route.request(),url=new URL(req.url());
        if(url.origin===origin && req.method()==="GET")return route.continue();
        if(receipt.externalRequests.length<50)receipt.externalRequests.push({browser:name,origin:url.origin,method:req.method()});
        return route.abort();
      });
      const page=await context.newPage();page.on("pageerror",error=>{
        limited(row.errors,error.message.slice(0,500),32);
        if(!limited(row.pageErrorEvents,{epochMilliseconds:Date.now(),name:error.name,
          message:error.message.slice(0,8192),messageTruncated:error.message.length>8192,
          stack:error.stack?.slice(0,16384)??null},32))row.pageErrorDropped++;
      });
      page.on("download",()=>row.downloads++);page.setDefaultTimeout(15000);
      await page.goto(origin+harnessPath,{waitUntil:"load",timeout:10000});
      row.documentURL=page.url();row.documentOrigin=networkURL(page.url());
      const result=await bounded(page.evaluate(async({workerPath,configs})=>{
        const api=Object.fromEntries(["Worker","VideoEncoder","AudioEncoder","VideoFrame","AudioContext","AudioWorkletNode","MediaRecorder"]
          .map(name=>[name,typeof globalThis[name]]));
        const mimes=Object.fromEntries(["video/mp4;codecs=avc1.42E01F,mp4a.40.2","video/mp4;codecs=avc1,mp4a.40.2","video/webm;codecs=vp8,opus","video/webm"]
          .map(mime=>[mime,typeof MediaRecorder==="function"?MediaRecorder.isTypeSupported(mime):false]));
        const results=[],violations=[];
        const violation=event=>{if(violations.length<20)violations.push({
          effectiveDirective:event.effectiveDirective,blockedURI:event.blockedURI,
          documentURI:event.documentURI,sourceFile:event.sourceFile,lineNumber:event.lineNumber,
          columnNumber:event.columnNumber,statusCode:event.statusCode,disposition:event.disposition,
          originalPolicy:event.originalPolicy});};
        document.addEventListener("securitypolicyviolation",violation);
        try{
          for(const config of configs){
            const observation={requested:config,status:"starting",sent:["init"],workerCreated:false,terminationCalls:0,
              documentURL:location.href,documentOrigin:location.origin,documentBaseURI:document.baseURI};
            results.push(observation);let worker,timer;
            const runId=crypto.randomUUID(),revision="distribution-capability";
            try{
              const url=new URL(workerPath,location.href);if(url.origin!==location.origin)throw new Error("Worker must remain same-origin.");
              observation.workerURL=url.href;worker=new Worker(url,{type:"module"});observation.workerCreated=true;
              await new Promise((resolve,reject)=>{
                timer=setTimeout(()=>reject(new Error("Actual worker initialization timed out.")),10000);
                worker.onerror=event=>{const message=event.message||"Compiled worker failed to load.";
                  try{observation.workerError={message:event.message,
                    filename:event.filename,lineNumber:event.lineno,columnNumber:event.colno,
                    type:event.type,isTrusted:event.isTrusted,errorName:event.error?.name??null,
                    errorMessage:event.error?.message??null};}
                  catch(error){observation.workerErrorObservationError=String(error).slice(0,8192);}
                  reject(new Error(message));};
                worker.onmessageerror=()=>reject(new Error("Compiled worker response could not be decoded."));
                worker.onmessage=({data})=>{
                  if(data?.runId!==runId || data?.revision!==revision)return;
                  if(data.type==="ready"){observation.status="ready";observation.echo=data.config;observation.credits=data.credits;resolve();}
                  else if(data.type==="error" && data.code==="ENCODER_UNSUPPORTED"){
                    observation.status="unsupported";observation.code=data.code;observation.message=data.message;resolve();
                  }else reject(new Error(`Unexpected worker initialization result: ${data.type}/${data.code??""}: ${data.message??""}`));
                };
                worker.postMessage({type:"init",runId,revision,config});
              });
            }catch(error){observation.status="failed";observation.error=String(error);
              observation.errorDetails={name:error?.name??null,message:error?.message??null,
                stack:typeof error?.stack==="string"?error.stack.slice(0,8192):null};}
            finally{clearTimeout(timer);if(worker){worker.onmessage=null;worker.onerror=null;worker.onmessageerror=null;worker.terminate();observation.terminationCalls++;}}
            if(observation.status==="failed")break;
          }
        }finally{document.removeEventListener("securitypolicyviolation",violation);}
        return {userAgent:navigator.userAgent,secureContext:isSecureContext,api,mediaRecorderMimes:mimes,
          configs:results,violations,downloadLinks:document.querySelectorAll("a[download]").length};
      },{workerPath:`/${worker[0].path}`,configs}),70000,`${name} capability matrix`);
      Object.assign(row,result);assert.equal(result.configs.length,configs.length);assert.equal(result.secureContext,true);
      for(const observed of result.configs){
        assert(["ready","unsupported"].includes(observed.status),observed.error||"Unknown capability state.");
        assert.equal(observed.workerCreated,true);assert.equal(observed.terminationCalls,1);assert.deepEqual(observed.sent,["init"]);
        if(observed.status==="ready"){assert.deepEqual(observed.echo,observed.requested);assert.deepEqual(observed.credits,{video:2,audio:8});}
        else assert.equal(observed.code,"ENCODER_UNSUPPORTED");
      }
      assert.deepEqual(row.errors,[]);assert.deepEqual(result.violations,[]);assert.equal(row.downloads,0);assert.equal(result.downloadLinks,0);
      await bounded(context.close(),5000,`${name} context close`);
    }catch(error){row.failure=String(error);receipt.errors.push(`${name}: ${String(error)}`);}
    finally{const owner=activeServer;activeServer=null;await closeBrowserServer(owner,name);row.cleanup=true;}
  }
  assert.deepEqual(receipt.externalRequests,[]);assert.deepEqual(receipt.errors,[]);
  assert.deepEqual((await readdir(join(dist,"assets"))).sort(),inventory.map(row=>row.path.slice("assets/".length)).sort(),"Built asset inventory changed during smoke.");
  for(const row of inventory)assert.equal(sha(await readFile(join(dist,row.path))),row.sha256,"Frozen built asset changed during smoke.");
  assert.equal(sha(await readFile(join(dist,"_headers"))),receipt.build.headersSHA256);
  assert.equal(sha(await readFile(join(dist,"_redirects"))),receipt.build.redirectsSHA256);
  assert.equal(sha(await readFile(join(dist,".vite/manifest.json"))),receipt.build.manifestSHA256);
  assert.equal(sha(await readFile(join(dist,"index.html"))),receipt.build.indexSHA256);
  receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error);process.exitCode=1;}
finally{
  try{await closeBrowserServer(activeServer,"interrupted-browser");}catch(error){receipt.status="failed";receipt.errors.push(String(error));process.exitCode=1;}
  httpsAgent?.destroy();
  if(server){
    try{server.closeAllConnections();await bounded(new Promise((done,fail)=>server.close(error=>error?fail(error):done())),5000,"Local HTTPS close");receipt.httpServerClosed=true;}
    catch(error){receipt.status="failed";receipt.errors.push(String(error));process.exitCode=1;}
  }
  if(privateKeyBuffer){privateKeyBuffer.fill(0);privateKeyBuffer=undefined;}
  if(certificateDirectory){
    try{await rm(certificateDirectory,{recursive:true,force:true});certificateDirectory=undefined;
      if(receipt.tls)receipt.tls.privateFilesRemoved=true;}
    catch(error){receipt.status="failed";receipt.errors.push("Ephemeral TLS cleanup failed: "+String(error));process.exitCode=1;}
  }
  await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2)+"\n");
  console.log(JSON.stringify({gate:receipt.gate,status:receipt.status,artifacts,scope:receipt.scope}));
}
