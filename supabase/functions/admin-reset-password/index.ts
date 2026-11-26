import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Metode permintaan tidak valid." }),
      {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
    return new Response(
      JSON.stringify({ error: "Konfigurasi server tidak lengkap." }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(
      JSON.stringify({ error: "Sesi login tidak ditemukan." }),
      {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Data permintaan tidak valid." }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const username =
    typeof body.username === "string" ? body.username.trim() : "";
  const password =
    typeof body.password === "string" ? body.password : "";

  if (!username) {
    return new Response(
      JSON.stringify({ error: "Username wajib dipilih." }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  if (password.length < 8 || password.length > 256) {
    return new Response(
      JSON.stringify({
        error: "Password baru harus memiliki 8 sampai 256 karakter.",
      }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userError } =
    await userClient.auth.getUser();

  if (userError || !user) {
    return new Response(
      JSON.stringify({ error: "Sesi login tidak valid." }),
      {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const { data: adminProfile, error: adminError } =
    await userClient
      .from("profiles")
      .select("role, is_active")
      .eq("id", user.id)
      .maybeSingle();

  if (
    adminError ||
    adminProfile?.role !== "admin" ||
    adminProfile?.is_active !== true
  ) {
    return new Response(
      JSON.stringify({ error: "Akses hanya untuk Admin." }),
      {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const adminClient = createClient(
    supabaseUrl,
    supabaseServiceKey,
  );

  const { data: targetProfile, error: targetError } =
    await adminClient
      .from("profiles")
      .select("id, role")
      .eq("username", username)
      .maybeSingle();

  if (targetError) {
    return new Response(
      JSON.stringify({ error: "Gagal mencari akun pengguna." }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  if (!targetProfile) {
    return new Response(
      JSON.stringify({ error: "Akun dengan username tersebut tidak ditemukan." }),
      {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  if (!["guru", "parent"].includes(targetProfile.role)) {
    return new Response(
      JSON.stringify({
        error: "Password hanya dapat direset untuk akun Guru atau Orang Tua.",
      }),
      {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const { error: updateError } =
    await adminClient.auth.admin.updateUserById(
      targetProfile.id,
      { password },
    );

  if (updateError) {
    return new Response(
      JSON.stringify({
        error: "Gagal memperbarui password: " + updateError.message,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  return new Response(
    JSON.stringify({ success: true }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
});
