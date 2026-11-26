console.log("SCRIPT PENGUMUMAN MULAI DIJALANKAN");
window.__announcementsDebug = { stage: "script-started" };

function setAnnouncementsDebugStage(stage, error) {
    window.__announcementsDebug = { stage };
    if (stage === "error") {
        window.__announcementsDebug.errorName = error?.name || "Error";
    }
}

window.addEventListener("error", event => {
    setAnnouncementsDebugStage("error", event.error);
});
window.addEventListener("unhandledrejection", event => {
    setAnnouncementsDebugStage("error", event.reason);
});

if (
    !window.supabase ||
    typeof window.supabase.createClient !== "function"
) {
    setAnnouncementsDebugStage("error", new Error("Supabase client unavailable"));
    console.error("[announcements] Supabase JavaScript library unavailable");
    document.getElementById("announcementMessage").textContent =
        "Klien Supabase gagal dimuat. Periksa koneksi internet lalu muat ulang halaman.";
    document.getElementById("announcementList").innerHTML =
        '<tr><td colspan="4" class="empty-row">Daftar pengumuman tidak dapat dimuat.</td></tr>';
    document.getElementById("announcementForm")
        .querySelectorAll("input, textarea, button")
        .forEach(control => {
            control.disabled = true;
        });
    throw new Error("Supabase JavaScript client tidak tersedia.");
}

const SUPABASE_URL = "https://ianbedmbrrmqhbpbbvnr.supabase.co";
const SUPABASE_KEY = "sb_publishable_vgmD7EpEDgzSSHZout_7FQ_civgvMQ8";
let supabaseClient;
try {
    console.info("[announcements] Supabase client initialization started");
    supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    setAnnouncementsDebugStage("client-created");
    console.info("[announcements] Supabase client initialized");
} catch (error) {
    setAnnouncementsDebugStage("error", error);
    console.error("[announcements] Supabase client initialization failed", {
        name: error?.name || "Error"
    });
    document.getElementById("announcementMessage").textContent =
        "Klien Supabase tidak dapat diinisialisasi. Periksa pemuatan library lalu muat ulang halaman.";
    document.getElementById("announcementList").innerHTML =
        '<tr><td colspan="4" class="empty-row">Daftar pengumuman tidak dapat dimuat.</td></tr>';
    document.getElementById("announcementForm")
        .querySelectorAll("input, textarea, button")
        .forEach(control => {
            control.disabled = true;
        });
    throw error;
}

const announcementMessage =
    document.getElementById("announcementMessage");
const announcementForm =
    document.getElementById("announcementForm");
const announcementId =
    document.getElementById("announcementId");
const announcementTitle =
    document.getElementById("announcementTitle");
const announcementContent =
    document.getElementById("announcementContent");
const formTitle =
    document.getElementById("formTitle");
const saveDraftButton =
    document.getElementById("saveDraftButton");
const saveAndPublishButton =
    document.getElementById("saveAndPublishButton");
const cancelEditButton =
    document.getElementById("cancelEditButton");
const announcementList =
    document.getElementById("announcementList");
const announcementCount =
    document.getElementById("announcementCount");

let announcements = [];
let sessionActive = null;


function escapeHTML(text) {
    return String(text ?? "").replace(/[&<>"']/g, character => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#039;"
    })[character]);
}

function formatDateTime(value) {
    if (!value) return "-";

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "-";

    return new Intl.DateTimeFormat("id-ID", {
        day: "numeric",
        month: "short",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit"
    }).format(date);
}

async function signOutAndRedirect() {
    try {
        await awaitPromiseWithTimeout(
            supabaseClient.auth.signOut(),
            "Proses sign-out"
        );
    } catch (error) {
        console.error("[auth] sign-out gagal", {
            name: error?.name || "Error",
            code: error?.code || null
        });
    } finally {
        window.location.replace("login.html");
    }
}

async function checkAdmin() {
    setAnnouncementsDebugStage("check-admin-started");
    console.info("[checkAdmin] pemeriksaan dimulai");
    let stage = "session";

    try {
        console.info("[checkAdmin] memeriksa session Supabase");
        const { data: sessionData, error: sessionError } =
            await awaitPromiseWithTimeout(
                supabaseClient.auth.getSession(),
                "Pemeriksaan sesi"
            );

        console.info("[checkAdmin] hasil pemeriksaan session", {
            hasSession: Boolean(sessionData?.session),
            hasError: Boolean(sessionError)
        });
        if (sessionError) {
            console.error("[checkAdmin] Supabase getSession gagal", {
                code: sessionError.code || null
            });
            showAdminAccessError(
                "Sesi tidak dapat diperiksa. Periksa koneksi lalu muat ulang halaman."
            );
            return false;
        }

        if (!sessionData?.session) {
            console.info("[checkAdmin] session tidak valid; redirect ke login");
            await signOutAndRedirect();
            return false;
        }

        sessionActive = sessionData.session;

        stage = "admin-role";
        console.info("[checkAdmin] memeriksa RPC is_admin()");
        const { data: isAdmin, error: rpcError } =
            await awaitSupabaseQuery(
                supabaseClient.rpc("is_admin"),
                "Pemeriksaan role Admin"
            );

        const safeRpcErrorMessage = rpcError?.message
            ? String(rpcError.message)
                .replace(/https?:\/\/\S+/gi, "[URL disembunyikan]")
                .replace(/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[token disembunyikan]")
                .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/gi, "[ID disembunyikan]")
                .replace(/\b(access[_-]?token|refresh[_-]?token|token|api[_-]?key|apikey|password|authorization)\b\s*[:=]\s*["']?[^,\s"'}`]+/gi, "$1=[disembunyikan]")
                .replace(/\bBearer\s+\S+/gi, "Bearer [disembunyikan]")
            : null;
        console.info("[checkAdmin] diagnostik RPC is_admin()", {
            rpcErrorIsNull: rpcError === null,
            isAdmin: isAdmin === true ? "true" : isAdmin === false ? "false" : "null",
            ...(rpcError ? {
                errorCode: String(rpcError.code || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 40) || null,
                errorMessage: safeRpcErrorMessage
            } : {})
        });

        console.info("[checkAdmin] hasil RPC is_admin()", {
            isAdmin: isAdmin === true,
            hasError: Boolean(rpcError)
        });
        if (rpcError) {
            console.error("[checkAdmin] RPC is_admin() gagal", {
                code: rpcError.code || null
            });
            showAdminAccessError(
                "Role Admin tidak dapat diverifikasi. Periksa koneksi lalu muat ulang halaman."
            );
            return false;
        }

        if (isAdmin !== true) {
            console.info("[checkAdmin] pemeriksaan RPC gagal; redirect ke login");
            await signOutAndRedirect();
            return false;
        }

        stage = "admin-profile";
        console.info("[checkAdmin] memeriksa profil Admin aktif");
        const { data: profile, error: profileError } =
            await awaitSupabaseQuery(
                supabaseClient
                    .from("profiles")
                    .select("role, is_active")
                    .eq("id", sessionActive.user.id)
                    .maybeSingle(),
                "Pemeriksaan profil Admin"
            );

        console.info("[checkAdmin] hasil pemeriksaan profil", {
            profileFound: Boolean(profile),
            role: profile?.role || null,
            isActive: profile?.is_active === true,
            hasError: Boolean(profileError)
        });
        if (profileError) {
            console.error("[checkAdmin] query profil gagal", {
                code: profileError.code || null
            });
            showAdminAccessError(
                "Profil Admin tidak dapat diverifikasi. Periksa koneksi lalu muat ulang halaman."
            );
            return false;
        }

        if (
            !profile ||
            profile.role !== "admin" ||
            profile.is_active !== true
        ) {
            console.info("[checkAdmin] profil bukan Admin aktif; redirect ke login");
            await signOutAndRedirect();
            return false;
        }

        console.info("[checkAdmin] pemeriksaan berhasil");
        setAnnouncementsDebugStage("check-admin-passed");
        return true;
    } catch (error) {
        setAnnouncementsDebugStage("error", error);
        console.error("[checkAdmin] pemeriksaan melempar exception", {
            stage,
            name: error?.name || "Error",
            code: error?.code || null
        });
        const stageMessage = {
            session: "Sesi Supabase tidak dapat diperiksa.",
            "admin-role": "Role Admin tidak dapat diverifikasi.",
            "admin-profile": "Profil Admin tidak dapat diverifikasi."
        }[stage];
        showAdminAccessError(
            `${stageMessage} Periksa koneksi lalu muat ulang halaman.`
        );
        return false;
    }
}

function setMessage(message, success = false) {
    announcementMessage.textContent = message;
    announcementMessage.classList.toggle("success", success);
}

function showAdminAccessError(message) {
    document.body.style.display = "block";
    setMessage(message);
    announcementCount.textContent = "Tidak tersedia";
    announcementList.innerHTML =
        '<tr><td colspan="4" class="empty-row">Daftar tidak dimuat karena akses Admin belum terverifikasi.</td></tr>';
    announcementForm.querySelectorAll("input, textarea, button")
        .forEach(control => {
            control.disabled = true;
        });
}

async function awaitPromiseWithTimeout(promise, action) {
    let timeoutId;

    try {
        return await Promise.race([
            promise,
            new Promise((resolve, reject) => {
                timeoutId = window.setTimeout(
                    () => reject(new Error(`${action} tidak merespons dalam 15 detik.`)),
                    15000
                );
            })
        ]);
    } finally {
        window.clearTimeout(timeoutId);
    }
}

async function awaitSupabaseQuery(query, action) {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(
        () => controller.abort(),
        15000
    );

    try {
        return await query.abortSignal(controller.signal);
    } catch (error) {
        if (controller.signal.aborted) {
            throw new Error(`${action} tidak merespons dalam 15 detik.`);
        }
        throw error;
    } finally {
        window.clearTimeout(timeoutId);
    }
}

function resetForm() {
    announcementId.value = "";
    announcementTitle.value = "";
    announcementContent.value = "";
    formTitle.textContent = "Buat Pengumuman";
    saveDraftButton.textContent = "Simpan sebagai Draft";
    saveAndPublishButton.textContent = "Simpan & Terbitkan";
    cancelEditButton.hidden = true;
    setMessage("");
}

async function loadAnnouncements() {
    console.log("[pengumuman] mulai memuat daftar");
    announcementList.innerHTML =
        '<tr><td colspan="4" class="empty-row">Memuat pengumuman...</td></tr>';

    try {
        const { data, error } = await awaitSupabaseQuery(supabaseClient
            .from("announcements")
            .select(
                "id, title, content, published_at, is_published, created_by, created_at"
            )
            .order("created_at", { ascending: false }), "Pemuatan daftar pengumuman");

        console.log("[pengumuman] hasil pemuatan daftar", {
            rows: data?.length ?? null,
            error
        });

        if (error) throw error;

        announcements = data || [];
        announcementCount.textContent =
            `${announcements.length} pengumuman`;
        renderAnnouncements();
        return null;
    } catch (error) {
        setAnnouncementsDebugStage("error", error);
        console.error("[pengumuman] pemuatan daftar gagal", error);
        announcementList.innerHTML =
            '<tr><td colspan="4" class="empty-row">Pengumuman belum dapat dimuat.</td></tr>';
        announcementCount.textContent = "Gagal memuat";
        setMessage(
            "Gagal memuat pengumuman: " +
            (error?.message || String(error))
        );
        return error;
    }
}

function renderAnnouncements() {
    if (announcements.length === 0) {
        announcementList.innerHTML =
            '<tr><td colspan="4" class="empty-row">Belum ada pengumuman.</td></tr>';
        return;
    }

    announcementList.innerHTML = announcements.map(item => {
        const published = item.is_published === true;
        const preview = item.content
            ? String(item.content).replace(/\s+/g, " ").trim()
            : "";

        return `
            <tr>
                <td>
                    <span class="announcement-title">${escapeHTML(item.title || "Tanpa judul")}</span>
                    <span class="announcement-preview">${escapeHTML(preview || "-")}</span>
                </td>
                <td>
                    <span class="status-badge ${published ? "published" : ""}">
                        ${published ? "Diterbitkan" : "Draft"}
                    </span>
                </td>
                <td class="date-cell">
                    Dibuat: ${escapeHTML(formatDateTime(item.created_at))}<br>
                    Diterbitkan: ${escapeHTML(formatDateTime(item.published_at))}
                </td>
                <td>
                    <div class="row-actions">
                        <button type="button" data-edit-id="${escapeHTML(item.id)}">Edit</button>
                        ${published
                            ? `<button type="button" data-withdraw-id="${escapeHTML(item.id)}">Tarik</button>`
                            : `<button type="button" data-publish-id="${escapeHTML(item.id)}">Terbitkan</button>`
                        }
                        <button type="button" class="danger-button" data-delete-id="${escapeHTML(item.id)}">
                            Hapus
                        </button>
                    </div>
                </td>
            </tr>
        `;
    }).join("");

    announcementList.querySelectorAll("[data-edit-id]")
        .forEach(button => {
            button.addEventListener("click", () => {
                startEdit(button.dataset.editId);
            });
        });

    announcementList.querySelectorAll("[data-publish-id]")
        .forEach(button => {
            button.addEventListener("click", () => {
                publishAnnouncement(button.dataset.publishId);
            });
        });

    announcementList.querySelectorAll("[data-withdraw-id]")
        .forEach(button => {
            button.addEventListener("click", () => {
                withdrawAnnouncement(button.dataset.withdrawId);
            });
        });

    announcementList.querySelectorAll("[data-delete-id]")
        .forEach(button => {
            button.addEventListener("click", () => {
                deleteAnnouncement(button.dataset.deleteId);
            });
        });
}

function startEdit(id) {
    const item = announcements.find(announcement => announcement.id === id);
    if (!item) return;

    announcementId.value = item.id;
    announcementTitle.value = item.title || "";
    announcementContent.value = item.content || "";
    formTitle.textContent = "Edit Pengumuman";
    saveDraftButton.textContent = "Simpan Perubahan";
    saveAndPublishButton.textContent =
        item.is_published ? "Simpan & Tetap Terbitkan" : "Simpan & Terbitkan";
    cancelEditButton.hidden = false;
    setMessage("");
    announcementTitle.focus();

    if (window.innerWidth < 1000) {
        document.querySelector(".announcement-panel")
            .scrollIntoView({ behavior: "smooth", block: "start" });
    }
}

async function saveAnnouncement(publish) {
    console.log("[pengumuman] saveAnnouncement dimulai", {
        publish,
        editing: Boolean(announcementId.value)
    });

    if (saveDraftButton.disabled || saveAndPublishButton.disabled) return;

    const id = announcementId.value;
    const title = announcementTitle.value.trim();
    const content = announcementContent.value.trim();

    if (!title) {
        setMessage("Judul pengumuman wajib diisi.");
        announcementTitle.focus();
        return;
    }

    if (!content) {
        setMessage("Isi pengumuman wajib diisi.");
        announcementContent.focus();
        return;
    }

    saveDraftButton.disabled = true;
    saveAndPublishButton.disabled = true;
    cancelEditButton.disabled = true;
    setMessage("Menyimpan pengumuman...");

    const now = new Date().toISOString();
    let savedRecord = null;
    try {
        let result;

        if (id) {
            const existing = announcements.find(item => item.id === id);
            const payload = {
                title,
                content,
                is_published: publish
                    ? true
                    : existing?.is_published === true
                        ? true
                        : false,
                published_at: publish
                    ? (existing?.published_at || now)
                    : existing?.is_published === true
                        ? existing.published_at
                        : null
            };

            console.log("[pengumuman] mengirim query update");
            result = await awaitSupabaseQuery(supabaseClient
                .from("announcements")
                .update(payload)
                .eq("id", id)
                .select("id, title, is_published, published_at")
                .single(), "Penyimpanan pengumuman");
        } else {
            const payload = {
                title,
                content,
                is_published: publish,
                published_at: publish ? now : null,
                created_by: sessionActive.user.id
            };

            console.log("[pengumuman] mengirim query insert");
            result = await awaitSupabaseQuery(supabaseClient
                .from("announcements")
                .insert(payload)
                .select("id, title, is_published, published_at")
                .single(), "Penyimpanan pengumuman");
        }

        console.log("[pengumuman] hasil query simpan", {
            hasData: Boolean(result.data),
            error: result.error
        });

        if (result.error) throw result.error;
        if (!result.data) {
            throw new Error("Supabase tidak mengembalikan baris pengumuman yang disimpan.");
        }
        savedRecord = result.data;
    } catch (error) {
        console.error("[pengumuman] penyimpanan gagal", error);
        setMessage(
            "Gagal menyimpan pengumuman: " +
            (error?.message || String(error))
        );
        return;
    } finally {
        saveDraftButton.disabled = false;
        saveAndPublishButton.disabled = false;
        cancelEditButton.disabled = false;
    }

    resetForm();
    const reloadError = await loadAnnouncements();
    if (reloadError) {
        setMessage(
            "Pengumuman berhasil disimpan, tetapi daftar gagal diperbarui: " +
            (reloadError.message || String(reloadError))
        );
    } else if (!announcements.some(item => item.id === savedRecord.id)) {
        setMessage(
            "Supabase mengonfirmasi penyimpanan, tetapi pengumuman tidak muncul dalam hasil pemuatan daftar."
        );
    } else {
        setMessage(
            publish
                ? "Pengumuman berhasil diterbitkan."
                : "Pengumuman berhasil disimpan.",
            true
        );
    }
}

async function publishAnnouncement(id) {
    const item = announcements.find(announcement => announcement.id === id);
    if (!item) return;

    setMessage("Menerbitkan pengumuman...");
    const payload = {
        is_published: true,
        published_at: item.published_at || new Date().toISOString()
    };

    const { error } = await supabaseClient
        .from("announcements")
        .update(payload)
        .eq("id", id);

    if (error) {
        setMessage("Gagal menerbitkan pengumuman: " + error.message);
        console.error("Gagal menerbitkan announcement:", error);
        return;
    }

    setMessage("Pengumuman berhasil diterbitkan.", true);
    await loadAnnouncements();
}

async function withdrawAnnouncement(id) {
    setMessage("Menarik pengumuman...");

    const { error } = await supabaseClient
        .from("announcements")
        .update({
            is_published: false,
            published_at: null
        })
        .eq("id", id);

    if (error) {
        setMessage("Gagal menarik pengumuman: " + error.message);
        console.error("Gagal menarik announcement:", error);
        return;
    }

    setMessage("Pengumuman berhasil ditarik menjadi draft.", true);
    await loadAnnouncements();
}

async function deleteAnnouncement(id) {
    const item = announcements.find(announcement => announcement.id === id);
    if (!item) return;

    const confirmed = window.confirm(
        `Hapus pengumuman "${item.title || "Tanpa judul"}"? Tindakan ini tidak dapat dibatalkan.`
    );
    if (!confirmed) return;

    setMessage("Menghapus pengumuman...");

    const { error } = await supabaseClient
        .from("announcements")
        .delete()
        .eq("id", id);

    if (error) {
        setMessage("Gagal menghapus pengumuman: " + error.message);
        console.error("Gagal menghapus announcement:", error);
        return;
    }

    if (announcementId.value === id) {
        resetForm();
    }

    setMessage("Pengumuman berhasil dihapus.", true);
    await loadAnnouncements();
}

announcementForm.addEventListener("submit", event => {
    console.log("[pengumuman] event submit form");
    event.preventDefault();
    saveAnnouncement(false);
});

saveDraftButton.addEventListener("click", () => {
    console.log("[pengumuman] event click Simpan sebagai Draft");
    saveAnnouncement(false);
});

saveAndPublishButton.addEventListener("click", () => {
    console.log("[pengumuman] event click Simpan & Terbitkan");
    saveAnnouncement(true);
});

cancelEditButton.addEventListener("click", resetForm);

document.getElementById("adminLogout").addEventListener("click", async () => {
    await signOutAndRedirect();
});

(async () => {
    try {
        const isAdmin = await checkAdmin();
        if (!isAdmin) {
            console.info("[announcements] daftar tidak dimuat; Admin belum terverifikasi");
            return;
        }

        document.body.style.display = "block";
        console.info("[announcements] Admin terverifikasi; memulai query daftar");
        setAnnouncementsDebugStage("load-started");
        await loadAnnouncements();
        if (window.__announcementsDebug.stage !== "error") {
            setAnnouncementsDebugStage("load-finished");
        }
    } catch (error) {
        console.error("[announcements] inisialisasi halaman gagal", {
            name: error?.name || "Error",
            code: error?.code || null
        });
        setAnnouncementsDebugStage("error", error);
        showAdminAccessError(
            "Halaman gagal diinisialisasi. Periksa console lalu muat ulang."
        );
    }
})();
