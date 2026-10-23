<!--
Dosya Yolu: REPO_ROOT/AGENTS.md
Amac: Proje gelistirmeleri icin ozel AI talimatlari
Modul - Markdown
Version: 2.0.1
Aciklama: Veri guvenligi ve Docker yonetim semantigi
Bagimli Oldugu Katman: Documentation
-->

# MSSQLTest_Docker AI Gelistirme Kurallari

Bu repo [BURAK DEV STANDARD](https://github.com/TurkuazSoft/DevStandards) v3.0.0 ve dogrulanmis daha guncel surumlerini izler.

- Once repo durumu, mevcut betik, PR ve CI incelenir.
- Uygulama akisinin tek giris noktasi `MSSQL.ps1` olarak korunur; eski kucuk scriptleri geri eklemeyin.
- `.env`, gercek sifreler, backup dosyalari, SQL data ve loglar repo/CI artifact'a eklenmez.
- Test ve production ortamlari ayridir; `ResetAll` ve `Restore -ForceReplace` acik kullanici onayi gerektirir.
- Mevcut named volume ve calisan container yapisi beklenmedik bicimde silinmez veya yeniden adlandirilmaz.
- Path'ler `$PSScriptRoot` ve `Join-Path` ile cozulur, gelistiriciye ozel disk yolu gomulmez.
- CI parser/config testleri canli Windows Docker/restore testi olarak sunulmaz.
