INSTANA STANDARD EDITION - GCP DEPLOYER v0.2.0
================================================

STATUS
------
Ovo je bezbednosno doradjena PREVIEW verzija za Ubuntu na GCP-u.
Nemoj je prvi put pokretati direktno kao produkcionu instalaciju.
Prvo obavezno pokreni dry-run i pregledaj plan/trosak.

POKRETANJE
----------
1. Instaliraj i prijavi Google Cloud CLI:
   gcloud auth login

2. Pokreni proveru bez kreiranja resursa:
   chmod +x install.sh destroy.sh
   ./install.sh --dry-run

3. Tek nakon pregleda plana:
   ./install.sh

4. Brisanje kreiranih resursa prvo proveri ovako:
   ./destroy.sh --dry-run

PODRZANI IZBORI U MENIJU
------------------------
- single-node ili three-node
- online ili air-gapped
- demo ili production za single-node
- Ubuntu 24.04 ili Ubuntu 22.04
- minimum, preporucena ili rucna velicina
- FQDN, tenant, unit, TLS, GCP region/zona/mreza/subnet
- skriven unos download, sales i agent kljuceva

AIR-GAPPED NAPOMENA
-------------------
Skripta trazi dva lokalna fajla:
- stanctl Debian paket koji odgovara Ubuntu verziji
- instana-airgapped.tar.gz napravljen odgovarajucom stanctl verzijom

Air-gapped arhiva ne mora sadrzati sve Ubuntu OS pakete. Ako dpkg prijavi
nedostajuce zavisnosti, skripta namerno staje. Tada je potreban pripremljen
Ubuntu image ili interni APT mirror. Skripta ne pokusava da zaobidje tu gresku.

BEZBEDNOSNE ZASTITE
-------------------
- nema eval izvrsavanja
- dry-run ne ispisuje tajne
- SSH CIDR se eksplicitno bira; preporuka je javna IP adresa /32
- disk sa postojecim filesystemom se NE formatira
- /etc/fstab unos se ne duplira
- tajni env fajl ima mode 600 i uklanja se nakon stanctl up
- destroy zahteva unos DELETE <project>/<zone>
- stanje ne sadrzi Instana kljuceve niti admin lozinku

VAZNO
-----
- DNS zapisi moraju biti napravljeni kod DNS provajdera. Skripta ih samo ispise.
- Self-signed TLS je pogodan za laboratoriju, ne i za normalnu produkciju.
- GCP SSD diskovi i velike VM masine mogu napraviti znacajan trosak.
- Prvi stvarni test treba uraditi kao single-node + online + demo.
- Multi-node i air-gapped putanje su implementirane, ali nisu potvrđene stvarnim
  deploymentom u ovom paketu.

FAJLOVI
-------
install.sh       Interaktivno kreiranje GCP resursa i Instana instalacija
destroy.sh       Kontrolisano uklanjanje resursa zapisanih u state fajlu
test-dry-run.sh  Lokalni smoke test menija i cetiri kombinacije
REVIEW_v0.2.0.txt Nalazi, ispravke i poznata ogranicenja

