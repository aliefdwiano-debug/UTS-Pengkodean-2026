-- =====================================================================
-- Soal 1.2 - Kekangan integritas (DDL PostgreSQL / Supabase)
-- Tabel: chart_of_accounts, journal_headers, journal_lines
-- Jalankan lebih dulu sebelum soal2/ dan soal3/3.2_audit_trail.sql
-- (data contoh akun di bagian bawah dipakai oleh pengujian 3.2).
-- =====================================================================

-- 1) Daftar akun
CREATE TABLE chart_of_accounts (
    account_id     SERIAL PRIMARY KEY,
    account_code   VARCHAR(10)  NOT NULL UNIQUE,
    account_name   VARCHAR(100) NOT NULL,
    normal_balance CHAR(1)      NOT NULL CHECK (normal_balance IN ('D', 'K')),
    report_class   VARCHAR(10)  NOT NULL CHECK (report_class IN ('NERACA', 'LABA_RUGI'))
);

-- 2) Header jurnal
CREATE TABLE journal_headers (
    header_id      BIGSERIAL PRIMARY KEY,
    trx_date       DATE         NOT NULL,
    ref_no         VARCHAR(30)  NOT NULL UNIQUE,
    description    TEXT,
    posting_status VARCHAR(10)  NOT NULL DEFAULT 'DRAFT'
                   CHECK (posting_status IN ('DRAFT', 'POSTED', 'REVERSED'))
);

-- 3) Baris jurnal
CREATE TABLE journal_lines (
    line_id    BIGSERIAL PRIMARY KEY,
    header_id  BIGINT NOT NULL
               REFERENCES journal_headers (header_id) ON DELETE RESTRICT,
    account_id INT NOT NULL
               REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT,
    debit      NUMERIC(15, 2) NOT NULL DEFAULT 0,
    credit     NUMERIC(15, 2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_debit_nonneg  CHECK (debit  >= 0),
    CONSTRAINT chk_credit_nonneg CHECK (credit >= 0),
    CONSTRAINT chk_not_both_zero CHECK (NOT (debit = 0 AND credit = 0))
);

CREATE INDEX idx_lines_header  ON journal_lines (header_id);
CREATE INDEX idx_lines_account ON journal_lines (account_id);

-- 4) Penegak asas berpasangan (Total Debit = Total Kredit per jurnal).
--    Constraint trigger ditunda sampai COMMIT, jadi semua baris boleh
--    dimasukkan dulu baru dicek.
CREATE OR REPLACE FUNCTION fn_check_balanced() RETURNS TRIGGER AS $$
DECLARE
    v_debit  NUMERIC(17, 2);
    v_credit NUMERIC(17, 2);
BEGIN
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
      INTO v_debit, v_credit
      FROM journal_lines
     WHERE header_id = NEW.header_id;

    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Jurnal % tidak seimbang: debit % <> kredit %',
                        NEW.header_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_journal_balanced
AFTER INSERT OR UPDATE ON journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_check_balanced();

-- ---------------------------------------------------------------------
-- Data contoh
-- ---------------------------------------------------------------------
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class) VALUES
    ('1-1100', 'Kas',           'D', 'NERACA'),
    ('2-1100', 'Utang Usaha',   'K', 'NERACA'),
    ('5-2100', 'Beban Listrik', 'D', 'LABA_RUGI');

WITH h AS (
    INSERT INTO journal_headers (trx_date, ref_no, description, posting_status)
    VALUES ('2026-10-12', 'KK-001', 'Bayar listrik bulan Oktober', 'DRAFT')
    RETURNING header_id
)
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT h.header_id, (SELECT account_id FROM chart_of_accounts WHERE account_code = '5-2100'), 500000, 0 FROM h
UNION ALL
SELECT h.header_id, (SELECT account_id FROM chart_of_accounts WHERE account_code = '1-1100'), 0, 500000 FROM h;

-- Cek hasil
SELECT h.ref_no, h.trx_date, a.account_code, a.account_name, l.debit, l.credit
  FROM journal_lines l
  JOIN journal_headers h ON h.header_id = l.header_id
  JOIN chart_of_accounts a ON a.account_id = l.account_id
 ORDER BY h.header_id, l.line_id;

-- ---------------------------------------------------------------------
-- Uji constraint (jalankan SATU PER SATU; semuanya harus ERROR)
-- ---------------------------------------------------------------------
-- a) Debit negatif -> melanggar chk_debit_nonneg
--    INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (1, 1, -100, 0);
-- b) Debit dan kredit sama-sama 0 -> melanggar chk_not_both_zero
--    INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (1, 1, 0, 0);
-- c) Hapus header yang sudah punya baris -> ditolak ON DELETE RESTRICT
--    DELETE FROM journal_headers WHERE header_id = 1;
-- d) Jurnal tidak seimbang -> ditolak trigger saat commit
--    WITH h AS (
--        INSERT INTO journal_headers (trx_date, ref_no) VALUES ('2026-10-12', 'KK-002')
--        RETURNING header_id
--    )
--    INSERT INTO journal_lines (header_id, account_id, debit, credit)
--    SELECT h.header_id, 3, 100000, 0 FROM h
--    UNION ALL
--    SELECT h.header_id, 1, 0, 90000 FROM h;
