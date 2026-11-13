-- Olimpo Ventas: cobros manuales de pedidos entregados, abonos y revisión del administrador.
-- Depende de la preparación de Pedidos. No se realizan operaciones bancarias.

alter table public.pagos
 add column if not exists client_ref uuid not null default gen_random_uuid(),
 add column if not exists creado_por uuid references auth.users(id),
 add column if not exists revision bigint not null default 1,
 add column if not exists updated_at timestamptz not null default now();
create unique index if not exists pagos_client_ref_uidx on public.pagos(client_ref);
create index if not exists pagos_pedido_estado_idx on public.pagos(pedido_id,estado);
alter table public.pedidos add column if not exists entregado_at timestamptz;
update public.pedidos set entregado_at=updated_at where estado='entregado' and entregado_at is null;
revoke all on public.pagos from anon;
revoke insert,update,delete,truncate,references,trigger on public.pagos from authenticated;
grant select on public.pagos to authenticated;
alter table public.pagos enable row level security;
drop policy if exists "Olimpo lee pagos de pedidos accesibles" on public.pagos;
create policy "Olimpo lee pagos de pedidos accesibles" on public.pagos for select to authenticated
 using (exists(select 1 from public.pedidos p where p.id=pedido_id));

create or replace function olimpo_private.registrar_pago(p_pedido text,p_monto text,p_metodo text,p_referencia text,p_ref uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); role_name text; ord public.pedidos%rowtype; previous public.pagos%rowtype;
 paid numeric; pending numeric; amount numeric; payment_id bigint; payment_state text;
begin
 select rol into role_name from public.perfiles where id=uid and activo;
 if uid is null or role_name is null or role_name not in ('administrador','vendedor') then raise exception 'Cuenta no autorizada' using errcode='42501'; end if;
 if p_ref is null then raise exception 'Referencia requerida' using errcode='P4000'; end if;
 perform pg_advisory_xact_lock(hashtextextended('olimpo-pago:'||p_ref::text,0));
 select * into previous from public.pagos where client_ref=p_ref;
 if found then
   if previous.creado_por is distinct from uid then raise exception 'Referencia no autorizada' using errcode='42501'; end if;
   return jsonb_build_object('id',previous.id::text,'estado',previous.estado,'monto',previous.monto,'repetido',true);
 end if;
 if coalesce(p_pedido,'') !~ '^[0-9]{1,18}$' or coalesce(p_monto,'') !~ '^[0-9]{1,13}(\.[0-9]{1,2})?$' or p_metodo not in ('efectivo','transferencia') or p_metodo is null then
   raise exception 'Datos de pago inválidos' using errcode='P4000';
 end if;
 amount:=p_monto::numeric;
 if amount<=0 or amount>1000000000000 or length(coalesce(p_referencia,''))>200 then raise exception 'Monto o referencia inválidos' using errcode='P4000'; end if;
 if p_metodo='transferencia' and nullif(btrim(p_referencia),'') is null then raise exception 'Referencia bancaria requerida' using errcode='P4000'; end if;
 select * into ord from public.pedidos where id=p_pedido::bigint for update;
 if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
 if role_name='vendedor' and not exists(select 1 from public.vendedores v where v.id=ord.vendedor_id and v.usuario_id=uid and v.activo) then
   raise exception 'Pedido no asignado al vendedor' using errcode='42501';
 end if;
 if ord.estado<>'entregado' then raise exception 'Solo se cobran pedidos entregados' using errcode='P4000'; end if;
 select coalesce(sum(monto) filter(where estado='verificado'),0),coalesce(sum(monto) filter(where estado='pendiente'),0)
 into paid,pending from public.pagos where pedido_id=ord.id;
 if amount>ord.total-paid-pending then raise exception 'El monto supera el saldo disponible. Actualiza la lista.' using errcode='P4093'; end if;
 payment_state:=case when role_name='administrador' and p_metodo='efectivo' then 'verificado' else 'pendiente' end;
 insert into public.pagos(pedido_id,vendedor_id,monto,metodo,referencia,estado,creado_por,client_ref)
 values(ord.id,ord.vendedor_id,amount,p_metodo,nullif(btrim(p_referencia),''),payment_state,uid,p_ref) returning id into payment_id;
 if payment_state='verificado' then paid:=paid+amount; end if;
 update public.pedidos set estado_pago=case when paid>=total then 'pagado' when paid>0 then 'parcial' else 'pendiente' end,
 revision=revision+1,updated_at=clock_timestamp() where id=ord.id;
 return jsonb_build_object('id',payment_id::text,'estado',payment_state,'monto',amount,'repetido',false);
end $$;
revoke all on function olimpo_private.registrar_pago(text,text,text,text,uuid) from public,anon;
grant execute on function olimpo_private.registrar_pago(text,text,text,text,uuid) to authenticated;
create or replace function public.olimpo_registrar_pago(p_pedido text,p_monto text,p_metodo text,p_referencia text,p_ref uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select olimpo_private.registrar_pago(p_pedido,p_monto,p_metodo,p_referencia,p_ref);
$$;
revoke all on function public.olimpo_registrar_pago(text,text,text,text,uuid) from public,anon;
grant execute on function public.olimpo_registrar_pago(text,text,text,text,uuid) to authenticated;

create or replace function olimpo_private.revisar_pago(p_id text,p_revision text,p_estado text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); payment public.pagos%rowtype; ord public.pedidos%rowtype; paid numeric;
begin
 if uid is null or not exists(select 1 from public.perfiles where id=uid and rol='administrador' and activo) then raise exception 'Solo el administrador verifica pagos' using errcode='42501'; end if;
 if coalesce(p_id,'') !~ '^[0-9]{1,18}$' or coalesce(p_revision,'') !~ '^[0-9]{1,18}$' or p_estado not in ('verificado','rechazado') or p_estado is null then raise exception 'Revisión inválida' using errcode='P4000'; end if;
 select * into payment from public.pagos where id=p_id::bigint;
 if not found then raise exception 'Pago no disponible' using errcode='P4000'; end if;
 select * into ord from public.pedidos where id=payment.pedido_id for update;
 select * into payment from public.pagos where id=p_id::bigint for update;
 if payment.estado=p_estado then return jsonb_build_object('id',payment.id::text,'estado',payment.estado); end if;
 if payment.revision<>p_revision::bigint then raise exception 'El pago cambió. Actualiza la lista.' using errcode='P4090'; end if;
 if payment.estado<>'pendiente' then raise exception 'Este pago ya fue revisado' using errcode='P4000'; end if;
 if ord.estado<>'entregado' then raise exception 'El pedido no está entregado' using errcode='P4000'; end if;
 select coalesce(sum(monto),0) into paid from public.pagos where pedido_id=ord.id and estado='verificado';
 if p_estado='verificado' and paid+payment.monto>ord.total then raise exception 'El pago excede el saldo' using errcode='P4093'; end if;
 update public.pagos set estado=p_estado,revision=revision+1,updated_at=clock_timestamp() where id=payment.id;
 if p_estado='verificado' then paid:=paid+payment.monto; end if;
 update public.pedidos set estado_pago=case when paid>=total then 'pagado' when paid>0 then 'parcial' else 'pendiente' end,
 revision=revision+1,updated_at=clock_timestamp() where id=ord.id;
 return jsonb_build_object('id',payment.id::text,'estado',p_estado);
end $$;
revoke all on function olimpo_private.revisar_pago(text,text,text) from public,anon;
grant execute on function olimpo_private.revisar_pago(text,text,text) to authenticated;
create or replace function public.olimpo_revisar_pago(p_id text,p_revision text,p_estado text)
returns jsonb language sql security invoker set search_path='' as $$
 select olimpo_private.revisar_pago(p_id,p_revision,p_estado);
$$;
revoke all on function public.olimpo_revisar_pago(text,text,text) from public,anon;
grant execute on function public.olimpo_revisar_pago(text,text,text) to authenticated;

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
 update public.pedidos set estado=p_estado,entregado_at=case when p_estado='entregado' then clock_timestamp() else entregado_at end,estado_pago=case when p_estado='entregado' and total=0 then 'pagado' else estado_pago end,revision=revision+1,updated_at=clock_timestamp() where id=ord.id returning * into ord;
 return jsonb_build_object('id',ord.id::text,'estado',ord.estado,'revision',ord.revision::text);
end $$;