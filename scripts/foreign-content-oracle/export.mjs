#!/usr/bin/env node
// Produce immutable trees from the exact Web parse5/hast-util-raw packages, never from Swift output.
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
if (!process.argv[2]) throw Error('usage: node export.mjs <fixed-web-checkout>');
const web = resolve(process.argv[2]);
const revision = execFileSync('git', ['rev-parse', 'HEAD'], {cwd:web, encoding:'utf8'}).trim();
if (revision !== 'e9ec1799fdc380d99ce0a6313023515895bbd7bf') throw Error('the fixed Web revision is required');
const require = createRequire(resolve(web, 'packages/engine/package.json'));
const rehypeRequire = createRequire(require.resolve('@ai-markdown/rehype-raw'));
const rawPath = rehypeRequire.resolve('hast-util-raw');
const rawRequire = createRequire(rawPath);
const parse5 = await import(pathToFileURL(rawRequire.resolve('parse5').replace('/dist/cjs/', '/dist/')));
const {raw} = await import(pathToFileURL(rawPath));
const parseVersion = JSON.parse(readFileSync(resolve(rawRequire.resolve('parse5'), '../../../package.json'))).version;
const rawVersion = JSON.parse(readFileSync(resolve(rawPath, '../package.json'))).version;
if (parseVersion !== '7.3.0' || rawVersion !== '9.1.3') throw Error('the fixed Web package versions are required');
const foreignSource = readFileSync(resolve(rawRequire.resolve('parse5'), '../../common/foreign-content.js'), 'utf8');
function canonical(node) {
  if (node.nodeName === '#text') return {type:'text', value:node.value};
  if (node.nodeName === '#comment') return {type:'comment', value:node.data};
  if (node.nodeName === '#documentType') return {type:'doctype'};
  const children = (node.content || node).childNodes || [];
  return {type:'element', name:node.tagName, namespace:node.namespaceURI,
    attributes:node.attrs.map(a => ({name:a.prefix ? a.prefix + ':' + a.name : a.name, value:a.value, namespace:a.namespace || null, prefix:a.prefix ?? null})), children:children.map(canonical)};
}
const inputs=[];
function add(id,html) {inputs.push({id,html});}
const svgNames = [...foreignSource.split('SVG_TAG_NAMES_ADJUSTMENT_MAP = new Map([')[1].split('].map')[0].matchAll(/'([A-Za-z]+)'/g)].map(m=>m[1]);
const svgAttrs = [...foreignSource.split('SVG_ATTRS_ADJUSTMENT_MAP = new Map([')[1].split('].map')[0].matchAll(/'([A-Za-z]+)'/g)].map(m=>m[1]);
for (const name of svgNames) add('svg-name/'+name,`<svg><${name.toUpperCase()}>x</${name.toLowerCase()}><circle/></svg><p>tail</p>`);
for (const name of svgAttrs) add('svg-attribute/'+name,`<svg ${name.toUpperCase()}="v" ${name}="duplicate"><g ${name}="x"/></svg>`);
for (const outer of ['svg','math']) {
 for (const tag of ['b','big','blockquote','body','br','center','code','dd','div','dl','dt','em','embed','h1','h2','h3','h4','h5','h6','head','hr','i','img','li','listing','menu','meta','nobr','ol','p','pre','ruby','s','small','span','strong','strike','sub','sup','table','tt','u','ul','var','font']) {
  add(`breakout/${outer}/${tag}`,`<p>before<${outer}><g>left<${tag}>inside</${tag}>after</g></${outer}>tail`);
 }
 for(const attr of ['color','face','size','id']) add(`font/${outer}/${attr}`,`<${outer}><font ${attr}="x">text</font><g/>tail</${outer}>`);
 for(const close of ['p','br','svg','math','g','unknown']) add(`end/${outer}/${close}`,`<${outer}><g>a</${close}>b</g></${outer}>tail`);
 for(const body of ['a\0b','<![CDATA[a < b &amp;\0]]>tail','<![CDATA[x]]', '<![CDATA[x]', '<![CDATA[x', '<![CDATA[]]]]>tail', '<!--c--><!DOCTYPE html>x']) add(`characters/${outer}/${inputs.length}`,`<${outer}>${body}`);
}
for (const point of ['foreignObject','desc','title']) {
 for(const inside of ['<p>x</p>tail','<svg><g/></svg>after','<math><mi>x</mi></math>after','<![CDATA[x < y]]>tail','<b><i>x</b>y</i>tail','<div><svg><g></div>tail']) add(`svg-integration/${point}/${inputs.length}`,`<svg><${point}>${inside}</${point}><circle/></svg>`);
}
for (const point of ['mi','mo','mn','ms','mtext']) {
 for(const inside of ['<b>x</b>tail','<mglyph><b>x</b></mglyph>tail','<malignmark/><p>x</p>','<svg><title>x</title></svg>tail','<![CDATA[x]]>tail','<math><mi>x</mi></math>tail']) add(`math-integration/${point}/${inputs.length}`,`<math><${point}>${inside}</${point}><mi>after</mi></math>`);
}
for(const encoding of ['text/html','TEXT/HTML','application/xhtml+xml','image/svg+xml','text/plain','']) {
 for(const inside of ['<p>x</p>tail','<svg><g/></svg>tail','<![CDATA[x]]>tail']) add(`annotation/${encoding}/${inputs.length}`,`<math><annotation-xml encoding="${encoding}">${inside}</annotation-xml><mi>after</mi></math>`);
}
for(const html of [
 '<svg><image/><image>x</image><path/></svg>', '<svg><math><mi>x</mi></math></svg>', '<math><svg><g>x</g></svg></math>',
 '<svg><script>a < b &amp;<g/>tail</script></svg>', '<svg><style>a<g/>b</style></svg>',
 '<svg><foreignObject><table>x<tr><td><math><mi><b>y</b></mi></math></td></tr></table></foreignObject></svg>',
 '<table><svg><g>x</g></svg><tr><td>y</td></tr></table>', '<b><svg><foreignObject><i>x</b>y</i></foreignObject></svg>',
 '<svg><foreignObject><template><svg><g/></svg></template>tail</foreignObject></svg>', '<svg><foreignObject><select><option>x<svg><g/></svg></select></foreignObject></svg>',
 '<p><svg><title><p>x</p></title></svg></p>', '<math><mtext><div><math><annotation-xml><svg><g/></svg></annotation-xml></math></div></mtext></math>',
 '<![CDATA[x]]><p>after</p>', '<svg xmlns="x" xmlns:xlink="y"><a xlink:href="url" xml:lang="en" xml:space="preserve" xlink:role="r"/></svg>',
 '<math definitionURL="x"><mi definitionurl="y" xml:lang="zh">中</mi></math>', '<svg VIEWBOX="a" viewbox="b" viewBox="c"/>',
 '<svg><source><g/>after</source><circle/></svg>', '<svg><template><foreignObject><form><input></form></foreignObject></template></svg>',
 '<svg><foreignObject><b><svg><title><i>x</b>y</i></title></svg></foreignObject></svg>',
 '<math><annotation-xml><svg><foreignObject><table><caption><svg><desc><p>x</p></desc></svg></caption></table></foreignObject></svg></annotation-xml></math>',
 '<svg><foreignObject/></svg><p>outside</p>', '<math><annotation-xml encoding="text/html"/><mi>x</mi></math>', '<svg><g></SVG><p>tail</p>',
]) add('mixed/'+inputs.length,html);
for(const key of ['xlink:actuate','xlink:arcrole','xlink:href','xlink:role','xlink:show','xlink:title','xlink:type','xml:lang','xml:space','xmlns','xmlns:xlink']) add('xml-attribute/'+key,`<svg ${key}="value"><g ${key}="inner"/></svg>`);
for (const outer of ['svg','math']) {
 add('unicode-attributes/'+outer, `<${outer} İ="İ" Σ="Σ" É="É" AΣ="x" aσ="y" viewBox="ÉΣİ"><xÉ É="Σİ">文</xÉ></${outer}>`);
 for (const encoding of ['TÉXT/HTML', 'text/htmİ', 'Σ', 'TEXT/HTML']) add('unicode-encoding/'+outer+'/'+encoding,`<${outer}><annotation-xml encoding="${encoding}"><p>文</p></annotation-xml></${outer}>`);
}
for (const outer of ['svg','math']) {
 for (const [open, close] of [['xÉ','xÉ'],['xÉ','xé'],['xΣ','xΣ'],['xΣ','xσ'],['xΣ','xς'],['xΣa','xσa'],['xΣ\u0301a','xσ\u0301a'],['xİ','xİ'],['xİ','xi\u0307'],['xΣ\u0301','xς\u0301']]) {
  add('unicode-end/'+outer+'/'+open+'/'+close, `<${outer}><${open}>one</${close}><g>two</g></${outer}>`);
 }
}
const cases=inputs.map(({id,html})=>({id,html, tree:parse5.parseFragment(html,{scriptingEnabled:false}).childNodes.map(canonical),bodyTree:parse5.parseFragment(parse5.defaultTreeAdapter.createElement('body','http://www.w3.org/1999/xhtml',[]),html,{scriptingEnabled:false}).childNodes.map(canonical)}));
// Passive capture proves the generated/raw sequence is the actual hast-util-raw parser, not a rewritten driver.
const original=parse5.Parser.prototype.getFragment;
let captured;
parse5.Parser.prototype.getFragment=function(){ const node=original.call(this); captured=node; return node; };
function hastCase(id,children) {
 const input={type:'root',children};
 captured=null;
 const output=raw(structuredClone(input));
 const tree=captured.childNodes.map(canonical);
 parse5.Parser.prototype.getFragment=original;
 const control=raw(structuredClone(input));
 parse5.Parser.prototype.getFragment=function(){const node=original.call(this);captured=node;return node;};
 if(JSON.stringify(control)!==JSON.stringify(output)) throw Error('observer changed output');
 return {id,input,output,tree};
}
const sequences=[];
const rawNode=value=>({type:'raw',value});
const text=value=>({type:'text',value});
const element=(tagName,children=[])=>({type:'element',tagName,properties:{},children});
for (const html of ['<svg><foreignObject><p>x</p></foreignObject></svg>','<math><mi><mglyph/>x<b>y</b></mi></math>','<svg><![CDATA[a < &amp; ]]>b</svg>','<svg><g>x\0y</g></svg>','<svg><g></svg><h2>after</h2>']) {
 for(let i=0;i<=html.length;i++) sequences.push(hastCase(`raw-split/${sequences.length}`, [rawNode(html.slice(0,i)),rawNode(html.slice(i))]));
}
for(const outer of ['svg','math']) for(const child of [element('span',[text('generated')]),element('svg',[element('g',[text('in')])]),text('\0<generated>&'),text(''),element('p',[text('tail')])]) {
 sequences.push(hastCase(`generated/${sequences.length}`,[rawNode(`<${outer}><g>raw`),child,rawNode(`tail</g></${outer}><p>end</p>`)]));
}
for(const point of ['foreignObject','title','desc']) sequences.push(hastCase(`generated-point/${point}`,[rawNode(`<svg><${point}>`),element('b',[text('bold')]),rawNode(`</${point}><circle/></svg>`)]));
for(const tail of ['<![CDATA[x', '<![CDATA[x]', '<![CDATA[x]]']) sequences.push(hastCase(`cdata-generated/${sequences.length}`,[rawNode('<svg>'+tail),element('g',[text('generated')]),rawNode('tail]]></svg>')]));
for (const outer of ['svg','math']) sequences.push(hastCase('generated-unicode/'+outer, [rawNode(`<${outer}>`), {type:'element',tagName:'g',properties:{'É':'Σİ', 'İ':'É', 'AΣ':'value'},children:[text('文')]}, rawNode(`</${outer}>`)]));
for (const item of cases) {
 const actual = hastCase('whole-raw/' + item.id, [rawNode(item.html)]);
 item.rawTree = actual.tree;
 item.rawHAST = actual.output;
}
parse5.Parser.prototype.getFragment=original;
process.stdout.write(JSON.stringify({schemaVersion:1,webRevision:'e9ec1799fdc380d99ce0a6313023515895bbd7bf',parse5:'7.3.0',hastUtilRaw:'9.1.3',cases,sequences},null,2)+'\n');
