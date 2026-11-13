-- Olimpo Ventas: preparación del módulo Pedidos sobre el esquema existente.
-- Las escrituras se realizan mediante funciones con autorización explícita.

alter table public.pedidos
 add column if not exists client_ref uuid not null default gen_random_uuid(),
 add column if not exists creado_por uuid references auth.users(id),
 add column if not exists revision bigint not null default 1,
 add column if not exists updated_at timestamptz not null default now(),
 add column if not exists cliente_nombre text;
create unique index if not exists pedidos_client_ref_uidx on public.pedidos(client_ref);
create index if not exists pedidos_vendedor_fecha_idx on public.pedidos(vendedor_id,fecha desc);
create index if not exists detalle_pedidos_pedido_idx on public.detalle_pedidos(pedido_id);
alter table public.detalle_pedidos
 add column if not exists producto_nombre text,
 add column if not exists producto_unidad text,
 add column if not exists costo_unitario numeric;

-- Only read access is exposed. Transactional writes are performed through guarded functions.
-- Existing admin RLS is preserved; sellers can only read their own orders.
revoke all on public.pedidos, public.detalle_pedidos from anon;
revoke insert,update,delete,truncate,references,trigger on public.pedidos, public.detalle_pedidos from authenticated;
grant select on public.pedidos, public.detalle_pedidos to authenticated;
alter table public.pedidos enable row level security;
alter table public.detalle_pedidos enable row level security;
drop policy if exists "Vendedor consulta sus pedidos" on public.pedidos;
create policy "Vendedor consulta sus pedidos" on public.pedidos for select to authenticated
 using (
   exists (select 1 from public.perfiles p where p.id=(select auth.uid()) and p.rol='vendedor' and p.activo)
   and vendedor_id in (select v.id from public.vendedores v where v.usuario_id=(select auth.uid()) and v.activo)
 );
drop policy if exists "Olimpo lee detalles de pedidos accesibles" on public.detalle_pedidos;
create policy "Olimpo lee detalles de pedidos accesibles" on public.detalle_pedidos for select to authenticated
 using (exists(select 1 from public.pedidos p where p.id=pedido_id));

create or replace function olimpo_private.crear_pedido(p_cliente text,p_items jsonb,p_observaciones text,p_ref uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 uid uuid := auth.uid(); role_name text; customer public.clientes%rowtype;
 seller bigint; previous public.pedidos%rowtype; order_id bigint; item jsonb;
 product public.productos%rowtype; qty numeric; expected numeric; price numeric;
 amount numeric := 0; row_count integer; distinct_count integer; product_id bigint;
begin
 select rol into role_name from public.perfiles where id=uid and activo;
 if uid is null or role_name is null or role_name not in ('administrador','vendedor') then
   raise exception 'Cuenta no autorizada' using errcode='42501';
 end if;
 if p_ref is null then raise exception 'Referencia requerida' using errcode='P4000'; end if;
 perform pg_advisory_xact_lock(hashtextextended('olimpo-pedido:'||p_ref::text,0));
 select * into previous from public.pedidos where client_ref=p_ref;
 if found then
   if previous.creado_por is distinct from uid then raise exception 'Referencia no autorizada' using errcode='42501'; end if;
   return jsonb_build_object('id',previous.id::text,'total',previous.total,'repetido',true);
 end if;
 if p_cliente is null or p_cliente !~ '^[0-9]{1,18}$' then raise exception 'Cliente inválido' using errcode='P4000'; end if;
 select * into customer from public.clientes where id=p_cliente::bigint for share;
 if not found then raise exception 'Cliente no disponible' using errcode='P4000'; end if;
 if role_name='vendedor' then
   if customer.vendedor_id is distinct from uid then raise exception 'Cliente no asignado a tu cuenta' using errcode='42501'; end if;
   select id into seller from public.vendedores where usuario_id=uid and activo order by id limit 1;
   if seller is null then raise exception 'Vendedor inactivo' using errcode='42501'; end if;
 else
   select id into seller from public.vendedores where usuario_id=customer.vendedor_id and activo order by id limit 1;
 end if;
 if p_observaciones is not null and length(p_observaciones)>1000 then raise exception 'Observación demasiado larga' using errcode='P4000'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Lista de productos inválida' using errcode='P4000'; end if;
 row_count:=jsonb_array_length(p_items);
 if row_count<1 or row_count>100 then raise exception 'Agrega entre 1 y 100 productos' using errcode='P4000'; end if;
 select count(distinct x->>'producto_id') into distinct_count from jsonb_array_elements(p_items) x;
 if distinct_count<>row_count then raise exception 'Productos repetidos o inválidos' using errcode='P4000'; end if;
 insert into public.pedidos(cliente_id,vendedor_id,observaciones,client_ref,creado_por,cliente_nombre)
 values(customer.id,seller,nullif(btrim(p_observaciones),''),p_ref,uid,customer.nombre_negocio) returning id into order_id;
 -- Consistent product lock order avoids deadlocks with delivery.
 for item in select x from jsonb_array_elements(p_items) x order by x->>'producto_id' loop
   if coalesce(item->>'producto_id','') !~ '^[0-9]{1,18}$'
     or coalesce(item->>'cantidad','') !~ '^[0-9]{1,9}(\.[0-9]{1,3})?$'
     or coalesce(item->>'precio_esperado','') !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then
     raise exception 'Producto, cantidad o precio inválido' using errcode='P4000';
   end if;
   product_id:=(item->>'producto_id')::bigint;
   qty:=(item->>'cantidad')::numeric;
   expected:=(item->>'precio_esperado')::numeric;
   if qty<=0 or qty>1000000 then raise exception 'Cantidad inválida' using errcode='P4000'; end if;
   select * into product from public.productos where id=product_id for share;
   if not found or not product.activo then raise exception 'Producto no disponible' using errcode='P4000'; end if;
   price:=round(product.precio_venta,2);
   if price<>expected then raise exception 'El precio de un producto cambió. Actualiza el catálogo.' using errcode='P4092'; end if;
   if product.stock<qty then raise exception 'Stock insuficiente para %',product.nombre using errcode='P4091'; end if;
   insert into public.detalle_pedidos(pedido_id,producto_id,cantidad,precio_unitario,producto_nombre,producto_unidad,costo_unitario)
    values(order_id,product.id,qty,price,product.nombre,product.unidad,product.precio_compra);
   amount:=amount+round(qty*price,2);
 end loop;
 if amount>1000000000000 then raise exception 'Total fuera de rango' using errcode='P4000'; end if;
 update public.pedidos set total=amount where id=order_id;
 return jsonb_build_object('id',order_id::text,'total',amount,'repetido',false);
end $$;
revoke all on function olimpo_private.crear_pedido(text,jsonb,text,uuid) from public,anon;
grant execute on function olimpo_private.crear_pedido(text,jsonb,text,uuid) to authenticated;
create or replace function public.olimpo_crear_pedido(p_cliente text,p_items jsonb,p_observaciones text,p_ref uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select olimpo_private.crear_pedido(p_cliente,p_items,p_observaciones,p_ref);
$$;
revoke all on function public.olimpo_crear_pedido(text,jsonb,text,uuid) from public,anon;
grant execute on function public.olimpo_crear_pedido(text,jsonb,text,uuid) to authenticated;

create or replace function olimpo_private.cambiar_estado_pedido(p_id text,p_revision text,p_estado text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 uid uuid := auth.uid(); ord public.pedidos%rowtype; detail record;
 available numeric; product_id bigint;
begin
 if uid is null or not exists(select 1 from public.perfiles where id=uid and rol='administrador' and activo) then
   raise exception 'Solo un administrador puede cambiar el estado' using errcode='42501';
 end if;
 if coalesce(p_id,'') !~ '^[0-9]{1,18}$' or coalesce(p_revision,'') !~ '^[0-9]{1,18}$' or p_estado not in ('confirmado','entregado','cancelado') or p_estado is null then
   raise exception 'Estado o pedido inválido' using errcode='P4000';
 end if;
 select * into ord from public.pedidos where id=p_id::bigint for update;
 if not found then raise exception 'Pedido no disponible' using errcode='P4000'; end if;
 -- Identical retry is safe; delivery never subtracts stock twice.
 if ord.estado=p_estado then return jsonb_build_object('id',ord.id::text,'estado',ord.estado,'revision',ord.revision::text); end if;
 if ord.revision<>p_revision::bigint then raise exception 'El pedido cambió. Actualiza la lista.' using errcode='P4090'; end if;
 if not ((ord.estado='pendiente' and p_estado in ('confirmado','cancelado')) or (ord.estado='confirmado' and p_estado in ('entregado','cancelado'))) then
   raise exception 'Cambio de estado no permitido' using errcode='P4000';
 end if;
 if p_estado='entregado' then
   if not exists(select 1 from public.detalle_pedidos where pedido_id=ord.id) then raise exception 'Pedido sin productos' using errcode='P4000'; end if;
   for detail in select d.producto_id,sum(d.cantidad) as qty from public.detalle_pedidos d where pedido_id=ord.id group by d.producto_id order by d.producto_id::text loop
     product_id:=detail.producto_id;
     select stock into available from public.productos where id=product_id for update;
     if not found or available<detail.qty then raise exception 'Stock insuficiente para completar la entrega' using errcode='P4091'; end if;
     update public.productos set stock=stock-detail.qty where id=product_id;
   end loop;
 end if;
 update public.pedidos set estado=p_estado,revision=revision+1,updated_at=clock_timestamp() where id=ord.id returning * into ord;
 return jsonb_build_object('id',ord.id::text,'estado',ord.estado,'revision',ord.revision::text);
end $$;
revoke all on function olimpo_private.cambiar_estado_pedido(text,text,text) from public,anon;
grant execute on function olimpo_private.cambiar_estado_pedido(text,text,text) to authenticated;
create or replace function public.olimpo_estado_pedido(p_id text,p_revision text,p_estado text)
returns jsonb language sql security invoker set search_path='' as $$
 select olimpo_private.cambiar_estado_pedido(p_id,p_revision,p_estado);
$$;
revoke all on function public.olimpo_estado_pedido(text,text,text) from public,anon;
grant execute on function public.olimpo_estado_pedido(text,text,text) to authenticated;
