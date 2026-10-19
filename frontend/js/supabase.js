const SUPABASE_URL = "https://fulnozrxrucvmvhwfipe.supabase.co";

const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ1bG5venJ4cnVjdm12aHdmaXBlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk3NDY4MTQsImV4cCI6MjEwNTMyMjgxNH0.JtKBHVOITH44aLgpCVVAT5APe6HG3gnHG26ZuRMHYko";

window.supabaseClient = supabase.createClient(
  SUPABASE_URL,
  SUPABASE_ANON_KEY
);
