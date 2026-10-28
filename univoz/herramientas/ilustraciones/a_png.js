const {chromium}=require('playwright');const fs=require('fs');
(async()=>{const b=await chromium.launch();
const dir=process.argv[2], out=process.argv[3];
for (const f of fs.readdirSync(dir).filter(x=>x.endsWith('.svg'))){
 const svg=fs.readFileSync(dir+'/'+f,'utf8');
 for (const [sc,sub] of [[1,''],[2,'2.0x/'],[3,'3.0x/']]){
  const p=await b.newPage({viewport:{width:240,height:180},deviceScaleFactor:sc});
  await p.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('<svg ','<svg width="240" height="180" ')}</body></html>`);
  fs.mkdirSync(out+'/'+sub,{recursive:true});
  await p.screenshot({path:out+'/'+sub+f.replace('.svg','.png'),omitBackground:true,clip:{x:0,y:0,width:240,height:180}});
  await p.close();}}
await b.close();})();
