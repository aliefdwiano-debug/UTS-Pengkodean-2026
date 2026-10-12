-- =====================================================================
-- Soal 2.2 - Race condition pada penjualan stok terakhir
-- Skenario: stok BRG001 = 1, kasir A dan kasir B menjual bersamaan.
-- Butuh tabel dari 2.1_trigger_stok.sql.
-- =====================================================================

-- Siapkan stok 1 unit
UPDATE inventory_items SET stock_qty = 1 WHERE item_id = 'BRG001';

-- ---------------------------------------------------------------------
-- Solusi 1: SELECT ... FOR UPDATE (pessimistic locking)
-- Buka DUA tab SQL Editor. Tab A jalankan sampai SELECT (jangan COMMIT dulu),
-- lalu tab B jalankan SELECT yang sama -> B menunggu sampai A COMMIT.
-- ---------------------------------------------------------------------
-- BEGIN;
-- SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG001' FOR UPDATE;
-- INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG001', 'SALE', 1);
-- COMMIT;
-- Setelah A commit, B melihat stok = 0 dan trigger 2.1 menolak: "Stok tidak cukup".

-- ---------------------------------------------------------------------
-- Solusi 2: isolation level SERIALIZABLE (aplikasi harus retry saat error 40001)
-- ---------------------------------------------------------------------
-- BEGIN ISOLATION LEVEL SERIALIZABLE;
-- SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG001';
-- INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG001', 'SALE', 1);
-- COMMIT;   -- salah satu transaksi gagal: could not serialize access ...

-- ---------------------------------------------------------------------
-- Solusi 3: update atomik bersyarat (cek + kurangi dalam satu perintah)
-- ---------------------------------------------------------------------
UPDATE inventory_items
   SET stock_qty = stock_qty - 1
 WHERE item_id = 'BRG001'
   AND stock_qty >= 1;     -- 0 baris terpengaruh = stok habis

-- Pertahanan terakhir: CHECK (stock_qty >= 0) sudah ada pada inventory_items (lihat 2.1).
