// ═══════════════════════════════════════════════════════════════
//  KidCoins API layer — a thin, professional wrapper over Supabase.
//  Requires:  config.js  +  @supabase/supabase-js v2 (loaded via CDN).
//  Exposes a single global:  window.KC
// ═══════════════════════════════════════════════════════════════
(function () {
  const cfg = window.KIDCOINS_CONFIG;
  if (!cfg || cfg.SUPABASE_URL.includes('YOUR-PROJECT')) {
    console.warn('[KidCoins] Supabase not configured yet — edit js/config.js');
  }

  // supabase global comes from the CDN UMD build
  const client = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  // Local session cache for an independent-child login (children have no auth row)
  const CHILD_KEY = 'kc_child_session';

  const KC = {
    client,

    // ─────────────────────────────────────────────────────────
    //  AUTH — PARENTS (Supabase email/password)
    // ─────────────────────────────────────────────────────────
    async signUp({ email, password, fullName, familyName, locale = 'ar' }) {
      const { data, error } = await client.auth.signUp({
        email, password,
        options: {
          emailRedirectTo: cfg.APP_URL,
          data: { full_name: fullName, family_name: familyName, locale }
        }
      });
      if (error) throw error;
      return data;                      // if email-confirm ON, session is null until confirmed
    },

    async signIn({ email, password }) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
      return data;
    },

    async signOut() {
      localStorage.removeItem(CHILD_KEY);
      await client.auth.signOut();
    },

    async resetPassword(email) {
      const { error } = await client.auth.resetPasswordForEmail(email, {
        redirectTo: cfg.APP_URL
      });
      if (error) throw error;
    },

    async getSession() {
      const { data } = await client.auth.getSession();
      return data.session;
    },

    async getUser() {
      const { data } = await client.auth.getUser();
      return data.user;
    },

    onAuthChange(cb) {
      return client.auth.onAuthStateChange((_e, session) => cb(session));
    },

    // ─────────────────────────────────────────────────────────
    //  AUTH — CHILDREN (independent login via RPC)
    // ─────────────────────────────────────────────────────────
    async childLogin({ familyCode, username, pin }) {
      const { data, error } = await client.rpc('child_login', {
        p_family_code: familyCode, p_username: username, p_pin: pin
      });
      if (error) throw error;
      const child = Array.isArray(data) ? data[0] : data;
      if (!child) throw new Error('child not found');
      localStorage.setItem(CHILD_KEY, JSON.stringify(child));
      return child;
    },
    getChildSession() {
      try { return JSON.parse(localStorage.getItem(CHILD_KEY) || 'null'); }
      catch { return null; }
    },
    childLogout() { localStorage.removeItem(CHILD_KEY); },

    // ─────────────────────────────────────────────────────────
    //  PROFILE & FAMILY
    // ─────────────────────────────────────────────────────────
    async myProfile() {
      const { data, error } = await client.from('profiles').select('*').single();
      if (error) throw error; return data;
    },
    async myFamilies() {
      const { data, error } = await client
        .from('families')
        .select('*, family_members!inner(role)')
        .order('created_at');
      if (error) throw error; return data;
    },
    async updateFamily(id, patch) {
      const { data, error } = await client.from('families').update(patch).eq('id', id).select().single();
      if (error) throw error; return data;
    },

    // ─────────────────────────────────────────────────────────
    //  CHILDREN
    // ─────────────────────────────────────────────────────────
    async listChildren(familyId) {
      const { data, error } = await client.from('children')
        .select('id,family_id,name,username,avatar,color,balance,level,active')
        .eq('family_id', familyId).eq('active', true).order('created_at');
      if (error) throw error; return data;
    },
    async createChild({ familyId, name, username, pin, avatar, color }) {
      const { data, error } = await client.rpc('create_child', {
        p_family_id: familyId, p_name: name, p_username: username,
        p_pin: pin, p_avatar: avatar || '🧒', p_color: color || '#00C4B6'
      });
      if (error) throw error; return data;
    },
    async setChildPin(childId, pin) {
      const { error } = await client.rpc('set_child_pin', { p_child_id: childId, p_pin: pin });
      if (error) throw error;
    },
    async removeChild(childId) {
      const { error } = await client.from('children').update({ active: false }).eq('id', childId);
      if (error) throw error;
    },

    // ─────────────────────────────────────────────────────────
    //  TRANSACTIONS
    // ─────────────────────────────────────────────────────────
    async addTransaction({ familyId, childId, type, amount, description, status = 'approved' }) {
      const user = await this.getUser();
      const { data, error } = await client.from('transactions').insert({
        family_id: familyId, child_id: childId, type, amount,
        description, status, created_by: user ? user.id : null
      }).select().single();
      if (error) throw error; return data;
    },
    async listTransactions(familyId, { childId = null, limit = 50 } = {}) {
      let q = client.from('transactions').select('*')
        .eq('family_id', familyId).order('created_at', { ascending: false }).limit(limit);
      if (childId) q = q.eq('child_id', childId);
      const { data, error } = await q;
      if (error) throw error; return data;
    },
    async decideTransaction(txId, approve) {
      const user = await this.getUser();
      const { error } = await client.from('transactions')
        .update({ status: approve ? 'approved' : 'rejected', approved_by: user ? user.id : null })
        .eq('id', txId);
      if (error) throw error;
    },

    // ─────────────────────────────────────────────────────────
    //  TASKS
    // ─────────────────────────────────────────────────────────
    async listTasks(familyId, childId = null) {
      let q = client.from('tasks').select('*').eq('family_id', familyId).order('created_at', { ascending: false });
      if (childId) q = q.eq('child_id', childId);
      const { data, error } = await q; if (error) throw error; return data;
    },
    async createTask(t) {
      const user = await this.getUser();
      const { data, error } = await client.from('tasks')
        .insert({ ...t, created_by: user ? user.id : null }).select().single();
      if (error) throw error; return data;
    },
    async updateTaskStatus(taskId, status) {
      const { error } = await client.from('tasks').update({ status }).eq('id', taskId);
      if (error) throw error;
    },

    // ─────────────────────────────────────────────────────────
    //  SAVINGS GOALS
    // ─────────────────────────────────────────────────────────
    async listGoals(childId) {
      const { data, error } = await client.from('savings_goals').select('*')
        .eq('child_id', childId).order('created_at'); if (error) throw error; return data;
    },
    async listFamilyGoals(familyId) {
      const { data, error } = await client.from('savings_goals').select('*')
        .eq('family_id', familyId).order('created_at'); if (error) throw error; return data;
    },
    async createGoal(g) {
      const { data, error } = await client.from('savings_goals').insert(g).select().single();
      if (error) throw error; return data;
    },
    async depositGoal(goalId, amount) {
      const { data, error } = await client.rpc('goal_deposit', { p_goal_id: goalId, p_amount: amount });
      if (error) throw error; return data;
    },

    // ─────────────────────────────────────────────────────────
    //  STORE + PURCHASES
    // ─────────────────────────────────────────────────────────
    async listStore(familyId) {
      const { data, error } = await client.from('store_items').select('*')
        .eq('family_id', familyId).eq('active', true).order('cost'); if (error) throw error; return data;
    },
    async requestPurchase({ familyId, childId, itemId, title, cost }) {
      const { data, error } = await client.from('purchases')
        .insert({ family_id: familyId, child_id: childId, item_id: itemId, title, cost })
        .select().single();
      if (error) throw error; return data;
    },
    async listPurchases(familyId, status = 'pending') {
      const { data, error } = await client.from('purchases').select('*')
        .eq('family_id', familyId).eq('status', status).order('created_at');
      if (error) throw error; return data;
    },
    async createStoreItem({ familyId, title, icon, cost }) {
      const { data, error } = await client.from('store_items')
        .insert({ family_id: familyId, title, icon: icon || '🎁', cost }).select().single();
      if (error) throw error; return data;
    },
    async removeStoreItem(itemId) {
      const { error } = await client.from('store_items').update({ active: false }).eq('id', itemId);
      if (error) throw error;
    },
    // Approve/reject a purchase. On approve, also post a debiting transaction so the child balance drops.
    async decidePurchase(purchase, approve) {
      if (approve) {
        await this.addTransaction({
          familyId: purchase.family_id, childId: purchase.child_id,
          type: 'purchase', amount: -Math.abs(purchase.cost),
          description: '🛍️ ' + purchase.title, status: 'approved'
        });
      }
      const { error } = await client.from('purchases')
        .update({ status: approve ? 'approved' : 'rejected', decided_at: new Date().toISOString() })
        .eq('id', purchase.id);
      if (error) throw error;
    },

    // ─────────────────────────────────────────────────────────
    //  CHILD-FACING (independent child session, via SECURITY DEFINER RPCs)
    // ─────────────────────────────────────────────────────────
    async childStore(familyId) {
      const { data, error } = await client.rpc('child_store', { p_family_id: familyId });
      if (error) throw error; return data || [];
    },
    async childGoals(childId) {
      const { data, error } = await client.rpc('child_goals', { p_child_id: childId });
      if (error) throw error; return data || [];
    },
    async childTasks(childId) {
      const { data, error } = await client.rpc('child_tasks', { p_child_id: childId });
      if (error) throw error; return data || [];
    },
    async childTransactions(childId, limit = 20) {
      const { data, error } = await client.rpc('child_transactions', { p_child_id: childId, p_limit: limit });
      if (error) throw error; return data || [];
    },
    async childRequestPurchase(familyId, childId, itemId) {
      const { data, error } = await client.rpc('child_request_purchase',
        { p_family_id: familyId, p_child_id: childId, p_item_id: itemId });
      if (error) throw error; return data;
    },
    async childRefresh(childId) {
      const { data, error } = await client.rpc('child_refresh', { p_child_id: childId });
      if (error) throw error; return Array.isArray(data) ? data[0] : data;
    },

    // ─────────────────────────────────────────────────────────
    //  REALTIME  (subscribe to a family's data changes)
    // ─────────────────────────────────────────────────────────
    subscribeFamily(familyId, onChange) {
      return client.channel('family:' + familyId)
        .on('postgres_changes',
            { event: '*', schema: 'public', filter: `family_id=eq.${familyId}` },
            payload => onChange(payload))
        .subscribe();
    }
  };

  window.KC = KC;
})();
