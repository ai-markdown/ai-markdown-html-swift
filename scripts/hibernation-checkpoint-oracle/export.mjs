#!/usr/bin/env node
// Fixed Web execution only: no expected checkpoint or output tree is constructed by this producer.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,writeFile,readdir,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url)),root=path.resolve(here,'../..');
const fixture=path.join(root,'Tests/AIMarkdownHTMLTests/Fixtures/hibernation-checkpoints.json');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const entry=path.join(here,'runtime-entry.mjs'),bundle=path.join(here,'oracle.mjs');
const inputs=[];
const prefixes=new Set(['','<!😀😀>','<!中文>','<!a😀>','<!😀ab>','<!xxxxx>']);
for(const source of ['<!--x-->','<!DOCTYPE html>','<![CDATA[x]]>']) {
 const scalars=Array.from(source);
 for(let i=1;i<=scalars.length;i++)prefixes.add(scalars.slice(0,i).join(''));
}
function add(id,values) {
 let rawSource='',offset=0;
 const segments=values.map(([kind,role,value],index)=> {
  const raw=kind==='raw'?value:'';const start=offset;rawSource+=raw;offset+=Buffer.byteLength(raw);
  return {id:'e'+index,kind,role,value,rawUTF8Start:start,rawUTF8End:offset};
 });
 inputs.push({id,segments,rawSource});
}
for(const [container,prefix] of [['ascii','<div>x\n'],['unicode-crlf','<span title="a>b">文😀\r\n'],['unicode-cr','<svg>字\r']]) {
 for(const [index,tail]of [...prefixes].entries()) {
  const value=prefix+tail;
  add(container+'/'+index+'/end',[['raw','author-raw',value]]);
  add(container+'/'+index+'/continue',[['raw','author-raw',value],['raw','author-raw','>tail']]);
  add(container+'/'+index+'/generated',[['raw','author-raw',value],['raw','hast-generated-tag','<hr>'],['raw','author-raw','tail']]);
 }
}
add('rescue/text',[['raw','author-raw','<div>x\n<!--'],['characters','hast-generated-text','SAFE'],['raw','author-raw','tail']]);
add('rescue/element-then-text',[['raw','author-raw','<div>x\n<!--'],['raw','hast-generated-tag','<hr>'],['characters','hast-generated-text','SAFE'],['raw','author-raw','tail']]);
add('declaration/generated-no-pending',[['raw','author-raw','<div>x\n<!-'],['raw','hast-generated-tag','<hr>'],['raw','author-raw','tail']]);
add('declaration/continue-seven',[['raw','author-raw','<div>x\n<!-'],['raw','author-raw','>tailxx']]);
add('declaration/continue-five',[['raw','author-raw','<div>x\n<!-'],['raw','author-raw','>tail']]);
let manifest;
if(process.argv.includes('--check')) {
 manifest=JSON.parse(await readFile(path.join(here,'manifest.json'),'utf8'));
 assert.equal(manifest.webCommit,'e9ec1799fdc380d99ce0a6313023515895bbd7bf');
 assert.equal(sha(await readFile(bundle)),manifest.bundleSHA256);
 for(const [name,digest]of Object.entries(manifest.controls))assert.equal(sha(await readFile(path.join(root,name))),digest,name);
 for(const item of Object.values(manifest.packages))assert.equal(sha(await readFile(path.join(here,item.saved))),item.licenseSHA256,item.saved);
} else {
 const web=path.resolve(process.argv[2]??'');
 assert.equal(execFileSync('git',['rev-parse','HEAD'],{cwd:web,encoding:'utf8'}).trim(),'e9ec1799fdc380d99ce0a6313023515895bbd7bf');
 const require=createRequire(path.join(web,'packages/engine/package.json'));
 const rehypeRequire=createRequire(require.resolve('@ai-markdown/rehype-raw'));
 const rawPath=rehypeRequire.resolve('hast-util-raw'),rawRequire=createRequire(rawPath);
 const parsePath=rawRequire.resolve('parse5').replace('/dist/cjs/','/dist/');
 const esbuild=require('esbuild');
 const built=await esbuild.build({absWorkingDir:web,stdin:{contents:await readFile(entry,'utf8'),resolveDir:web,sourcefile:'checkpoint-entry.mjs'},
  alias:{'parse5':parsePath,'@ai-markdown/hast-util-raw':rawPath},outfile:bundle,bundle:true,platform:'node',format:'esm',target:'node24',metafile:true,logLevel:'warning'});
 const sourceHashes={},packages={};
 for(const input of Object.keys(built.metafile.inputs).sort()) {
  if(input.includes('checkpoint-entry.mjs'))continue;
  const file=path.resolve(web,input);sourceHashes[path.relative(web,file).split(path.sep).join('/')]=sha(await readFile(file));
  let directory=path.dirname(file);
  for(;;) {
   let pkg;try{pkg=JSON.parse(await readFile(path.join(directory,'package.json'),'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
   if(pkg?.name) {
    const id=pkg.name+'@'+pkg.version;
    if(!packages[id]) {
     const names=await readdir(directory),license=names.find(name=>/^licen[cs]e(?:[-.].*)?$/i.test(name));
     assert.ok(license,'A complete license is required for '+id);
     const bytes=await readFile(path.join(directory,license)),saved='LICENSE-'+id.replaceAll('/','-');
     await writeFile(path.join(here,saved),bytes);
     packages[id]={licenseSHA256:sha(bytes),packageJSONSHA256:sha(await readFile(path.join(directory,'package.json'))),saved};
    }
    break;
   }
   const parent=path.dirname(directory);assert.notEqual(parent,directory);directory=parent;
  }
 }
 manifest={schemaVersion:1,webCommit:'e9ec1799fdc380d99ce0a6313023515895bbd7bf',bundleSHA256:sha(await readFile(bundle)),sourceHashes,packages,
  controls:{},scope:'Actual parse5 7.3.0 tokenizer writes observed passively inside actual hast-util-raw 9.1.3; complete Web trees and consumed checkpoints are preserved. Native UTF-8 event endpoints are not inferred from expected HAST positions.'};
}
const runtime=await import(pathToFileURL(bundle));
const cases=inputs.map(input=>({...input,...runtime.run(input)}));
const body=JSON.stringify({schemaVersion:1,webCommit:manifest.webCommit,cases})+'\n';
if(process.argv.includes('--check')) {
 assert.equal(await readFile(fixture,'utf8'),body);
 assert.equal(sha(await readFile(fixture)),manifest.fixtureSHA256);
} else {
 await mkdir(path.dirname(fixture),{recursive:true});await writeFile(fixture,body);
 manifest.fixtureSHA256=sha(body);manifest.caseCount=cases.length;
 for(const name of ['scripts/hibernation-checkpoint-oracle/export.mjs','scripts/hibernation-checkpoint-oracle/runtime-entry.mjs'])manifest.controls[name]=sha(await readFile(path.join(root,name)));
 await writeFile(path.join(here,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
}
console.log(cases.length+' complete fixed-Web checkpoint controls '+(process.argv.includes('--check')?'replayed':'captured'));
