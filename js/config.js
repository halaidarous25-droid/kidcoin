// ═══════════════════════════════════════════════════════════════
//  KidCoins — Supabase configuration  (LIVE — project: kidcoins-family-bank)
//  Organization: KidCoin · Region: eu-west-2 (London)
//  The anon/publishable key is SAFE to expose publicly — Row Level
//  Security protects all data. NEVER put the service_role key here.
// ═══════════════════════════════════════════════════════════════

window.KIDCOINS_CONFIG = {
  SUPABASE_URL:      'https://ecuqkmvhrkulebmwmwan.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_72r3ca88Zh9sE1WIGpJOcA_pcSSwqj9',

  // Where the app lives (used for email-confirmation redirect)
  APP_URL: window.location.origin + window.location.pathname.replace(/[^/]*$/, '') + 'dashboard.html'
};
