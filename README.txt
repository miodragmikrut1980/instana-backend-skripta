Instana GCP lab v0.5.9 — guided air-gapped package (explain, build or fall back)
CURRENT: read IZMENE_v0.5.9.txt, IZMENE_v0.5.8.txt and IZMENE_v0.5.7.txt first.

The installer now shows a 12-phase checklist, explains every phase before it
changes the VM or GCP project, displays overall completion percentage, and
records completed phases in .install-state.json. Resource validation remains
authoritative: a saved visual checkpoint never bypasses resume verification.

Use ./install.sh for a new deployment. Use ./install.sh --resume in the same
deployment folder when the selected topology supports continuation.
Started without options from a terminal, install.sh shows a start menu:
install / dry-run / resume (if a deployment is recorded) / destroy preview /
destroy / exit. ./install.sh --destroy (optionally with --dry-run) runs the
cleanup directly; destroy.sh still exists but need not be called by hand.
Legacy v0.3.x resources are not adopted. Uncertain stanctl up execution
requires inspection; never starts a second remote installer blindly.

Na upravljackoj Ubuntu VM v NOVEM folderu:
chmod +x *.sh
./install.sh --dry-run
Po pregleda plana stvarno pokretanje: ./install.sh

Izaberi three-node, online, SMALL, Ubuntu 24.04 ili 22.04.
Koristi tri NOVA VM naziva i NOVI domen, npr. instana-lab.mikrut.rs.
Postojeci single-node DNS ne menjati. Novi domen, UI i acceptore usmeri na
external IP node0. DNS nije automatizovan. Instana production install type
je obavezan za multi, ali ovo je interno LAB okruzenje.

IBM small minimum: 12 CPU/48 GB po nodu. GCP mapping: n2-standard-16
(16 CPU/64 GB po nodu), ukupno 48 CPU/192 GB. Boot SSD270 GB po nodu;
objects1000 na node0, data500/metrics1000/analytics1200 na node1.
Ukupno provisioned4510 GB. Fizicka izolacija i sustained I/O nisu
sertifikovani; ne predstavlja produkcionu preporuku.

Posebni firewall/tag za ovaj deployment; CPU flags; OS bootstrap; kernel;
boot ID provera restarta; root SSH node0->sva tri privateIP; UFW; blank disk
format/mount; stanctl na node0; multi IP redosled backend/datastore/other;
provera 3 Ready nodes. Pod check je nasledjen osnovni, ne kompletan health.
Na novim multi VM OS Login je iskljucen radi root key SSH. Ako je to
zabranjeno organizacionom politikom, STOP; ne zaobilaziti politiku.

Pamti parametre mode600 bez tajni. Svaki deployment u zasebnom folderu.
State belezi resurse/checkpoints, ali MULTINODE RESUME NIJE implementiran.
Posle greske ne pokretati naslepo ponovo; sacuvati log/state za pregled.
destroy.sh cita state iz istog foldera; brise trajno uz eksplicitnu potvrdu.

Air-gapped (v0.5.9): kad izaberes air-gapped, skripta objasni sta je paket
(instana-airgapped.tar.gz, pravi ga 'stanctl air-gapped package' na masini sa
internetom, sadrzi i stanctl binarni fajl, vise desetina GB) i ponudi meni:
1) postojeca arhiva na ovoj masini, 2) napravi paket sada OVDE (skripta sama
instalira stanctl iz Instana APT repoa i pokrene pakovanje; treba internet,
sudo, ~40 GB), 3) predji na online instalaciju, 4) otkazi. Verzije se citaju
iz arhive i prikazuju u planu. Air-gapped tok je POTVRDJEN stvarnim
deploymentom 18.09.2026 (single-node demo, paket napravljen opcijom 2 na
upravljackoj VM, stanctl 1.15.0 / backend 3.323.470-0, svih 12 faza).
Resume za air-gapped i dalje nije podrzan.

Single-node kernel skip jos ostaje iz working kopije i nije genericki
installer za novu single VM.
Stari v0.2.2 tekst opisuje prethodni release, ovaj README ima prednost.

Testovi: bash syntax, 4 mock dry-run toka, config persistence tests,
test-input-reask.sh (ponovno pitanje umesto prekida).
Stvarni GCP deploy NIJE testiran. IBM docs PDF145–154 i169–172;
stanctl flags pregledani iz dostavljenog source. Confidential IBM source
i PDF se NE distribuiraju u ZIP-u.
