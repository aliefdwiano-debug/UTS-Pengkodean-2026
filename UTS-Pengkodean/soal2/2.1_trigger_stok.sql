-- =====================================================================
-- Soal 2.1 - Otomatisasi mutasi stok via trigger (PostgreSQL / Supabase)
-- Catatan: kolom tabel di bawah mengikuti asumsi jawaban; sesuaikan bila
-- skema di naskah soal berbeda.
-- =====================================================================

CREATE TABLE IF NOT EXISTS inventory_items (
    item_id    VARCHAR(20)  PRIMARY KEY,
    item_name  VARCHAR(100) NOT NULL,
    stock_qty  INT          NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),  -- pertahanan terakhir
    unit_cost  NUMERIC(15, 2) NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS inventory_transactions (
    trx_id    BIGSERIAL PRIMARY KEY,
    item_id   VARCHAR(20) NOT NULL REFERENCES inventory_items (item_id),
    trx_type  VARCHAR(12) NOT NULL CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Asumsi: PURCHASE/SALE -> qty selalu positif (arah ditentukan trx_type).
--         ADJUSTMENT    -> qty boleh positif (tambah) atau negatif (kurang).
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER AS $$
DECLARE
    v_stock INT;
    v_delta INT;
BEGIN
    IF NEW.trx_type IN ('PURCHASE', 'SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty untuk % harus lebih dari 0', NEW.trx_type;
    END IF;

    -- kunci baris barang agar tidak diubah transaksi lain secara bersamaan
    SELECT stock_qty INTO v_stock
      FROM inventory_items
     WHERE item_id = NEW.item_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Barang % tidak ditemukan', NEW.item_id;
    END IF;

    IF NEW.trx_type = 'SALE' THEN
        v_delta := -NEW.qty;
    ELSE
        v_delta := NEW.qty;
    END IF;

    -- b. anti-negative inventory
    IF v_stock + v_delta < 0 THEN
        RAISE EXCEPTION 'Stok % tidak cukup: tersedia %, diminta %',
                        NEW.item_id, v_stock, NEW.qty;
    END IF;

    -- a. perbarui stock_qty
    UPDATE inventory_items
       SET stock_qty = stock_qty + v_delta
     WHERE item_id = NEW.item_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_inventory_transactions_stock ON inventory_transactions;
CREATE TRIGGER trg_inventory_transactions_stock
BEFORE INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION trg_update_stock_and_journal();

-- ---------------------------------------------------------------------
-- Pengujian
-- ---------------------------------------------------------------------
INSERT INTO inventory_items (item_id, item_name, stock_qty, unit_cost)
VALUES ('BRG001', 'Kertas A4', 10, 45000.00)
ON CONFLICT (item_id) DO NOTHING;

INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG001', 'SALE', 4);
SELECT item_id, stock_qty FROM inventory_items WHERE item_id = 'BRG001';  -- harus 6

-- Jalankan baris di bawah SECARA TERPISAH; harus ERROR (stok tidak cukup):
-- INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG001', 'SALE', 10);
