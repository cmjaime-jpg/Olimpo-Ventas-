// Run: NODE_PATH=/path/to/node_modules node tests/inventario.cjs
const {JSDOM}=require('jsdom');const fs=require('node:fs');const assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const dom=new JSDOM(html,{url:'https://olimpo.test',runScripts:'outside-only'}),w=dom.window;
const $=id=>w.document.getElementById(id);let orders=[],stock=0,rpcs=[];
w.HTMLDialogElement.prototype.close=function(){this.open=false;};w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.confirm=()=>true;
const product={id:'1',nombre:'Dulce de prueba',codigo:'7801234567890',unidad:'unidad',categoria:'Dulces',stock:0,stock_minimo:5,precio_compra:123.45,precio_venta:200,activo:true,revision:'1'};
function query(table){let q={select(){return q},order(){return q},range(){return Promise.resolve({data:table==='productos'?[{...product,stock}]:table==='inv_proveedores'?[{id:'supplier',nombre:'Proveedor prueba'}]:table==='inv_compras'?orders:[],error:null})}};return q;}
const client={from:query,rpc:async(name,args)=>{rpcs.push({name,args:JSON.parse(JSON.stringify(args))});if(name==='inv_crear_compra'){orders=[{id:args.p_ref,proveedor_nombre:'Proveedor prueba',estado:'pendiente',created_at:new Date().toISOString(),notas:'',inv_compra_items:args.p_items.map(l=>({producto_id:l.producto_id,nombre:product.nombre,unidad:'unidad',cantidad:Number(l.cantidad),precio:Number(l.precio),recibido:0}))}];}else {stock+=Number(args.p_items[0].cantidad);orders[0].estado='parcial';orders[0].inv_compra_items[0].recibido=stock;}return {data:args.p_ref,error:null};}};
w.supabase={createClient:()=>({auth:{onAuthStateChange(){}}})};
const marker='  lock();\n  try {';let htmlScript=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const compiled=[];for(let script of htmlScript){if(script.includes(marker))script=script.replace(marker,`window.__qa={activate(c){client=c;user={id:'admin'};profile={rol:'administrador',activo:true};products=[${JSON.stringify(product)}];inventoryReady=true;renderProducts();},invLoad,invReset,invNum,getCart:()=>invCart};\n${marker}`);compiled.push(script);}w.eval(compiled.join("\n"));
(async()=>{
  w.__qa.activate(client);await w.__qa.invLoad();
  assert.match($('invAlert').textContent,/agotados: 1/g);
  $('invSuggest').click();assert.equal(w.__qa.getCart()[0].cantidad,'5');assert.equal(w.__qa.getCart()[0].precio,'123.45');
  $('invSuggest').click();assert.equal(w.__qa.getCart().length,1);
  $('invSupplier').value='supplier';await $('invPurchaseForm').onsubmit({preventDefault(){}});
  assert.equal(rpcs[0].name,'inv_crear_compra');assert.equal(rpcs[0].args.p_items[0].cantidad,'5');assert.equal(stock,0);
  const form=$('invOrders').querySelector('form'),inputs=form.querySelectorAll('input');inputs[0].value='1.25';inputs[1].value='130.50';
  await form.onsubmit({preventDefault(){}});assert.equal(stock,1.25);assert.equal(rpcs[1].args.p_items[0].precio,'130.5');assert.match($('invAlert').textContent,/agotados: 1/g);
  assert.equal(w.__qa.invNum(100,2),'100');assert.equal(w.__qa.invNum(0,3),'0');assert.equal(w.__qa.invNum(.125,3),'0.125');
  $('invScanSearch').click();await new Promise(r=>setTimeout(r,0));assert.match($('invScanStatus').textContent,/no admite/);$('invScanClose').click();assert.equal($('invScanner').open,false);
  if(process.env.OLIMPO_VISUAL_FIXTURE){
    $('acceso').classList.add('oculto');$('areaAplicacion').classList.remove('oculto');$('admin').classList.add('oculto');$('inventario').classList.remove('oculto');$('invPurchaseDetails').open=true;
    w.document.querySelectorAll('script').forEach(e=>e.remove());
    fs.writeFileSync(process.env.OLIMPO_VISUAL_FIXTURE,dom.serialize());
  }
  w.__qa.invReset();assert.equal($('invOrders').children.length,0);assert.equal($('invCart').children.length,0);
  console.log('PASS: app initialization, low stock, suggestions, purchase payload, partial receipt, decimal conversion, camera fallback, logout clearing');dom.window.close();
})().catch(e=>{console.error(e);dom.window.close();process.exitCode=1});
