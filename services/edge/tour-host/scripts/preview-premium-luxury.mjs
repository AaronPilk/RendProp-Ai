// Local-only presentation preview. No API, enquiry, telemetry or publication.
import {createServer} from 'node:http';
import {readFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {resolve,extname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildSrc,ROOT} from './build-src.mjs';
export async function premiumPreview({port=0}={}) {
 const load=buildSrc('luxury-preview-'+process.pid);
 const {renderTourPage}=await load('player'),{buildDemoTour}=await load('demo'),{propertyPage}=await load('property-site');
 const mediaDir=resolve(ROOT,'../../../../local-media');mkdirSync(mediaDir,{recursive:true});
 const film=resolve(mediaDir,'synthetic-listing-8s.mp4');
 if(!existsSync(film)){
  const input=resolve(ROOT,'public/assets/demo-tour.mp4');
  const args=['-v','error','-i',input,'-t','8','-vf','scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=24','-an','-c:v','libx264','-preset','veryfast','-crf','23','-pix_fmt','yuv420p','-movflags','+faststart',film];
  execFileSync('ffmpeg',args,{stdio:['ignore','pipe','pipe']});
  const metadata=JSON.parse(execFileSync('ffprobe',['-v','error','-show_entries','format=duration:stream=width,height,r_frame_rate,nb_frames','-of','json',film],{encoding:'utf8'}));
  writeFileSync(resolve(mediaDir,'SYNTHETIC-LISTING-FILM-LINEAGE.json'),JSON.stringify({synthetic:true,source:input,source_sha256:createHash('sha256').update(readFileSync(input)).digest('hex'),command:['ffmpeg',...args],metadata,output_sha256:createHash('sha256').update(readFileSync(film)).digest('hex'),paid_calls:0},null,2)+'\n');
 }
 const retained=JSON.parse(readFileSync(resolve(ROOT,'scripts/fixtures/retained-855-public-home.json'),'utf8'));
 const server=createServer((req,res)=>{
  const u=new URL(req.url,'http://127.0.0.1');
  if(u.pathname==='/local-fixture/synthetic-listing-8s.mp4'){const bytes=readFileSync(film);const range=req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);if(range){const start=Number(range[1]),end=Math.min(Number(range[2]||bytes.length-1),bytes.length-1);if(start> end){res.writeHead(416,{'Content-Range':'bytes */'+bytes.length});res.end();return;}res.writeHead(206,{'Content-Type':'video/mp4','Accept-Ranges':'bytes','Content-Range':`bytes ${start}-${end}/${bytes.length}`,'Content-Length':end-start+1});res.end(bytes.subarray(start,end+1));}else{res.writeHead(200,{'Content-Type':'video/mp4','Content-Length':bytes.length,'Accept-Ranges':'bytes'});res.end(bytes);}return;}
  if(u.pathname.startsWith('/assets/')) {const p=resolve(ROOT,'public','.'+u.pathname);if(p.startsWith(resolve(ROOT,'public/assets')+'/')&&existsSync(p)){res.writeHead(200,{'Content-Type':({'.webp':'image/webp','.mp4':'video/mp4','.svg':'image/svg+xml','.jpg':'image/jpeg','.png':'image/png'})[extname(p)]||'application/octet-stream'});res.end(readFileSync(p));return;}}
  if(u.pathname==='/') {res.writeHead(200,{'Content-Type':'text/html'});res.end('<h1>Local paid design previews</h1><p>855: actual retained38 display images. First4 master links verified from home HTML; remaining links are display observations, some thumbnails. Rich and Listing-video fixtures below are explicitly synthetic.</p>'+['signature-estate','coastal-luxe','basic'].map(t=>`<p><a href="/property/${retained.tour.slug}?preview_theme=${t}">${t} · actual855</a> · <a href="/property/estate-demo?preview_theme=${t}&fixture=rich">synthetic rich + Listing film</a> · <a href="/property/estate-demo?preview_theme=${t}&fixture=rich&media=photo">synthetic rich + photo hero</a></p>`).join(''));return;}
  if(u.pathname.startsWith('/property/')){
   const rich=u.searchParams.get('fixture')==='rich';const t=rich?buildDemoTour():structuredClone(retained.tour);
   if(rich){if(u.searchParams.get('media')!=='photo')t.listing_video={url:'/local-fixture/synthetic-listing-8s.mp4',poster_url:'/assets/demo-poster.webp',duration_s:8,width:1920,height:1080,disclosure:'Synthetic accepted Listing-video fixture. Photo-based property video.',branding_policy:'unbranded'};t.listing.tagline='Synthetic demonstration property';}
   // Preview mode disables enquiries/telemetry. All renderer links stay local.
   const theme=['basic','signature-estate','coastal-luxe'].includes(u.searchParams.get('preview_theme'))?u.searchParams.get('preview_theme'):'signature-estate';
   let html=renderTourPage(t,'/closed-api','','',{origin,publicBase:'/property',page:propertyPage(u.searchParams.get('page')),previewTheme:theme});
   if(rich)html=html.replaceAll('preview_theme='+theme,'preview_theme='+theme+'&amp;fixture=rich'+(u.searchParams.get('media')==='photo'?'&amp;media=photo':''));
   res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store','Content-Security-Policy':"connect-src 'self'; frame-src 'none'; form-action 'none'"});res.end(html);return;
  }
  res.writeHead(404);res.end('Local preview: no API available');
 });
 let origin;await new Promise(r=>server.listen(port,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;return{server,origin,load,retained};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){const {origin}=await premiumPreview({port:Number(process.env.PORT||4179)});console.log(origin);}
