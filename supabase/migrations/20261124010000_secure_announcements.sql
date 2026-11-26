-- 1. Helper untuk memeriksa Parent aktif
CREATE OR REPLACE FUNCTION public.is_active_parent()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = (SELECT auth.uid())
          AND p.role = 'parent'
          AND p.is_active = true
    );
$function$;

REVOKE ALL ON FUNCTION public.is_active_parent() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_active_parent() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_active_parent() TO authenticated;

-- 2. Aktifkan RLS dan batasi hak akses tabel
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.announcements FROM PUBLIC;
REVOKE ALL ON TABLE public.announcements FROM anon;

-- 3. Berikan hak akses dasar kepada pengguna login
-- RLS tetap menjadi pembatas akses setiap role
REVOKE ALL ON TABLE public.announcements FROM authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.announcements TO authenticated;

-- 4. Hapus policy announcements lama agar migration dapat dijalankan ulang
DROP POLICY IF EXISTS admin_read_announcements ON public.announcements;
DROP POLICY IF EXISTS announcements_select_by_role ON public.announcements;
DROP POLICY IF EXISTS announcements_admin_insert ON public.announcements;
DROP POLICY IF EXISTS announcements_admin_update ON public.announcements;
DROP POLICY IF EXISTS announcements_admin_delete ON public.announcements;

-- 5. Admin, Guru, dan Parent membaca pengumuman
CREATE POLICY announcements_select_by_role
ON public.announcements
FOR SELECT
TO authenticated
USING (
    public.is_active_child_development_admin()
    OR (
        public.is_active_child_development_guru()
        AND is_published = true
    )
    OR (
        public.is_active_parent()
        AND is_published = true
    )
);

-- 6. Hanya Admin aktif yang boleh membuat pengumuman
CREATE POLICY announcements_admin_insert
ON public.announcements
FOR INSERT
TO authenticated
WITH CHECK (
    public.is_active_child_development_admin()
);

-- 7. Hanya Admin aktif yang boleh mengedit
CREATE POLICY announcements_admin_update
ON public.announcements
FOR UPDATE
TO authenticated
USING (
    public.is_active_child_development_admin()
)
WITH CHECK (
    public.is_active_child_development_admin()
);

-- 8. Hanya Admin aktif yang boleh menghapus
CREATE POLICY announcements_admin_delete
ON public.announcements
FOR DELETE
TO authenticated
USING (
    public.is_active_child_development_admin()
);
