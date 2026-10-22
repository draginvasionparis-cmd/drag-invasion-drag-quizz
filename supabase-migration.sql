begin;
alter table public.games add column if not exists question_started_at timestamptz;
alter table public.games add column if not exists revealed boolean not null default false;
-- Repair the mismatch between the existing positive-position constraint and the original RPC.
do $fix$ declare d text; begin select pg_get_functiondef('public.save_quiz(text,integer,jsonb)'::regprocedure) into d; d:=replace(d,'v_position integer := 0','v_position integer := 1'); execute d; end $fix$;
create or replace function public.start_game(p_game_id uuid) returns boolean language plpgsql security definer set search_path='' as $f$
declare g public.games; begin select * into g from public.games where id=p_game_id and created_by=auth.uid() for update;
if not found or g.status<>'waiting' then raise exception 'Partie introuvable ou déjà démarrée.'; end if;
if not exists(select 1 from public.questions where quiz_id=g.quiz_id) then raise exception 'Le quiz est vide.'; end if;
update public.games set status='playing',current_question=(select min(position) from public.questions where quiz_id=g.quiz_id),question_started_at=clock_timestamp(),revealed=false where id=g.id; return true; end $f$;
create or replace function public.royale_control(p_game_id uuid,p_action text,p_expected_question integer,p_expected_revealed boolean) returns boolean language plpgsql security definer set search_path='' as $f$
declare g public.games; n integer; begin select * into g from public.games where id=p_game_id and created_by=auth.uid() for update;
if not found then raise exception 'Accès animateur refusé.'; end if;
if g.status<>'playing' or g.current_question is distinct from p_expected_question or g.revealed is distinct from p_expected_revealed then raise exception 'La partie a changé. Actualise son état.'; end if;
if p_action='reveal' then update public.games set revealed=true where id=g.id;
elsif p_action='next' then if not g.revealed then raise exception 'Révèle la réponse avant de continuer.'; end if;
select min(position) into n from public.questions where quiz_id=g.quiz_id and position>g.current_question;
if n is null then update public.games set status='finished' where id=g.id;
else update public.games set current_question=n,revealed=false,question_started_at=clock_timestamp() where id=g.id; end if;
else raise exception 'Action invalide.'; end if; return true; end $f$;
create or replace function public.royale_state(p_join_code text,p_player_id uuid default null,p_session_token text default null) returns jsonb language plpgsql security definer set search_path='' as $f$
declare g public.games; q public.questions; qt public.quizzes; me public.players; question jsonb; own boolean; begin
select * into g from public.games where join_code=upper(trim(p_join_code)); if not found then raise exception 'Partie introuvable.'; end if;
select * into qt from public.quizzes where id=g.quiz_id; own:=coalesce(g.created_by=auth.uid(),false);
if p_player_id is not null then select * into me from public.players where id=p_player_id and game_id=g.id and session_token_hash=encode(extensions.digest(coalesce(p_session_token,''),'sha256'),'hex'); if not found then raise exception 'Session joueur invalide.'; end if; end if;
if g.status<>'waiting' then select * into q from public.questions where quiz_id=g.quiz_id and position=g.current_question;
question:=jsonb_build_object('id',q.id,'position',q.position,'text',q.question_text,'options',q.options,'image',q.image_url,'audio',q.audio_url);
if g.revealed or own then question:=question||jsonb_build_object('correct',q.correct_option); end if; end if;
return jsonb_build_object('id',g.id,'code',g.join_code,'title',qt.title,'status',g.status,'current',g.current_question,'total',(select count(*) from public.questions where quiz_id=g.quiz_id),'revealed',g.revealed,'server_time',clock_timestamp(),'started_at',g.question_started_at,'duration',qt.question_time,'question',question,'is_host',own,'players',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.nickname,'score',p.score) order by p.score desc,p.joined_at,p.id) from public.players p where p.game_id=g.id),'[]'::jsonb),'answered',(select count(*) from public.answers a where a.game_id=g.id and a.question_id=q.id),'my_answer',(select selected_option from public.answers a where a.player_id=me.id and a.question_id=q.id),'my_score',me.score); end $f$;
create or replace function public.royale_answer(p_game_id uuid,p_player_id uuid,p_session_token text,p_question_id uuid,p_selected_option integer) returns jsonb language plpgsql security definer set search_path='' as $f$
declare g public.games; q public.questions; dur integer; existing integer; begin
select * into g from public.games where id=p_game_id for update;
if not found then raise exception 'Partie introuvable.'; end if;
if not exists(select 1 from public.players where id=p_player_id and game_id=g.id and session_token_hash=encode(extensions.digest(coalesce(p_session_token,''),'sha256'),'hex')) then raise exception 'Session joueur invalide.'; end if;
if p_selected_option is null or p_selected_option<0 or p_selected_option>3 then raise exception 'Réponse invalide.'; end if;
select selected_option into existing from public.answers where player_id=p_player_id and question_id=p_question_id;
if found then return jsonb_build_object('accepted',true,'selected',existing); end if;
select * into q from public.questions where id=p_question_id and quiz_id=g.quiz_id and position=g.current_question;
if not found or g.status<>'playing' or g.revealed or g.question_started_at is null then raise exception 'Question fermée.'; end if;
select question_time into dur from public.quizzes where id=g.quiz_id;
if dur>0 and clock_timestamp()>=g.question_started_at+make_interval(secs=>dur) then raise exception 'Temps écoulé.'; end if;
insert into public.answers(game_id,player_id,question_id,selected_option,response_time_ms) values(g.id,p_player_id,q.id,p_selected_option,greatest(0,(extract(epoch from (clock_timestamp()-g.question_started_at))*1000)::integer));
update public.players set score=score+case when p_selected_option=q.correct_option then 100 else 0 end where id=p_player_id;
return jsonb_build_object('accepted',true,'selected',p_selected_option); end $f$;
-- Preserve player identity on reconnect and reject late joins atomically with start.
create or replace function public.join_game(p_join_code text,p_nickname text) returns table(player_id uuid,game_id uuid,nickname text,session_token text) language plpgsql security definer set search_path='' as $f$
declare g public.games; pid uuid; tok text; begin
if p_nickname is null or length(trim(p_nickname)) not between 1 and 20 then raise exception 'Le pseudo doit contenir entre 1 et 20 caractères.'; end if;
select * into g from public.games where public.games.join_code=upper(trim(p_join_code)) for update;
if not found or g.status<>'waiting' then raise exception 'Partie introuvable ou déjà commencée.'; end if;
if (select count(*) from public.players p where p.game_id=g.id)>=500 then raise exception 'Partie complète.'; end if;
if exists(select 1 from public.players p where p.game_id=g.id and lower(p.nickname)=lower(trim(p_nickname))) then raise exception 'Ce pseudo est déjà utilisé.'; end if;
tok:=encode(extensions.gen_random_bytes(32),'hex');
insert into public.players(game_id,nickname,session_token_hash) values(g.id,trim(p_nickname),encode(extensions.digest(tok,'sha256'),'hex')) returning id into pid;
return query select pid,g.id,trim(p_nickname),tok; end $f$;
revoke all on function public.royale_control(uuid,text,integer,boolean) from public,anon;
grant execute on function public.royale_control(uuid,text,integer,boolean) to authenticated;
revoke all on function public.royale_state(text,uuid,text) from public;
grant execute on function public.royale_state(text,uuid,text) to anon,authenticated;
revoke all on function public.royale_answer(uuid,uuid,text,uuid,integer) from public;
grant execute on function public.royale_answer(uuid,uuid,text,uuid,integer) to anon,authenticated;
notify pgrst,'reload schema';
commit;