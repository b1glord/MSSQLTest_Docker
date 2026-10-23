<!--
Dosya Yolu: REPO_ROOT/README.md
Amac: MSSQL 2022 test Docker paketinin guvenli kurulum ve bakimini aciklar
Modul - Markdown
Version: 2.0.1
Aciklama: Tek PowerShell yoneticisi, secrets ayrimi ve veri korunumu
Bagimli Oldugu Katman: Documentation
-->

# MSSQLTest Docker

Docker Desktop uzerinde **Microsoft SQL Server 2022 Developer** test ortami. Tek yonetim dosyasi: **`MSSQL.ps1`**.

> Uyari: Bu paket test/gelistirme ortami icindir. Production ortamina oldugu gibi tasimayin. `ResetAll` tum named-volume verilerini silebilir.

## Gereksinimler

- Windows 10/11 + PowerShell 5.1 veya PowerShell 7
- Docker Desktop (Linux containers modunda) ve `docker compose` v2
- Test ortami icin yeterli disk alani ve RAM

## Ilk kurulum

1. Repoyu klonlayin veya ZIP olarak indirin ve Docker Desktop'i calistirin.
2. PowerShell'de repo klasorune gecin:

```powershell
cd .\MSSQLTest_Docker
.\MSSQL.ps1
```

3. Menuden **1 - Baslat / ilk kurulum** secin. Mevcut container/volume yoksa SA sifresi gizli olarak sorulur; `.env` uretilir ve SQL Server baslar.
4. Saglik ve baglanti kontrolu icin menuden **4 (Durum)** ve **5 (Test)** secin.

Komut satiri ile:

```powershell
.\MSSQL.ps1 -Action Start
.\MSSQL.ps1 -Action Status
.\MSSQL.ps1 -Action Test
```

> Daha once `mssql-test` container'i veya `mssql-test-data` volume'u varsa betik yeni sifreyle eski veriyi acmaya calismaz. Eski `.env` dosyanizi geri getirin. Mevcut `.env` ve compose dosyalari uzerine yazilmaz. `.env.example` sadece referanstir.

## Baglanti

- Host: `localhost`
- Port: `.env` icindeki `MSSQL_PORT` (varsayilan `1433`)
- Kullanici: `sa`
- Sifre: ilk kurulumda sizin belirlediginiz yerel `.env` parolasi
- HeidiSQL / SSMS: gerekirse **Trust server certificate** secenegini etkinlestirin.

Bu repodaki `docker-compose.yml` guvenlik icin host portunu **127.0.0.1** adresinde acar. Uzak erisim varsayilan olarak kapali. Eskiden uzaktan baglaniyorsaniz mevcut compose dosyanizi degistirmeden once yedekleyin.

## Backup / Restore

Backup dosyasini repo kokundeki `backup/` klasorune kopyalayin (Git'e dahil edilmez).

```powershell
.\MSSQL.ps1 -Action CheckBackup -BackupFile 'logodb.bck'
.\MSSQL.ps1 -Action Restore -BackupFile 'logodb.bck' -DatabaseName 'LOGODB'
```

**Var olan veritabanina restore** icin `-ForceReplace` ve terminalde ayrica `USTUNE YAZ` onayi gerekir:

```powershell
.\MSSQL.ps1 -Action Restore -BackupFile 'logodb.bck' -DatabaseName 'LOGODB' -ForceReplace
```

Diger islemler: `Stop`, `Restart`, `Down` (volume korunur), `ResetContainer` (volume korunur), `ListDatabases`, `Logs`, `ResetAll` (verileri siler, ayrica `SIL` onayi ister).

## Veri ve gizlilik

- **`.env` repoya eklenmez**. SA sifresi sadece lokal dosyadadir.
- **`backup/` repoya eklenmez**. SQL backup, log ve DB veri dosyalari dislanir.
- SQL Server data, `mssql-test-data` adli Docker named volume'unda saklanir.
- Yerel `.env` dosyasinda sifre acik metin bulunur; paylasmayin.
- `ResetAll`, Docker volume'unu kaldirir; once bagimsiz bir backup alin.

## Standartlar ve test

Proje, [BURAK DEV STANDARD](https://github.com/TurkuazSoft/DevStandards) v3.0.0 temel ilkelerini izler. CI, PowerShell parser'i ve Docker Compose konfigurasyonunu statik olarak denetler. **Canli SQL entegrasyon ve restore testini dogrulamaz**; bunlar Windows + Docker Desktop uzerinde ayrica denenmelidir.
