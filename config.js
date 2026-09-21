/* The Green Warden — Supabase connection
   Both index.html and dashboard.html read this file.
   These two values are safe to ship in the browser: row-level security and the
   SECURITY DEFINER functions in supabase-setup.sql are what actually protect the data.
   Never put your service_role / secret key in here. */
window.WARDEN_CONFIG = {
  SUPABASE_URL: 'https://toxgbqhmpjnsknyahxyc.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_2WkFLloWjwM8NRt9o7ZvaQ_osAXZYRB'
};
