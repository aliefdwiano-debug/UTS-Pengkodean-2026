-- =====================================================================
-- Soal 3.2 - Audit trail & immutability jurnal (PostgreSQL / Supabase)
-- Prasyarat: tabel chart_of_accounts, journal_headers, journal_lines (Soal 1)
-- sudah dibuat, beserta fn_check_balanced() dan trigger penyeimbangnya.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- a. Kolom audit pada header
ALTER TABLE journal_headers
    ADD COLUMN IF NOT EXISTS created_by    UUID DEFAULT auth.uid(),
    ADD COLUMN IF NOT EXISTS created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS hash_checksum TEXT,
    ADD COLUMN IF NOT EXISTS prev_hash     TEXT,
    ADD COLUMN IF NOT EXISTS reversal_of   BIGINT REFERENCES journal_headers (header_id) ON DELETE RESTRICT;

-- b. Penghitung hash (SHA-256). COALESCE pada created_by penting: di SQL Editor
--    auth.uid() bernilai NULL dan tanpa COALESCE seluruh hash menjadi NULL.
CREATE OR REPLACE FUNCTION fn_calc_hash(p_header_id BIGINT, p_prev TEXT)
RETURNS TEXT AS $$
    SELECT encode(digest(
        h.ref_no || '|' || h.trx_date::text || '|' || COALESCE(h.description, '') || '|'
        || COALESCE(h.created_by::text, '') || '|' || h.created_at::text || '|'
        || COALESCE((SELECT string_agg(l.account_id || ':' || l.debit || ':' || l.credit, ','
                                       ORDER BY l.line_id)
                       FROM journal_lines l WHERE l.header_id = h.header_id), '')
        || '|' || COALESCE(p_prev, ''),
        'sha256'), 'hex')
    FROM journal_headers h
    WHERE h.header_id = p_header_id;
$$ LANGUAGE sql
SET search_path = public, extensions;

-- c. Trigger penolak perubahan pada jurnal POSTED
CREATE OR REPLACE FUNCTION trg_block_posted_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF TG_TABLE_NAME = 'journal_headers' THEN
        v_status := OLD.posting_status;
    ELSE
        SELECT posting_status INTO v_status FROM journal_headers
         WHERE header_id = CASE WHEN TG_OP = 'INSERT' THEN NEW.header_id ELSE OLD.header_id END;
    END IF;

    IF v_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal berstatus POSTED tidak boleh di-%. Gunakan jurnal pembalik (reversing entry).', TG_OP;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_headers_immutable ON journal_headers;
CREATE TRIGGER trg_headers_immutable
BEFORE UPDATE OR DELETE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION trg_block_posted_changes();

DROP TRIGGER IF EXISTS trg_lines_immutable ON journal_lines;
CREATE TRIGGER trg_lines_immutable
BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
FOR EACH ROW EXECUTE FUNCTION trg_block_posted_changes();

-- Lapisan tambahan: cabut hak ubah/hapus dari role aplikasi
REVOKE UPDATE, DELETE ON journal_headers, journal_lines FROM anon, authenticated;

-- d. Posting jurnal DRAFT: cek seimbang, isi hash, ubah status
CREATE OR REPLACE FUNCTION post_journal(p_header_id BIGINT)
RETURNS VOID AS $$
DECLARE
    v_prev   TEXT;
    v_debit  NUMERIC;
    v_credit NUMERIC;
BEGIN
    SELECT SUM(debit), SUM(credit) INTO v_debit, v_credit
      FROM journal_lines WHERE header_id = p_header_id;
    IF v_debit IS NULL OR v_debit <> v_credit THEN
        RAISE EXCEPTION 'Jurnal tidak seimbang, tidak dapat diposting';
    END IF;

    SELECT hash_checksum INTO v_prev FROM journal_headers
     WHERE posting_status = 'POSTED' ORDER BY header_id DESC LIMIT 1;

    UPDATE journal_headers
       SET prev_hash      = v_prev,
           hash_checksum  = fn_calc_hash(p_header_id, v_prev),
           posting_status = 'POSTED'
     WHERE header_id = p_header_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions;

-- Jurnal pembalik (storno): debit/kredit ditukar, jurnal asal tidak diubah
CREATE OR REPLACE FUNCTION reverse_journal(p_header_id BIGINT, p_reason TEXT)
RETURNS BIGINT AS $$
DECLARE
    v_old journal_headers%ROWTYPE;
    v_new BIGINT;
BEGIN
    SELECT * INTO v_old FROM journal_headers WHERE header_id = p_header_id;
    IF v_old.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik';
    END IF;
    IF EXISTS (SELECT 1 FROM journal_headers WHERE reversal_of = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal ini sudah pernah dibalik';
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description, posting_status, reversal_of)
    VALUES (CURRENT_DATE, 'REV-' || v_old.ref_no,
            'Pembalik ' || v_old.ref_no || ': ' || p_reason, 'DRAFT', p_header_id)
    RETURNING header_id INTO v_new;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_new, account_id, credit, debit
      FROM journal_lines WHERE header_id = p_header_id;

    PERFORM post_journal(v_new);
    RETURN v_new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions;

-- e. Verifikasi integritas (hasil kosong = tidak ada data yang diubah)
-- SELECT header_id, ref_no FROM journal_headers
--  WHERE posting_status = 'POSTED'
--    AND hash_checksum IS DISTINCT FROM fn_calc_hash(header_id, prev_hash);

-- ---------------------------------------------------------------------
-- Pengujian (butuh akun 5-2100 dan 1-1100 dari data contoh Soal 1)
-- ---------------------------------------------------------------------
WITH h AS (
    INSERT INTO journal_headers (trx_date, ref_no, description)
    VALUES (CURRENT_DATE, 'KK-AUDIT-01', 'Uji audit trail')
    RETURNING header_id
)
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT h.header_id, (SELECT account_id FROM chart_of_accounts WHERE account_code = '5-2100'), 250000, 0 FROM h
UNION ALL
SELECT h.header_id, (SELECT account_id FROM chart_of_accounts WHERE account_code = '1-1100'), 0, 250000 FROM h;

SELECT post_journal((SELECT header_id FROM journal_headers WHERE ref_no = 'KK-AUDIT-01'));

SELECT header_id, ref_no, posting_status, hash_checksum FROM journal_headers WHERE ref_no = 'KK-AUDIT-01';

-- Jalankan SATU PER SATU; semuanya harus ERROR (jurnal POSTED terkunci):
-- UPDATE journal_headers SET description = 'diubah' WHERE ref_no = 'KK-AUDIT-01';
-- DELETE FROM journal_headers WHERE ref_no = 'KK-AUDIT-01';
-- UPDATE journal_lines SET debit = 1 WHERE header_id = (SELECT header_id FROM journal_headers WHERE ref_no = 'KK-AUDIT-01');

-- Koreksi yang benar = jurnal pembalik:
-- SELECT reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no = 'KK-AUDIT-01'), 'Salah akun beban');
