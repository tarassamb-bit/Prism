// One Supabase client per page: separate clients sharing a session race each other when they refresh it.
// The publishable key belongs in browser code. Row level security limits reads to the signed-in
// user's own rows; service-role keys never ship here.
window.prismDb = (() => {
  try {
    return window.supabase.createClient(
      'https://isdplhahgggundbohmlr.supabase.co',
      'sb_publishable_ATTcp2-mrca0swMStHHdYQ_Le851b8l',
    );
  } catch {
    return null;
  }
})();
