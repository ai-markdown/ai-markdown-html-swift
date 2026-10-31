// Passive checkpoint observations from the actual fixed parse5 / hast-util-raw implementation.
import assert from 'node:assert/strict';
import {Tokenizer} from 'parse5';
import {raw} from '@ai-markdown/hast-util-raw';
const clone=value=>JSON.parse(JSON.stringify(value));
function point(value) {
 const lines=value.split(/\r\n|\r|\n/);
 return {line:lines.length,column:lines.at(-1).length+1,offset:value.length};
}
function semantic(node) {
 if(node.type==='root')return {type:'root',children:node.children.map(semantic)};
 if(node.type==='text'||node.type==='comment')return {type:node.type,value:node.value};
 if(node.type==='doctype')return {type:'doctype'};
 return {type:'element',name:node.tagName,attributes:node.properties??{},children:(node.children??[]).map(semantic)};
}
export function run(item) {
 const rawSegments=item.segments.filter(s=>s.kind==='raw'&&s.role==='author-raw');
 const children=item.segments.map(segment=> {
  if(segment.kind==='characters')return {type:'text',value:segment.value};
  if(segment.role==='hast-generated-tag')return {type:'element',tagName:'hr',properties:{},children:[]};
  const before=Buffer.from(item.rawSource).subarray(0,segment.rawUTF8Start).toString();
  return {type:'raw',value:segment.value,position:{start:point(before),end:point(before+segment.value)}};
 });
 const tree={type:'root',children}, observed=[];
 const original=Tokenizer.prototype.write;
 Tokenizer.prototype.write=function(value,last,callback) {
  const base=this.preprocessor.droppedBufferSize;
  let result,error;
  try {result=original.call(this,value,last,callback);}catch(value){error=value;}
  const consumed=this.preprocessor.offset+1-base;
  observed.push({value,last,state:this.state,consumedUTF16:consumed,
                 consumedUTF8:Buffer.byteLength(value.slice(0,consumed)),pending:clone(this.currentCharacterToken?.location??null),
                 error:error?{name:error.name,message:error.message}:null});
  if(error)throw error;
  return result;
 };
 let actual,webError,baseline,baselineError;
 try {actual=raw(clone(tree));}catch(error){webError={name:error.name,message:error.message};}finally{Tokenizer.prototype.write=original;}
 try {baseline=raw(clone(tree));}catch(error){baselineError={name:error.name,message:error.message};}
 assert.deepEqual(webError,baselineError,'Observers must not change real Web errors');
 assert.deepEqual(actual,baseline,'Passive observations must not change the complete real Web tree');
 assert.ok(observed.length<=rawSegments.length);
 if(!webError)assert.equal(observed.length,rawSegments.length);
 const checkpoints=[];
 for(const [index,observation]of observed.entries()) {
  const segment=rawSegments[index],segmentIndex=item.segments.indexOf(segment),next=item.segments[segmentIndex+1];
  assert.equal(observation.value,segment.value);
  if(!observation.error&&observation.consumedUTF16<segment.value.length&&!(next?.kind==='raw'&&next?.role==='author-raw')) {
   checkpoints.push({emissionID:segment.id,end:segment.rawUTF8Start+observation.consumedUTF8,state:observation.state,pendingCharacter:observation.pending!==null});
  }
 }
 return {semantic:actual?semantic(actual):null,completeHast:actual??null,webError:webError??null,observations:observed,checkpoints,passiveObserversVerified:true};
}
