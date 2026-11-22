import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return json({ error: 'server_not_configured' }, 500);
  const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    const body = await req.json();
    const action = String(body.action || '');
    const username = String(body.username || '').trim();
    const password = String(body.password || '');
    if (!/^[A-Za-z0-9_.-]{3,32}$/.test(username) || password.length < 10) return json({ error: 'invalid_credentials_format' }, 400);
    // Internal synthetic address enables Supabase Auth without collecting a member email address.
    const email = `${username.toLowerCase()}@members.riviera.invalid`;
    if (action === 'register') {
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { username } });
      if (error || !data.user) return json({ error: error?.message || 'registration_failed' }, 400);
      const { error: profileError } = await admin.from('profiles').insert({ id: data.user.id, username, status: 'pending', is_superadmin: false, rank: null });
      if (profileError) { await admin.auth.admin.deleteUser(data.user.id); return json({ error: profileError.message }, 400); }
      return json({ status: 'pending' }, 201);
    }
    if (action === 'login') {
      const client = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error || !data.user || !data.session) return json({ error: 'invalid_login' }, 401);
      const { data: profile, error: profileError } = await admin.from('profiles').select('status,username').eq('id', data.user.id).maybeSingle();
      if (profileError || !profile || profile.status !== 'approved') { await client.auth.signOut(); return json({ error: profile?.status === 'rejected' ? 'registration_rejected' : 'approval_pending' }, 403); }
      return json({ access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_at: data.session.expires_at, user: { id: data.user.id, username: profile.username } });
    }
    if (action === 'setup_admin') {
      const setupToken = String(body.setup_token || '');
      if (!Deno.env.get('RIVIERA_SETUP_TOKEN') || setupToken !== Deno.env.get('RIVIERA_SETUP_TOKEN')) return json({ error: 'invalid_setup_token' }, 403);
      const { data: existing } = await admin.from('profiles').select('id').eq('username', 'admin').maybeSingle();
      if (existing) return json({ error: 'admin_already_exists' }, 409);
      const { data, error } = await admin.auth.admin.createUser({ email: 'admin@members.riviera.invalid', password, email_confirm: true, user_metadata: { username: 'admin' } });
      if (error || !data.user) return json({ error: error?.message || 'admin_creation_failed' }, 400);
      const all = ['dashboard','members_view','members_manage','registrations_approve','leader_view','leader_book','leader_manage','leader_permissions','general_view','general_book','general_manage','general_permissions','attendance_view','attendance_add','attendance_edit','quotas_view','permissions_grant','admin_manage'];
      const { error: profileError } = await admin.from('profiles').insert({ id: data.user.id, username: 'admin', status: 'approved', is_superadmin: true, rank: null, permissions: all, delegable_permissions: all });
      if (profileError) { await admin.auth.admin.deleteUser(data.user.id); return json({ error: profileError.message }, 400); }
      return json({ status: 'admin_created' }, 201);
    }
    return json({ error: 'unknown_action' }, 400);
  } catch { return json({ error: 'invalid_request' }, 400); }
});
