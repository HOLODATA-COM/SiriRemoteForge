import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
const root=resolve(import.meta.dirname,'..');
const meta=JSON.parse(execFileSync('cargo',['metadata','--locked','--format-version','1','--manifest-path',join(root,'src-tauri/Cargo.toml')],{maxBuffer:32*1024*1024,encoding:'utf8'}));
const sections=['VoiceInk dependency copyright and license notices.\nGenerated from locked dependencies.\n'];
for(const p of meta.packages.sort((a,b)=>a.name.localeCompare(b.name))){
  if(p.name==='voiceink')continue;
  const dir=dirname(p.manifest_path);
  const files=readdirSync(dir,{withFileTypes:true}).filter(f=>f.isFile()&&/^(licen[cs]e|copying|notice)([.-]|$)/i.test(f.name));
  sections.push(`\n${'='.repeat(72)}\n${p.name} ${p.version}\nLicense: ${p.license||'see included notice'}\nSource: ${p.repository||p.source||''}\n`);
  for(const f of files)sections.push(`\n--- ${f.name} ---\n${readFileSync(join(dir,f.name),'utf8')}`);
  if(!files.length&&p.license_file)sections.push(readFileSync(join(dir,p.license_file),'utf8'));
}
const packages=JSON.parse(readFileSync(join(root,'package-lock.json'),'utf8')).packages;
for(const [path,p] of Object.entries(packages)){
  if(!path||!path.startsWith('node_modules/'))continue;
  const dir=join(root,path);
  let files=[];try{files=readdirSync(dir).filter(f=>/^(licen[cs]e|copying|notice)([.-]|$)/i.test(f));}catch{continue;}
  sections.push(`\n${'='.repeat(72)}\n${path} ${p.version}\nLicense: ${p.license||'see included notice'}\n`);
  for(const file of files)sections.push(`\n--- ${file} ---\n${readFileSync(join(dir,file),'utf8')}`);
}
writeFileSync(join(root,'src-tauri/THIRD_PARTY_NOTICES.txt'),sections.join('\n'));
console.log(`Collected license notices for ${meta.packages.length-1} Rust packages and installed npm dependencies.`);
